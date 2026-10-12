//! JSON configuration DTOs (cold path). Every field is explicitly mapped onto the `dnp3`
//! types so that the Dart side does not depend on the crate's internal serde format.

use std::net::SocketAddr;
use std::time::Duration;

use serde::Deserialize;

use dnp3::app::{BufferSize, ConnectStrategy, RetryStrategy, Timeout};
use dnp3::decode::*;
use dnp3::link::{EndpointAddress, LinkErrorMode, LinkReadMode};
use dnp3::master::{
    AssociationConfig, Classes, EventClasses, MasterChannelConfig, TimeSyncProcedure,
};
use dnp3::outstation::database::{ClassZeroConfig, EventBufferConfig};
use dnp3::outstation::{Feature, Features, OutstationConfig};

use crate::core::{Error, Result};

pub fn parse<'a, T: Deserialize<'a>>(json: &'a str) -> Result<T> {
    Ok(serde_json::from_str(json)?)
}

pub fn address(value: u16) -> Result<EndpointAddress> {
    EndpointAddress::try_new(value)
        .map_err(|e| Error::config(format!("invalid DNP3 address {value}: {e:?}")))
}

pub fn socket_addr(s: &str) -> Result<SocketAddr> {
    s.parse()
        .map_err(|_| Error::config(format!("invalid socket address: '{s}'")))
}

pub fn ms(x: u64) -> Duration {
    Duration::from_millis(x)
}

pub fn timeout_ms(x: u64) -> Result<Timeout> {
    Timeout::from_millis(x).map_err(|e| Error::config(format!("invalid timeout {x} ms: {e:?}")))
}

// ---------------------------------------------------------------------------------------
// common
// ---------------------------------------------------------------------------------------

#[derive(Deserialize, Default, Copy, Clone)]
#[serde(rename_all = "camelCase", default)]
pub struct DecodeLevelDto {
    pub application: AppLevel,
    pub transport: TransportLevel,
    pub link: LinkLevel,
    pub physical: PhysLevel,
}

#[derive(Deserialize, Default, Copy, Clone)]
#[serde(rename_all = "camelCase")]
pub enum AppLevel {
    #[default]
    Nothing,
    Header,
    ObjectHeaders,
    ObjectValues,
}

#[derive(Deserialize, Default, Copy, Clone)]
#[serde(rename_all = "camelCase")]
pub enum TransportLevel {
    #[default]
    Nothing,
    Header,
    Payload,
}

#[derive(Deserialize, Default, Copy, Clone)]
#[serde(rename_all = "camelCase")]
pub enum LinkLevel {
    #[default]
    Nothing,
    Header,
    Payload,
}

#[derive(Deserialize, Default, Copy, Clone)]
#[serde(rename_all = "camelCase")]
pub enum PhysLevel {
    #[default]
    Nothing,
    Length,
    Data,
}

impl From<PhysLevel> for PhysDecodeLevel {
    fn from(x: PhysLevel) -> Self {
        match x {
            PhysLevel::Nothing => PhysDecodeLevel::Nothing,
            PhysLevel::Length => PhysDecodeLevel::Length,
            PhysLevel::Data => PhysDecodeLevel::Data,
        }
    }
}

impl From<DecodeLevelDto> for DecodeLevel {
    fn from(x: DecodeLevelDto) -> Self {
        DecodeLevel::new(
            match x.application {
                AppLevel::Nothing => AppDecodeLevel::Nothing,
                AppLevel::Header => AppDecodeLevel::Header,
                AppLevel::ObjectHeaders => AppDecodeLevel::ObjectHeaders,
                AppLevel::ObjectValues => AppDecodeLevel::ObjectValues,
            },
            match x.transport {
                TransportLevel::Nothing => TransportDecodeLevel::Nothing,
                TransportLevel::Header => TransportDecodeLevel::Header,
                TransportLevel::Payload => TransportDecodeLevel::Payload,
            },
            match x.link {
                LinkLevel::Nothing => LinkDecodeLevel::Nothing,
                LinkLevel::Header => LinkDecodeLevel::Header,
                LinkLevel::Payload => LinkDecodeLevel::Payload,
            },
            x.physical.into(),
        )
    }
}

