//! C ABI of the `dnp3` Dart plugin.
//!
//! Conventions:
//! * Every function returns an `i64`: `>= 0` on success, `-error_code` on failure. The
//!   message of the last failure on the calling thread is available via [`dnp3_last_error`].
//! * Objects are referenced by opaque 64-bit handles. Handles are plain integers and can be
//!   used from any Dart isolate.
//! * Asynchronous operations take a `port` (a Dart `SendPort.nativePort`) and a `request`
//!   id; completion is posted as `[RESULT, request, status, payload]`.
//! * Buffers passed in are only borrowed for the duration of the call (no copy for the
//!   database / request decoders).

#![allow(clippy::missing_safety_doc)]
#![allow(clippy::too_many_arguments)]

pub mod codec;
pub mod common;
pub mod config;
pub mod core;
pub mod dart;
pub mod database;
pub mod logging;
pub mod master;
pub mod master_server;
pub mod measurement;
pub mod outstation;
pub mod requests;
pub mod variation;

use std::ffi::{c_char, c_void};
use std::panic::AssertUnwindSafe;

use crate::core::*;

fn run(f: impl FnOnce() -> Result<i64>) -> i64 {
    guard(AssertUnwindSafe(f))
}

fn c(port: i64, request: i64) -> Completion {
    Completion::new(port, request)
}

unsafe fn opt_str<'a>(ptr: *const u8, len: usize, present: bool) -> Result<Option<&'a str>> {
    if present {
        Ok(Some(str_arg(ptr, len)?))
    } else {
        Ok(None)
    }
}

// ---------------------------------------------------------------------------------------
// library
// ---------------------------------------------------------------------------------------

#[no_mangle]
pub extern "C" fn dnp3_abi_version() -> i64 {
    ABI_VERSION
}

static VERSION: &[u8] = concat!(env!("CARGO_PKG_VERSION"), "+dnp3-1.7.0\0").as_bytes();

#[no_mangle]
pub extern "C" fn dnp3_version() -> *const c_char {
    VERSION.as_ptr() as *const c_char
}

/// Must be called once per process with `NativeApi.postCObject` (idempotent)
#[no_mangle]
pub extern "C" fn dnp3_init(post_cobject: *mut c_void) -> i64 {
    run(|| {
        if post_cobject.is_null() {
            return Err(Error::arg("postCObject pointer is null"));
        }
        dart::set_post_cobject(post_cobject);
        Ok(0)
    })
}

#[no_mangle]
pub extern "C" fn dnp3_runtime_start(worker_threads: u32) -> i64 {
    run(|| {
        if !dart::is_initialized() {
            return Err(Error::new(
                err::NOT_INITIALIZED,
                "dnp3_init has not been called",
            ));
        }
        start_runtime(worker_threads)
    })
}

#[no_mangle]
pub extern "C" fn dnp3_runtime_shutdown(timeout_ms: u64) -> i64 {
    run(|| {
        shutdown_runtime(timeout_ms);
        Ok(0)
    })
}

#[no_mangle]
pub extern "C" fn dnp3_last_error() -> *const c_char {
    last_error_ptr()
}

#[no_mangle]
pub extern "C" fn dnp3_logging_init(port: i64, level: u8, with_target: u8) -> i64 {
    run(|| Ok(logging::init(port, level, with_target != 0) as i64))
}

#[no_mangle]
pub extern "C" fn dnp3_logging_set_level(level: u8) -> i64 {
    logging::set_level(level);
    0
}

/// Payloads at least this large are transferred to Dart as external typed data (zero-copy)
#[no_mangle]
pub extern "C" fn dnp3_set_external_threshold(bytes: u64) -> i64 {
    dart::EXTERNAL_THRESHOLD.store(bytes as usize, std::sync::atomic::Ordering::Relaxed);
    0
}

#[no_mangle]
pub unsafe extern "C" fn dnp3_reply(token: u64, status: i64, data: *const u8, len: usize) -> i64 {
    run(|| {
        let data = bytes_arg(data, len)?.to_vec();
        Ok(deliver_reply(token, Reply { status, data }) as i64)
    })
}

