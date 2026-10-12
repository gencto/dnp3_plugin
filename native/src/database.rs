//! Batched outstation database operations.
//!
//! Dart encodes any number of operations into a single native buffer and hands the pointer
//! to [`apply`], which decodes them in place (no copy) and executes all of them inside one
//! database transaction (a single lock/unlock + a single change notification).
//!
//! Every op starts with a 4-byte header `u8 op, u8 point type, u16 index`:
//!
//! | op | name           | body                                                                   |
//! |----|----------------|------------------------------------------------------------------------|
//! | 1  | update         | `u8 flags, u8 time kind, u8 event mode, u8 options, u32 pad, u64 value, u64 time` (24 bytes total) |
//! | 1  | update (octet) | `u8 event mode, u8 options, u16 len, bytes, pad to 4`                  |
//! | 2  | add            | `u8 class, u8 static var, u8 event var, u8 pad, f64 dead band` (16)    |
//! | 3  | remove         | — (4)                                                                  |
//! | 4  | update flags   | `u8 flags, u8 time kind, u8 event mode, u8 options, u64 time` (16)     |
//! | 5  | define attr    | `u8 writable, u8[3] pad, attribute` (see `requests::owned_attribute`)  |
//! | 6  | discard unselected events | point type byte = class bit mask (4)                        |
//!
//! `options` bit 0 = update static value. The value slot holds the bool / double-bit code,
//! the u32 counter value or the f64 bits depending on the point type.
//!
//! Optional results are written as 24-byte records `u32 status, u32 pad, u64 a, u64 b`:
//! status 0 = no point / failure, 1 = ok (no event), 2 = event created (a = id),
//! 3 = overflow (a = created id, b = discarded id).

use std::collections::BTreeSet;

use dnp3::app::attr::AttrProp;
use dnp3::app::measurement::*;
use dnp3::app::Timestamp;
use dnp3::master::EventClasses;
use dnp3::outstation::database::*;

use crate::codec::{Reader, Writer};
use crate::core::{Error, Result};
use crate::measurement::{double_bit_from_u8, double_bit_to_u8, kind, record, time_from_parts};

pub mod op {
    pub const UPDATE: u8 = 1;
    pub const ADD: u8 = 2;
    pub const REMOVE: u8 = 3;
    pub const UPDATE_FLAGS: u8 = 4;
    pub const DEFINE_ATTR: u8 = 5;
    pub const DISCARD_UNSELECTED: u8 = 6;
}

pub const RESULT_SIZE: usize = 24;

fn options(event_mode: u8, opts: u8) -> UpdateOptions {
    let mode = match event_mode {
        1 => EventMode::Force,
        2 => EventMode::Suppress,
        _ => EventMode::Detect,
    };
    UpdateOptions::new(opts & 1 != 0, mode)
}

fn class(x: u8) -> Option<EventClass> {
    match x {
        1 => Some(EventClass::Class1),
        2 => Some(EventClass::Class2),
        3 => Some(EventClass::Class3),
        _ => None,
    }
}

fn bad_var(t: &str, v: u8) -> Error {
    Error::arg(format!("invalid {t} variation {v}"))
}

