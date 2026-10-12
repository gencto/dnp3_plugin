//! Binary encoding of measurement data received by a master.
//!
//! Every response fragment (between `begin_fragment` and `end_fragment`) is encoded into a
//! single contiguous buffer which is then *moved* into the Dart heap as an external
//! `Uint8List` (see [`crate::dart`]). The Dart side decodes the buffer lazily with
//! flyweight views, so measurement values are never copied or boxed unless requested.
//!
//! Layout (little endian), documented in `doc/wire_format.md`:
//!
//! ```text
//! Fragment header (16 bytes)
//!   u8  version (=1)
//!   u8  read type     (0 startup integrity, 1 unsolicited, 2 single poll, 3 periodic poll)
//!   u8  function      (0 response, 1 unsolicited response)
//!   u8  control       (fir<<7 | fin<<6 | con<<5 | uns<<4 | seq)
//!   u8  iin1, u8 iin2
//!   u16 block count
//!   u32 total length (including this header)
//!   u32 reserved
//! Block header (16 bytes)
//!   u8  kind, u8 group, u8 variation, u8 qualifier
//!   u8  info flags (bit0 is_event, bit1 has_flags)
//!   u8  record size (0 = variable)
//!   u16 reserved
//!   u32 record count
//!   u32 payload length in bytes
//! ```

use std::sync::{Arc, Mutex};

use dnp3::app::attr::{AnyAttribute, AttrSet, AttrValue, FloatType, KnownAttribute};
use dnp3::app::measurement::*;
use dnp3::app::{MaybeAsync, ResponseFunction, ResponseHeader, Timestamp};
use dnp3::master::{HeaderInfo, ReadHandler, ReadType};

use crate::codec::Writer;
use crate::core::msg;
use crate::dart::{post, DartPort, Payload};

pub mod kind {
    pub const BINARY_INPUT: u8 = 1;
    pub const DOUBLE_BIT_BINARY_INPUT: u8 = 2;
    pub const BINARY_OUTPUT_STATUS: u8 = 3;
    pub const COUNTER: u8 = 4;
    pub const FROZEN_COUNTER: u8 = 5;
    pub const ANALOG_INPUT: u8 = 6;
    pub const FROZEN_ANALOG_INPUT: u8 = 7;
    pub const ANALOG_INPUT_DEAD_BAND: u8 = 8;
    pub const ANALOG_OUTPUT_STATUS: u8 = 9;
    pub const ANALOG_OUTPUT_COMMAND_EVENT: u8 = 10;
    pub const BINARY_OUTPUT_COMMAND_EVENT: u8 = 11;
    pub const UNSIGNED_INTEGER: u8 = 12;
    pub const OCTET_STRING: u8 = 13;
    pub const DEVICE_ATTRIBUTE: u8 = 14;
    pub const ABS_TIME: u8 = 15;
}

pub const FRAGMENT_HEADER_SIZE: usize = 16;
pub const BLOCK_HEADER_SIZE: usize = 16;

#[inline]
pub fn time_parts(t: Option<Time>) -> (u8, u64) {
    match t {
        None => (0, 0),
        Some(Time::Synchronized(ts)) => (1, ts.raw_value()),
        Some(Time::Unsynchronized(ts)) => (2, ts.raw_value()),
    }
}

#[inline]
pub fn time_from_parts(kind: u8, value: u64) -> Option<Time> {
    match kind {
        1 => Some(Time::Synchronized(Timestamp::new(value))),
        2 => Some(Time::Unsynchronized(Timestamp::new(value))),
        _ => None,
    }
}

pub fn double_bit_to_u8(x: DoubleBit) -> u8 {
    match x {
        DoubleBit::Intermediate => 0,
        DoubleBit::DeterminedOff => 1,
        DoubleBit::DeterminedOn => 2,
        DoubleBit::Indeterminate => 3,
    }
}

pub fn double_bit_from_u8(x: u8) -> DoubleBit {
    match x & 0x03 {
        0 => DoubleBit::Intermediate,
        1 => DoubleBit::DeterminedOff,
        2 => DoubleBit::DeterminedOn,
        _ => DoubleBit::Indeterminate,
    }
}

