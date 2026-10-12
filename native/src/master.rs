//! Master side: channels, associations, polls, commands and file transfer.

use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};

use dnp3::app::{FunctionCode, MaybeAsync, Sequence, Timestamp};
use dnp3::app::{PermissionSet, Permissions};
use dnp3::master::*;

use crate::codec::Writer;
use crate::common::*;
use crate::config::{self, MasterCreateDto, MasterTransportDto};
use crate::core::*;
use crate::dart::{post, DartPort, Payload};
use crate::measurement::{MeasurementHandler, Sink};

pub struct MasterEntry {
    pub channel: MasterChannel,
    pub children: Mutex<Vec<u64>>,
}

pub struct AssociationEntry {
    pub handle: AssociationHandle,
    pub master: u64,
    pub polls: Mutex<Vec<u64>>,
    pub time_offset_ms: Arc<AtomicI64>,
}

pub static MASTERS: Registry<Arc<MasterEntry>> = Registry::new();
pub static ASSOCIATIONS: Registry<Arc<AssociationEntry>> = Registry::new();
pub static POLLS: Registry<PollHandle> = Registry::new();
static FILE_READS: Registry<Arc<AtomicBool>> = Registry::new();

pub fn clear() {
    POLLS.clear();
    ASSOCIATIONS.clear();
    MASTERS.clear();
    FILE_READS.clear();
}

// ---------------------------------------------------------------------------------------
// creation
// ---------------------------------------------------------------------------------------

pub fn create(json: &str, events: DartPort) -> Result<i64> {
    let dto: MasterCreateDto = config::parse(json)?;
    let channel_config = dto.channel.to_config()?;
    let id = next_id();
    let channel = match dto.transport {
        MasterTransportDto::Tcp { client } => {
            let handler = DartConnectHandler::create(&client, events, id as i64)?;
            enter(|| {
                dnp3::tcp::spawn_master_tcp_client_3(
                    client.link_error_mode.into(),
                    channel_config,
                    handler,
                    Box::new(ClientStateListener {
                        port: events,
                        id: id as i64,
                    }),
                )
            })?
        }
        MasterTransportDto::Tls { client, tls } => {
            let tls = tls.client()?;
            let handler = DartConnectHandler::create(&client, events, id as i64)?;
            enter(|| {
                dnp3::tcp::tls::spawn_master_tls_client_3(
                    client.link_error_mode.into(),
                    channel_config,
                    handler,
                    Box::new(ClientStateListener {
                        port: events,
                        id: id as i64,
                    }),
                    tls,
                )
            })?
        }
        MasterTransportDto::Serial {
            path,
            settings,
            retry_delay_ms,
        } => create_serial(id, events, channel_config, &path, settings, retry_delay_ms)?,
        MasterTransportDto::Udp {
            local_endpoint,
            link_read_mode,
            retry_delay_ms,
        } => {
            let local = config::socket_addr(&local_endpoint)?;
            let retry = config::timeout_ms(retry_delay_ms)?;
            enter(|| {
                dnp3::udp::spawn_master_udp(local, link_read_mode.into(), retry, channel_config)
            })?
        }
    };
    register_channel(id, channel);
    Ok(id as i64)
}

pub fn register_channel(id: u64, channel: MasterChannel) {
    MASTERS.insert_with_id(
        id,
        Arc::new(MasterEntry {
            channel,
            children: Mutex::new(Vec::new()),
        }),
    );
}

#[cfg(has_serial)]
fn create_serial(
    id: u64,
    events: DartPort,
    config: MasterChannelConfig,
    path: &str,
    settings: config::SerialSettingsDto,
    retry_delay_ms: u64,
) -> Result<MasterChannel> {
    let settings = settings.to_settings()?;
    enter(|| {
        dnp3::serial::spawn_master_serial(
            config,
            path,
            settings,
            Duration::from_millis(retry_delay_ms),
            Box::new(PortStateListener {
                port: events,
                id: id as i64,
            }),
        )
    })
}

#[cfg(not(has_serial))]
fn create_serial(
    _id: u64,
    _events: DartPort,
    _config: MasterChannelConfig,
    _path: &str,
    _settings: config::SerialSettingsDto,
    _retry_delay_ms: u64,
) -> Result<MasterChannel> {
    Err(Error::new(
        err::NOT_SUPPORTED,
        "serial ports are not supported on this platform",
    ))
}

