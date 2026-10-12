# Binary formats between Dart and native code

All integers are little endian. ABI version: `3` (`dnp3_abi_version()`); the Dart side
refuses to run against a different version.

## Port messages (native → Dart)

Every message is a 4 element list `[kind, a, b, payload]`:

| kind | name | a | b | payload |
|---|---|---|---|---|
| 1 | RESULT | request id | error code (0 = ok) | value, or `"sub|detail|message"` on error |
| 2 | LOG | level (1 error … 5 trace) | 0 | text |
| 10 | CLIENT_STATE | object id | state | retry delay ms |
| 11 | PORT_STATE | object id | state | retry delay ms |
| 12 | CONNECTION_STATE | outstation id | 0 disconnected / 1 connected | – |
| 13 | CONNECTION_EVENT | object id | 0 connecting, 1 connected, 2 failed, 3 disconnected, 4 resolution failed | `"addr|host"` |
| 20 | MEASUREMENTS | association id | 0 | fragment (below) |
| 21 | ASSOCIATION_INFO | association id | event | packed int |
| 22 | FILE_READ | transfer id | 0 opened, 1 block, 2 aborted, 3 completed | size / `u32 block, u32 len, data` / `"code|sub|detail|message"` |
| 23 | FILE_OPEN_REQUEST | reply token | transfer id | `u32 size, u32` — reply 1 continue, else abort |
| 30 | CONTROL_REQUEST | reply token | outstation id | control record |
| 31 | APPLICATION_REQUEST | reply token | outstation id | `u8 type, u8[7], …` |
| 32 | OUTSTATION_INFO | outstation id | event | packed int |
| 33 | OUTSTATION_EVENT | outstation id | event | event specific |
| 40 | MASTER_SERVER_REQUEST | reply token | server id | `u8 type, u8, u16 src, u16 dst, u16, u64 channel, blob addr`; type 0 accept, 1 start, 2 accept link id, 3 start with link id, 4 session closed (token 0, no reply; the channel is already released) |
| 41 | CONNECTION_REQUEST | reply token | channel / outstation id | next: `u8 0, u8[3], u32 failures, u32 next index, u32 endpoints`; disconnected: `u8 1, u8[3], blob "addr|host"` — reply 1 = connect (JSON `{endpoint, timeoutMs?, localEndpoint?, masterAddress?}`), 2 = wait (`u64 ms`), else native policy |

Control records (kind 30) start with a phase byte: 0 SELECT, 1 OPERATE, 3 end of the
request fragment (reply data = database ops). Outstation event 7 marks the beginning of a
request containing controls.

Measurement flow control: `dnp3_association_ack(id, n)` releases `n` fragments of an
association created with `maxInFlightFragments > 0`.

Requests (23, 30, 31, 40, 41) are answered with `dnp3_reply(token, status, data, len)`:

| kind | status |
|---|---|
| 23 FILE_OPEN_REQUEST | 1 continue the read, else abort |
| 30 CONTROL_REQUEST | `CommandStatus` code; reply data = database ops |
| 31 APPLICATION_REQUEST | time write / freeze: 0 ok, 1 parameter error, else not supported (freeze reply data = database ops); restart: 1 seconds, 2 milliseconds (`u16` delay), else not supported; attribute write: 1 accepted |
| 40 MASTER_SERVER_REQUEST | 1 accepted (data = JSON), else rejected |
| 41 CONNECTION_REQUEST | see above |

Status `-1` (`REPLY_NO_HANDLER`) is sent when no object of the isolate handles the
request (e.g. it was destroyed there): the native side then behaves as on a callback
timeout (configured fallback / timeout status).

## Measurement fragment