fn read_type_code(x: ReadType) -> u8 {
    match x {
        ReadType::StartupIntegrity => 0,
        ReadType::Unsolicited => 1,
        ReadType::SinglePoll => 2,
        ReadType::PeriodicPoll => 3,
    }
}

fn control_byte(h: &ResponseHeader) -> u8 {
    let c = h.control;
    ((c.fir as u8) << 7)
        | ((c.fin as u8) << 6)
        | ((c.con as u8) << 5)
        | ((c.uns as u8) << 4)
        | (c.seq.value() & 0x0F)
}

/// Record encoders shared by the master read handler and outstation database reads
pub mod record {
    use super::*;

    #[inline]
    pub fn binary(w: &mut Writer, index: u16, value: u8, flags: u8, time: Option<Time>) {
        let (tk, t) = time_parts(time);
        w.u16(index);
        w.u8(value);
        w.u8(flags);
        w.u8(tk);
        w.zeros(3);
        w.u64(t);
    }

    #[inline]
    pub fn counter(w: &mut Writer, index: u16, value: u32, flags: u8, time: Option<Time>) {
        let (tk, t) = time_parts(time);
        w.u16(index);
        w.u8(flags);
        w.u8(tk);
        w.u32(value);
        w.u64(t);
    }

    #[inline]
    pub fn analog(w: &mut Writer, index: u16, value: f64, flags: u8, time: Option<Time>) {
        let (tk, t) = time_parts(time);
        w.u16(index);
        w.u8(flags);
        w.u8(tk);
        w.u32(0);
        w.f64(value);
        w.u64(t);
    }

    pub fn octet_string(w: &mut Writer, index: u16, value: &[u8]) {
        w.u16(index);
        w.u16(value.len() as u16);
        w.bytes(value);
        w.pad4();
    }
}

/// Incrementally builds one encoded fragment
pub struct FragmentBuilder {
    w: Writer,
    blocks: u16,
    block_start: Option<usize>,
    block_count: u32,
}

impl FragmentBuilder {
    pub fn new(capacity: usize, read_type: u8, header: Option<&ResponseHeader>) -> Self {
        let mut w = Writer::with_capacity(capacity.max(64));
        w.u8(1);
        w.u8(read_type);
        match header {
            Some(h) => {
                w.u8(match h.function {
                    ResponseFunction::Response => 0,
                    ResponseFunction::UnsolicitedResponse => 1,
                });
                w.u8(control_byte(h));
                w.u8(h.iin.iin1.value);
                w.u8(h.iin.iin2.value);
            }
            None => w.zeros(4),
        }
        w.u16(0); // block count
        w.u32(0); // total length
        w.u32(0);
        Self {
            w,
            blocks: 0,
            block_start: None,
            block_count: 0,
        }
    }

    pub fn begin_block(&mut self, kind: u8, info: Option<HeaderInfo>, record_size: u8) {
        debug_assert!(self.block_start.is_none());
        self.block_start = Some(self.w.len());
        self.block_count = 0;
        self.w.u8(kind);
        match info {
            Some(info) => {
                let (g, v) = crate::variation::to_group_var(info.variation);
                self.w.u8(g);
                self.w.u8(v);
                self.w.u8(info.qualifier.as_u8());
                self.w
                    .u8((info.is_event as u8) | ((info.has_flags as u8) << 1));
            }
            None => self.w.zeros(4),
        }
        self.w.u8(record_size);
        self.w.u16(0);
        self.w.u32(0);
        self.w.u32(0);
    }

    #[inline]
    pub fn writer(&mut self) -> &mut Writer {
        self.block_count += 1;
        &mut self.w
    }

    pub fn end_block(&mut self) {
        if let Some(start) = self.block_start.take() {
            let payload = self.w.len() - start - BLOCK_HEADER_SIZE;
            self.w.patch_u32(start + 8, self.block_count);
            self.w.patch_u32(start + 12, payload as u32);
            self.blocks += 1;
        }
    }

