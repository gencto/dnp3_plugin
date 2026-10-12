//! Shared infrastructure: message kinds, error codes, handle registry, runtime and the
//! request/reply mechanism used for callbacks that need an answer from Dart.

use std::cell::RefCell;
use std::collections::HashMap;
use std::ffi::{c_char, CString};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, LazyLock, Mutex, RwLock};
use std::time::Duration;

use crate::dart::{post, DartPort, Payload};

/// Version of the binary/C ABI. Dart refuses to work with a library whose version differs.
pub const ABI_VERSION: i64 = 1;

/// Message kinds posted to Dart ports. Mirrored in `lib/src/native/protocol.dart`.
pub mod msg {
    pub const RESULT: i64 = 1;
    pub const LOG: i64 = 2;
    pub const CLIENT_STATE: i64 = 10;
    pub const PORT_STATE: i64 = 11;
    pub const CONNECTION_STATE: i64 = 12;
    pub const CONNECTION_EVENT: i64 = 13;
    pub const MEASUREMENTS: i64 = 20;
    pub const ASSOCIATION_INFO: i64 = 21;
    pub const FILE_READ: i64 = 22;
    pub const CONTROL_REQUEST: i64 = 30;
    pub const APPLICATION_REQUEST: i64 = 31;
    pub const OUTSTATION_INFO: i64 = 32;
    pub const OUTSTATION_EVENT: i64 = 33;
    pub const MASTER_SERVER_REQUEST: i64 = 40;
}

/// Error codes. 0 is success. Mirrored in `lib/src/native/protocol.dart`.
pub mod err {
    pub const OK: i64 = 0;
    pub const NOT_INITIALIZED: i64 = 1;
    pub const INVALID_HANDLE: i64 = 2;
    pub const INVALID_ARGUMENT: i64 = 3;
    pub const BAD_CONFIG: i64 = 4;
    pub const SHUTDOWN: i64 = 5;
    pub const IO: i64 = 6;
    pub const TLS: i64 = 7;
    pub const NOT_SUPPORTED: i64 = 8;
    pub const PANIC: i64 = 9;
    pub const ASSOCIATION: i64 = 10;
    pub const TASK: i64 = 11;
    pub const COMMAND: i64 = 12;
    pub const TIME_SYNC: i64 = 13;
    pub const WRITE: i64 = 14;
    pub const POLL: i64 = 15;
    pub const FILE: i64 = 16;
    pub const FILTER: i64 = 17;
    pub const BUFFER_TOO_SMALL: i64 = 18;
    pub const ATTR: i64 = 19;
}

#[derive(Debug, Clone)]
pub struct Error {
    pub code: i64,
    /// optional sub-code, e.g. a `CommandStatus` or `TaskError` discriminant
    pub sub: i64,
    pub message: String,
}

impl Error {
    pub fn new(code: i64, message: impl Into<String>) -> Self {
        Self {
            code,
            sub: 0,
            message: message.into(),
        }
    }

    pub fn with_sub(code: i64, sub: i64, message: impl Into<String>) -> Self {
        Self {
            code,
            sub,
            message: message.into(),
        }
    }

    pub fn invalid_handle(id: u64) -> Self {
        Self::new(
            err::INVALID_HANDLE,
            format!("invalid or destroyed handle: {id}"),
        )
    }

    pub fn arg(message: impl Into<String>) -> Self {
        Self::new(err::INVALID_ARGUMENT, message)
    }

    pub fn config(message: impl Into<String>) -> Self {
        Self::new(err::BAD_CONFIG, message)
    }
}

impl From<dnp3::app::Shutdown> for Error {
    fn from(_: dnp3::app::Shutdown) -> Self {
        Error::new(err::SHUTDOWN, "the channel has been shut down")
    }
}

impl From<serde_json::Error> for Error {
    fn from(e: serde_json::Error) -> Self {
        Error::config(format!("invalid JSON configuration: {e}"))
    }
}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Error::new(err::IO, e.to_string())
    }
}