```
Fragment header (16 bytes)
  u8  version (=1)
  u8  read type     (0 startup integrity, 1 unsolicited, 2 single poll, 3 periodic poll, 255 local)
  u8  function      (0 response, 1 unsolicited response)
  u8  control       (fir<<7 | fin<<6 | con<<5 | uns<<4 | seq)
  u8  iin1, u8 iin2
  u16 block count
  u32 total length (including this header)
  u32 reserved
Block header (16 bytes)
  u8  kind, u8 group, u8 variation, u8 qualifier
  u8  info flags (bit0 is_event, bit1 has_flags)
  u8  record size (0 = variable)
  u16 reserved
  u32 record count
  u32 payload length in bytes
```

Records (time kind: 0 none, 1 synchronized, 2 unsynchronized; time = ms since epoch):

| kind | type | size | layout |
|---|---|---|---|
| 1, 3 | binary input / output status | 16 | `u16 index, u8 value, u8 flags, u8 tk, u8[3], u64 time` |
| 2 | double-bit binary | 16 | same, value 0..3 |
| 4, 5 | counter / frozen counter | 16 | `u16 index, u8 flags, u8 tk, u32 value, u64 time` |
| 6, 7, 9 | analog input / frozen analog / AO status | 24 | `u16 index, u8 flags, u8 tk, u32, f64 value, u64 time` |
| 8 | analog dead band | 16 | `u16 index, u8 type (u16/u32/f32), u8, u32, f64 value` |
| 10 | analog output command event | 24 | `u16 index, u8 status, u8 type, u8 tk, u8[3], f64 value, u64 time` |
| 11 | binary output command event | 16 | `u16 index, u8 state, u8 status, u8 tk, u8[3], u64 time` |
| 12 | unsigned integer | 4 | `u16 index, u8 value, u8` |
| 13 | octet string | var | `u16 index, u16 len, bytes, pad 4` |
| 14 | device attribute | var | `u8 set kind, u8 set, u8 variation, u8 type, u8 float kind, u8[3]` + value |
| 15 | absolute time | 8 | `u64 time` |

Attribute values: types 1/5/6/254 → `u32 len, bytes, pad 4`; 2/3 → `i64`; 4 → `f64`; 7 → `u64`.

## Requests (Dart → native)

* read request: `u8 0, u8 class mask` or `u8 1, u16 count, u8 pad` + headers
  `u8 kind (0 all, 1 range8, 2 range16, 3 count8, 4 count16), u8 group, u8 var, u8, u16 a, u16 b`
* generic headers: read headers, `u8 5, u8[3], u32 interval, u64 time` (g50v2),
  `u8 6, u8[3], attribute`
* commands: `u8 mode, u8, u16 header count` then per header `u8 type, u8 index size, u16 count`
  and records (`g12v1: u16 index, u8 code, u8 count, u32 on, u32 off`, `g41v1: u16, u16, i32`,
  `g41v2: u16, i16`, `g41v3: u16, u16, f32`, `g41v4: u16, u8[6], f64`)
* dead bands: `u8 type, u8 index size, u16 count` + `u16 index, u16, u32 value bits`

## Database operations

Every op starts with `u8 op, u8 point type, u16 index`:

| op | name | body |
|---|---|---|
| 1 | update | `u8 flags, u8 tk, u8 event mode, u8 options, u64 value, u64 time` (24 bytes) |
| 1 | update octet string | `u8 event mode, u8 options, u16 len, bytes, pad 4` |
| 2 | add | `u8 class, u8 static var, u8 event var, u8, f64 dead band` (16 bytes) |
| 3 | remove | – (4 bytes) |
| 4 | update flags | `u8 flags, u8 tk, u8 event mode, u8 options, u64 time` (16 bytes) |
| 5 | define attribute | `u8 writable, u8[3], attribute` |
| 6 | discard unselected events | point type byte = class mask |

A batch is all-or-nothing: every op is validated before the first one is executed.

Optional results: 24 bytes per op `u32 status, u32, u64 a, u64 b`. Status 0 = no point /
failure, 1 = ok, 2 = event created (a = event id), 3 = event buffer overflow (a = created
id, b = discarded id). For op 5 a failure carries the reason in `a` (1 already defined,
2 bad type, 3 reserved variation, 4 not writable); op 6 reports the number of discarded
events in `a`.