    pub fn finish(mut self) -> Vec<u8> {
        self.end_block();
        let total = self.w.len() as u32;
        self.w.patch_u16(6, self.blocks);
        self.w.patch_u32(8, total);
        self.w.finish()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    pub fn len(&self) -> usize {
        self.w.len()
    }
}

/// Encode a device attribute record (variable size)
pub fn encode_attribute(w: &mut Writer, set: AttrSet, variation: u8, value: &AttrValue) {
    let (set_kind, set_value) = match set {
        AttrSet::Default => (0u8, 0u8),
        AttrSet::Private(x) => (1, x),
    };
    w.u8(set_kind);
    w.u8(set_value);
    w.u8(variation);
    match value {
        AttrValue::VisibleString(s) => {
            w.u8(1);
            w.zeros(4);
            w.blob(s.as_bytes());
        }
        AttrValue::UnsignedInt(x) => {
            w.u8(2);
            w.zeros(4);
            w.i64(*x as i64);
        }
        AttrValue::SignedInt(x) => {
            w.u8(3);
            w.zeros(4);
            w.i64(*x as i64);
        }
        AttrValue::FloatingPoint(f) => {
            w.u8(4);
            w.u8(match f {
                FloatType::F32(_) => 0,
                FloatType::F64(_) => 1,
            });
            w.zeros(3);
            w.f64(f.value());
        }
        AttrValue::OctetString(b) => {
            w.u8(5);
            w.zeros(4);
            w.blob(b);
        }
        AttrValue::BitString(b) => {
            w.u8(6);
            w.zeros(4);
            w.blob(b);
        }
        AttrValue::Dnp3Time(t) => {
            w.u8(7);
            w.zeros(4);
            w.u64(t.raw_value());
        }
        AttrValue::AttrList(list) => {
            w.u8(254);
            w.zeros(4);
            let items: Vec<_> = list.iter().collect();
            w.u32((items.len() * 2) as u32);
            for item in items {
                w.u8(item.variation);
                w.u8(item.properties.is_writable() as u8);
            }
            w.pad4();
        }
    }
}

/// Where completed fragments go
#[derive(Clone)]
pub enum Sink {
    /// Post each fragment to a Dart port as `[MEASUREMENTS, id, 0, bytes]`
    Port { port: DartPort, id: i64 },
    /// Accumulate length-prefixed fragments (used by `read_with_handler`)
    Collect(Arc<Mutex<Vec<u8>>>),
}

pub struct MeasurementHandler {
    sink: Sink,
    current: Option<FragmentBuilder>,
    /// capacity hint: size of the previous fragment
    last_size: usize,
}

impl MeasurementHandler {
    pub fn new(sink: Sink) -> Self {
        Self {
            sink,
            current: None,
            last_size: 256,
        }
    }

    fn builder(&mut self) -> &mut FragmentBuilder {
        // handle_* without begin_fragment cannot happen, but be defensive
        self.current
            .get_or_insert_with(|| FragmentBuilder::new(256, 255, None))
    }

    fn emit(&mut self, data: Vec<u8>) {
        match &self.sink {
            Sink::Port { port, id } => {
                post(*port, msg::MEASUREMENTS, *id, 0, Payload::Bytes(data));
            }
            Sink::Collect(acc) => {
                let mut acc = acc.lock().unwrap();
                acc.extend_from_slice(&(data.len() as u32).to_le_bytes());
                acc.extend_from_slice(&data);
                // keep fragments 8-byte aligned inside the collection
                while acc.len() % 8 != 0 {
                    acc.push(0);
                }
            }
        }
    }
}

macro_rules! block {
    ($self:ident, $kind:expr, $info:expr, $size:expr, $iter:ident, |$w:ident, $item:ident, $idx:ident| $body:block) => {{
        let b = $self.builder();
        b.begin_block($kind, Some($info), $size);
        for ($item, $idx) in $iter {
            let $w = b.writer();
            $body
        }
        b.end_block();
    }};
}

impl ReadHandler for MeasurementHandler {
    fn begin_fragment(&mut self, read_type: ReadType, header: ResponseHeader) -> MaybeAsync<()> {
        let cap = self.last_size + self.last_size / 4;
        self.current = Some(FragmentBuilder::new(
            cap,
            read_type_code(read_type),
            Some(&header),
        ));
        MaybeAsync::ready(())
    }