#[no_mangle]
pub extern "C" fn dnp3_disable_tcp_no_delay(client: u8, server: u8) -> i64 {
    if client != 0 {
        dnp3::tcp::disable_client_tcp_no_delay();
    }
    if server != 0 {
        dnp3::tcp::disable_server_tcp_no_delay();
    }
    0
}

/// Number of live objects per registry (diagnostics / leak tests):
/// masters, associations, polls, outstations
#[no_mangle]
pub extern "C" fn dnp3_debug_object_count(kind: u8) -> i64 {
    match kind {
        0 => master::MASTERS.len() as i64,
        1 => master::ASSOCIATIONS.len() as i64,
        2 => master::POLLS.len() as i64,
        3 => outstation::OUTSTATIONS.len() as i64,
        _ => -1,
    }
}

/// Free a buffer returned by a `*_alloc` style function (8-byte length header before `ptr`)
#[no_mangle]
pub unsafe extern "C" fn dnp3_buffer_free(ptr: *mut u8) {
    if ptr.is_null() {
        return;
    }
    let base = ptr.sub(8);
    let len = u64::from_le_bytes(std::slice::from_raw_parts(base, 8).try_into().unwrap()) as usize;
    drop(Vec::from_raw_parts(base, len + 8, len + 8));
}

fn into_raw_buffer(data: Vec<u8>, out_len: *mut usize) -> *mut u8 {
    let mut buf = Vec::with_capacity(data.len() + 8);
    buf.extend_from_slice(&(data.len() as u64).to_le_bytes());
    buf.extend_from_slice(&data);
    let mut buf = std::mem::ManuallyDrop::new(buf.into_boxed_slice().into_vec());
    if !out_len.is_null() {
        unsafe { *out_len = data.len() };
    }
    unsafe { buf.as_mut_ptr().add(8) }
}

// ---------------------------------------------------------------------------------------
// master
// ---------------------------------------------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn dnp3_master_create(json: *const u8, len: usize, events: i64) -> i64 {
    run(|| master::create(str_arg(json, len)?, events))
}

#[no_mangle]
pub extern "C" fn dnp3_master_destroy(id: u64) -> i64 {
    run(|| master::destroy(id))
}

#[no_mangle]
pub extern "C" fn dnp3_master_enable(id: u64, enable: u8, port: i64, request: i64) -> i64 {
    run(|| {
        if enable != 0 {
            master::enable(id, c(port, request))
        } else {
            master::disable(id, c(port, request))
        }
    })
}

#[no_mangle]
pub unsafe extern "C" fn dnp3_master_set_decode_level(
    id: u64,
    json: *const u8,
    len: usize,
    port: i64,
    request: i64,
) -> i64 {
    run(|| master::set_decode_level(id, str_arg(json, len)?, c(port, request)))
}

#[no_mangle]
pub extern "C" fn dnp3_master_get_decode_level(id: u64, port: i64, request: i64) -> i64 {
    run(|| master::get_decode_level(id, c(port, request)))
}

#[no_mangle]
pub unsafe extern "C" fn dnp3_master_add_association(
    id: u64,
    json: *const u8,
    len: usize,
    events: i64,
    port: i64,
    request: i64,
) -> i64 {
    run(|| master::add_association(id, str_arg(json, len)?, events, c(port, request)))
}

#[no_mangle]
pub extern "C" fn dnp3_association_remove(id: u64, port: i64, request: i64) -> i64 {
    run(|| master::remove_association(id, c(port, request)))
}

/// Acknowledge processed measurement fragments of an association with flow control.
/// Returns the number of fragments still in flight. Never calls back into Dart.
#[no_mangle]
pub extern "C" fn dnp3_association_ack(id: u64, n: i64) -> i64 {
    run(|| master::ack(id, n))
}

/// mode 0: system clock + `value` ms, 1: time unavailable, 2: manual time `value` (epoch ms)
#[no_mangle]
pub extern "C" fn dnp3_association_set_time_source(id: u64, mode: u8, value: i64) -> i64 {
    run(|| master::set_time_source(id, mode, value))
}

#[no_mangle]
pub unsafe extern "C" fn dnp3_association_read(
    id: u64,
    req: *const u8,
    len: usize,
    port: i64,
    request: i64,
) -> i64 {
    run(|| master::read(id, bytes_arg(req, len)?, c(port, request)))
}