pub type Result<T> = std::result::Result<T, Error>;

// ---------------------------------------------------------------------------------------
// last error (thread local) for synchronous calls
// ---------------------------------------------------------------------------------------

thread_local! {
    static LAST_ERROR: RefCell<Option<CString>> = const { RefCell::new(None) };
}

pub fn set_last_error(e: &Error) {
    let text = e.message.replace('\0', " ");
    LAST_ERROR.with(|cell| *cell.borrow_mut() = CString::new(text).ok());
}

/// Pointer to the last error message produced on the calling thread (or null). Valid until
/// the next failing call on the same thread.
pub fn last_error_ptr() -> *const c_char {
    LAST_ERROR.with(|cell| match &*cell.borrow() {
        Some(s) => s.as_ptr(),
        None => std::ptr::null(),
    })
}

/// Convert a result of a synchronous operation into a C return value: the non-negative value
/// on success, `-code` on failure (with the message stored as last error).
pub fn to_ret(res: Result<i64>) -> i64 {
    match res {
        Ok(x) => x,
        Err(e) => {
            set_last_error(&e);
            -e.code
        }
    }
}

/// Run `f` and convert panics into an error code so that unwinding never crosses the FFI
/// boundary.
pub fn guard<F: FnOnce() -> Result<i64> + std::panic::UnwindSafe>(f: F) -> i64 {
    match std::panic::catch_unwind(f) {
        Ok(r) => to_ret(r),
        Err(p) => {
            let msg = panic_message(&p);
            set_last_error(&Error::new(err::PANIC, msg));
            -err::PANIC
        }
    }
}

fn panic_message(p: &Box<dyn std::any::Any + Send>) -> String {
    if let Some(s) = p.downcast_ref::<&str>() {
        format!("panic: {s}")
    } else if let Some(s) = p.downcast_ref::<String>() {
        format!("panic: {s}")
    } else {
        "panic in native code".to_string()
    }
}

// ---------------------------------------------------------------------------------------
// async results
// ---------------------------------------------------------------------------------------

/// Destination for the completion of an asynchronous operation
#[derive(Copy, Clone, Debug)]
pub struct Completion {
    pub port: DartPort,
    pub request: i64,
}

impl Completion {
    pub fn new(port: DartPort, request: i64) -> Self {
        Self { port, request }
    }

    pub fn ok(self, payload: impl Into<Payload>) {
        post(
            self.port,
            msg::RESULT,
            self.request,
            err::OK,
            payload.into(),
        );
    }

    pub fn fail(self, e: Error) {
        // error results carry: b = error code, payload = "sub|message"
        post(
            self.port,
            msg::RESULT,
            self.request,
            e.code,
            Payload::Str(format!("{}|{}", e.sub, e.message)),
        );
    }

    pub fn complete<T: Into<Payload>>(self, res: Result<T>) {
        match res {
            Ok(x) => self.ok(x),
            Err(e) => self.fail(e),
        }
    }
}

// ---------------------------------------------------------------------------------------
// runtime
// ---------------------------------------------------------------------------------------

static RUNTIME: RwLock<Option<Arc<tokio::runtime::Runtime>>> = RwLock::new(None);

pub fn start_runtime(threads: u32) -> Result<i64> {
    let mut guard = RUNTIME.write().unwrap();
    if guard.is_some() {
        return Ok(0);
    }
    let mut builder = tokio::runtime::Builder::new_multi_thread();
    builder.enable_all().thread_name("dnp3-worker");
    if threads > 0 {
        builder.worker_threads(threads as usize);
    }
    let rt = builder
        .build()
        .map_err(|e| Error::new(err::IO, format!("unable to create runtime: {e}")))?;
    *guard = Some(Arc::new(rt));
    Ok(1)
}

pub fn runtime() -> Result<Arc<tokio::runtime::Runtime>> {
    RUNTIME
        .read()
        .unwrap()
        .clone()
        .ok_or_else(|| Error::new(err::NOT_INITIALIZED, "runtime not started"))
}