pub fn destroy(id: u64) -> Result<i64> {
    let entry = MASTERS
        .remove(id)
        .ok_or_else(|| Error::invalid_handle(id))?;
    let children = std::mem::take(&mut *entry.children.lock().unwrap());
    for assoc in children {
        drop_association_entry(assoc);
    }
    Ok(0)
}

fn drop_association_entry(id: u64) {
    if let Some(a) = ASSOCIATIONS.remove(id) {
        for p in a.polls.lock().unwrap().drain(..) {
            POLLS.remove(p);
        }
    }
}

fn channel(id: u64) -> Result<MasterChannel> {
    MASTERS.with(id, |m| m.channel.clone())
}

fn association(id: u64) -> Result<AssociationHandle> {
    ASSOCIATIONS.with(id, |a| a.handle.clone())
}

pub fn enable(id: u64, c: Completion) -> Result<i64> {
    let mut ch = channel(id)?;
    spawn_op(c, async move { ch.enable().await.map_err(Error::from) })
}

pub fn disable(id: u64, c: Completion) -> Result<i64> {
    let mut ch = channel(id)?;
    spawn_op(c, async move { ch.disable().await.map_err(Error::from) })
}

pub fn set_decode_level(id: u64, json: &str, c: Completion) -> Result<i64> {
    let level: config::DecodeLevelDto = config::parse(json)?;
    let mut ch = channel(id)?;
    spawn_op(c, async move {
        ch.set_decode_level(level.into()).await.map_err(Error::from)
    })
}

pub fn get_decode_level(id: u64, c: Completion) -> Result<i64> {
    let mut ch = channel(id)?;
    spawn_op(c, async move {
        let level = ch.get_decode_level().await?;
        Ok(config::decode_level_to_json(level))
    })
}

// ---------------------------------------------------------------------------------------
// associations
// ---------------------------------------------------------------------------------------

struct TimeProvider {
    offset_ms: Arc<AtomicI64>,
}

impl AssociationHandler for TimeProvider {
    fn get_current_time(&self) -> Option<Timestamp> {
        let offset = self.offset_ms.load(Ordering::Relaxed);
        let now = SystemTime::now();
        let t = if offset >= 0 {
            now.checked_add(Duration::from_millis(offset as u64))?
        } else {
            now.checked_sub(Duration::from_millis(offset.unsigned_abs()))?
        };
        Timestamp::try_from_system_time(t)
    }
}

pub mod assoc_event {
    pub const TASK_START: i64 = 0;
    pub const TASK_SUCCESS: i64 = 1;
    pub const TASK_FAIL: i64 = 2;
    pub const UNSOLICITED: i64 = 3;
}

fn task_type_code(t: TaskType) -> (i64, i64) {
    match t {
        TaskType::UserRead => (0, 0),
        TaskType::PeriodicPoll => (1, 0),
        TaskType::StartupIntegrity => (2, 0),
        TaskType::AutoEventScan => (3, 0),
        TaskType::Command => (4, 0),
        TaskType::ClearRestartBit => (5, 0),
        TaskType::EnableUnsolicited => (6, 0),
        TaskType::DisableUnsolicited => (7, 0),
        TaskType::TimeSync => (8, 0),
        TaskType::Restart => (9, 0),
        TaskType::WriteDeadBands => (10, 0),
        TaskType::GenericEmptyResponse(fc) => (11, fc.as_u8() as i64),
        TaskType::FileRead => (12, 0),
        TaskType::FileAuth => (13, 0),
        TaskType::FileOpen => (14, 0),
        TaskType::FileWriteBlock => (15, 0),
        TaskType::FileClose => (16, 0),
        TaskType::GetFileInfo => (17, 0),
    }
}

/// Packs association information into a single integer:
/// `task_type | fc << 8 | seq << 16 | sub << 24` (sub = task error sub-code / duplicate flag)
struct InfoForwarder {
    port: DartPort,
    id: i64,
    enabled: bool,
}