pub fn decode_level_to_json(level: DecodeLevel) -> String {
    let app = match level.application {
        AppDecodeLevel::Nothing => "nothing",
        AppDecodeLevel::Header => "header",
        AppDecodeLevel::ObjectHeaders => "objectHeaders",
        AppDecodeLevel::ObjectValues => "objectValues",
    };
    let transport = match level.transport {
        TransportDecodeLevel::Nothing => "nothing",
        TransportDecodeLevel::Header => "header",
        TransportDecodeLevel::Payload => "payload",
    };
    let link = match level.link {
        LinkDecodeLevel::Nothing => "nothing",
        LinkDecodeLevel::Header => "header",
        LinkDecodeLevel::Payload => "payload",
    };
    let phys = match level.physical {
        PhysDecodeLevel::Nothing => "nothing",
        PhysDecodeLevel::Length => "length",
        PhysDecodeLevel::Data => "data",
    };
    format!(
        r#"{{"application":"{app}","transport":"{transport}","link":"{link}","physical":"{phys}"}}"#
    )
}

#[derive(Deserialize, Default, Copy, Clone)]
#[serde(rename_all = "camelCase")]
pub enum LinkErrorModeDto {
    #[default]
    Close,
    Discard,
}

impl From<LinkErrorModeDto> for LinkErrorMode {
    fn from(x: LinkErrorModeDto) -> Self {
        match x {
            LinkErrorModeDto::Close => LinkErrorMode::Close,
            LinkErrorModeDto::Discard => LinkErrorMode::Discard,
        }
    }
}

#[derive(Deserialize, Default, Copy, Clone)]
#[serde(rename_all = "camelCase")]
pub enum LinkReadModeDto {
    #[default]
    Datagram,
    Stream,
}

impl From<LinkReadModeDto> for LinkReadMode {
    fn from(x: LinkReadModeDto) -> Self {
        match x {
            LinkReadModeDto::Datagram => LinkReadMode::Datagram,
            LinkReadModeDto::Stream => LinkReadMode::Stream,
        }
    }
}

#[derive(Deserialize, Copy, Clone)]
#[serde(rename_all = "camelCase", default)]
pub struct RetryStrategyDto {
    pub min_delay_ms: u64,
    pub max_delay_ms: u64,
}

impl Default for RetryStrategyDto {
    fn default() -> Self {
        Self {
            min_delay_ms: 1000,
            max_delay_ms: 10_000,
        }
    }
}

impl From<RetryStrategyDto> for RetryStrategy {
    fn from(x: RetryStrategyDto) -> Self {
        RetryStrategy::new(ms(x.min_delay_ms), ms(x.max_delay_ms))
    }
}

#[derive(Deserialize, Copy, Clone)]
#[serde(rename_all = "camelCase", default)]
pub struct ConnectStrategyDto {
    pub min_connect_delay_ms: u64,
    pub max_connect_delay_ms: u64,
    pub reconnect_delay_ms: u64,
}

impl Default for ConnectStrategyDto {
    fn default() -> Self {
        Self {
            min_connect_delay_ms: 1000,
            max_connect_delay_ms: 10_000,
            reconnect_delay_ms: 1000,
        }
    }
}

impl From<ConnectStrategyDto> for ConnectStrategy {
    fn from(x: ConnectStrategyDto) -> Self {
        ConnectStrategy::new(
            ms(x.min_connect_delay_ms),
            ms(x.max_connect_delay_ms),
            ms(x.reconnect_delay_ms),
        )
    }
}

#[derive(Deserialize, Default, Clone)]
#[serde(rename_all = "camelCase", default)]
pub struct ConnectOptionsDto {
    pub local_endpoint: Option<String>,
    pub connect_timeout_ms: Option<u64>,
}

/// Endpoint list + reconnect behaviour of TCP/TLS clients
#[derive(Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct ClientDto {
    pub endpoints: Vec<String>,
    #[serde(default)]
    pub link_error_mode: LinkErrorModeDto,
    #[serde(default)]
    pub connect_strategy: ConnectStrategyDto,
    #[serde(default)]
    pub connect_options: ConnectOptionsDto,
    /// When set, the master address is overridden per connection (outstation clients only)
    #[serde(default)]
    pub master_address: Option<u16>,
}

#[derive(Deserialize, Clone, Copy, Default)]
#[serde(rename_all = "camelCase")]
pub enum TlsModeDto {
    #[default]
    Authority,
    SelfSigned,
}