/// Shut down the runtime, dropping every object in the registry first
pub fn shutdown_runtime(timeout_ms: u64) {
    clear_registry();
    let rt = RUNTIME.write().unwrap().take();
    if let Some(rt) = rt {
        match Arc::try_unwrap(rt) {
            Ok(rt) => rt.shutdown_timeout(Duration::from_millis(timeout_ms)),
            Err(rt) => {
                // still referenced by an in-flight operation; it will be dropped there
                drop(rt);
            }
        }
    }
}

/// Spawn a future on the runtime
pub fn spawn<F>(future: F) -> Result<()>
where
    F: std::future::Future<Output = ()> + Send + 'static,
{
    let rt = runtime()?;
    rt.spawn(future);
    Ok(())
}

/// Spawn an async operation whose result is posted to Dart
pub fn spawn_op<F, T>(completion: Completion, future: F) -> Result<i64>
where
    F: std::future::Future<Output = Result<T>> + Send + 'static,
    T: Into<Payload>,
{
    spawn(async move {
        let res = future.await;
        completion.complete(res);
    })?;
    Ok(0)
}

/// Run `f` inside the runtime context (needed for the `spawn_*` functions of the library)
pub fn enter<R>(f: impl FnOnce() -> R) -> Result<R> {
    let rt = runtime()?;
    let _guard = rt.enter();
    Ok(f())
}

// ---------------------------------------------------------------------------------------
// handle registry
// ---------------------------------------------------------------------------------------

static NEXT_ID: AtomicU64 = AtomicU64::new(1);

pub fn next_id() -> u64 {
    NEXT_ID.fetch_add(1, Ordering::Relaxed)
}

/// A typed map from opaque 64-bit handles to native objects. Handles are plain integers and
/// can therefore be shared between Dart isolates.
pub struct Registry<T> {
    map: RwLock<HashMap<u64, T, IdBuildHasher>>,
}

/// Handles are sequential integers generated by us: a multiplicative hash is plenty.
#[derive(Default)]
pub struct IdHasher(u64);

impl std::hash::Hasher for IdHasher {
    fn finish(&self) -> u64 {
        self.0
    }

    fn write(&mut self, bytes: &[u8]) {
        for b in bytes {
            self.0 = (self.0 ^ *b as u64).wrapping_mul(0x100000001b3);
        }
    }

    fn write_u64(&mut self, i: u64) {
        self.0 = i.wrapping_mul(0x9E37_79B9_7F4A_7C15);
    }
}

pub type IdBuildHasher = std::hash::BuildHasherDefault<IdHasher>;

impl<T: Clone> Default for Registry<T> {
    fn default() -> Self {
        Self::new()
    }
}

impl<T: Clone> Registry<T> {
    pub const fn new() -> Self {
        Self {
            map: RwLock::new(HashMap::with_hasher(std::hash::BuildHasherDefault::new())),
        }
    }

    pub fn insert(&self, value: T) -> u64 {
        let id = next_id();
        self.map.write().unwrap().insert(id, value);
        id
    }

    pub fn insert_with_id(&self, id: u64, value: T) {
        self.map.write().unwrap().insert(id, value);
    }

    pub fn get(&self, id: u64) -> Result<T> {
        self.map
            .read()
            .unwrap()
            .get(&id)
            .cloned()
            .ok_or_else(|| Error::invalid_handle(id))
    }

    pub fn with<R>(&self, id: u64, f: impl FnOnce(&T) -> R) -> Result<R> {
        let guard = self.map.read().unwrap();
        let value = guard.get(&id).ok_or_else(|| Error::invalid_handle(id))?;
        Ok(f(value))
    }

    pub fn remove(&self, id: u64) -> Option<T> {
        self.map.write().unwrap().remove(&id)
    }

    pub fn clear(&self) {
        self.map.write().unwrap().clear();
    }

