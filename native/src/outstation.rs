//! Outstation side: creation on every transport, TCP/TLS servers, database access and the
//! callback handlers (controls, application, information).

use std::sync::atomic::{AtomicU16, AtomicU8, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};

use dnp3::app::attr::Attribute;
use dnp3::app::control::*;
use dnp3::app::measurement::*;
use dnp3::app::{FunctionCode, MaybeAsync, RequestHeader, Sequence, Timestamp};
use dnp3::outstation::database::*;
use dnp3::outstation::*;
use dnp3::tcp::{AddressFilter, Server, ServerHandle};

use crate::codec::Writer;
use crate::common::*;
use crate::config::{self, *};
use crate::core::*;
use crate::dart::{post, DartPort, Payload};
use crate::database::{self as dbops, PointIndex};
use crate::measurement::kind;

pub struct Shared {
    pub application_iin: AtomicU8,
    pub processing_delay_ms: AtomicU16,
    pub points: Mutex<PointIndex>,
    /// native FREEZE_AT_TIME schedule (`FreezeMode::Auto`)
    freeze_task: Mutex<Option<tokio::task::AbortHandle>>,
}

impl Shared {
    fn new(processing_delay_ms: u16) -> Arc<Self> {
        Arc::new(Self {
            application_iin: AtomicU8::new(0),
            processing_delay_ms: AtomicU16::new(processing_delay_ms),
            points: Mutex::new(PointIndex::default()),
            freeze_task: Mutex::new(None),
        })
    }
}