    fn end_fragment(&mut self, _read_type: ReadType, _header: ResponseHeader) -> MaybeAsync<()> {
        if let Some(b) = self.current.take() {
            let data = b.finish();
            self.last_size = data.len();
            self.emit(data);
        }
        MaybeAsync::ready(())
    }

    fn handle_binary_input(
        &mut self,
        info: HeaderInfo,
        iter: &mut dyn Iterator<Item = (BinaryInput, u16)>,
    ) {
        block!(self, kind::BINARY_INPUT, info, 16, iter, |w, x, i| {
            record::binary(w, i, x.value as u8, x.flags.value, x.time);
        })
    }

    fn handle_double_bit_binary_input(
        &mut self,
        info: HeaderInfo,
        iter: &mut dyn Iterator<Item = (DoubleBitBinaryInput, u16)>,
    ) {
        block!(
            self,
            kind::DOUBLE_BIT_BINARY_INPUT,
            info,
            16,
            iter,
            |w, x, i| {
                record::binary(w, i, double_bit_to_u8(x.value), x.flags.value, x.time);
            }
        )
    }

    fn handle_binary_output_status(
        &mut self,
        info: HeaderInfo,
        iter: &mut dyn Iterator<Item = (BinaryOutputStatus, u16)>,
    ) {
        block!(
            self,
            kind::BINARY_OUTPUT_STATUS,
            info,
            16,
            iter,
            |w, x, i| {
                record::binary(w, i, x.value as u8, x.flags.value, x.time);
            }
        )
    }

    fn handle_counter(&mut self, info: HeaderInfo, iter: &mut dyn Iterator<Item = (Counter, u16)>) {
        block!(self, kind::COUNTER, info, 16, iter, |w, x, i| {
            record::counter(w, i, x.value, x.flags.value, x.time);
        })
    }

    fn handle_frozen_counter(
        &mut self,
        info: HeaderInfo,
        iter: &mut dyn Iterator<Item = (FrozenCounter, u16)>,
    ) {
        block!(self, kind::FROZEN_COUNTER, info, 16, iter, |w, x, i| {
            record::counter(w, i, x.value, x.flags.value, x.time);
        })
    }

    fn handle_analog_input(
        &mut self,
        info: HeaderInfo,
        iter: &mut dyn Iterator<Item = (AnalogInput, u16)>,
    ) {
        block!(self, kind::ANALOG_INPUT, info, 24, iter, |w, x, i| {
            record::analog(w, i, x.value, x.flags.value, x.time);
        })
    }

    fn handle_frozen_analog_input(
        &mut self,
        info: HeaderInfo,
        iter: &mut dyn Iterator<Item = (FrozenAnalogInput, u16)>,
    ) {
        block!(
            self,
            kind::FROZEN_ANALOG_INPUT,
            info,
            24,
            iter,
            |w, x, i| {
                record::analog(w, i, x.value, x.flags.value, x.time);
            }
        )
    }

    fn handle_analog_input_dead_band(
        &mut self,
        info: HeaderInfo,
        iter: &mut dyn Iterator<Item = (AnalogInputDeadBand, u16)>,
    ) {
        block!(
            self,
            kind::ANALOG_INPUT_DEAD_BAND,
            info,
            16,
            iter,
            |w, x, i| {
                let (k, v) = match x {
                    AnalogInputDeadBand::U16(v) => (0u8, v as f64),
                    AnalogInputDeadBand::U32(v) => (1, v as f64),
                    AnalogInputDeadBand::F32(v) => (2, v as f64),
                };
                w.u16(i);
                w.u8(k);
                w.u8(0);
                w.u32(0);
                w.f64(v);
            }
        )
    }

    fn handle_analog_output_status(
        &mut self,
        info: HeaderInfo,
        iter: &mut dyn Iterator<Item = (AnalogOutputStatus, u16)>,
    ) {
        block!(
            self,
            kind::ANALOG_OUTPUT_STATUS,
            info,
            24,
            iter,
            |w, x, i| {
                record::analog(w, i, x.value, x.flags.value, x.time);
            }
        )
    }