#[no_mangle]
pub unsafe extern "C" fn dnp3_association_read_with_handler(
    id: u64,
    req: *const u8,
    len: usize,
    port: i64,
    request: i64,
) -> i64 {
    run(|| master::read_with_handler(id, bytes_arg(req, len)?, c(port, request)))
}

#[no_mangle]
pub unsafe extern "C" fn dnp3_association_operate(
    id: u64,
    req: *const u8,
    len: usize,
    port: i64,
    request: i64,
) -> i64 {
    run(|| master::operate(id, bytes_arg(req, len)?, c(port, request)))
}

#[no_mangle]
pub unsafe extern "C" fn dnp3_association_send_and_expect_empty_response(
    id: u64,
    function: u8,
    req: *const u8,
    len: usize,
    port: i64,
    request: i64,
) -> i64 {
    run(|| {
        master::send_and_expect_empty_response(id, function, bytes_arg(req, len)?, c(port, request))
    })
}

#[no_mangle]
pub extern "C" fn dnp3_association_restart(id: u64, cold: u8, port: i64, request: i64) -> i64 {
    run(|| master::restart(id, cold != 0, c(port, request)))
}

#[no_mangle]
pub extern "C" fn dnp3_association_synchronize_time(
    id: u64,
    procedure: u8,
    port: i64,
    request: i64,
) -> i64 {
    run(|| master::synchronize_time(id, procedure, c(port, request)))
}

#[no_mangle]
pub unsafe extern "C" fn dnp3_association_write_dead_bands(
    id: u64,
    req: *const u8,
    len: usize,
    port: i64,
    request: i64,
) -> i64 {
    run(|| master::write_dead_bands(id, bytes_arg(req, len)?, c(port, request)))
}

#[no_mangle]
pub extern "C" fn dnp3_association_check_link_status(id: u64, port: i64, request: i64) -> i64 {
    run(|| master::check_link_status(id, c(port, request)))
}

#[no_mangle]
pub unsafe extern "C" fn dnp3_association_add_poll(
    id: u64,
    req: *const u8,
    len: usize,
    period_ms: u64,
    port: i64,
    request: i64,
) -> i64 {
    run(|| master::add_poll(id, bytes_arg(req, len)?, period_ms, c(port, request)))
}

#[no_mangle]
pub extern "C" fn dnp3_poll_demand(id: u64, port: i64, request: i64) -> i64 {
    run(|| master::demand_poll(id, c(port, request)))
}

#[no_mangle]
pub extern "C" fn dnp3_poll_remove(id: u64, port: i64, request: i64) -> i64 {
    run(|| master::remove_poll(id, c(port, request)))
}

#[no_mangle]
pub unsafe extern "C" fn dnp3_association_get_file_auth_key(
    id: u64,
    user: *const u8,
    user_len: usize,
    password: *const u8,
    password_len: usize,
    port: i64,
    request: i64,
) -> i64 {
    run(|| {
        master::get_file_auth_key(
            id,
            str_arg(user, user_len)?,
            str_arg(password, password_len)?,
            c(port, request),
        )
    })
}

#[no_mangle]
pub unsafe extern "C" fn dnp3_association_open_file(
    id: u64,
    name: *const u8,
    name_len: usize,
    auth_key: u32,
    permissions: u16,
    file_size: u32,
    mode: u16,
    max_block_size: u16,
    port: i64,
    request: i64,
) -> i64 {
    run(|| {
        master::open_file(
            id,
            str_arg(name, name_len)?,
            auth_key,
            permissions,
            file_size,
            mode,
            max_block_size,
            c(port, request),
        )
    })
}

#[no_mangle]
pub unsafe extern "C" fn dnp3_association_write_file_block(
    id: u64,
    handle: u32,
    block: u32,
    data: *const u8,
    len: usize,
    port: i64,
    request: i64,
) -> i64 {
    run(|| master::write_file_block(id, handle, block, bytes_arg(data, len)?, c(port, request)))
}

#[no_mangle]
pub extern "C" fn dnp3_association_close_file(
    id: u64,
    handle: u32,
    port: i64,
    request: i64,
) -> i64 {
    run(|| master::close_file(id, handle, c(port, request)))
}