impl Drop for Shared {
    fn drop(&mut self) {
        if let Some(t) = self.freeze_task.get_mut().unwrap().take() {
            t.abort();
        }
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// Next fire time (epoch ms) of a freeze schedule at or after `now`; `None` when a
/// one-shot schedule has already fired.
pub fn next_freeze_time(interval: FreezeInterval, now: u64, fired: bool) -> Option<u64> {
    let periodic = |anchor: u64, period: u64| -> u64 {
        if now <= anchor {
            anchor
        } else {
            anchor + ((now - anchor) / period + 1) * period
        }
    };
    match interval {
        FreezeInterval::FreezeOnceImmediately => (!fired).then_some(now),
        FreezeInterval::FreezeOnceAtTime(t) => (!fired).then_some(t.raw_value().max(now)),
        FreezeInterval::PeriodicallyFreeze(t, period) => {
            Some(periodic(t.raw_value(), period.max(1) as u64))
        }
        FreezeInterval::PeriodicallyFreezeRelative(period) => {
            let hour_start = now - now % 3_600_000;
            Some(periodic(hour_start, period.max(1) as u64))
        }
    }
}

#[derive(Clone)]
pub struct OutstationEntry {
    pub handle: OutstationHandle,
    pub db: DatabaseHandle,
    pub shared: Arc<Shared>,
}

enum ServerState {
    Building(Server),
    Bound(#[allow(dead_code)] ServerHandle),
    Binding,
}

pub struct ServerEntry {
    state: Mutex<ServerState>,
    outstations: Mutex<Vec<u64>>,
}

pub static OUTSTATIONS: Registry<OutstationEntry> = Registry::new();
static SERVERS: Registry<Arc<ServerEntry>> = Registry::new();

pub fn clear() {
    OUTSTATIONS.clear();
    SERVERS.clear();
}

pub fn get(id: u64) -> Result<OutstationEntry> {
    OUTSTATIONS.get(id)
}

// ---------------------------------------------------------------------------------------
// control handler
// ---------------------------------------------------------------------------------------

pub mod event {
    pub const CONTROL_EXECUTED: i64 = 0;
    pub const TIME_WRITTEN: i64 = 1;
    pub const DEAD_BANDS_WRITTEN: i64 = 2;
    pub const ATTRIBUTE_WRITTEN: i64 = 3;
    pub const CONFIRM: i64 = 4;
    pub const COUNTERS_FROZEN: i64 = 5;
    pub const RESTART: i64 = 6;
    pub const CONTROL_FRAGMENT_BEGIN: i64 = 7;
}

pub mod app_request {
    pub const WRITE_TIME: u8 = 1;
    pub const COLD_RESTART: u8 = 2;
    pub const WARM_RESTART: u8 = 3;
    pub const FREEZE: u8 = 4;
    pub const WRITE_ATTRIBUTE: u8 = 5;
}

#[derive(Copy, Clone)]
enum Cmd {
    Crob(Group12Var1),
    I32(Group41Var1),
    I16(Group41Var2),
    F32(Group41Var3),
    F64(Group41Var4),
}

impl Cmd {
    fn type_code(&self) -> u8 {
        match self {
            Cmd::Crob(_) => 0,
            Cmd::I32(_) => 1,
            Cmd::I16(_) => 2,
            Cmd::F32(_) => 3,
            Cmd::F64(_) => 4,
        }
    }

    fn analog_value(&self) -> f64 {
        match self {
            Cmd::Crob(_) => 0.0,
            Cmd::I32(x) => x.value as f64,
            Cmd::I16(x) => x.value as f64,
            Cmd::F32(x) => x.value as f64,
            Cmd::F64(x) => x.value,
        }
    }

    /// 24-byte record: `u8 phase, u8 op type, u8 cmd type, u8 status, u16 index, u16 pad,`
    /// then either `u8 code, u8 count, u16 pad, u32 on, u32 off, u32 pad` or `f64 value, u64 pad`
    fn encode(&self, phase: u8, op_type: u8, index: u16, status: u8) -> Vec<u8> {
        let mut w = Writer::with_capacity(24);
        w.u8(phase);
        w.u8(op_type);
        w.u8(self.type_code());
        w.u8(status);
        w.u16(index);
        w.u16(0);
        match self {
            Cmd::Crob(c) => {
                w.u8(crate::requests::control_code_byte(&c.code));
                w.u8(c.count);
                w.u16(0);
                w.u32(c.on_time);
                w.u32(c.off_time);
                w.u32(0);
            }
            _ => {
                w.f64(self.analog_value());
                w.u64(0);
            }
        }
        w.finish()
    }
}

fn op_type_code(x: OperateType) -> u8 {
    match x {
        OperateType::SelectBeforeOperate => 0,
        OperateType::DirectOperate => 1,
        OperateType::DirectOperateNoAck => 2,
    }
}

struct DartControlHandler {
    id: i64,
    port: DartPort,
    cfg: ControlHandlerDto,
    shared: Arc<Shared>,
    /// accept mode: commanded values mirrored into the database at `end_fragment`, so a
    /// request with N controls costs a single database transaction
    pending_mirror: Vec<(Cmd, u16)>,
}

/// phase byte of control records: SELECT / OPERATE / end of the request fragment
pub mod control_phase {
    pub const SELECT: u8 = 0;
    pub const OPERATE: u8 = 1;
    pub const FRAGMENT_END: u8 = 3;
}

fn event_mode(x: u8) -> EventMode {
    match x {
        1 => EventMode::Force,
        2 => EventMode::Suppress,
        _ => EventMode::Detect,
    }
}

fn apply_reply_ops(db: &mut Database, shared: &Shared, ops: &[u8], what: &str) {
    let mut points = shared.points.lock().unwrap();
    if let Err(e) = dbops::apply(db, ops, None, Some(&mut points)) {
        tracing::warn!("invalid database ops in {what}: {}", e.message);
    }
}

impl DartControlHandler {
    fn handle(
        &mut self,
        cmd: Cmd,
        index: u16,
        op: Option<OperateType>,
        db: &mut DatabaseHandle,
    ) -> CommandStatus {
        let phase = if op.is_some() {
            control_phase::OPERATE
        } else {
            control_phase::SELECT
        };
        let op_code = op.map(op_type_code).unwrap_or(255);
        match self.cfg.mode {
            ControlModeDto::Reject => CommandStatus::from(self.cfg.reject_status),
            ControlModeDto::Accept => {
                if op.is_some() {
                    if self.cfg.update_database {
                        self.pending_mirror.push((cmd, index));
                    }
                    if self.cfg.notify {
                        post(
                            self.port,
                            msg::OUTSTATION_EVENT,
                            self.id,
                            event::CONTROL_EXECUTED,
                            Payload::CopiedBytes(cmd.encode(phase, op_code, index, 0)),
                        );
                    }
                }
                CommandStatus::Success
            }
            ControlModeDto::Callback => {
                let payload = cmd.encode(phase, op_code, index, 0);
                match request_sync(
                    self.port,
                    msg::CONTROL_REQUEST,
                    self.id,
                    payload,
                    Duration::from_millis(self.cfg.timeout_ms),
                ) {
                    None => CommandStatus::from(self.cfg.timeout_status),
                    Some(reply) => {
                        if !reply.data.is_empty() {
                            let shared = self.shared.clone();
                            db.transaction(|db| {
                                apply_reply_ops(db, &shared, &reply.data, "control reply")
                            });
                        }
                        CommandStatus::from(reply.status as u8)
                    }
                }
            }
        }
    }

    fn mirror(db: &mut Database, cmd: Cmd, index: u16, opts: UpdateOptions, time: Option<Time>) {
        match cmd {
            Cmd::Crob(c) => {
                let state = match (c.code.op_type, c.code.tcc) {
                    (_, TripCloseCode::Close) => Some(true),
                    (_, TripCloseCode::Trip) => Some(false),
                    (OpType::LatchOn | OpType::PulseOn, _) => Some(true),
                    (OpType::LatchOff | OpType::PulseOff, _) => Some(false),
                    _ => None,
                };
                if let Some(value) = state {
                    db.update(
                        index,
                        &BinaryOutputStatus {
                            value,
                            flags: Flags::ONLINE,
                            time,
                        },
                        opts,
                    );
                }
            }
            _ => {
                db.update(
                    index,
                    &AnalogOutputStatus {
                        value: cmd.analog_value(),
                        flags: Flags::ONLINE,
                        time,
                    },
                    opts,
                );
            }
        }
    }
}

macro_rules! control_support {
    ($t:ty, $variant:ident) => {
        impl ControlSupport<$t> for DartControlHandler {
            fn select(
                &mut self,
                control: $t,
                index: u16,
                database: &mut DatabaseHandle,
            ) -> CommandStatus {
                self.handle(Cmd::$variant(control), index, None, database)
            }

            fn operate(
                &mut self,
                control: $t,
                index: u16,
                op_type: OperateType,
                database: &mut DatabaseHandle,
            ) -> CommandStatus {
                self.handle(Cmd::$variant(control), index, Some(op_type), database)
            }
        }
    };
}

control_support!(Group12Var1, Crob);
control_support!(Group41Var1, I32);
control_support!(Group41Var2, I16);
control_support!(Group41Var3, F32);
control_support!(Group41Var4, F64);

impl ControlHandler for DartControlHandler {
    fn begin_fragment(&mut self) {
        self.pending_mirror.clear();
        if self.cfg.fragment_callbacks {
            post(
                self.port,
                msg::OUTSTATION_EVENT,
                self.id,
                event::CONTROL_FRAGMENT_BEGIN,
                Payload::Null,
            );
        }
    }

    fn end_fragment(&mut self, database: &mut DatabaseHandle) -> MaybeAsync<()> {
        if !self.pending_mirror.is_empty() {
            let opts = UpdateOptions::new(true, event_mode(self.cfg.event_mode));
            let time = Timestamp::try_from_system_time(SystemTime::now()).map(Time::Synchronized);
            let pending = std::mem::take(&mut self.pending_mirror);
            database.transaction(|db| {
                for (cmd, index) in &pending {
                    Self::mirror(db, *cmd, *index, opts, time);
                }
            });
            self.pending_mirror = pending;
            self.pending_mirror.clear();
        }
        if !self.cfg.fragment_callbacks {
            return MaybeAsync::ready(());
        }
        // ask Dart (asynchronously, no worker is blocked) for database ops that complete
        // the request; they are applied before the response is sent
        let (port, id, timeout) = (
            self.port,
            self.id,
            Duration::from_millis(self.cfg.timeout_ms),
        );
        let shared = self.shared.clone();
        let db = database.clone();
        let mut payload = vec![0u8; 24];
        payload[0] = control_phase::FRAGMENT_END;
        MaybeAsync::asynchronous(async move {
            if let Some(reply) =
                request_async(port, msg::CONTROL_REQUEST, id, payload, timeout).await
            {
                if !reply.data.is_empty() {
                    db.transaction(|db| {
                        apply_reply_ops(db, &shared, &reply.data, "control fragment end")
                    });
                }
            }
        })
    }
}

// ---------------------------------------------------------------------------------------
// outstation application
// ---------------------------------------------------------------------------------------

struct DartApplication {
    id: i64,
    port: DartPort,
    cfg: ApplicationDto,
    shared: Arc<Shared>,
    dead_bands: Vec<(u16, f64)>,
    cleared: Vec<u64>,
}

impl DartApplication {
    fn timeout(&self) -> Duration {
        Duration::from_millis(self.cfg.callback_timeout_ms)
    }

    fn notify(&self, ev: i64, payload: Payload) {
        post(self.port, msg::OUTSTATION_EVENT, self.id, ev, payload);
    }

    fn ask(&self, payload: Vec<u8>) -> Option<Reply> {
        request_sync(
            self.port,
            msg::APPLICATION_REQUEST,
            self.id,
            payload,
            self.timeout(),
        )
    }

    fn restart(&mut self, cold: bool) -> Option<RestartDelay> {
        let (mode, delay) = if cold {
            (self.cfg.cold_restart, self.cfg.cold_restart_delay)
        } else {
            (self.cfg.warm_restart, self.cfg.warm_restart_delay)
        };
        let result = match mode {
            RestartModeDto::NotSupported => None,
            RestartModeDto::Seconds => Some(RestartDelay::Seconds(delay)),
            RestartModeDto::Milliseconds => Some(RestartDelay::Milliseconds(delay)),
            RestartModeDto::Callback => {
                let kind = if cold {
                    app_request::COLD_RESTART
                } else {
                    app_request::WARM_RESTART
                };
                let reply = self.ask(vec![kind, 0, 0, 0, 0, 0, 0, 0])?;
                let value = reply
                    .data
                    .get(0..2)
                    .map(|x| u16::from_le_bytes([x[0], x[1]]))
                    .unwrap_or(0);
                return match reply.status {
                    1 => Some(RestartDelay::Seconds(value)),
                    2 => Some(RestartDelay::Milliseconds(value)),
                    _ => None,
                };
            }
        };
        if result.is_some() {
            self.notify(event::RESTART, Payload::Int(cold as i64));
        }
        result
    }
}

impl DartApplication {
    /// Replace the current FREEZE_AT_TIME schedule
    fn schedule_freeze(
        &self,
        interval: FreezeInterval,
        start: u16,
        stop: u16,
        db: DatabaseHandle,
        record: Vec<u8>,
    ) {
        let weak = Arc::downgrade(&self.shared);
        let (port, id) = (self.port, self.id);
        let task = tokio::spawn(async move {
            let mut fired = false;
            while let Some(at) = next_freeze_time(interval, now_ms(), fired) {
                let wait = at.saturating_sub(now_ms());
                if wait > 0 {
                    tokio::time::sleep(Duration::from_millis(wait)).await;
                }
                let Some(shared) = weak.upgrade() else { return };
                let ts = Timestamp::new(at);
                db.transaction(|db| {
                    let points = shared.points.lock().unwrap();
                    dbops::freeze_counters(
                        db,
                        points.counters.range(start..=stop).copied(),
                        false,
                        ts,
                    );
                });
                post(
                    port,
                    msg::OUTSTATION_EVENT,
                    id,
                    event::COUNTERS_FROZEN,
                    Payload::CopiedBytes(record.clone()),
                );
                fired = true;
                // never fire twice for the same instant
                if now_ms() <= at {
                    tokio::time::sleep(Duration::from_millis(1)).await;
                }
            }
        });
        if let Some(old) = self
            .shared
            .freeze_task
            .lock()
            .unwrap()
            .replace(task.abort_handle())
        {
            old.abort();
        }
    }
}

fn request_error(status: i64) -> std::result::Result<(), RequestError> {
    match status {
        0 => Ok(()),
        1 => Err(RequestError::ParameterError),
        _ => Err(RequestError::NotSupported),
    }
}

impl OutstationApplication for DartApplication {
    fn get_processing_delay_ms(&self) -> u16 {
        self.shared.processing_delay_ms.load(Ordering::Relaxed)
    }

    fn write_absolute_time(&mut self, time: Timestamp) -> std::result::Result<(), RequestError> {
        match self.cfg.write_absolute_time {
            TimeWriteModeDto::NotSupported => Err(RequestError::NotSupported),
            TimeWriteModeDto::Accept => {
                self.notify(event::TIME_WRITTEN, Payload::Int(time.raw_value() as i64));
                Ok(())
            }
            TimeWriteModeDto::Callback => {
                let mut w = Writer::with_capacity(16);
                w.u8(app_request::WRITE_TIME);
                w.zeros(7);
                w.u64(time.raw_value());
                match self.ask(w.finish()) {
                    Some(reply) => request_error(reply.status),
                    None => Err(RequestError::NotSupported),
                }
            }
        }
    }

    fn get_application_iin(&self) -> ApplicationIin {
        let bits = self.shared.application_iin.load(Ordering::Relaxed);
        ApplicationIin {
            need_time: bits & 1 != 0,
            local_control: bits & 2 != 0,
            device_trouble: bits & 4 != 0,
            config_corrupt: bits & 8 != 0,
        }
    }

    fn cold_restart(&mut self) -> Option<RestartDelay> {
        self.restart(true)
    }

    fn warm_restart(&mut self) -> Option<RestartDelay> {
        self.restart(false)
    }

    fn freeze_counter(
        &mut self,
        indices: FreezeIndices,
        freeze_type: FreezeType,
        database: &mut DatabaseHandle,
    ) -> std::result::Result<(), RequestError> {
        let (ft, time, interval) = match freeze_type {
            FreezeType::ImmediateFreeze => (0u8, 0u64, 0u32),
            FreezeType::FreezeAndClear => (1, 0, 0),
            FreezeType::FreezeAtTime(i) => {
                let (t, interval) = i.get_time_and_interval();
                (2, t.raw_value(), interval)
            }
        };
        let (ik, start, stop) = match indices {
            FreezeIndices::All => (0u8, 0u16, u16::MAX),
            FreezeIndices::Range(a, b) => (1, a, b),
        };
        let mut w = Writer::with_capacity(24);
        w.u8(app_request::FREEZE);
        w.u8(ik);
        w.u8(ft);
        w.u8(0);
        w.u16(start);
        w.u16(stop);
        w.u64(time);
        w.u32(interval);
        w.u32(0);
        let record = w.finish();

        match self.cfg.freeze {
            FreezeModeDto::NotSupported => Err(RequestError::NotSupported),
            FreezeModeDto::Auto => {
                if let FreezeType::FreezeAtTime(interval) = freeze_type {
                    self.schedule_freeze(interval, start, stop, database.clone(), record);
                    return Ok(());
                }
                let now =
                    Timestamp::try_from_system_time(SystemTime::now()).unwrap_or(Timestamp::zero());
                let shared = self.shared.clone();
                database.transaction(|db| {
                    let points = shared.points.lock().unwrap();
                    let iter = points.counters.range(start..=stop).copied();
                    dbops::freeze_counters(db, iter, ft == 1, now);
                });
                self.notify(event::COUNTERS_FROZEN, Payload::CopiedBytes(record));
                Ok(())
            }
            FreezeModeDto::Callback => match self.ask(record) {
                None => Err(RequestError::NotSupported),
                Some(reply) => {
                    if !reply.data.is_empty() {
                        let shared = self.shared.clone();
                        database.transaction(|db| {
                            apply_reply_ops(db, &shared, &reply.data, "freeze reply")
                        });
                    }
                    request_error(reply.status)
                }
            },
        }
    }

    fn support_write_analog_dead_bands(&mut self) -> bool {
        self.cfg.support_write_analog_dead_bands
    }

    fn begin_write_analog_dead_bands(&mut self) {
        self.dead_bands.clear();
    }

    fn write_analog_dead_band(&mut self, index: u16, dead_band: f64) {
        self.dead_bands.push((index, dead_band));
    }

    fn end_write_analog_dead_bands(&mut self) -> MaybeAsync<()> {
        if !self.dead_bands.is_empty() {
            let mut w = Writer::with_capacity(16 * self.dead_bands.len());
            for (i, v) in self.dead_bands.drain(..) {
                w.u16(i);
                w.zeros(6);
                w.f64(v);
            }
            self.notify(event::DEAD_BANDS_WRITTEN, Payload::Bytes(w.finish()));
        }
        MaybeAsync::ready(())
    }

    fn write_device_attr(&mut self, attr: Attribute) -> MaybeAsync<bool> {
        let mut w = Writer::with_capacity(32);
        crate::measurement::encode_attribute(&mut w, attr.set, attr.variation, &attr.value);
        let encoded = w.finish();
        match self.cfg.write_device_attr {
            AttrWriteModeDto::Reject => MaybeAsync::ready(false),
            AttrWriteModeDto::Accept => {
                self.notify(event::ATTRIBUTE_WRITTEN, Payload::CopiedBytes(encoded));
                MaybeAsync::ready(true)
            }
            AttrWriteModeDto::Callback => {
                let port = self.port;
                let id = self.id;
                let timeout = self.timeout();
                let mut payload = vec![app_request::WRITE_ATTRIBUTE, 0, 0, 0, 0, 0, 0, 0];
                payload.extend_from_slice(&encoded);
                MaybeAsync::asynchronous(async move {
                    match request_async(port, msg::APPLICATION_REQUEST, id, payload, timeout).await
                    {
                        Some(reply) => reply.status == 1,
                        None => false,
                    }
                })
            }
        }
    }

    fn begin_confirm(&mut self) {
        self.cleared.clear();
    }

    fn event_cleared(&mut self, id: u64) {
        if self.cfg.notify_confirm {
            self.cleared.push(id);
        }
    }

    fn end_confirm(&mut self, state: BufferState) -> MaybeAsync<()> {
        if self.cfg.notify_confirm {
            let mut w = Writer::with_capacity(48 + 8 * self.cleared.len());
            let c = state.classes;
            let t = state.types;
            for x in [
                c.num_class_1,
                c.num_class_2,
                c.num_class_3,
                t.num_binary_input,
                t.num_double_bit_binary_input,
                t.num_binary_output_status,
                t.num_counter,
                t.num_frozen_counter,
                t.num_analog,
                t.num_analog_output_status,
                t.num_octet_string,
            ] {
                w.u32(x as u32);
            }
            w.u32(self.cleared.len() as u32);
            for id in self.cleared.drain(..) {
                w.u64(id);
            }
            self.notify(event::CONFIRM, Payload::Bytes(w.finish()));
        }
        MaybeAsync::ready(())
    }
}

// ---------------------------------------------------------------------------------------
// outstation information
// ---------------------------------------------------------------------------------------

struct DartInformation {
    id: i64,
    port: DartPort,
    enabled: bool,
}

impl DartInformation {
    fn send(&self, ev: i64, value: i64) {
        if self.enabled {
            post(
                self.port,
                msg::OUTSTATION_INFO,
                self.id,
                ev,
                Payload::Int(value),
            );
        }
    }
}

fn seq(s: Sequence) -> i64 {
    s.value() as i64
}

impl OutstationInformation for DartInformation {
    fn process_request_from_idle(&mut self, header: RequestHeader) {
        let c = header.control;
        let control = ((c.fir as i64) << 7)
            | ((c.fin as i64) << 6)
            | ((c.con as i64) << 5)
            | ((c.uns as i64) << 4)
            | seq(c.seq);
        self.send(0, header.function.as_u8() as i64 | (control << 8));
    }

    fn broadcast_received(&mut self, function: FunctionCode, action: BroadcastAction) {
        let a = match action {
            BroadcastAction::Processed => 0,
            BroadcastAction::IgnoredByConfiguration => 1,
            BroadcastAction::BadObjectHeaders => 2,
            BroadcastAction::UnsupportedFunction(fc) => 3 | ((fc.as_u8() as i64) << 8),
        };
        self.send(1, function.as_u8() as i64 | (a << 8));
    }

    fn enter_solicited_confirm_wait(&mut self, ecsn: Sequence) {
        self.send(2, seq(ecsn));
    }

    fn solicited_confirm_timeout(&mut self, ecsn: Sequence) {
        self.send(3, seq(ecsn));
    }

    fn solicited_confirm_received(&mut self, ecsn: Sequence) {
        self.send(4, seq(ecsn));
    }

    fn solicited_confirm_wait_new_request(&mut self) {
        self.send(5, 0);
    }

    fn wrong_solicited_confirm_seq(&mut self, ecsn: Sequence, s: Sequence) {
        self.send(6, seq(ecsn) | (seq(s) << 8));
    }

    fn unexpected_confirm(&mut self, unsolicited: bool, s: Sequence) {
        self.send(7, unsolicited as i64 | (seq(s) << 8));
    }

    fn enter_unsolicited_confirm_wait(&mut self, ecsn: Sequence) {
        self.send(8, seq(ecsn));
    }

    fn unsolicited_confirm_timeout(&mut self, ecsn: Sequence, retry: bool) {
        self.send(9, seq(ecsn) | ((retry as i64) << 8));
    }

    fn unsolicited_confirmed(&mut self, ecsn: Sequence) {
        self.send(10, seq(ecsn));
    }

    fn clear_restart_iin(&mut self) {
        self.send(11, 0);
    }
}

type Handlers = (
    Box<dyn OutstationApplication>,
    Box<dyn OutstationInformation>,
    Box<dyn ControlHandler>,
    Arc<Shared>,
);

fn handlers(id: u64, port: DartPort, h: &HandlersDto) -> Handlers {
    let shared = Shared::new(h.application.processing_delay_ms);
    (
        Box::new(DartApplication {
            id: id as i64,
            port,
            cfg: h.application,
            shared: shared.clone(),
            dead_bands: Vec::new(),
            cleared: Vec::new(),
        }),
        Box::new(DartInformation {
            id: id as i64,
            port,
            enabled: h.information,
        }),
        Box::new(DartControlHandler {
            id: id as i64,
            port,
            cfg: h.control,
            shared: shared.clone(),
            pending_mirror: Vec::new(),
        }),
        shared,
    )
}

fn register(id: u64, handle: OutstationHandle, shared: Arc<Shared>) {
    OUTSTATIONS.insert_with_id(
        id,
        OutstationEntry {
            db: handle.get_database_handle(),
            handle,
            shared,
        },
    );
}

// ---------------------------------------------------------------------------------------
// creation
// ---------------------------------------------------------------------------------------

pub fn create(json: &str, events: DartPort) -> Result<i64> {
    let dto: OutstationCreateDto = config::parse(json)?;
    let config = dto.config.to_config()?;
    let id = next_id();
    let (app, info, control, shared) = handlers(id, events, &dto.handlers);
    let handle = match dto.transport {
        OutstationTransportDto::TcpClient { client } => {
            let connect = DartConnectHandler::create(&client, events, id as i64)?;
            enter(|| {
                dnp3::tcp::spawn_outstation_tcp_client_2(
                    client.link_error_mode.into(),
                    config,
                    connect,
                    app,
                    info,
                    control,
                    Box::new(ClientStateListener {
                        port: events,
                        id: id as i64,
                    }),
                )
            })?
        }
        OutstationTransportDto::TlsClient { client, tls } => {
            let tls = tls.client()?;
            let connect = DartConnectHandler::create(&client, events, id as i64)?;
            enter(|| {
                dnp3::tcp::tls::spawn_outstation_tls_client_2(
                    client.link_error_mode.into(),
                    config,
                    connect,
                    app,
                    info,
                    control,
                    Box::new(ClientStateListener {
                        port: events,
                        id: id as i64,
                    }),
                    tls,
                )
            })?
        }
        OutstationTransportDto::Serial {
            path,
            settings,
            retry,
        } => create_serial(
            id, events, config, &path, settings, retry, app, info, control,
        )?,
        OutstationTransportDto::Udp {
            local_endpoint,
            remote_endpoint,
            socket_mode,
            link_read_mode,
            retry_delay_ms,
        } => {
            let udp = dnp3::udp::OutstationUdpConfig {
                local_endpoint: config::socket_addr(&local_endpoint)?,
                remote_endpoint: config::socket_addr(&remote_endpoint)?,
                socket_mode: match socket_mode {
                    UdpSocketModeDto::OneToOne => dnp3::udp::UdpSocketMode::OneToOne,
                    UdpSocketModeDto::OneToMany => dnp3::udp::UdpSocketMode::OneToMany,
                },
                link_read_mode: link_read_mode.into(),
                retry_delay: config::timeout_ms(retry_delay_ms)?,
            };
            enter(|| dnp3::udp::spawn_outstation_udp(udp, config, app, info, control))?
        }
    };
    register(id, handle, shared);
    Ok(id as i64)
}

#[cfg(has_serial)]
#[allow(clippy::too_many_arguments)]
fn create_serial(
    id: u64,
    events: DartPort,
    config: OutstationConfig,
    path: &str,
    settings: SerialSettingsDto,
    retry: Option<RetryStrategyDto>,
    app: Box<dyn OutstationApplication>,
    info: Box<dyn OutstationInformation>,
    control: Box<dyn ControlHandler>,
) -> Result<OutstationHandle> {
    let settings = settings.to_settings()?;
    match retry {
        Some(retry) => enter(|| {
            dnp3::serial::spawn_outstation_serial_2(
                path,
                settings,
                config,
                retry.into(),
                app,
                info,
                control,
                Box::new(PortStateListener {
                    port: events,
                    id: id as i64,
                }),
            )
        }),
        None => enter(|| {
            dnp3::serial::spawn_outstation_serial(path, settings, config, app, info, control)
        })?
        .map_err(Error::from),
    }
}

#[cfg(not(has_serial))]
#[allow(clippy::too_many_arguments)]
fn create_serial(
    _id: u64,
    _events: DartPort,
    _config: OutstationConfig,
    _path: &str,
    _settings: SerialSettingsDto,
    _retry: Option<RetryStrategyDto>,
    _app: Box<dyn OutstationApplication>,
    _info: Box<dyn OutstationInformation>,
    _control: Box<dyn ControlHandler>,
) -> Result<OutstationHandle> {
    Err(Error::new(
        err::NOT_SUPPORTED,
        "serial ports are not supported on this platform",
    ))
}

pub fn destroy(id: u64) -> Result<i64> {
    OUTSTATIONS
        .remove(id)
        .map(|_| 0)
        .ok_or_else(|| Error::invalid_handle(id))
}

pub fn enable(id: u64, c: Completion) -> Result<i64> {
    let mut h = get(id)?.handle;
    spawn_op(c, async move { h.enable().await.map_err(Error::from) })
}

pub fn disable(id: u64, c: Completion) -> Result<i64> {
    let mut h = get(id)?.handle;
    spawn_op(c, async move { h.disable().await.map_err(Error::from) })
}

pub fn set_decode_level(id: u64, json: &str, c: Completion) -> Result<i64> {
    let level: DecodeLevelDto = config::parse(json)?;
    let mut h = get(id)?.handle;
    spawn_op(c, async move {
        h.set_decode_level(level.into()).await.map_err(Error::from)
    })
}

pub fn set_application_iin(id: u64, bits: u8) -> Result<i64> {
    OUTSTATIONS.with(id, |o| {
        o.shared.application_iin.store(bits, Ordering::Relaxed)
    })?;
    Ok(0)
}

pub fn set_processing_delay(id: u64, ms: u16) -> Result<i64> {
    OUTSTATIONS.with(id, |o| {
        o.shared.processing_delay_ms.store(ms, Ordering::Relaxed)
    })?;
    Ok(0)
}

/// Apply a batch of database ops in one transaction
pub fn transaction(id: u64, ops: &[u8], mut out: Option<&mut [u8]>) -> Result<i64> {
    let (db, shared) = OUTSTATIONS.with(id, |o| (o.db.clone(), o.shared.clone()))?;
    db.transaction(|db| {
        let mut points = shared.points.lock().unwrap();
        dbops::apply(db, ops, out.as_deref_mut(), Some(&mut points))
    })
}

/// Read a single point. Returns the number of bytes written to `out` (0 if no such point).
pub fn get_point(id: u64, ty: u8, index: u16, out: &mut [u8]) -> Result<i64> {
    let db = OUTSTATIONS.with(id, |o| o.db.clone())?;
    let mut w = Writer::with_capacity(out.len().max(32));
    let found = db.transaction(|db| dbops::get(db, ty, index, &mut w))?;
    if !found {
        return Ok(0);
    }
    let data = w.finish();
    if data.len() > out.len() {
        return Err(Error::new(err::BUFFER_TOO_SMALL, "output buffer too small"));
    }
    out[..data.len()].copy_from_slice(&data);
    Ok(data.len() as i64)
}

/// Read a range of points of one type. Returns an encoded block (see measurement.rs)
pub fn get_range(id: u64, ty: u8, start: u16, stop: u16) -> Result<Vec<u8>> {
    let db = OUTSTATIONS.with(id, |o| o.db.clone())?;
    let mut b = crate::measurement::FragmentBuilder::new(64, 255, None);
    let record_size = match ty {
        kind::ANALOG_INPUT | kind::ANALOG_OUTPUT_STATUS => 24,
        kind::OCTET_STRING => 0,
        _ => 16,
    };
    b.begin_block(ty, None, record_size);
    db.transaction(|db| -> Result<()> {
        for i in start..=stop {
            // writer() increments the record count, so probe first
            let mut tmp = Writer::with_capacity(32);
            if dbops::get(db, ty, i, &mut tmp)? {
                b.writer().bytes(&tmp.buf);
            }
        }
        Ok(())
    })?;
    b.end_block();
    Ok(b.finish())
}

// ---------------------------------------------------------------------------------------
// TCP / TLS servers
// ---------------------------------------------------------------------------------------

pub fn server_create(json: &str) -> Result<i64> {
    let dto: ServerDto = config::parse(json)?;
    let server = match dto {
        ServerDto::Tcp {
            address,
            link_error_mode,
        } => Server::new_tcp_server(link_error_mode.into(), config::socket_addr(&address)?),
        ServerDto::Tls {
            address,
            link_error_mode,
            tls,
        } => Server::new_tls_server(
            link_error_mode.into(),
            config::socket_addr(&address)?,
            tls.server()?,
        ),
    };
    Ok(SERVERS.insert(Arc::new(ServerEntry {
        state: Mutex::new(ServerState::Building(server)),
        outstations: Mutex::new(Vec::new()),
    })) as i64)
}

pub fn server_add_outstation(server: u64, json: &str, events: DartPort) -> Result<i64> {
    let dto: ServerOutstationDto = config::parse(json)?;
    let config = dto.config.to_config()?;
    let filter: AddressFilter = dto.filter.to_filter()?;
    let entry = SERVERS.get(server)?;
    let mut state = entry.state.lock().unwrap();
    let ServerState::Building(srv) = &mut *state else {
        return Err(Error::arg(
            "outstations must be added before the server is bound",
        ));
    };
    let id = next_id();
    let (app, info, control, shared) = handlers(id, events, &dto.handlers);
    let handle = enter(|| {
        srv.add_outstation(
            config,
            app,
            info,
            control,
            Box::new(ConnectionStateListener {
                port: events,
                id: id as i64,
            }),
            filter,
        )
    })?
    .map_err(|e| Error::new(err::FILTER, e.to_string()))?;
    register(id, handle, shared);
    entry.outstations.lock().unwrap().push(id);
    Ok(id as i64)
}

pub fn server_bind(server: u64, c: Completion) -> Result<i64> {
    let entry = SERVERS.get(server)?;
    let srv = {
        let mut state = entry.state.lock().unwrap();
        match std::mem::replace(&mut *state, ServerState::Binding) {
            ServerState::Building(s) => s,
            other => {
                *state = other;
                return Err(Error::arg("server is already bound"));
            }
        }
    };
    spawn_op(c, async move {
        match srv.bind().await {
            Ok(handle) => {
                let addr = handle
                    .local_addr()
                    .map(|x| x.to_string())
                    .unwrap_or_default();
                *entry.state.lock().unwrap() = ServerState::Bound(handle);
                Ok(addr)
            }
            Err(e) => Err(Error::new(err::IO, format!("unable to bind server: {e}"))),
        }
    })
}

pub fn server_destroy(server: u64) -> Result<i64> {
    let entry = SERVERS
        .remove(server)
        .ok_or_else(|| Error::invalid_handle(server))?;
    for id in entry.outstations.lock().unwrap().drain(..) {
        OUTSTATIONS.remove(id);
    }
    // dropping the ServerHandle shuts down the server and its outstations
    drop(entry);
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn freeze_schedule() {
        let t = |x| Timestamp::new(x);
        assert_eq!(
            next_freeze_time(FreezeInterval::FreezeOnceAtTime(t(500)), 100, false),
            Some(500)
        );
        assert_eq!(
            next_freeze_time(FreezeInterval::FreezeOnceAtTime(t(500)), 600, false),
            Some(600)
        );
        assert_eq!(
            next_freeze_time(FreezeInterval::FreezeOnceAtTime(t(500)), 600, true),
            None
        );
        assert_eq!(
            next_freeze_time(FreezeInterval::PeriodicallyFreeze(t(1000), 100), 900, false),
            Some(1000)
        );
        assert_eq!(
            next_freeze_time(FreezeInterval::PeriodicallyFreeze(t(1000), 100), 1050, true),
            Some(1100)
        );
        assert_eq!(
            next_freeze_time(FreezeInterval::PeriodicallyFreeze(t(1000), 100), 1100, true),
            Some(1200)
        );
        let now = 3_600_000 * 5 + 61_000;
        assert_eq!(
            next_freeze_time(
                FreezeInterval::PeriodicallyFreezeRelative(60_000),
                now,
                false
            ),
            Some(3_600_000 * 5 + 120_000)
        );
    }
}