fn add_point(db: &mut Database, ty: u8, index: u16, class: Option<EventClass>, s: u8, e: u8, deadband: f64) -> Result<bool> {
    Ok(match ty {
        kind::BINARY_INPUT => {
            let s = match s {
                1 => StaticBinaryInputVariation::Group1Var1,
                2 => StaticBinaryInputVariation::Group1Var2,
                x => return Err(bad_var("g1", x)),
            };
            let e = match e {
                1 => EventBinaryInputVariation::Group2Var1,
                2 => EventBinaryInputVariation::Group2Var2,
                3 => EventBinaryInputVariation::Group2Var3,
                x => return Err(bad_var("g2", x)),
            };
            db.add(index, class, BinaryInputConfig::new(s, e))
        }
        kind::DOUBLE_BIT_BINARY_INPUT => {
            let s = match s {
                1 => StaticDoubleBitBinaryInputVariation::Group3Var1,
                2 => StaticDoubleBitBinaryInputVariation::Group3Var2,
                x => return Err(bad_var("g3", x)),
            };
            let e = match e {
                1 => EventDoubleBitBinaryInputVariation::Group4Var1,
                2 => EventDoubleBitBinaryInputVariation::Group4Var2,
                3 => EventDoubleBitBinaryInputVariation::Group4Var3,
                x => return Err(bad_var("g4", x)),
            };
            db.add(index, class, DoubleBitBinaryInputConfig::new(s, e))
        }
        kind::BINARY_OUTPUT_STATUS => {
            let s = match s {
                1 => StaticBinaryOutputStatusVariation::Group10Var1,
                2 => StaticBinaryOutputStatusVariation::Group10Var2,
                x => return Err(bad_var("g10", x)),
            };
            let e = match e {
                1 => EventBinaryOutputStatusVariation::Group11Var1,
                2 => EventBinaryOutputStatusVariation::Group11Var2,
                x => return Err(bad_var("g11", x)),
            };
            db.add(index, class, BinaryOutputStatusConfig::new(s, e))
        }
        kind::COUNTER => {
            let s = match s {
                1 => StaticCounterVariation::Group20Var1,
                2 => StaticCounterVariation::Group20Var2,
                5 => StaticCounterVariation::Group20Var5,
                6 => StaticCounterVariation::Group20Var6,
                x => return Err(bad_var("g20", x)),
            };
            let e = match e {
                1 => EventCounterVariation::Group22Var1,
                2 => EventCounterVariation::Group22Var2,
                5 => EventCounterVariation::Group22Var5,
                6 => EventCounterVariation::Group22Var6,
                x => return Err(bad_var("g22", x)),
            };
            db.add(index, class, CounterConfig::new(s, e, deadband as u32))
        }
        kind::FROZEN_COUNTER => {
            let s = match s {
                1 => StaticFrozenCounterVariation::Group21Var1,
                2 => StaticFrozenCounterVariation::Group21Var2,
                5 => StaticFrozenCounterVariation::Group21Var5,
                6 => StaticFrozenCounterVariation::Group21Var6,
                9 => StaticFrozenCounterVariation::Group21Var9,
                10 => StaticFrozenCounterVariation::Group21Var10,
                x => return Err(bad_var("g21", x)),
            };
            let e = match e {
                1 => EventFrozenCounterVariation::Group23Var1,
                2 => EventFrozenCounterVariation::Group23Var2,
                5 => EventFrozenCounterVariation::Group23Var5,
                6 => EventFrozenCounterVariation::Group23Var6,
                x => return Err(bad_var("g23", x)),
            };
            db.add(index, class, FrozenCounterConfig::new(s, e, deadband as u32))
        }
        kind::ANALOG_INPUT => {
            let s = match s {
                1 => StaticAnalogInputVariation::Group30Var1,
                2 => StaticAnalogInputVariation::Group30Var2,
                3 => StaticAnalogInputVariation::Group30Var3,
                4 => StaticAnalogInputVariation::Group30Var4,
                5 => StaticAnalogInputVariation::Group30Var5,
                6 => StaticAnalogInputVariation::Group30Var6,
                x => return Err(bad_var("g30", x)),
            };
            let e = match e {
                1 => EventAnalogInputVariation::Group32Var1,
                2 => EventAnalogInputVariation::Group32Var2,
                3 => EventAnalogInputVariation::Group32Var3,
                4 => EventAnalogInputVariation::Group32Var4,
                5 => EventAnalogInputVariation::Group32Var5,
                6 => EventAnalogInputVariation::Group32Var6,
                7 => EventAnalogInputVariation::Group32Var7,
                8 => EventAnalogInputVariation::Group32Var8,
                x => return Err(bad_var("g32", x)),
            };
            db.add(index, class, AnalogInputConfig::new(s, e, deadband))
        }
        kind::ANALOG_OUTPUT_STATUS => {
            let s = match s {
                1 => StaticAnalogOutputStatusVariation::Group40Var1,
                2 => StaticAnalogOutputStatusVariation::Group40Var2,
                3 => StaticAnalogOutputStatusVariation::Group40Var3,
                4 => StaticAnalogOutputStatusVariation::Group40Var4,
                x => return Err(bad_var("g40", x)),
            };
            let e = match e {
                1 => EventAnalogOutputStatusVariation::Group42Var1,
                2 => EventAnalogOutputStatusVariation::Group42Var2,
                3 => EventAnalogOutputStatusVariation::Group42Var3,
                4 => EventAnalogOutputStatusVariation::Group42Var4,
                5 => EventAnalogOutputStatusVariation::Group42Var5,
                6 => EventAnalogOutputStatusVariation::Group42Var6,
                7 => EventAnalogOutputStatusVariation::Group42Var7,
                8 => EventAnalogOutputStatusVariation::Group42Var8,
                x => return Err(bad_var("g42", x)),
            };
            db.add(index, class, AnalogOutputStatusConfig::new(s, e, deadband))
        }
        kind::OCTET_STRING => db.add(index, class, OctetStringConfig),
        x => return Err(Error::arg(format!("point type {x} cannot be added to the database"))),
    })
}