#[no_mangle]
pub unsafe extern "C" fn dnp3_association_get_file_info(
    id: u64,
    path: *const u8,
    len: usize,
    port: i64,
    request: i64,
) -> i64 {
    run(|| master::get_file_info(id, str_arg(path, len)?, c(port, request)))
}

#[no_mangle]
pub unsafe extern "C" fn dnp3_association_read_directory(
    id: u64,
    path: *const u8,
    path_len: usize,
    max_block_size: u16,
    max_file_size: u64,
    has_credentials: u8,
    user: *const u8,
    user_len: usize,
    password: *const u8,
    password_len: usize,
    port: i64,
    request: i64,
) -> i64 {
    run(|| {
        let present = has_credentials != 0;
        master::read_directory(
            id,
            str_arg(path, path_len)?,
            max_block_size,
            max_file_size,
            opt_str(user, user_len, present)?,
            opt_str(password, password_len, present)?,
            c(port, request),
        )
    })
}

#[no_mangle]
pub unsafe extern "C" fn dnp3_association_read_file(
    id: u64,
    path: *const u8,
    path_len: usize,
    max_block_size: u16,
    max_file_size: u64,
    has_credentials: u8,
    user: *const u8,
    user_len: usize,
    password: *const u8,
    password_len: usize,
    confirm_open_timeout_ms: u64,
    events: i64,
) -> i64 {
    run(|| {
        let present = has_credentials != 0;
        master::read_file(
            id,
            str_arg(path, path_len)?,
            max_block_size,
            max_file_size,
            opt_str(user, user_len, present)?,
            opt_str(password, password_len, present)?,
            confirm_open_timeout_ms,
            events,
        )
    })
}

#[no_mangle]
pub extern "C" fn dnp3_file_read_abort(id: u64) -> i64 {
    run(|| master::abort_file_read(id))
}

#[no_mangle]
pub unsafe extern "C" fn dnp3_master_server_create(
    json: *const u8,
    len: usize,
    events: i64,
    port: i64,
    request: i64,
) -> i64 {
    run(|| master_server::create(str_arg(json, len)?, events, c(port, request)))
}

#[no_mangle]
pub extern "C" fn dnp3_master_server_destroy(id: u64) -> i64 {
    run(|| master_server::destroy(id))
}

// ---------------------------------------------------------------------------------------
// outstation
// ---------------------------------------------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn dnp3_outstation_create(json: *const u8, len: usize, events: i64) -> i64 {
    run(|| outstation::create(str_arg(json, len)?, events))
}

#[no_mangle]
pub extern "C" fn dnp3_outstation_destroy(id: u64) -> i64 {
    run(|| outstation::destroy(id))
}

#[no_mangle]
pub extern "C" fn dnp3_outstation_enable(id: u64, enable: u8, port: i64, request: i64) -> i64 {
    run(|| {
        if enable != 0 {
            outstation::enable(id, c(port, request))
        } else {
            outstation::disable(id, c(port, request))
        }
    })
}

#[no_mangle]
pub unsafe extern "C" fn dnp3_outstation_set_decode_level(
    id: u64,
    json: *const u8,
    len: usize,
    port: i64,
    request: i64,
) -> i64 {
    run(|| outstation::set_decode_level(id, str_arg(json, len)?, c(port, request)))
}

#[no_mangle]
pub extern "C" fn dnp3_outstation_set_application_iin(id: u64, bits: u8) -> i64 {
    run(|| outstation::set_application_iin(id, bits))
}

#[no_mangle]
pub extern "C" fn dnp3_outstation_set_processing_delay(id: u64, ms: u16) -> i64 {
    run(|| outstation::set_processing_delay(id, ms))
}

/// Apply a batch of database ops (see `database.rs`). `out` (optional) receives 24-byte
/// result records. This function never calls back into Dart and may be used as a leaf call.
#[no_mangle]
pub unsafe extern "C" fn dnp3_outstation_transaction(
    id: u64,
    ops: *const u8,
    len: usize,
    out: *mut u8,
    out_len: usize,
) -> i64 {
    run(|| {
        let ops = bytes_arg(ops, len)?;
        let out = if out.is_null() || out_len == 0 {
            None
        } else {
            Some(std::slice::from_raw_parts_mut(out, out_len))
        };
        outstation::transaction(id, ops, out)
    })
}