impl InfoForwarder {
    fn send(&self, event: i64, value: i64) {
        if self.enabled {
            post(
                self.port,
                msg::ASSOCIATION_INFO,
                self.id,
                event,
                Payload::Int(value),
            );
        }
    }
}

impl AssociationInformation for InfoForwarder {
    fn task_start(&mut self, task_type: TaskType, fc: FunctionCode, seq: Sequence) {
        let (t, _) = task_type_code(task_type);
        self.send(
            assoc_event::TASK_START,
            t | ((fc.as_u8() as i64) << 8) | ((seq.value() as i64) << 16),
        );
    }

    fn task_success(&mut self, task_type: TaskType, fc: FunctionCode, seq: Sequence) {
        let (t, _) = task_type_code(task_type);
        self.send(
            assoc_event::TASK_SUCCESS,
            t | ((fc.as_u8() as i64) << 8) | ((seq.value() as i64) << 16),
        );
    }

    fn task_fail(&mut self, task_type: TaskType, error: TaskError) {
        let (t, fc) = task_type_code(task_type);
        let sub = task_error_sub(&error);
        self.send(assoc_event::TASK_FAIL, t | (fc << 8) | (sub << 24));
    }

    fn unsolicited_response(&mut self, is_duplicate: bool, seq: Sequence) {
        self.send(
            assoc_event::UNSOLICITED,
            (is_duplicate as i64) | ((seq.value() as i64) << 16),
        );
    }
}

pub fn add_association(master: u64, json: &str, events: DartPort, c: Completion) -> Result<i64> {
    let dto: config::AddAssociationDto = config::parse(json)?;
    let address = config::address(dto.address)?;
    let assoc_config = dto.config.to_config()?;
    let destination = match &dto.udp_destination {
        Some(x) => Some(config::socket_addr(x)?),
        None => None,
    };
    let mut ch = channel(master)?;
    let id = next_id();
    let offset = Arc::new(AtomicI64::new(0));
    let read_handler = Box::new(MeasurementHandler::new(Sink::Port {
        port: events,
        id: id as i64,
    }));
    let assoc_handler = Box::new(TimeProvider {
        offset_ms: offset.clone(),
    });
    let info = Box::new(InfoForwarder {
        port: events,
        id: id as i64,
        enabled: dto.information,
    });

    spawn_op(c, async move {
        let handle = match destination {
            None => {
                ch.add_association(address, assoc_config, read_handler, assoc_handler, info)
                    .await
            }
            Some(dest) => {
                ch.add_udp_association(
                    address,
                    dest,
                    assoc_config,
                    read_handler,
                    assoc_handler,
                    info,
                )
                .await
            }
        }
        .map_err(association_error)?;

        // the master may have been destroyed concurrently
        let registered = MASTERS.with(master, |m| m.children.lock().unwrap().push(id));
        if registered.is_err() {
            return Err(Error::invalid_handle(master));
        }
        ASSOCIATIONS.insert_with_id(
            id,
            Arc::new(AssociationEntry {
                handle,
                master,
                polls: Mutex::new(Vec::new()),
                time_offset_ms: offset,
            }),
        );
        Ok(id as i64)
    })
}

pub fn remove_association(id: u64, c: Completion) -> Result<i64> {
    let entry = ASSOCIATIONS.get(id)?;
    let _ = MASTERS.with(entry.master, |m| {
        m.children.lock().unwrap().retain(|x| *x != id)
    });
    drop_association_entry(id);
    let handle = entry.handle.clone();
    spawn_op(c, async move { handle.remove().await.map_err(Error::from) })
}

pub fn set_time_offset(id: u64, offset_ms: i64) -> Result<i64> {
    ASSOCIATIONS.with(id, |a| a.time_offset_ms.store(offset_ms, Ordering::Relaxed))?;
    Ok(0)
}

pub fn read(id: u64, req: &[u8], c: Completion) -> Result<i64> {
    let request = crate::requests::read_request(req)?;
    let mut a = association(id)?;
    spawn_op(c, async move { a.read(request).await.map_err(task_error) })
}