fn remove_point(db: &mut Database, ty: u8, index: u16) -> Result<bool> {
    Ok(match ty {
        kind::BINARY_INPUT => Remove::<BinaryInput>::remove(db, index),
        kind::DOUBLE_BIT_BINARY_INPUT => Remove::<DoubleBitBinaryInput>::remove(db, index),
        kind::BINARY_OUTPUT_STATUS => Remove::<BinaryOutputStatus>::remove(db, index),
        kind::COUNTER => Remove::<Counter>::remove(db, index),
        kind::FROZEN_COUNTER => Remove::<FrozenCounter>::remove(db, index),
        kind::ANALOG_INPUT => Remove::<AnalogInput>::remove(db, index),
        kind::ANALOG_OUTPUT_STATUS => Remove::<AnalogOutputStatus>::remove(db, index),
        kind::OCTET_STRING => Remove::<OctetString>::remove(db, index),
        x => return Err(Error::arg(format!("invalid point type {x}"))),
    })
}

#[inline]
fn update_point(db: &mut Database, ty: u8, index: u16, flags: u8, time: Option<Time>, value: u64, opts: UpdateOptions) -> Result<UpdateInfo> {
    let flags = Flags::new(flags);
    Ok(match ty {
        kind::BINARY_INPUT => db.update2(index, &BinaryInput { value: value != 0, flags, time }, opts),
        kind::DOUBLE_BIT_BINARY_INPUT => db.update2(
            index,
            &DoubleBitBinaryInput {
                value: double_bit_from_u8(value as u8),
                flags,
                time,
            },
            opts,
        ),
        kind::BINARY_OUTPUT_STATUS => db.update2(index, &BinaryOutputStatus { value: value != 0, flags, time }, opts),
        kind::COUNTER => db.update2(index, &Counter { value: value as u32, flags, time }, opts),
        kind::FROZEN_COUNTER => db.update2(index, &FrozenCounter { value: value as u32, flags, time }, opts),
        kind::ANALOG_INPUT => db.update2(index, &AnalogInput { value: f64::from_bits(value), flags, time }, opts),
        kind::ANALOG_OUTPUT_STATUS => db.update2(
            index,
            &AnalogOutputStatus {
                value: f64::from_bits(value),
                flags,
                time,
            },
            opts,
        ),
        x => return Err(Error::arg(format!("invalid point type {x} for update"))),
    })
}

fn flags_type(ty: u8) -> Result<UpdateFlagsType> {
    Ok(match ty {
        kind::BINARY_INPUT => UpdateFlagsType::BinaryInput,
        kind::DOUBLE_BIT_BINARY_INPUT => UpdateFlagsType::DoubleBitBinaryInput,
        kind::BINARY_OUTPUT_STATUS => UpdateFlagsType::BinaryOutputStatus,
        kind::COUNTER => UpdateFlagsType::Counter,
        kind::FROZEN_COUNTER => UpdateFlagsType::FrozenCounter,
        kind::ANALOG_INPUT => UpdateFlagsType::AnalogInput,
        kind::ANALOG_OUTPUT_STATUS => UpdateFlagsType::AnalogOutputStatus,
        x => return Err(Error::arg(format!("invalid point type {x} for flags update"))),
    })
}

