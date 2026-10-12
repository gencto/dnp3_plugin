//! Minimal, dependency-free binding to the Dart native messaging API.
//!
//! Dart hands us the address of `Dart_PostCObject` (`NativeApi.postCObject`) during
//! initialisation. Every message we send is a 4-element array:
//!
//! `[i64 kind, i64 a, i64 b, payload]`
//!
//! where `payload` is `null`, an `int`, a `String` or a `Uint8List`. Large binary payloads
//! are transferred as *external* typed data: the Dart VM adopts the Rust allocation and
//! calls back into [`free_vec`] when the `Uint8List` is garbage collected. No copy is made.

use std::ffi::{c_char, c_void, CString};
use std::sync::atomic::{AtomicPtr, AtomicUsize, Ordering};

pub type DartPort = i64;

#[repr(C)]
#[allow(dead_code)]
#[derive(Copy, Clone)]
enum CObjectType {
    Null = 0,
    Bool,
    Int32,
    Int64,
    Double,
    String,
    Array,
    TypedData,
    ExternalTypedData,
    SendPort,
    Capability,
    NativePointer,
    Unsupported,
    UnmodifiableExternalTypedData,
}

const DART_TYPED_DATA_UINT8: i32 = 2;

type HandleFinalizer = unsafe extern "C" fn(isolate_callback_data: *mut c_void, peer: *mut c_void);

#[repr(C)]
#[derive(Copy, Clone)]
struct ArrayValue {
    length: isize,
    values: *mut *mut CObject,
}

#[repr(C)]
#[derive(Copy, Clone)]
struct TypedDataValue {
    ty: i32,
    length: isize,
    values: *const u8,
}

#[repr(C)]
#[derive(Copy, Clone)]
struct ExternalTypedDataValue {
    ty: i32,
    length: isize,
    data: *mut u8,
    peer: *mut c_void,
    callback: HandleFinalizer,
}

#[repr(C)]
#[derive(Copy, Clone)]
union CObjectValue {
    as_bool: bool,
    as_int32: i32,
    as_int64: i64,
    as_double: f64,
    as_string: *const c_char,
    as_array: ArrayValue,
    as_typed_data: TypedDataValue,
    as_external_typed_data: ExternalTypedDataValue,
    // largest member of the C union has 5 pointer-sized fields
    _pad: [usize; 5],
}

#[repr(C)]
struct CObject {
    ty: CObjectType,
    value: CObjectValue,
}

impl CObject {
    fn null() -> Self {
        Self {
            ty: CObjectType::Null,
            value: CObjectValue { as_int64: 0 },
        }
    }

    fn int(value: i64) -> Self {
        Self {
            ty: CObjectType::Int64,
            value: CObjectValue { as_int64: value },
        }
    }
}

type PostCObjectFn = unsafe extern "C" fn(port: DartPort, message: *mut CObject) -> bool;

static POST_COBJECT: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());

/// Payloads smaller than this are copied (`kTypedData`) instead of being transferred as
/// external typed data. Measured on the Dart VM (benchmark/run_all.dart, section 1): a copy
/// into the young generation beats the finalizer + external-allocation accounting of an
/// external typed data object up to ~100 KB; above that zero-copy wins by a wide margin
/// (4x at 384 KB). Adjustable at runtime with `dnp3_set_external_threshold`.
pub(crate) static EXTERNAL_THRESHOLD: AtomicUsize = AtomicUsize::new(128 * 1024);

pub(crate) fn set_post_cobject(ptr: *mut c_void) {
    POST_COBJECT.store(ptr, Ordering::Release);
}

pub(crate) fn is_initialized() -> bool {
    !POST_COBJECT.load(Ordering::Acquire).is_null()
}

unsafe fn post_raw(port: DartPort, obj: &mut CObject) -> bool {
    let ptr = POST_COBJECT.load(Ordering::Acquire);
    if ptr.is_null() || port == 0 {
        return false;
    }
    let func: PostCObjectFn = std::mem::transmute(ptr);
    func(port, obj as *mut CObject)
}

/// Finalizer invoked by the Dart VM when an external `Uint8List` created from a `Vec<u8>`
/// becomes unreachable.
unsafe extern "C" fn free_vec(_isolate_data: *mut c_void, peer: *mut c_void) {
    // `peer` is a leaked `Box<Vec<u8>>`
    drop(Box::from_raw(peer as *mut Vec<u8>));
}