    fn handle_analog_output_command_event(
        &mut self,
        info: HeaderInfo,
        iter: &mut dyn Iterator<Item = (AnalogOutputCommandEvent, u16)>,
    ) {
        block!(
            self,
            kind::ANALOG_OUTPUT_COMMAND_EVENT,
            info,
            24,
            iter,
            |w, x, i| {
                let (k, v) = match x.commanded_value {
                    AnalogCommandValue::I16(v) => (0u8, v as f64),
                    AnalogCommandValue::I32(v) => (1, v as f64),
                    AnalogCommandValue::F32(v) => (2, v as f64),
                    AnalogCommandValue::F64(v) => (3, v),
                };
                let (tk, t) = time_parts(x.time);
                w.u16(i);
                w.u8(x.status.as_u8());
                w.u8(k);
                w.u8(tk);
                w.zeros(3);
                w.f64(v);
                w.u64(t);
            }
        )
    }

    fn handle_binary_output_command_event(
        &mut self,
        info: HeaderInfo,
        iter: &mut dyn Iterator<Item = (BinaryOutputCommandEvent, u16)>,
    ) {
        block!(
            self,
            kind::BINARY_OUTPUT_COMMAND_EVENT,
            info,
            16,
            iter,
            |w, x, i| {
                let (tk, t) = time_parts(x.time);
                w.u16(i);
                w.u8(x.commanded_state as u8);
                w.u8(x.status.as_u8());
                w.u8(tk);
                w.zeros(3);
                w.u64(t);
            }
        )
    }

    fn handle_unsigned_integer(
        &mut self,
        info: HeaderInfo,
        iter: &mut dyn Iterator<Item = (UnsignedInteger, u16)>,
    ) {
        block!(self, kind::UNSIGNED_INTEGER, info, 4, iter, |w, x, i| {
            w.u16(i);
            w.u8(x.value);
            w.u8(0);
        })
    }

    fn handle_octet_string<'a>(
        &mut self,
        info: HeaderInfo,
        iter: &'a mut dyn Iterator<Item = (&'a [u8], u16)>,
    ) {
        let b = self.builder();
        b.begin_block(kind::OCTET_STRING, Some(info), 0);
        for (x, i) in iter {
            record::octet_string(b.writer(), i, x);
        }
        b.end_block();
    }

    fn handle_device_attribute(&mut self, info: HeaderInfo, attr: AnyAttribute) {
        let attr = match attr {
            AnyAttribute::Other(a) => a,
            AnyAttribute::Known(k) => {
                // re-derive the raw attribute from the known one
                let (variation, value) = known_to_raw(&k);
                let b = self.builder();
                b.begin_block(kind::DEVICE_ATTRIBUTE, Some(info), 0);
                encode_attribute(b.writer(), AttrSet::Default, variation, &value);
                b.end_block();
                return;
            }
        };
        let b = self.builder();
        b.begin_block(kind::DEVICE_ATTRIBUTE, Some(info), 0);
        encode_attribute(b.writer(), attr.set, attr.variation, &attr.value);
        b.end_block();
    }

    fn handle_abs_time(&mut self, info: HeaderInfo, time: Timestamp) {
        let b = self.builder();
        b.begin_block(kind::ABS_TIME, Some(info), 8);
        b.writer().u64(time.raw_value());
        b.end_block();
    }
}

fn known_to_raw<'a>(k: &KnownAttribute<'a>) -> (u8, AttrValue<'a>) {
    match k {
        KnownAttribute::AttributeList(v, list) => (v.variation(), AttrValue::AttrList(*list)),
        KnownAttribute::String(v, s) => (v.variation(), AttrValue::VisibleString(s)),
        KnownAttribute::Float(v, f) => (v.variation(), AttrValue::FloatingPoint(*f)),
        KnownAttribute::UInt(v, x) => (v.variation(), AttrValue::UnsignedInt(*x)),
        KnownAttribute::Bool(v, b) => (v.variation(), AttrValue::SignedInt(*b as i32)),
        KnownAttribute::OctetString(v, b) => (v.variation(), AttrValue::OctetString(b)),
        KnownAttribute::DNP3Time(v, t) => (v.variation(), AttrValue::Dnp3Time(*t)),
    }
}