#[derive(Deserialize, Clone, Copy, Default)]
#[serde(rename_all = "camelCase")]
pub enum MinTlsVersionDto {
    #[default]
    V12,
    V13,
}

#[derive(Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct TlsDto {
    #[serde(default)]
    pub mode: TlsModeDto,
    /// Expected subject name of the peer (authority mode). `null` disables name verification.
    #[serde(default)]
    pub subject_name: Option<String>,
    pub peer_cert_path: String,
    pub local_cert_path: String,
    pub private_key_path: String,
    #[serde(default)]
    pub password: Option<String>,
    #[serde(default)]
    pub min_tls_version: MinTlsVersionDto,
}

impl From<MinTlsVersionDto> for dnp3::tcp::tls::MinTlsVersion {
    fn from(x: MinTlsVersionDto) -> Self {
        match x {
            MinTlsVersionDto::V12 => Self::V12,
            MinTlsVersionDto::V13 => Self::V13,
        }
    }
}

impl TlsDto {
    pub fn client(&self) -> Result<dnp3::tcp::tls::TlsClientConfig> {
        use dnp3::tcp::tls::TlsClientConfig;
        use std::path::Path;
        let res = match self.mode {
            TlsModeDto::Authority => TlsClientConfig::full_pki(
                self.subject_name.clone(),
                Path::new(&self.peer_cert_path),
                Path::new(&self.local_cert_path),
                Path::new(&self.private_key_path),
                self.password.as_deref(),
                self.min_tls_version.into(),
            ),
            TlsModeDto::SelfSigned => TlsClientConfig::self_signed(
                Path::new(&self.peer_cert_path),
                Path::new(&self.local_cert_path),
                Path::new(&self.private_key_path),
                self.password.as_deref(),
                self.min_tls_version.into(),
            ),
        };
        res.map_err(|e| Error::new(crate::core::err::TLS, e.to_string()))
    }

    pub fn server(&self) -> Result<dnp3::tcp::tls::TlsServerConfig> {
        use dnp3::tcp::tls::TlsServerConfig;
        use std::path::Path;
        let res = match self.mode {
            TlsModeDto::Authority => TlsServerConfig::full_pki(
                self.subject_name.clone(),
                Path::new(&self.peer_cert_path),
                Path::new(&self.local_cert_path),
                Path::new(&self.private_key_path),
                self.password.as_deref(),
                self.min_tls_version.into(),
            ),
            TlsModeDto::SelfSigned => TlsServerConfig::self_signed(
                Path::new(&self.peer_cert_path),
                Path::new(&self.local_cert_path),
                Path::new(&self.private_key_path),
                self.password.as_deref(),
                self.min_tls_version.into(),
            ),
        };
        res.map_err(|e| Error::new(crate::core::err::TLS, e.to_string()))
    }
}

#[derive(Deserialize, Clone, Copy)]
#[serde(rename_all = "camelCase", default)]
pub struct SerialSettingsDto {
    pub baud_rate: u32,
    pub data_bits: u8,
    pub flow_control: FlowControlDto,
    pub stop_bits: u8,
    pub parity: ParityDto,
}

#[derive(Deserialize, Clone, Copy, Default)]
#[serde(rename_all = "camelCase")]
pub enum FlowControlDto {
    #[default]
    None,
    Software,
    Hardware,
}

#[derive(Deserialize, Clone, Copy, Default)]
#[serde(rename_all = "camelCase")]
pub enum ParityDto {
    #[default]
    None,
    Odd,
    Even,
}

impl Default for SerialSettingsDto {
    fn default() -> Self {
        Self {
            baud_rate: 9600,
            data_bits: 8,
            flow_control: FlowControlDto::None,
            stop_bits: 1,
            parity: ParityDto::None,
        }
    }
}

#[cfg(has_serial)]
impl SerialSettingsDto {
    pub fn to_settings(self) -> Result<dnp3::serial::SerialSettings> {
        use dnp3::serial::*;
        Ok(SerialSettings {
            baud_rate: self.baud_rate,
            data_bits: match self.data_bits {
                5 => DataBits::Five,
                6 => DataBits::Six,
                7 => DataBits::Seven,
                8 => DataBits::Eight,
                x => return Err(Error::config(format!("invalid data bits: {x}"))),
            },
            flow_control: match self.flow_control {
                FlowControlDto::None => FlowControl::None,
                FlowControlDto::Software => FlowControl::Software,
                FlowControlDto::Hardware => FlowControl::Hardware,
            },
            stop_bits: match self.stop_bits {
                1 => StopBits::One,
                2 => StopBits::Two,
                x => return Err(Error::config(format!("invalid stop bits: {x}"))),
            },
            parity: match self.parity {
                ParityDto::None => Parity::None,
                ParityDto::Odd => Parity::Odd,
                ParityDto::Even => Parity::Even,
            },
        })
    }
}