/// Read with a one-off handler: all fragments are returned in the completion payload as
/// `[u32 length, fragment, padding to 8]*`
pub fn read_with_handler(id: u64, req: &[u8], c: Completion) -> Result<i64> {
    let request = crate::requests::read_request(req)?;
    let mut a = association(id)?;
    spawn_op(c, async move {
        let acc = Arc::new(Mutex::new(Vec::with_capacity(512)));
        let handler = Box::new(MeasurementHandler::new(Sink::Collect(acc.clone())));
        a.read_with_handler(request, handler)
            .await
            .map_err(task_error)?;
        let data = std::mem::take(&mut *acc.lock().unwrap());
        Ok(data)
    })
}

pub fn operate(id: u64, req: &[u8], c: Completion) -> Result<i64> {
    let (mode, headers) = crate::requests::command(req)?;
    let mut a = association(id)?;
    spawn_op(c, async move {
        a.operate(mode, headers).await.map_err(command_error)
    })
}

pub fn send_and_expect_empty_response(id: u64, fc: u8, req: &[u8], c: Completion) -> Result<i64> {
    let function = crate::requests::function_code(fc)?;
    let headers = crate::requests::headers(req)?;
    let mut a = association(id)?;
    spawn_op(c, async move {
        a.send_and_expect_empty_response(function, headers)
            .await
            .map_err(write_error)
    })
}

pub fn restart(id: u64, cold: bool, c: Completion) -> Result<i64> {
    let mut a = association(id)?;
    spawn_op(c, async move {
        let d = if cold {
            a.cold_restart().await
        } else {
            a.warm_restart().await
        }
        .map_err(task_error)?;
        Ok(d.as_millis() as i64)
    })
}

pub fn synchronize_time(id: u64, procedure: u8, c: Completion) -> Result<i64> {
    let procedure = match procedure {
        0 => TimeSyncProcedure::Lan,
        1 => TimeSyncProcedure::NonLan,
        2 => TimeSyncProcedure::DirectWriteAbsTime,
        x => return Err(Error::arg(format!("unknown time sync procedure {x}"))),
    };
    let mut a = association(id)?;
    spawn_op(c, async move {
        a.synchronize_time(procedure).await.map_err(time_sync_error)
    })
}

pub fn write_dead_bands(id: u64, req: &[u8], c: Completion) -> Result<i64> {
    let headers = crate::requests::dead_bands(req)?;
    let mut a = association(id)?;
    spawn_op(c, async move {
        a.write_dead_bands(headers).await.map_err(write_error)
    })
}

pub fn check_link_status(id: u64, c: Completion) -> Result<i64> {
    let mut a = association(id)?;
    spawn_op(
        c,
        async move { a.check_link_status().await.map_err(task_error) },
    )
}

// ---------------------------------------------------------------------------------------
// polls
// ---------------------------------------------------------------------------------------

pub fn add_poll(id: u64, req: &[u8], period_ms: u64, c: Completion) -> Result<i64> {
    let request = crate::requests::read_request(req)?;
    let mut a = association(id)?;
    spawn_op(c, async move {
        let poll = a
            .add_poll(request, Duration::from_millis(period_ms))
            .await
            .map_err(poll_error)?;
        let poll_id = POLLS.insert(poll);
        if ASSOCIATIONS
            .with(id, |a| a.polls.lock().unwrap().push(poll_id))
            .is_err()
        {
            POLLS.remove(poll_id);
            return Err(Error::invalid_handle(id));
        }
        Ok(poll_id as i64)
    })
}

pub fn demand_poll(id: u64, c: Completion) -> Result<i64> {
    let mut poll = POLLS.get(id)?;
    spawn_op(c, async move { poll.demand().await.map_err(Error::from) })
}

pub fn remove_poll(id: u64, c: Completion) -> Result<i64> {
    let poll = POLLS.remove(id).ok_or_else(|| Error::invalid_handle(id))?;
    spawn_op(c, async move { poll.remove().await.map_err(Error::from) })
}

// ---------------------------------------------------------------------------------------
// file transfer
// ---------------------------------------------------------------------------------------

pub fn permissions_from_u16(x: u16) -> Permissions {
    let set = |shift: u16| PermissionSet {
        execute: x & (1 << shift) != 0,
        write: x & (1 << (shift + 1)) != 0,
        read: x & (1 << (shift + 2)) != 0,
    };
    Permissions {
        world: set(0),
        group: set(3),
        owner: set(6),
    }
}

