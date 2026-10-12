//! Pieces shared by master and outstation: state listeners, connection handler, error
//! mapping.

use std::net::SocketAddr;
use std::time::Duration;

use dnp3::app::{Listener, MaybeAsync};
use dnp3::link::EndpointAddress;
use dnp3::master::{
    AssociationError, CommandError, CommandResponseError, FileError, PollError, TaskError,
    TimeSyncError, WriteError,
};
use dnp3::tcp::{ClientConnectionHandler, ClientState, ConnectionInfo, Endpoint};

use crate::config::{socket_addr, ClientDto};
use crate::core::{err, msg, Error, Result};
use crate::dart::{post, DartPort, Payload};

// ---------------------------------------------------------------------------------------
// listeners
// ---------------------------------------------------------------------------------------

fn dur_ms(d: Duration) -> i64 {
    d.as_millis().min(i64::MAX as u128) as i64
}

pub struct ClientStateListener {
    pub port: DartPort,
    pub id: i64,
}

impl Listener<ClientState> for ClientStateListener {
    fn update(&mut self, value: ClientState) -> MaybeAsync<()> {
        let (code, d) = match value {
            ClientState::Disabled => (0, 0),
            ClientState::Connecting => (1, 0),
            ClientState::Connected => (2, 0),
            ClientState::WaitAfterFailedConnect(d) => (3, dur_ms(d)),
            ClientState::WaitAfterDisconnect(d) => (4, dur_ms(d)),
            ClientState::Shutdown => (5, 0),
        };
        post(self.port, msg::CLIENT_STATE, self.id, code, Payload::Int(d));
        MaybeAsync::ready(())
    }
}

#[cfg(has_serial)]
pub struct PortStateListener {
    pub port: DartPort,
    pub id: i64,
}

#[cfg(has_serial)]
impl Listener<dnp3::serial::PortState> for PortStateListener {
    fn update(&mut self, value: dnp3::serial::PortState) -> MaybeAsync<()> {
        use dnp3::serial::PortState;
        let (code, d) = match value {
            PortState::Disabled => (0, 0),
            PortState::Wait(d) => (1, dur_ms(d)),
            PortState::Open => (2, 0),
            PortState::Shutdown => (3, 0),
        };
        post(self.port, msg::PORT_STATE, self.id, code, Payload::Int(d));
        MaybeAsync::ready(())
    }
}

pub struct ConnectionStateListener {
    pub port: DartPort,
    pub id: i64,
}

impl Listener<dnp3::outstation::ConnectionState> for ConnectionStateListener {
    fn update(&mut self, value: dnp3::outstation::ConnectionState) -> MaybeAsync<()> {
        let code = match value {
            dnp3::outstation::ConnectionState::Disconnected => 0,
            dnp3::outstation::ConnectionState::Connected => 1,
        };
        post(
            self.port,
            msg::CONNECTION_STATE,
            self.id,
            code,
            Payload::Null,
        );
        MaybeAsync::ready(())
    }
}

// ---------------------------------------------------------------------------------------
// client connection handler that reports every step to Dart
// ---------------------------------------------------------------------------------------

pub mod conn_event {
    pub const CONNECTING: i64 = 0;
    pub const CONNECTED: i64 = 1;
    pub const CONNECT_FAILED: i64 = 2;
    pub const DISCONNECTED: i64 = 3;
    pub const RESOLUTION_FAILED: i64 = 4;
}

/// Equivalent of the library's `SimpleConnectHandler` (round-robin endpoint list with
/// exponential back-off) that additionally forwards connection events to Dart.
pub struct DartConnectHandler {
    endpoints: Vec<Endpoint>,
    names: Vec<String>,
    next: usize,
    timeout: Option<Duration>,
    local: Option<SocketAddr>,
    master_address: Option<EndpointAddress>,
    min_delay: Duration,
    max_delay: Duration,
    last_delay: Option<Duration>,
    reconnect_delay: Duration,
    /// attempt in progress (`connecting` seen, no outcome yet). The library only reports
    /// `connect_failed` for timeouts, so refused connections / TLS failures are detected
    /// when the next attempt starts.
    pending: Option<(SocketAddr, Option<String>)>,
    /// consecutive failed attempts since the last successful connection
    failures: u32,
    /// `Some(timeout)` when a Dart `ConnectionPolicy` is installed
    callback: Option<Duration>,
    port: DartPort,
    id: i64,
}