// ---------------------------------------------------------------------------------------
// master
// ---------------------------------------------------------------------------------------

#[derive(Deserialize, Clone, Copy)]
#[serde(rename_all = "camelCase")]
pub struct MasterChannelConfigDto {
    pub master_address: u16,
    #[serde(default)]
    pub decode_level: DecodeLevelDto,
    #[serde(default = "default_buffer")]
    pub tx_buffer_size: usize,
    #[serde(default = "default_buffer")]
    pub rx_buffer_size: usize,
}

fn default_buffer() -> usize {
    2048
}

impl MasterChannelConfigDto {
    pub fn to_config(self) -> Result<MasterChannelConfig> {
        let mut config = MasterChannelConfig::new(address(self.master_address)?);
        config.decode_level = self.decode_level.into();
        config.tx_buffer_size = BufferSize::new(self.tx_buffer_size)
            .map_err(|e| Error::config(format!("invalid tx buffer size: {e:?}")))?;
        config.rx_buffer_size = BufferSize::new(self.rx_buffer_size)
            .map_err(|e| Error::config(format!("invalid rx buffer size: {e:?}")))?;
        Ok(config)
    }
}

#[derive(Deserialize, Clone)]
#[serde(
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    tag = "type"
)]
pub enum MasterTransportDto {
    Tcp {
        #[serde(flatten)]
        client: ClientDto,
    },
    Tls {
        #[serde(flatten)]
        client: ClientDto,
        tls: TlsDto,
    },
    Serial {
        path: String,
        #[serde(default)]
        settings: SerialSettingsDto,
        #[serde(default = "default_retry_ms")]
        retry_delay_ms: u64,
    },
    Udp {
        local_endpoint: String,
        #[serde(default)]
        link_read_mode: LinkReadModeDto,
        #[serde(default = "default_retry_ms")]
        retry_delay_ms: u64,
    },
}

fn default_retry_ms() -> u64 {
    1000
}

#[derive(Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct MasterCreateDto {
    pub channel: MasterChannelConfigDto,
    pub transport: MasterTransportDto,
}

#[derive(Deserialize, Clone, Copy, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct EventClassesDto {
    pub class1: bool,
    pub class2: bool,
    pub class3: bool,
}

impl EventClassesDto {
    fn all() -> Self {
        Self {
            class1: true,
            class2: true,
            class3: true,
        }
    }
}

impl From<EventClassesDto> for EventClasses {
    fn from(x: EventClassesDto) -> Self {
        EventClasses::new(x.class1, x.class2, x.class3)
    }
}

#[derive(Deserialize, Clone, Copy)]
#[serde(rename_all = "camelCase", default)]
pub struct ClassesDto {
    pub class0: bool,
    pub class1: bool,
    pub class2: bool,
    pub class3: bool,
}

impl Default for ClassesDto {
    fn default() -> Self {
        Self {
            class0: true,
            class1: true,
            class2: true,
            class3: true,
        }
    }
}

impl From<ClassesDto> for Classes {
    fn from(x: ClassesDto) -> Self {
        Classes::new(x.class0, EventClasses::new(x.class1, x.class2, x.class3))
    }
}

#[derive(Deserialize, Clone, Copy)]
#[serde(rename_all = "camelCase")]
pub enum TimeSyncDto {
    Lan,
    NonLan,
    DirectWriteAbsTime,
}

impl From<TimeSyncDto> for TimeSyncProcedure {
    fn from(x: TimeSyncDto) -> Self {
        match x {
            TimeSyncDto::Lan => TimeSyncProcedure::Lan,
            TimeSyncDto::NonLan => TimeSyncProcedure::NonLan,
            TimeSyncDto::DirectWriteAbsTime => TimeSyncProcedure::DirectWriteAbsTime,
        }
    }
}