#[no_mangle]
pub unsafe extern "C" fn dnp3_outstation_get(
    id: u64,
    point_type: u8,
    index: u16,
    out: *mut u8,
    cap: usize,
) -> i64 {
    run(|| {
        if out.is_null() {
            return Err(Error::arg("null output buffer"));
        }
        outstation::get_point(
            id,
            point_type,
            index,
            std::slice::from_raw_parts_mut(out, cap),
        )
    })
}

/// Returns a native buffer (free with `dnp3_buffer_free`) containing one encoded fragment
/// with a single block of all defined points in `[start, stop]`.
#[no_mangle]
pub unsafe extern "C" fn dnp3_outstation_get_range(
    id: u64,
    point_type: u8,
    start: u16,
    stop: u16,
    out_len: *mut usize,
) -> *mut u8 {
    match std::panic::catch_unwind(AssertUnwindSafe(|| {
        outstation::get_range(id, point_type, start, stop)
    })) {
        Ok(Ok(data)) => into_raw_buffer(data, out_len),
        Ok(Err(e)) => {
            set_last_error(&e);
            std::ptr::null_mut()
        }
        Err(_) => {
            set_last_error(&Error::new(err::PANIC, "panic in get_range"));
            std::ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn dnp3_outstation_server_create(json: *const u8, len: usize) -> i64 {
    run(|| outstation::server_create(str_arg(json, len)?))
}

#[no_mangle]
pub unsafe extern "C" fn dnp3_outstation_server_add_outstation(
    id: u64,
    json: *const u8,
    len: usize,
    events: i64,
) -> i64 {
    run(|| outstation::server_add_outstation(id, str_arg(json, len)?, events))
}

#[no_mangle]
pub extern "C" fn dnp3_outstation_server_bind(id: u64, port: i64, request: i64) -> i64 {
    run(|| outstation::server_bind(id, c(port, request)))
}

#[no_mangle]
pub extern "C" fn dnp3_outstation_server_destroy(id: u64) -> i64 {
    run(|| outstation::server_destroy(id))
}

// ---------------------------------------------------------------------------------------
// benchmarking helpers (no network involved)
// ---------------------------------------------------------------------------------------

/// Synthesise `fragments` measurement fragments of `points` analog inputs each and post them
/// to `port` from a background thread, exactly like the master read handler does. Completes
/// with `[RESULT, request, 0, elapsed_ns]` once everything has been posted.
#[no_mangle]
pub extern "C" fn dnp3_bench_emit(port: i64, fragments: u32, points: u32, request: i64) -> i64 {
    run(|| {
        std::thread::spawn(move || {
            use dnp3::app::measurement::{AnalogInput, Flags, Time};
            use dnp3::app::{ControlField, Iin, ResponseFunction, ResponseHeader, Sequence};
            use dnp3::master::{ReadHandler, ReadType};

            let header = ResponseHeader {
                control: ControlField {
                    fir: true,
                    fin: true,
                    con: false,
                    uns: false,
                    seq: Sequence::default(),
                },
                function: ResponseFunction::Response,
                iin: Iin::default(),
            };
            let info = bench_header_info();
            let mut handler = measurement::MeasurementHandler::new(measurement::Sink::Port {
                port,
                id: 0,
                credits: None,
            });
            let start = std::time::Instant::now();
            for f in 0..fragments {
                let _ = handler.begin_fragment(ReadType::PeriodicPoll, header);
                let mut iter = (0..points).map(|i| {
                    (
                        AnalogInput::new(
                            (f as f64) + i as f64 * 0.5,
                            Flags::ONLINE,
                            Time::synchronized(1_700_000_000_000 + i as u64),
                        ),
                        i as u16,
                    )
                });
                handler.handle_analog_input(info, &mut iter);
                let _ = handler.end_fragment(ReadType::PeriodicPoll, header);
            }
            let elapsed = start.elapsed().as_nanos() as i64;
            Completion::new(port, request).ok(elapsed);
        });
        Ok(0)
    })
}

fn bench_header_info() -> dnp3::master::HeaderInfo {
    dnp3::master::HeaderInfo {
        variation: dnp3::app::Variation::Group30Var1,
        qualifier: dnp3::app::QualifierCode::Range16,
        is_event: false,
        has_flags: true,
    }
}