pub mod conn_request {
    pub const NEXT: u8 = 0;
    pub const DISCONNECTED: u8 = 1;
}

impl DartConnectHandler {
    pub fn create(
        dto: &ClientDto,
        port: DartPort,
        id: i64,
    ) -> Result<Box<dyn ClientConnectionHandler>> {
        if dto.endpoints.is_empty() {
            return Err(Error::config("at least one endpoint is required"));
        }
        let local = match &dto.connect_options.local_endpoint {
            Some(x) => Some(socket_addr(x)?),
            None => None,
        };
        let master_address = match dto.master_address {
            Some(x) => Some(crate::config::address(x)?),
            None => None,
        };
        Ok(Box::new(Self {
            endpoints: dto.endpoints.iter().cloned().map(Endpoint::from).collect(),
            names: dto.endpoints.clone(),
            next: 0,
            timeout: dto
                .connect_options
                .connect_timeout_ms
                .map(Duration::from_millis),
            local,
            master_address,
            min_delay: Duration::from_millis(dto.connect_strategy.min_connect_delay_ms),
            max_delay: Duration::from_millis(dto.connect_strategy.max_connect_delay_ms),
            last_delay: None,
            reconnect_delay: Duration::from_millis(dto.connect_strategy.reconnect_delay_ms),
            pending: None,
            failures: 0,
            callback: dto
                .connection_callback
                .then(|| Duration::from_millis(dto.callback_timeout_ms)),
            port,
            id,
        }))
    }

    fn event(&self, kind: i64, addr: Option<SocketAddr>, hostname: Option<&str>) {
        if self.port == 0 {
            return;
        }
        let text = match (addr, hostname) {
            (Some(a), Some(h)) => format!("{a}|{h}"),
            (Some(a), None) => format!("{a}|"),
            (None, Some(h)) => format!("|{h}"),
            (None, None) => "|".to_string(),
        };
        post(
            self.port,
            msg::CONNECTION_EVENT,
            self.id,
            kind,
            Payload::Str(text),
        );
    }
}

impl ClientConnectionHandler for DartConnectHandler {
    fn endpoint_span_name(&self) -> String {
        self.names[0].clone()
    }

    fn disconnected(&mut self, addr: SocketAddr, hostname: Option<&str>) -> Duration {
        self.event(conn_event::DISCONNECTED, Some(addr), hostname);
        if self.callback.is_some() {
            let mut w = crate::codec::Writer::with_capacity(32);
            w.u8(conn_request::DISCONNECTED);
            w.zeros(3);
            w.blob(format!("{addr}|{}", hostname.unwrap_or("")).as_bytes());
            if let Some(reply) = self.request(w.finish()) {
                if reply.status == 2 {
                    if let Some(x) = reply.data.get(0..8) {
                        return Duration::from_millis(u64::from_le_bytes(x.try_into().unwrap()));
                    }
                }
            }
        }
        self.reconnect_delay
    }

    fn next(&mut self) -> std::result::Result<ConnectionInfo, Duration> {
        if let Some((addr, host)) = self.pending.take() {
            self.failures += 1;
            self.event(conn_event::CONNECT_FAILED, Some(addr), host.as_deref());
        }
        if let Some(decision) = self.ask_next() {
            return decision;
        }
        self.native_next()
    }

    fn connecting(&mut self, addr: SocketAddr, hostname: Option<&str>) {
        if let Some((a, h)) = self.pending.take() {
            self.failures += 1;
            self.event(conn_event::CONNECT_FAILED, Some(a), h.as_deref());
        }
        self.pending = Some((addr, hostname.map(str::to_string)));
        self.event(conn_event::CONNECTING, Some(addr), hostname);
    }

    fn connect_failed(&mut self, addr: SocketAddr, hostname: Option<&str>) {
        self.pending = None;
        self.failures += 1;
        self.event(conn_event::CONNECT_FAILED, Some(addr), hostname);
    }

    fn connected(&mut self, addr: SocketAddr, hostname: Option<&str>) {
        self.pending = None;
        self.failures = 0;
        self.next = 0;
        self.last_delay = None;
        self.event(conn_event::CONNECTED, Some(addr), hostname);
    }

    fn resolution_failed(&mut self, host_name: &str) {
        self.event(conn_event::RESOLUTION_FAILED, None, Some(host_name));
    }
}

impl DartConnectHandler {
    fn request(&self, payload: Vec<u8>) -> Option<crate::core::Reply> {
        let timeout = self.callback?;
        crate::core::request_sync(
            self.port,
            msg::CONNECTION_REQUEST,
            self.id,
            payload,
            timeout,
        )
    }