#[inline]
fn write_result(out: &mut Option<&mut [u8]>, n: usize, status: u32, a: u64, b: u64) {
    if let Some(out) = out {
        let pos = n * RESULT_SIZE;
        if pos + RESULT_SIZE <= out.len() {
            out[pos..pos + 4].copy_from_slice(&status.to_le_bytes());
            out[pos + 4..pos + 8].copy_from_slice(&0u32.to_le_bytes());
            out[pos + 8..pos + 16].copy_from_slice(&a.to_le_bytes());
            out[pos + 16..pos + 24].copy_from_slice(&b.to_le_bytes());
        }
    }
}

#[inline]
fn info_result(out: &mut Option<&mut [u8]>, n: usize, info: UpdateInfo) {
    match info {
        UpdateInfo::NoPoint => write_result(out, n, 0, 0, 0),
        UpdateInfo::NoEvent => write_result(out, n, 1, 0, 0),
        UpdateInfo::Created(id) => write_result(out, n, 2, id, 0),
        UpdateInfo::Overflow { created, discarded } => write_result(out, n, 3, created, discarded),
    }
}

/// Bookkeeping performed alongside database edits (used by the native freeze implementation)
#[derive(Default)]
pub struct PointIndex {
    pub counters: BTreeSet<u16>,
}

/// Apply all ops in `data` to the database. Returns the number of ops executed.
pub fn apply(db: &mut Database, data: &[u8], mut out: Option<&mut [u8]>, index: Option<&mut PointIndex>) -> Result<i64> {
    let mut r = Reader::new(data);
    let mut n = 0usize;
    let mut index = index;
    while !r.is_empty() {
        let opcode = r.u8()?;
        let ty = r.u8()?;
        let idx = r.u16()?;
        match opcode {
            op::UPDATE if ty == kind::OCTET_STRING => {
                let event_mode = r.u8()?;
                let opts = r.u8()?;
                let len = r.u16()? as usize;
                let bytes = r.take(len)?;
                let rem = len % 4;
                if rem != 0 {
                    r.skip(4 - rem)?;
                }
                let value = OctetString::new(bytes)
                    .map_err(|_| Error::arg("octet string longer than 255 bytes"))?;
                let info = db.update2(idx, &value, options(event_mode, opts));
                info_result(&mut out, n, info);
            }
            op::UPDATE => {
                let flags = r.u8()?;
                let tk = r.u8()?;
                let event_mode = r.u8()?;
                let opts = r.u8()?;
                r.skip(4)?;
                let value = r.u64()?;
                let time = r.u64()?;
                let info = update_point(db, ty, idx, flags, time_from_parts(tk, time), value, options(event_mode, opts))?;
                info_result(&mut out, n, info);
            }
            op::ADD => {
                let class = class(r.u8()?);
                let s = r.u8()?;
                let e = r.u8()?;
                r.u8()?;
                let deadband = r.f64()?;
                let ok = add_point(db, ty, idx, class, s, e, deadband)?;
                if ok && ty == kind::COUNTER {
                    if let Some(index) = index.as_deref_mut() {
                        index.counters.insert(idx);
                    }
                }
                write_result(&mut out, n, ok as u32, 0, 0);
            }
            op::REMOVE => {
                let ok = remove_point(db, ty, idx)?;
                if ok && ty == kind::COUNTER {
                    if let Some(index) = index.as_deref_mut() {
                        index.counters.remove(&idx);
                    }
                }
                write_result(&mut out, n, ok as u32, 0, 0);
            }
            op::UPDATE_FLAGS => {
                let flags = r.u8()?;
                let tk = r.u8()?;
                let event_mode = r.u8()?;
                let opts = r.u8()?;
                let time = r.u64()?;
                let info = db.update_flags(
                    idx,
                    flags_type(ty)?,
                    Flags::new(flags),
                    time_from_parts(tk, time),
                    options(event_mode, opts),
                );
                info_result(&mut out, n, info);
            }
            op::DEFINE_ATTR => {
                let writable = r.u8()? != 0;
                r.skip(3)?;
                let attr = crate::requests::owned_attribute(&mut r)?;
                let prop = if writable {
                    AttrProp::writable()
                } else {
                    AttrProp::default()
                };
                match db.define_attr(prop, attr) {
                    Ok(()) => write_result(&mut out, n, 1, 0, 0),
                    Err(e) => {
                        let code = match e {
                            AttrDefError::AlreadyDefined => 1,
                            AttrDefError::BadType(_) => 2,
                            AttrDefError::ReservedVariation(_) => 3,
                            AttrDefError::NotWritable(_, _) => 4,
                        };
                        write_result(&mut out, n, 0, code, 0)
                    }
                }
            }
            op::DISCARD_UNSELECTED => {
                let c = db.discard_unselected_events(EventClasses::new(ty & 2 != 0, ty & 4 != 0, ty & 8 != 0));
                write_result(&mut out, n, 1, (c.num_class_1 + c.num_class_2 + c.num_class_3) as u64, 0);
            }
            x => return Err(Error::arg(format!("unknown database op {x}"))),
        }
        n += 1;
    }
    Ok(n as i64)
}