#[derive(Deserialize, Clone, Copy)]
#[serde(rename_all = "camelCase", default)]
pub struct AssociationConfigDto {
    pub response_timeout_ms: u64,
    pub disable_unsol_classes: EventClassesDto,
    pub enable_unsol_classes: EventClassesDto,
    pub startup_integrity_classes: ClassesDto,
    pub auto_time_sync: Option<TimeSyncDto>,
    pub auto_tasks_retry_strategy: RetryStrategyDto,
    pub keep_alive_timeout_ms: Option<u64>,
    pub auto_integrity_scan_on_buffer_overflow: bool,
    pub event_scan_on_events_available: EventClassesDto,
    pub max_queued_user_requests: usize,
}

impl Default for AssociationConfigDto {
    fn default() -> Self {
        Self {
            response_timeout_ms: 5000,
            disable_unsol_classes: EventClassesDto::all(),
            enable_unsol_classes: EventClassesDto::all(),
            startup_integrity_classes: ClassesDto::default(),
            auto_time_sync: None,
            auto_tasks_retry_strategy: RetryStrategyDto::default(),
            keep_alive_timeout_ms: None,
            auto_integrity_scan_on_buffer_overflow: true,
            event_scan_on_events_available: EventClassesDto::default(),
            max_queued_user_requests: 16,
        }
    }
}

impl AssociationConfigDto {
    pub fn to_config(self) -> Result<AssociationConfig> {
        let mut c = AssociationConfig::new(
            self.disable_unsol_classes.into(),
            self.enable_unsol_classes.into(),
            self.startup_integrity_classes.into(),
            self.event_scan_on_events_available.into(),
        );
        c.response_timeout = timeout_ms(self.response_timeout_ms)?;
        c.auto_time_sync = self.auto_time_sync.map(Into::into);
        c.auto_tasks_retry_strategy = self.auto_tasks_retry_strategy.into();
        c.keep_alive_timeout = self.keep_alive_timeout_ms.map(ms);
        c.auto_integrity_scan_on_buffer_overflow = self.auto_integrity_scan_on_buffer_overflow;
        c.max_queued_user_requests = self.max_queued_user_requests;
        Ok(c)
    }
}

#[derive(Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct AddAssociationDto {
    pub address: u16,
    #[serde(default)]
    pub udp_destination: Option<String>,
    #[serde(default)]
    pub config: AssociationConfigDto,
    /// forward association information events (task start/success/fail, unsolicited)
    #[serde(default)]
    pub information: bool,
}

// ---------------------------------------------------------------------------------------
// outstation
// ---------------------------------------------------------------------------------------

#[derive(Deserialize, Clone, Copy, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct EventBufferDto {
    pub max_binary: u16,
    pub max_double_binary: u16,
    pub max_binary_output_status: u16,
    pub max_counter: u16,
    pub max_frozen_counter: u16,
    pub max_analog: u16,
    pub max_analog_output_status: u16,
    pub max_octet_string: u16,
}

impl From<EventBufferDto> for EventBufferConfig {
    fn from(x: EventBufferDto) -> Self {
        EventBufferConfig::new(
            x.max_binary,
            x.max_double_binary,
            x.max_binary_output_status,
            x.max_counter,
            x.max_frozen_counter,
            x.max_analog,
            x.max_analog_output_status,
            x.max_octet_string,
        )
    }
}

#[derive(Deserialize, Clone, Copy)]
#[serde(rename_all = "camelCase", default)]
pub struct FeaturesDto {
    pub self_address: bool,
    pub broadcast: bool,
    pub unsolicited: bool,
    pub respond_to_any_master: bool,
}

impl Default for FeaturesDto {
    fn default() -> Self {
        Self {
            self_address: false,
            broadcast: true,
            unsolicited: true,
            respond_to_any_master: false,
        }
    }
}

fn feature(x: bool) -> Feature {
    if x {
        Feature::Enabled
    } else {
        Feature::Disabled
    }
}

impl From<FeaturesDto> for Features {
    fn from(x: FeaturesDto) -> Self {
        Features {
            self_address: feature(x.self_address),
            broadcast: feature(x.broadcast),
            unsolicited: feature(x.unsolicited),
            respond_to_any_master: feature(x.respond_to_any_master),
        }
    }
}

#[derive(Deserialize, Clone, Copy)]
#[serde(rename_all = "camelCase", default)]
pub struct ClassZeroDto {
    pub binary: bool,
    pub double_bit_binary: bool,
    pub binary_output_status: bool,
    pub counter: bool,
    pub frozen_counter: bool,
    pub analog: bool,
    pub analog_output_status: bool,
    pub octet_string: bool,
}