    /// `u8 NEXT, u8[3], u32 consecutive failures, u32 native next index, u32 endpoint count`
    /// Reply: status 1 = connect (JSON `ConnectDecisionDto`), 2 = wait (`u64 ms`),
    /// anything else = native policy.
    fn ask_next(&mut self) -> Option<std::result::Result<ConnectionInfo, Duration>> {
        self.callback?;
        let mut w = crate::codec::Writer::with_capacity(16);
        w.u8(conn_request::NEXT);
        w.zeros(3);
        w.u32(self.failures);
        w.u32(self.next as u32);
        w.u32(self.endpoints.len() as u32);
        let reply = self.request(w.finish())?;
        match reply.status {
            1 => {
                let text = std::str::from_utf8(&reply.data).ok()?;
                let d: crate::config::ConnectDecisionDto = match crate::config::parse(text) {
                    Ok(d) => d,
                    Err(e) => {
                        tracing::warn!("invalid connection decision from Dart: {}", e.message);
                        return None;
                    }
                };
                let mut info = ConnectionInfo::new(Endpoint::from(d.endpoint));
                if let Some(t) = d.timeout_ms.map(Duration::from_millis).or(self.timeout) {
                    info.set_timeout(t);
                }
                let local = match d.local_endpoint.as_deref().map(socket_addr) {
                    Some(Ok(x)) => Some(x),
                    Some(Err(_)) => None,
                    None => self.local,
                };
                if let Some(l) = local {
                    info.set_local_endpoint(l);
                }
                let master = match d.master_address.map(crate::config::address) {
                    Some(Ok(x)) => Some(x),
                    _ => self.master_address,
                };
                if let Some(a) = master {
                    info.set_master_address(a);
                }
                Some(Ok(info))
            }
            2 => {
                let ms = reply
                    .data
                    .get(0..8)
                    .map(|x| u64::from_le_bytes(x.try_into().unwrap()))
                    .unwrap_or(1000);
                Some(Err(Duration::from_millis(ms)))
            }
            _ => None,
        }
    }

    fn native_next(&mut self) -> std::result::Result<ConnectionInfo, Duration> {
        match self.endpoints.get(self.next) {
            None => {
                self.next = 0;
                let delay = match self.last_delay {
                    Some(x) => x
                        .checked_mul(2)
                        .unwrap_or(self.max_delay)
                        .min(self.max_delay),
                    None => self.min_delay,
                };
                self.last_delay = Some(delay);
                Err(delay)
            }
            Some(x) => {
                self.next += 1;
                let mut info = ConnectionInfo::new(x.clone());
                if let Some(t) = self.timeout {
                    info.set_timeout(t);
                }
                if let Some(l) = self.local {
                    info.set_local_endpoint(l);
                }
                if let Some(a) = self.master_address {
                    info.set_master_address(a);
                }
                Ok(info)
            }
        }
    }
}

// ---------------------------------------------------------------------------------------
// error mapping
// ---------------------------------------------------------------------------------------

pub fn task_error_sub(e: &TaskError) -> i64 {
    match e {
        TaskError::TooManyRequests => 1,
        TaskError::Link(_) => 2,
        TaskError::Transport => 3,
        TaskError::RejectedByIin2(iin) => 4 | ((iin.iin2.value as i64) << 8),
        TaskError::MalformedResponse(_) => 5,
        TaskError::UnexpectedResponseHeaders => 6,
        TaskError::NonFinWithoutCon => 7,
        TaskError::NeverReceivedFir => 8,
        TaskError::UnexpectedFir => 9,
        TaskError::MultiFragmentResponse => 10,
        TaskError::ResponseTimeout => 11,
        TaskError::WriteError => 12,
        TaskError::BadEncoding(_) => 13,
        TaskError::NoSuchAssociation(_) => 14,
        TaskError::NoConnection => 15,
        TaskError::Shutdown => 16,
        TaskError::Disabled => 17,
    }
}

/// Task errors carry the `Debug` rendering of the library error as detail, e.g.
/// `Link(Stdio(ConnectionReset))` or `MalformedResponse(InsufficientBytes)`.
pub fn task_error(e: TaskError) -> Error {
    Error::with_sub(err::TASK, task_error_sub(&e), e.to_string()).detail(format!("{e:?}"))
}