/// Encode the current value of a point using the measurement record format
/// (see `measurement::record`). Returns false if the point does not exist.
pub fn get(db: &Database, ty: u8, index: u16, w: &mut Writer) -> Result<bool> {
    let found = match ty {
        kind::BINARY_INPUT => Get::<BinaryInput>::get(db, index)
            .map(|x| record::binary(w, index, x.value as u8, x.flags.value, x.time)),
        kind::DOUBLE_BIT_BINARY_INPUT => Get::<DoubleBitBinaryInput>::get(db, index)
            .map(|x| record::binary(w, index, double_bit_to_u8(x.value), x.flags.value, x.time)),
        kind::BINARY_OUTPUT_STATUS => Get::<BinaryOutputStatus>::get(db, index)
            .map(|x| record::binary(w, index, x.value as u8, x.flags.value, x.time)),
        kind::COUNTER => Get::<Counter>::get(db, index)
            .map(|x| record::counter(w, index, x.value, x.flags.value, x.time)),
        kind::FROZEN_COUNTER => Get::<FrozenCounter>::get(db, index)
            .map(|x| record::counter(w, index, x.value, x.flags.value, x.time)),
        kind::ANALOG_INPUT => Get::<AnalogInput>::get(db, index)
            .map(|x| record::analog(w, index, x.value, x.flags.value, x.time)),
        kind::ANALOG_OUTPUT_STATUS => Get::<AnalogOutputStatus>::get(db, index)
            .map(|x| record::analog(w, index, x.value, x.flags.value, x.time)),
        kind::OCTET_STRING => {
            Get::<OctetString>::get(db, index).map(|x| record::octet_string(w, index, x.value()))
        }
        x => return Err(Error::arg(format!("invalid point type {x}"))),
    };
    Ok(found.is_some())
}

/// Copy counters into frozen counters (optionally clearing the counters)
pub fn freeze_counters(db: &mut Database, indices: impl Iterator<Item = u16>, clear: bool, now: Timestamp) {
    for idx in indices {
        if let Some(c) = Get::<Counter>::get(db, idx) {
            let frozen = FrozenCounter {
                value: c.value,
                flags: c.flags,
                time: Some(Time::Synchronized(now)),
            };
            db.update(idx, &frozen, UpdateOptions::detect_event());
            if clear {
                let cleared = Counter {
                    value: 0,
                    flags: c.flags,
                    time: Some(Time::Synchronized(now)),
                };
                db.update(idx, &cleared, UpdateOptions::detect_event());
            }
        }
    }
}
