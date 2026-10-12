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
        post(self.port, msg::CONNECTION_STATE, self.id, code, Payload::Null);
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
    port: DartPort,
    id: i64,
}

impl DartConnectHandler {
    pub fn create(dto: &ClientDto, port: DartPort, id: i64) -> Result<Box<dyn ClientConnectionHandler>> {
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
            timeout: dto.connect_options.connect_timeout_ms.map(Duration::from_millis),
            local,
            master_address,
            min_delay: Duration::from_millis(dto.connect_strategy.min_connect_delay_ms),
            max_delay: Duration::from_millis(dto.connect_strategy.max_connect_delay_ms),
            last_delay: None,
            reconnect_delay: Duration::from_millis(dto.connect_strategy.reconnect_delay_ms),
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
        post(self.port, msg::CONNECTION_EVENT, self.id, kind, Payload::Str(text));
    }
}

impl ClientConnectionHandler for DartConnectHandler {
    fn endpoint_span_name(&self) -> String {
        self.names[0].clone()
    }

    fn disconnected(&mut self, addr: SocketAddr, hostname: Option<&str>) -> Duration {
        self.event(conn_event::DISCONNECTED, Some(addr), hostname);
        self.reconnect_delay
    }

    fn next(&mut self) -> std::result::Result<ConnectionInfo, Duration> {
        match self.endpoints.get(self.next) {
            None => {
                self.next = 0;
                let delay = match self.last_delay {
                    Some(x) => x.checked_mul(2).unwrap_or(self.max_delay).min(self.max_delay),
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

    fn connecting(&mut self, addr: SocketAddr, hostname: Option<&str>) {
        self.event(conn_event::CONNECTING, Some(addr), hostname);
    }

    fn connect_failed(&mut self, addr: SocketAddr, hostname: Option<&str>) {
        self.event(conn_event::CONNECT_FAILED, Some(addr), hostname);
    }

    fn connected(&mut self, addr: SocketAddr, hostname: Option<&str>) {
        self.next = 0;
        self.last_delay = None;
        self.event(conn_event::CONNECTED, Some(addr), hostname);
    }

    fn resolution_failed(&mut self, host_name: &str) {
        self.event(conn_event::RESOLUTION_FAILED, None, Some(host_name));
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

pub fn task_error(e: TaskError) -> Error {
    Error::with_sub(err::TASK, task_error_sub(&e), e.to_string())
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
            Error::with_sub(err::COMMAND, sub, r.to_string())
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
    match e {
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
    }
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
    match e {
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
    }
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