pub fn command_error(e: CommandError) -> Error {
    match e {
        CommandError::Task(t) | CommandError::Response(CommandResponseError::Request(t)) => {
            task_error(t)
        }
        CommandError::Response(r) => {
            let sub = match r {
                CommandResponseError::BadStatus(s) => 1 | ((s.as_u8() as i64) << 8),
                CommandResponseError::HeaderCountMismatch => 2,
                CommandResponseError::HeaderTypeMismatch => 3,
                CommandResponseError::ObjectCountMismatch => 4,
                CommandResponseError::ObjectValueMismatch => 5,
                CommandResponseError::Request(_) => unreachable!(),
            };
            Error::with_sub(err::COMMAND, sub, r.to_string()).detail(format!("{r:?}"))
        }
    }
}

pub fn write_error(e: WriteError) -> Error {
    match e {
        WriteError::Task(t) => task_error(t),
        WriteError::IinError(iin2) => Error::with_sub(
            err::WRITE,
            iin2.value as i64,
            format!("outstation returned IIN2 error: {iin2}"),
        ),
    }
}

pub fn time_sync_error(e: TimeSyncError) -> Error {
    let msg = e.to_string();
    let detail = format!("{e:?}");
    let e2 = match e {
        TimeSyncError::Task(t) => task_error(t),
        TimeSyncError::ClockRollback => Error::with_sub(err::TIME_SYNC, 1, msg),
        TimeSyncError::SystemTimeNotUnix => Error::with_sub(err::TIME_SYNC, 2, msg),
        TimeSyncError::BadOutstationTimeDelay(x) => {
            Error::with_sub(err::TIME_SYNC, 3 | ((x as i64) << 8), msg)
        }
        TimeSyncError::Overflow => Error::with_sub(err::TIME_SYNC, 4, msg),
        TimeSyncError::StillNeedsTime => Error::with_sub(err::TIME_SYNC, 5, msg),
        TimeSyncError::SystemTimeNotAvailable => Error::with_sub(err::TIME_SYNC, 6, msg),
        TimeSyncError::IinError(iin2) => {
            Error::with_sub(err::TIME_SYNC, 7 | ((iin2.value as i64) << 8), msg)
        }
    };
    e2.detail(detail)
}

pub fn file_status_u8(s: dnp3::app::FileStatus) -> u8 {
    use dnp3::app::FileStatus::*;
    match s {
        Success => 0,
        PermissionDenied => 1,
        InvalidMode => 2,
        FileNotFound => 3,
        FileLocked => 4,
        TooManyOpen => 5,
        InvalidHandle => 6,
        WriteBlockSize => 7,
        CommLost => 8,
        CannotAbort => 9,
        NotOpened => 16,
        HandleExpired => 17,
        BufferOverrun => 18,
        Fatal => 19,
        BlockSeq => 20,
        Undefined => 255,
        Other(x) => x,
    }
}

pub fn file_error(e: FileError) -> Error {
    let msg = e.to_string();
    let detail = format!("{e:?}");
    let e2 = match e {
        FileError::TaskError(t) => task_error(t),
        FileError::BadResponse => Error::with_sub(err::FILE, 1, msg),
        FileError::BadStatus(s) => {
            Error::with_sub(err::FILE, 2 | ((file_status_u8(s) as i64) << 8), msg)
        }
        FileError::WrongHandle => Error::with_sub(err::FILE, 3, msg),
        FileError::NoPermission => Error::with_sub(err::FILE, 4, msg),
        FileError::BadBlockNum => Error::with_sub(err::FILE, 5, msg),
        FileError::AbortByUser => Error::with_sub(err::FILE, 6, msg),
        FileError::MaxLengthExceeded => Error::with_sub(err::FILE, 7, msg),
    };
    e2.detail(detail)
}

pub fn association_error(e: AssociationError) -> Error {
    let msg = e.to_string();
    match e {
        AssociationError::Shutdown => Error::new(err::SHUTDOWN, msg),
        AssociationError::DuplicateAddress(_) => Error::with_sub(err::ASSOCIATION, 1, msg),
        AssociationError::WrongChannelType { .. } => Error::with_sub(err::ASSOCIATION, 2, msg),
    }
}

pub fn poll_error(e: PollError) -> Error {
    let msg = e.to_string();
    match e {
        PollError::Shutdown => Error::new(err::SHUTDOWN, msg),
        PollError::NoSuchAssociation(_) => Error::with_sub(err::POLL, 1, msg),
    }
}
