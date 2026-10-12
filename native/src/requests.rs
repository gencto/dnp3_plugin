//! Decoders for the binary request formats produced by the Dart side
//! (`lib/src/native/encoders.dart`).

use dnp3::app::attr::{AttrSet, FloatType, OwnedAttrValue, OwnedAttribute};
use dnp3::app::control::*;
use dnp3::app::{FunctionCode, Timestamp};
use dnp3::master::*;
use dnp3::outstation::FreezeInterval;

use crate::codec::Reader;
use crate::core::{Error, Result};
use crate::variation::from_group_var;

fn variation(group: u8, var: u8) -> Result<dnp3::app::Variation> {
    from_group_var(group, var)
        .ok_or_else(|| Error::arg(format!("unknown variation g{group}v{var}")))
}

/// Read header (8 bytes): u8 kind, u8 group, u8 var, u8 pad, u16 a, u16 b
///
/// kinds: 0 all objects, 1 one-byte range, 2 two-byte range, 3 one-byte limited count,
/// 4 two-byte limited count
/// One-byte range / count / index
fn narrow(x: u16) -> Result<u8> {
    u8::try_from(x).map_err(|_| Error::arg("value exceeds 255 for a one-byte prefix"))
}

fn dead_band_u16(x: u32) -> Result<u16> {
    u16::try_from(x).map_err(|_| Error::arg("group 34 var 1 dead band exceeds 65535"))
}

fn read_header(r: &mut Reader) -> Result<ReadHeader> {
    let kind = r.u8()?;
    let g = r.u8()?;
    let v = r.u8()?;
    r.u8()?;
    let a = r.u16()?;
    let b = r.u16()?;
    let var = variation(g, v)?;
    Ok(match kind {
        0 => ReadHeader::all_objects(var),
        1 => ReadHeader::one_byte_range(var, narrow(a)?, narrow(b)?),
        2 => ReadHeader::two_byte_range(var, a, b),
        3 => ReadHeader::one_byte_limited_count(var, narrow(a)?),
        4 => ReadHeader::two_byte_limited_count(var, a),
        x => return Err(Error::arg(format!("unknown read header kind {x}"))),
    })
}

/// Read request:
///  * `u8 0, u8 classes`  — class scan, bit0..3 = class 0..3
///  * `u8 1, u16 count, [8-byte headers]`
pub fn read_request(data: &[u8]) -> Result<ReadRequest> {
    let mut r = Reader::new(data);
    match r.u8()? {
        0 => {
            let c = r.u8()?;
            Ok(ReadRequest::class_scan(Classes::new(
                c & 1 != 0,
                EventClasses::new(c & 2 != 0, c & 4 != 0, c & 8 != 0),
            )))
        }
        1 => {
            let count = r.u16()? as usize;
            r.u8()?; // alignment
            let mut headers = Vec::with_capacity(count);
            for _ in 0..count {
                headers.push(read_header(&mut r)?);
            }
            Ok(match headers.len() {
                1 => ReadRequest::SingleHeader(headers[0]),
                _ => ReadRequest::MultipleHeader(headers),
            })
        }
        x => Err(Error::arg(format!("unknown read request type {x}"))),
    }
}

/// Generic headers used with `send_and_expect_empty_response` (FREEZE, WRITE, ...):
/// sequence of `u8 kind` entries:
///  * 0..=4 — read header (kind is the read header kind, followed by the remaining 7 bytes)
///  * 5     — time and interval (g50v2): `u8[3] pad, u32 interval, u64 time`
///  * 6     — attribute (see [`owned_attribute`])
pub fn headers(data: &[u8]) -> Result<Headers> {
    let mut r = Reader::new(data);
    let mut headers = Headers::new();
    while !r.is_empty() {
        let kind = r.u8()?;
        match kind {
            0..=4 => {
                let g = r.u8()?;
                let v = r.u8()?;
                r.u8()?;
                let a = r.u16()?;
                let b = r.u16()?;
                let var = variation(g, v)?;
                headers = match kind {
                    0 => headers.add_all_objects(var),
                    1 => headers.add_range_8(var, narrow(a)?, narrow(b)?),
                    2 => headers.add_range_16(var, a, b),
                    3 => headers.add_one_byte_limited_count(var, narrow(a)?),
                    _ => headers.add_two_byte_limited_count(var, a),
                };
            }
            5 => {
                r.skip(3)?;
                let interval = r.u32()?;
                let time = r.u64()?;
                headers = headers
                    .add_freeze_interval(FreezeInterval::new(Timestamp::new(time), interval));
            }
            6 => {
                r.skip(3)?;
                headers = headers.add_attribute(owned_attribute(&mut r)?);
            }
            x => return Err(Error::arg(format!("unknown header kind {x}"))),
        }
    }
    Ok(headers)
}