impl Default for ClassZeroDto {
    fn default() -> Self {
        Self {
            binary: true,
            double_bit_binary: true,
            binary_output_status: true,
            counter: true,
            frozen_counter: true,
            analog: true,
            analog_output_status: true,
            octet_string: false,
        }
    }
}

impl From<ClassZeroDto> for ClassZeroConfig {
    fn from(x: ClassZeroDto) -> Self {
        ClassZeroConfig::new(
            x.binary,
            x.double_bit_binary,
            x.binary_output_status,
            x.counter,
            x.frozen_counter,
            x.analog,
            x.analog_output_status,
            x.octet_string,
        )
    }
}

#[derive(Deserialize, Clone, Copy)]
#[serde(rename_all = "camelCase")]
pub struct OutstationConfigDto {
    pub outstation_address: u16,
    pub master_address: u16,
    #[serde(default)]
    pub event_buffer_config: EventBufferDto,
    #[serde(default = "default_buffer")]
    pub solicited_buffer_size: usize,
    #[serde(default = "default_buffer")]
    pub unsolicited_buffer_size: usize,
    #[serde(default = "default_buffer")]
    pub rx_buffer_size: usize,
    #[serde(default)]
    pub decode_level: DecodeLevelDto,
    #[serde(default = "default_timeout_ms")]
    pub confirm_timeout_ms: u64,
    #[serde(default = "default_timeout_ms")]
    pub select_timeout_ms: u64,
    #[serde(default)]
    pub features: FeaturesDto,
    #[serde(default)]
    pub max_unsolicited_retries: Option<usize>,
    #[serde(default = "default_timeout_ms")]
    pub unsolicited_retry_delay_ms: u64,
    #[serde(default = "default_keep_alive")]
    pub keep_alive_timeout_ms: Option<u64>,
    #[serde(default)]
    pub max_read_request_headers: Option<u16>,
    #[serde(default)]
    pub max_controls_per_request: Option<u16>,
    #[serde(default)]
    pub class_zero: ClassZeroDto,
}

fn default_timeout_ms() -> u64 {
    5000
}

fn default_keep_alive() -> Option<u64> {
    Some(60_000)
}

impl OutstationConfigDto {
    pub fn to_config(self) -> Result<OutstationConfig> {
        let mut c = OutstationConfig::new(
            address(self.outstation_address)?,
            address(self.master_address)?,
            self.event_buffer_config.into(),
        );
        let buf = |x: usize, name: &str| {
            BufferSize::new(x).map_err(|e| Error::config(format!("invalid {name}: {e:?}")))
        };
        c.solicited_buffer_size = buf(self.solicited_buffer_size, "solicited buffer size")?;
        c.unsolicited_buffer_size = buf(self.unsolicited_buffer_size, "unsolicited buffer size")?;
        c.rx_buffer_size = buf(self.rx_buffer_size, "rx buffer size")?;
        c.decode_level = self.decode_level.into();
        c.confirm_timeout = timeout_ms(self.confirm_timeout_ms)?;
        c.select_timeout = timeout_ms(self.select_timeout_ms)?;
        c.features = self.features.into();
        c.max_unsolicited_retries = self.max_unsolicited_retries;
        c.unsolicited_retry_delay = ms(self.unsolicited_retry_delay_ms);
        c.keep_alive_timeout = self.keep_alive_timeout_ms.map(ms);
        c.max_read_request_headers = self.max_read_request_headers;
        c.max_controls_per_request = self.max_controls_per_request;
        c.class_zero = self.class_zero.into();
        Ok(c)
    }
}

/// How control operations (CROB / analog outputs) received by an outstation are handled
#[derive(Deserialize, Clone, Copy, Default, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum ControlModeDto {
    /// Ask Dart synchronously for every SELECT / OPERATE
    Callback,
    /// Accept every control in native code; optionally mirror it into the database
    #[default]
    Accept,
    /// Reject every control with a fixed status
    Reject,
}