    pub fn len(&self) -> usize {
        self.map.read().unwrap().len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

// The registries live in their respective modules; this hook clears all of them.
fn clear_registry() {
    crate::master::clear();
    crate::outstation::clear();
    crate::master_server::clear();
    PENDING.lock().unwrap().clear();
}

// ---------------------------------------------------------------------------------------
// request / reply (callbacks that need an answer from Dart)
// ---------------------------------------------------------------------------------------

#[derive(Debug, Default, Clone)]
pub struct Reply {
    pub status: i64,
    pub data: Vec<u8>,
}

enum Waiter {
    Sync(std::sync::mpsc::SyncSender<Reply>),
    Async(tokio::sync::oneshot::Sender<Reply>),
}

static PENDING: LazyLock<Mutex<HashMap<u64, Waiter>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// Deliver a reply from Dart. Returns false if the token is unknown (e.g. timed out).
pub fn deliver_reply(token: u64, reply: Reply) -> bool {
    let waiter = PENDING.lock().unwrap().remove(&token);
    match waiter {
        Some(Waiter::Sync(tx)) => tx.try_send(reply).is_ok(),
        Some(Waiter::Async(tx)) => tx.send(reply).is_ok(),
        None => false,
    }
}

/// Post a request to Dart and block the current runtime worker until Dart replies or the
/// timeout elapses. Used for callbacks of the library that are synchronous by design
/// (e.g. outstation control operations).
///
/// The worker thread is handed over to the runtime with `block_in_place`, so other tasks
/// keep running while we wait.
pub fn request_sync(
    port: DartPort,
    kind: i64,
    id: i64,
    payload: Vec<u8>,
    timeout: Duration,
) -> Option<Reply> {
    let token = next_id();
    let (tx, rx) = std::sync::mpsc::sync_channel(1);
    PENDING.lock().unwrap().insert(token, Waiter::Sync(tx));

    if !post(port, kind, token as i64, id, Payload::CopiedBytes(payload)) {
        PENDING.lock().unwrap().remove(&token);
        return None;
    }

    let wait = || rx.recv_timeout(timeout).ok();
    let result = match tokio::runtime::Handle::try_current() {
        Ok(handle) if handle.runtime_flavor() == tokio::runtime::RuntimeFlavor::MultiThread => {
            tokio::task::block_in_place(wait)
        }
        _ => wait(),
    };

    if result.is_none() {
        PENDING.lock().unwrap().remove(&token);
    }
    result
}

/// Post a request to Dart and asynchronously wait for the reply
pub async fn request_async(
    port: DartPort,
    kind: i64,
    id: i64,
    payload: Vec<u8>,
    timeout: Duration,
) -> Option<Reply> {
    let token = next_id();
    let (tx, rx) = tokio::sync::oneshot::channel();
    PENDING.lock().unwrap().insert(token, Waiter::Async(tx));

    if !post(port, kind, token as i64, id, Payload::CopiedBytes(payload)) {
        PENDING.lock().unwrap().remove(&token);
        return None;
    }

    match tokio::time::timeout(timeout, rx).await {
        Ok(Ok(reply)) => Some(reply),
        _ => {
            PENDING.lock().unwrap().remove(&token);
            None
        }
    }
}

// ---------------------------------------------------------------------------------------
// C string helpers
// ---------------------------------------------------------------------------------------

/// Borrow a UTF-8 buffer passed from Dart
///
/// # Safety
/// `ptr` must be valid for `len` bytes or null with len 0
pub unsafe fn str_arg<'a>(ptr: *const u8, len: usize) -> Result<&'a str> {
    let bytes = bytes_arg(ptr, len)?;
    std::str::from_utf8(bytes).map_err(|_| Error::arg("string argument is not valid UTF-8"))
}

/// Borrow a byte buffer passed from Dart
///
/// # Safety
/// `ptr` must be valid for `len` bytes or null with len 0
pub unsafe fn bytes_arg<'a>(ptr: *const u8, len: usize) -> Result<&'a [u8]> {
    if len == 0 {
        return Ok(&[]);
    }
    if ptr.is_null() {
        return Err(Error::arg("null buffer"));
    }
    Ok(std::slice::from_raw_parts(ptr, len))
}