pub fn permissions_to_u16(p: &Permissions) -> u16 {
    let set = |s: &PermissionSet, shift: u16| -> u16 {
        ((s.execute as u16) << shift)
            | ((s.write as u16) << (shift + 1))
            | ((s.read as u16) << (shift + 2))
    };
    set(&p.world, 0) | set(&p.group, 3) | set(&p.owner, 6)
}

/// `u8 type (0 dir, 1 file, 2 other), u8 pad, u16 raw type, u32 size, u64 created,
///  u16 permissions, u16 pad, blob name`
fn encode_file_info(w: &mut Writer, info: &FileInfo) {
    use dnp3::app::FileType;
    let (t, raw) = match info.file_type {
        FileType::Directory => (0u8, 0u16),
        FileType::File => (1, 1),
        FileType::Other(x) => (2, x),
    };
    w.u8(t);
    w.u8(0);
    w.u16(raw);
    w.u32(info.size);
    w.u64(info.time_created.raw_value());
    w.u16(permissions_to_u16(&info.permissions));
    w.u16(0);
    w.blob(info.name.as_bytes());
}

fn credentials(user: Option<&str>, password: Option<&str>) -> Option<FileCredentials> {
    match (user, password) {
        (Some(u), Some(p)) => Some(FileCredentials {
            user_name: u.to_string(),
            password: p.to_string(),
        }),
        _ => None,
    }
}

pub fn get_file_auth_key(id: u64, user: &str, password: &str, c: Completion) -> Result<i64> {
    let mut a = association(id)?;
    let creds = FileCredentials {
        user_name: user.to_string(),
        password: password.to_string(),
    };
    spawn_op(c, async move {
        let key = a.get_file_auth_key(creds).await.map_err(file_error)?;
        Ok(u32::from(key) as i64)
    })
}

#[allow(clippy::too_many_arguments)]
pub fn open_file(
    id: u64,
    name: &str,
    auth_key: u32,
    permissions: u16,
    file_size: u32,
    mode: u16,
    max_block_size: u16,
    c: Completion,
) -> Result<i64> {
    let mut a = association(id)?;
    let name = name.to_string();
    let mode = match mode {
        0 => FileMode::Null,
        1 => FileMode::Read,
        2 => FileMode::Write,
        3 => FileMode::Append,
        x => FileMode::Reserved(x),
    };
    spawn_op(c, async move {
        let open = a
            .open_file(
                name,
                AuthKey::new(auth_key),
                permissions_from_u16(permissions),
                file_size,
                mode,
                max_block_size,
            )
            .await
            .map_err(file_error)?;
        let mut w = Writer::with_capacity(16);
        w.u32(u32::from(open.file_handle));
        w.u32(open.file_size);
        w.u16(open.max_block_size);
        w.u16(0);
        Ok(Payload::CopiedBytes(w.finish()))
    })
}

pub fn write_file_block(
    id: u64,
    handle: u32,
    block: u32,
    data: &[u8],
    c: Completion,
) -> Result<i64> {
    let mut a = association(id)?;
    let data = data.to_vec();
    spawn_op(c, async move {
        a.write_file_block(
            FileHandle::new(handle),
            BlockNumber::from_ffi_raw(block),
            data,
        )
        .await
        .map_err(file_error)
    })
}

pub fn close_file(id: u64, handle: u32, c: Completion) -> Result<i64> {
    let mut a = association(id)?;
    spawn_op(c, async move {
        a.close_file(FileHandle::new(handle))
            .await
            .map_err(file_error)
    })
}

pub fn get_file_info(id: u64, path: &str, c: Completion) -> Result<i64> {
    let mut a = association(id)?;
    let path = path.to_string();
    spawn_op(c, async move {
        let info = a.get_file_info(path).await.map_err(file_error)?;
        let mut w = Writer::with_capacity(64);
        encode_file_info(&mut w, &info);
        Ok(Payload::CopiedBytes(w.finish()))
    })
}