#[derive(Deserialize, Clone, Copy)]
#[serde(rename_all = "camelCase", default)]
pub struct ControlHandlerDto {
    pub mode: ControlModeDto,
    /// CommandStatus returned in `reject` mode
    pub reject_status: u8,
    /// In `accept` mode, update BinaryOutputStatus / AnalogOutputStatus with the commanded value
    pub update_database: bool,
    /// Event mode used for the mirrored update: 0 detect, 1 force, 2 suppress
    pub event_mode: u8,
    /// Send an asynchronous notification for every executed control (accept mode)
    pub notify: bool,
    /// Timeout for callback mode; on expiry the status below is returned
    pub timeout_ms: u64,
    pub timeout_status: u8,
}

impl Default for ControlHandlerDto {
    fn default() -> Self {
        Self {
            mode: ControlModeDto::Accept,
            reject_status: 4, // NOT_SUPPORTED
            update_database: true,
            event_mode: 0,
            notify: true,
            timeout_ms: 2000,
            timeout_status: 1, // TIMEOUT
        }
    }
}

#[derive(Deserialize, Clone, Copy, Default, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum RestartModeDto {
    #[default]
    NotSupported,
    Seconds,
    Milliseconds,
    Callback,
}

#[derive(Deserialize, Clone, Copy, Default, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum TimeWriteModeDto {
    #[default]
    NotSupported,
    /// accept the time and notify Dart asynchronously
    Accept,
    Callback,
}

#[derive(Deserialize, Clone, Copy, Default, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum FreezeModeDto {
    #[default]
    NotSupported,
    /// copy counters into frozen counters natively (optionally clearing them)
    Auto,
    Callback,
}

#[derive(Deserialize, Clone, Copy, Default, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum AttrWriteModeDto {
    #[default]
    Accept,
    Reject,
    Callback,
}

#[derive(Deserialize, Clone, Copy)]
#[serde(rename_all = "camelCase", default)]
pub struct ApplicationDto {
    pub processing_delay_ms: u16,
    pub cold_restart: RestartModeDto,
    pub cold_restart_delay: u16,
    pub warm_restart: RestartModeDto,
    pub warm_restart_delay: u16,
    pub write_absolute_time: TimeWriteModeDto,
    pub freeze: FreezeModeDto,
    pub support_write_analog_dead_bands: bool,
    pub write_device_attr: AttrWriteModeDto,
    /// notify begin/end confirm (with cleared event ids) and dead band writes
    pub notify_confirm: bool,
    pub callback_timeout_ms: u64,
}

impl Default for ApplicationDto {
    fn default() -> Self {
        Self {
            processing_delay_ms: 0,
            cold_restart: RestartModeDto::NotSupported,
            cold_restart_delay: 0,
            warm_restart: RestartModeDto::NotSupported,
            warm_restart_delay: 0,
            write_absolute_time: TimeWriteModeDto::NotSupported,
            freeze: FreezeModeDto::NotSupported,
            support_write_analog_dead_bands: false,
            write_device_attr: AttrWriteModeDto::Accept,
            notify_confirm: false,
            callback_timeout_ms: 2000,
        }
    }
}

#[derive(Deserialize, Clone, Copy, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct HandlersDto {
    pub control: ControlHandlerDto,
    pub application: ApplicationDto,
    /// forward `OutstationInformation` callbacks
    pub information: bool,
}

#[derive(Deserialize, Clone)]
#[serde(
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    tag = "type"
)]
pub enum OutstationTransportDto {
    TcpClient {
        #[serde(flatten)]
        client: ClientDto,
    },
    TlsClient {
        #[serde(flatten)]
        client: ClientDto,
        tls: TlsDto,
    },
    Serial {
        path: String,
        #[serde(default)]
        settings: SerialSettingsDto,
        /// when present the port is re-opened after failures (fault tolerant mode)
        #[serde(default)]
        retry: Option<RetryStrategyDto>,
    },
    Udp {
        local_endpoint: String,
        remote_endpoint: String,
        #[serde(default)]
        socket_mode: UdpSocketModeDto,
        #[serde(default)]
        link_read_mode: LinkReadModeDto,
        #[serde(default = "default_retry_ms")]
        retry_delay_ms: u64,
    },
}

#[derive(Deserialize, Clone, Copy, Default)]
#[serde(rename_all = "camelCase")]
pub enum UdpSocketModeDto {
    #[default]
    OneToOne,
    OneToMany,
}

#[derive(Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct OutstationCreateDto {
    pub config: OutstationConfigDto,
    #[serde(default)]
    pub handlers: HandlersDto,
    pub transport: OutstationTransportDto,
}