/// Owned attribute: `u8 set_kind, u8 set_value, u8 variation, u8 type, u8 float_kind, u8[3]`
/// followed by the value:
///  * 1 visible string, 5 octet string, 6 bit string — blob
///  * 2 unsigned int, 3 signed int — i64
///  * 4 float — f64 (float_kind 0 = f32, 1 = f64)
///  * 7 DNP3 time — u64
pub fn owned_attribute(r: &mut Reader) -> Result<OwnedAttribute> {
    let set_kind = r.u8()?;
    let set_value = r.u8()?;
    let variation = r.u8()?;
    let ty = r.u8()?;
    let float_kind = r.u8()?;
    r.skip(3)?;
    let set = match set_kind {
        0 => AttrSet::Default,
        _ => AttrSet::Private(set_value),
    };
    let value = match ty {
        1 => OwnedAttrValue::VisibleString(r.string()?),
        2 => OwnedAttrValue::UnsignedInt(
            u32::try_from(r.i64()?).map_err(|_| Error::arg("unsigned attribute exceeds u32"))?,
        ),
        3 => OwnedAttrValue::SignedInt(
            i32::try_from(r.i64()?).map_err(|_| Error::arg("signed attribute exceeds i32"))?,
        ),
        4 => {
            let x = r.f64()?;
            OwnedAttrValue::FloatingPoint(if float_kind == 0 {
                FloatType::F32(x as f32)
            } else {
                FloatType::F64(x)
            })
        }
        5 => OwnedAttrValue::OctetString(r.blob()?.to_vec()),
        6 => OwnedAttrValue::BitString(r.blob()?.to_vec()),
        7 => OwnedAttrValue::Dnp3Time(Timestamp::new(r.u64()?)),
        x => return Err(Error::arg(format!("unsupported attribute type {x}"))),
    };
    Ok(OwnedAttribute::new(set, variation, value))
}

pub fn control_code(raw: u8) -> ControlCode {
    ControlCode {
        tcc: TripCloseCode::from((raw >> 6) & 0x03),
        clear: raw & 0x20 != 0,
        queue: raw & 0x10 != 0,
        op_type: OpType::from(raw & 0x0F),
    }
}

pub fn control_code_byte(c: &ControlCode) -> u8 {
    (c.tcc.as_u8() << 6)
        | ((c.clear as u8) << 5)
        | ((c.queue as u8) << 4)
        | (c.op_type.as_u8() & 0x0F)
}

/// Command request:
/// `u8 mode (0 direct operate, 1 select-before-operate), u8 pad, u16 header count` then headers:
/// `u8 type, u8 index size (1|2), u16 count`, followed by `count` records:
///  * type 0 g12v1: `u16 index, u8 code, u8 count, u32 on, u32 off` (12 bytes)
///  * type 1 g41v1: `u16 index, u16 pad, i32 value` (8 bytes)
///  * type 2 g41v2: `u16 index, i16 value` (4 bytes)
///  * type 3 g41v3: `u16 index, u16 pad, f32 value` (8 bytes)
///  * type 4 g41v4: `u16 index, u8[6] pad, f64 value` (16 bytes)
pub fn command(data: &[u8]) -> Result<(CommandMode, CommandHeaders)> {
    let mut r = Reader::new(data);
    let mode = match r.u8()? {
        0 => CommandMode::DirectOperate,
        1 => CommandMode::SelectBeforeOperate,
        x => return Err(Error::arg(format!("unknown command mode {x}"))),
    };
    r.u8()?;
    let header_count = r.u16()?;
    let mut builder = CommandBuilder::new();

    fn add<T>(builder: &mut CommandBuilder, wide: bool, cmd: T, index: u16) -> Result<()>
    where
        CommandBuilder: CommandSupport<T>,
    {
        if wide {
            builder.add_u16(cmd, index);
        } else {
            let index = u8::try_from(index)
                .map_err(|_| Error::arg("index exceeds 255 for 1-byte prefix"))?;
            builder.add_u8(cmd, index);
        }
        Ok(())
    }

    for _ in 0..header_count {
        let ty = r.u8()?;
        let wide = match r.u8()? {
            1 => false,
            2 => true,
            x => return Err(Error::arg(format!("invalid index size {x}"))),
        };
        let count = r.u16()?;
        for _ in 0..count {
            let index = r.u16()?;
            match ty {
                0 => {
                    let code = control_code(r.u8()?);
                    let cnt = r.u8()?;
                    let on = r.u32()?;
                    let off = r.u32()?;
                    add(
                        &mut builder,
                        wide,
                        Group12Var1 {
                            code,
                            count: cnt,
                            on_time: on,
                            off_time: off,
                            status: CommandStatus::Success,
                        },
                        index,
                    )?;
                }
                1 => {
                    r.u16()?;
                    let value = r.i32()?;
                    add(
                        &mut builder,
                        wide,
                        Group41Var1 {
                            value,
                            status: CommandStatus::Success,
                        },
                        index,
                    )?;
                }
                2 => {
                    let value = r.i16()?;
                    add(
                        &mut builder,
                        wide,
                        Group41Var2 {
                            value,
                            status: CommandStatus::Success,
                        },
                        index,
                    )?;
                }
                3 => {
                    r.u16()?;
                    let value = r.f32()?;
                    add(
                        &mut builder,
                        wide,
                        Group41Var3 {
                            value,
                            status: CommandStatus::Success,
                        },
                        index,
                    )?;
                }
                4 => {
                    r.skip(6)?;
                    let value = r.f64()?;
                    add(
                        &mut builder,
                        wide,
                        Group41Var4 {
                            value,
                            status: CommandStatus::Success,
                        },
                        index,
                    )?;
                }
                x => return Err(Error::arg(format!("unknown command type {x}"))),
            }
        }
        builder.finish_header();
    }
    Ok((mode, builder.build()))
}