/// The payload of a message sent to Dart
pub enum Payload {
    Null,
    Int(i64),
    Str(String),
    /// Binary data. Large buffers are moved into the Dart heap without copying.
    Bytes(Vec<u8>),
    /// Binary data that is always copied (useful for small scratch buffers)
    CopiedBytes(Vec<u8>),
}

impl From<()> for Payload {
    fn from(_: ()) -> Self {
        Payload::Null
    }
}

impl From<i64> for Payload {
    fn from(x: i64) -> Self {
        Payload::Int(x)
    }
}

impl From<String> for Payload {
    fn from(x: String) -> Self {
        Payload::Str(x)
    }
}

impl From<&str> for Payload {
    fn from(x: &str) -> Self {
        Payload::Str(x.to_string())
    }
}

impl From<Vec<u8>> for Payload {
    fn from(x: Vec<u8>) -> Self {
        Payload::Bytes(x)
    }
}

/// Post `[kind, a, b, payload]` to a Dart `ReceivePort`. Returns `true` if the message was
/// enqueued. Ownership of external data is released to the VM only when this returns true.
pub(crate) fn post(port: DartPort, kind: i64, a: i64, b: i64, payload: Payload) -> bool {
    let mut c_kind = CObject::int(kind);
    let mut c_a = CObject::int(a);
    let mut c_b = CObject::int(b);

    // storage that must outlive the post call
    let mut _cstring: Option<CString> = None;
    let mut _copied: Option<Vec<u8>> = None;
    let mut external: Option<*mut Vec<u8>> = None;

    let mut c_payload = match payload {
        Payload::Null => CObject::null(),
        Payload::Int(x) => CObject::int(x),
        Payload::Str(s) => {
            // interior NULs are not representable, replace them
            let s = if s.contains('\0') {
                s.replace('\0', " ")
            } else {
                s
            };
            let cs = CString::new(s).unwrap_or_default();
            let obj = CObject {
                ty: CObjectType::String,
                value: CObjectValue {
                    as_string: cs.as_ptr(),
                },
            };
            _cstring = Some(cs);
            obj
        }
        Payload::Bytes(vec) if vec.len() >= EXTERNAL_THRESHOLD.load(Ordering::Relaxed) => {
            let boxed = Box::into_raw(Box::new(vec));
            // SAFETY: boxed is a valid pointer we just created
            let (data, len) = unsafe { ((*boxed).as_mut_ptr(), (*boxed).len()) };
            external = Some(boxed);
            CObject {
                ty: CObjectType::ExternalTypedData,
                value: CObjectValue {
                    as_external_typed_data: ExternalTypedDataValue {
                        ty: DART_TYPED_DATA_UINT8,
                        length: len as isize,
                        data,
                        peer: boxed as *mut c_void,
                        callback: free_vec,
                    },
                },
            }
        }
        Payload::Bytes(vec) | Payload::CopiedBytes(vec) => {
            let obj = CObject {
                ty: CObjectType::TypedData,
                value: CObjectValue {
                    as_typed_data: TypedDataValue {
                        ty: DART_TYPED_DATA_UINT8,
                        length: vec.len() as isize,
                        values: vec.as_ptr(),
                    },
                },
            };
            _copied = Some(vec);
            obj
        }
    };

    let mut values: [*mut CObject; 4] = [&mut c_kind, &mut c_a, &mut c_b, &mut c_payload];
    let mut array = CObject {
        ty: CObjectType::Array,
        value: CObjectValue {
            as_array: ArrayValue {
                length: 4,
                values: values.as_mut_ptr(),
            },
        },
    };

    // SAFETY: all objects referenced by the array live until the end of this function
    let posted = unsafe { post_raw(port, &mut array) };

    if !posted {
        if let Some(boxed) = external {
            // VM did not take ownership, reclaim the allocation
            // SAFETY: pointer created by Box::into_raw above and not adopted by the VM
            unsafe { drop(Box::from_raw(boxed)) };
        }
    }

    posted
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cobject_layout_matches_c() {
        // On 64-bit targets Dart_CObject is 8 (type + padding) + 40 (union) bytes
        if std::mem::size_of::<usize>() == 8 {
            assert_eq!(std::mem::size_of::<CObject>(), 48);
        }
    }
}