#[derive(Deserialize, Clone)]
#[serde(
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    tag = "type"
)]
pub enum ServerDto {
    Tcp {
        address: String,
        #[serde(default)]
        link_error_mode: LinkErrorModeDto,
    },
    Tls {
        address: String,
        #[serde(default)]
        link_error_mode: LinkErrorModeDto,
        tls: TlsDto,
    },
}

#[derive(Deserialize, Clone, Default)]
#[serde(
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    tag = "type"
)]
pub enum AddressFilterDto {
    #[default]
    Any,
    Exact {
        address: String,
    },
    AnyOf {
        addresses: Vec<String>,
    },
    Wildcard {
        pattern: String,
    },
}

impl AddressFilterDto {
    pub fn to_filter(&self) -> Result<dnp3::tcp::AddressFilter> {
        use dnp3::tcp::{AddressFilter, WildcardIPv4};
        let ip = |s: &str| -> Result<std::net::IpAddr> {
            s.parse()
                .map_err(|_| Error::config(format!("invalid IP address: {s}")))
        };
        Ok(match self {
            Self::Any => AddressFilter::Any,
            Self::Exact { address } => AddressFilter::Exact(ip(address)?),
            Self::AnyOf { addresses } => AddressFilter::AnyOf(
                addresses
                    .iter()
                    .map(|x| ip(x))
                    .collect::<Result<std::collections::HashSet<_>>>()?,
            ),
            Self::Wildcard { pattern } => AddressFilter::WildcardIpv4(
                pattern
                    .parse::<WildcardIPv4>()
                    .map_err(|_| Error::config(format!("invalid IPv4 wildcard: {pattern}")))?,
            ),
        })
    }
}

#[derive(Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct ServerOutstationDto {
    pub config: OutstationConfigDto,
    #[serde(default)]
    pub handlers: HandlersDto,
    #[serde(default)]
    pub filter: AddressFilterDto,
}

// ---------------------------------------------------------------------------------------
// master server (master accepting TCP connections from outstations)
// ---------------------------------------------------------------------------------------

#[derive(Deserialize, Clone, Copy)]
#[serde(rename_all = "camelCase", default)]
pub struct LinkIdConfigDto {
    pub max_tasks: usize,
    pub timeout_ms: u64,
    pub decode_level: PhysLevel,
}

impl Default for LinkIdConfigDto {
    fn default() -> Self {
        Self {
            max_tasks: 16,
            timeout_ms: 5000,
            decode_level: PhysLevel::Nothing,
        }
    }
}

#[derive(Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct MasterServerDto {
    pub address: String,
    #[serde(default)]
    pub link_id_config: LinkIdConfigDto,
    #[serde(default = "default_timeout_ms")]
    pub callback_timeout_ms: u64,
}

#[derive(Deserialize, Clone, Copy)]
#[serde(rename_all = "camelCase")]
pub struct AcceptConfigDto {
    #[serde(default)]
    pub link_error_mode: LinkErrorModeDto,
    pub channel: MasterChannelConfigDto,
}

/// Reply of Dart to an `accept` request of the master server
#[derive(Deserialize, Clone, Copy)]
#[serde(
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    tag = "action"
)]
pub enum AcceptActionDto {
    Reject,
    GetLinkIdentity,
    Accept { config: AcceptConfigDto },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_minimal_master() {
        let x: MasterCreateDto = parse(
            r#"{"channel":{"masterAddress":1},"transport":{"type":"tcp","endpoints":["127.0.0.1:20000"]}}"#,
        )
        .unwrap();
        assert!(x.channel.to_config().is_ok());
    }

    #[test]
    fn parses_outstation_defaults() {
        let x: OutstationCreateDto = parse(
            r#"{"config":{"outstationAddress":10,"masterAddress":1},"transport":{"type":"udp","localEndpoint":"0.0.0.0:20000","remoteEndpoint":"127.0.0.1:20001"}}"#,
        )
        .unwrap();
        assert!(x.config.to_config().is_ok());
        assert!(x.handlers.control.mode == ControlModeDto::Accept);
    }

    #[test]
    fn parses_accept_action() {
        let x: AcceptActionDto =
            parse(r#"{"action":"accept","config":{"channel":{"masterAddress":1}}}"#).unwrap();
        assert!(matches!(x, AcceptActionDto::Accept { .. }));
    }
}