/// Dead band headers: sequence of `u8 type (1 g34v1, 2 g34v2, 3 g34v3), u8 index size, u16 count`
/// followed by `count` records of `u16 index, u16 pad, f32/u32 value` (8 bytes; g34v1 uses u32
/// and must fit in u16)
pub fn dead_bands(data: &[u8]) -> Result<Vec<DeadBandHeader>> {
    let mut r = Reader::new(data);
    let mut out = Vec::new();
    while !r.is_empty() {
        let ty = r.u8()?;
        let wide = r.u8()? == 2;
        let count = r.u16()? as usize;
        let mut raw = Vec::with_capacity(count);
        for _ in 0..count {
            let index = r.u16()?;
            r.u16()?;
            let bits = r.u32()?;
            raw.push((index, bits));
        }
        let header = match (ty, wide) {
            (1, false) => DeadBandHeader::group34_var1_u8(
                raw.iter()
                    .map(|(i, v)| Ok((narrow(*i)?, dead_band_u16(*v)?)))
                    .collect::<Result<_>>()?,
            ),
            (1, true) => DeadBandHeader::group34_var1_u16(
                raw.iter()
                    .map(|(i, v)| Ok((*i, dead_band_u16(*v)?)))
                    .collect::<Result<_>>()?,
            ),
            (2, false) => DeadBandHeader::group34_var2_u8(
                raw.iter()
                    .map(|(i, v)| Ok((narrow(*i)?, *v)))
                    .collect::<Result<_>>()?,
            ),
            (2, true) => DeadBandHeader::group34_var2_u16(raw),
            (3, false) => DeadBandHeader::group34_var3_u8(
                raw.iter()
                    .map(|(i, v)| Ok((narrow(*i)?, f32::from_bits(*v))))
                    .collect::<Result<_>>()?,
            ),
            (3, true) => DeadBandHeader::group34_var3_u16(
                raw.iter().map(|(i, v)| (*i, f32::from_bits(*v))).collect(),
            ),
            (x, _) => return Err(Error::arg(format!("unknown dead band type {x}"))),
        };
        out.push(header);
    }
    Ok(out)
}

pub fn function_code(x: u8) -> Result<FunctionCode> {
    FunctionCode::from(x).ok_or_else(|| Error::arg(format!("unknown function code {x}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn control_code_round_trip() {
        for raw in [0x41u8, 0x81, 0x03, 0x64, 0x11] {
            let c = control_code(raw);
            assert_eq!(control_code_byte(&c), raw);
        }
    }

    #[test]
    fn decodes_class_scan() {
        let r = read_request(&[0, 0x0F]).unwrap();
        assert!(matches!(r, ReadRequest::ClassScan(_)));
    }

    #[test]
    fn decodes_command() {
        let mut d = vec![0u8, 0, 1, 0, 0, 2, 1, 0];
        d.extend_from_slice(&7u16.to_le_bytes());
        d.extend_from_slice(&[0x03, 1]);
        d.extend_from_slice(&100u32.to_le_bytes());
        d.extend_from_slice(&200u32.to_le_bytes());
        let (mode, _) = command(&d).unwrap();
        assert_eq!(mode, CommandMode::DirectOperate);
    }
}