pub fn read_directory(
    id: u64,
    path: &str,
    max_block_size: u16,
    max_file_size: u64,
    user: Option<&str>,
    password: Option<&str>,
    c: Completion,
) -> Result<i64> {
    let mut a = association(id)?;
    let path = path.to_string();
    let creds = credentials(user, password);
    let config = DirReadConfig {
        max_block_size,
        max_file_size: max_file_size.min(usize::MAX as u64) as usize,
    };
    spawn_op(c, async move {
        let items = a
            .read_directory(path, config, creds)
            .await
            .map_err(file_error)?;
        let mut w = Writer::with_capacity(64 * items.len() + 4);
        w.u32(items.len() as u32);
        for x in &items {
            encode_file_info(&mut w, x);
        }
        Ok(w.finish())
    })
}

pub mod file_event {
    pub const OPENED: i64 = 0;
    pub const BLOCK: i64 = 1;
    pub const ABORTED: i64 = 2;
    pub const COMPLETED: i64 = 3;
}

struct DartFileReader {
    port: DartPort,
    id: i64,
    abort: Arc<AtomicBool>,
}

impl DartFileReader {
    fn action(&self) -> FileAction {
        if self.abort.load(Ordering::Relaxed) {
            FileAction::Abort
        } else {
            FileAction::Continue
        }
    }
}

impl FileReader for DartFileReader {
    fn opened(&mut self, size: u32) -> FileAction {
        post(
            self.port,
            msg::FILE_READ,
            self.id,
            file_event::OPENED,
            Payload::Int(size as i64),
        );
        self.action()
    }

    fn block_received(&mut self, block_num: u32, data: &[u8]) -> MaybeAsync<FileAction> {
        // 8-byte prefix keeps the data aligned: u32 block number, u32 length
        let mut buf = Vec::with_capacity(data.len() + 8);
        buf.extend_from_slice(&block_num.to_le_bytes());
        buf.extend_from_slice(&(data.len() as u32).to_le_bytes());
        buf.extend_from_slice(data);
        post(
            self.port,
            msg::FILE_READ,
            self.id,
            file_event::BLOCK,
            Payload::Bytes(buf),
        );
        MaybeAsync::ready(self.action())
    }

    fn aborted(&mut self, err: FileError) {
        let e = file_error(err);
        FILE_READS.remove(self.id as u64);
        post(
            self.port,
            msg::FILE_READ,
            self.id,
            file_event::ABORTED,
            Payload::Str(format!("{}|{}|{}", e.code, e.sub, e.message)),
        );
    }

    fn completed(&mut self) {
        FILE_READS.remove(self.id as u64);
        post(
            self.port,
            msg::FILE_READ,
            self.id,
            file_event::COMPLETED,
            Payload::Null,
        );
    }
}

/// Start reading a file. Returns the id of the transfer; progress is reported on `events`.
pub fn read_file(
    id: u64,
    path: &str,
    max_block_size: u16,
    max_file_size: u64,
    user: Option<&str>,
    password: Option<&str>,
    events: DartPort,
) -> Result<i64> {
    let mut a = association(id)?;
    let abort = Arc::new(AtomicBool::new(false));
    let read_id = FILE_READS.insert(abort.clone());
    let reader = Box::new(DartFileReader {
        port: events,
        id: read_id as i64,
        abort,
    });
    let config = FileReadConfig {
        max_block_size,
        max_file_size: max_file_size.min(usize::MAX as u64) as usize,
    };
    let path = path.to_string();
    let creds = credentials(user, password);
    spawn(async move {
        if a.read_file(path, config, reader, creds).await.is_err() {
            FILE_READS.remove(read_id);
            post(
                events,
                msg::FILE_READ,
                read_id as i64,
                file_event::ABORTED,
                Payload::Str(format!("{}|0|master has been shut down", err::SHUTDOWN)),
            );
        }
    })?;
    Ok(read_id as i64)
}

pub fn abort_file_read(id: u64) -> Result<i64> {
    FILE_READS.with(id, |x| x.store(true, Ordering::Relaxed))?;
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn permissions_round_trip() {
        for x in [0u16, 0x1FF, 0x124, 0x049, 0x0A5] {
            assert_eq!(permissions_to_u16(&permissions_from_u16(x)), x);
        }
    }
}
