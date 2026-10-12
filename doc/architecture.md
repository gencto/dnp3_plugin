# Architecture

```
 Dart isolate(s)                         │ native (Rust, one per process)
─────────────────────────────────────────┼──────────────────────────────────────────────
 MasterChannel / Association / Poll       │  dnp3_dart  (native/)
 Outstation / OutstationServer / Database │   ├─ C ABI (lib.rs), handle registry
 MasterServer                             │   ├─ tokio multi-thread runtime
   │  @Native leaf calls                  │   ├─ dnp3 1.7.0 master / outstation tasks
   │  (Uint8List.address → no copy) ─────►│   ├─ ReadHandler → binary fragment encoder
   │                                      │   ├─ ControlHandler / OutstationApplication /
   │◄──── Dart_PostCObject ───────────────│   │  OutstationInformation / AssociationInformation
   │  [kind, id, sub, payload]            │   │  → port messages, sync/async request-reply
   │  payload: external typed data        │   └─ tracing → package:logging
 RawReceivePort per isolate               │
```

* **Handles are integers.** Every native object (channel, association, poll, outstation,
  server) lives in a process-wide registry and is referenced by a 64-bit handle that can be
  sent to any isolate and re-attached (`Association.attach(handle)`, `Outstation.attach`,
  `Database(handle)`).
* **One `RawReceivePort` per isolate** receives completions, events and callback requests.
  Async operations complete through it; events are routed to the owning Dart object.
* **Callbacks that DNP3 requires to be synchronous** (outstation SELECT/OPERATE, restart,
  time write, freeze) are executed natively by default (`ControlMode.accept`,
  `FreezeMode.auto`, ...). When configured as `callback`, the protocol worker posts a request
  to Dart and parks itself with `block_in_place` (other sessions keep running) until Dart
  replies or a configurable timeout expires. Replies can carry database operations which are
  applied atomically before the response is sent.
* **Configuration** objects are serialized to JSON once (cold path); all hot paths
  (measurements, database updates, commands, read requests) use compact little-endian binary
  formats documented in [`doc/wire_format.md`](wire_format.md).

## Isolates

* `MasterChannel.addAssociation(..., eventPort: worker.port)` — measurement fragments are
  posted by native code **directly to the worker isolate**; the creating (UI) isolate is not
  involved at all. `MeasurementWorker.spawn(callback)` creates such a worker.
* `Database(outstationHandle)` works in any isolate: e.g. a sampling isolate can feed the
  outstation database at high rate without touching the UI isolate.
* `Association.attach(handle)`, `MasterChannel.attach(handle)`, `Poll.attach(handle)`,
  `Outstation.attach(handle)` give full API access from other isolates; completions are
  delivered to the isolate that issued the call.
* `DatabaseTransaction` can be built anywhere and shipped as bytes
  (`TransferableTypedData`) to be applied with `database.applyBytes(...)`.

## Zero-copy in detail

| Path | Mechanism |
|---|---|
| native → Dart measurements | one contiguous buffer per fragment; ≥ threshold it is posted as **external typed data** (the VM adopts the Rust allocation, freed by a finalizer). Dart reads it in place through `ByteData` flyweights. |
| Dart → native requests / database ops | encoded into a reusable Dart `Uint8List`; passed to `@Native(isLeaf: true)` functions via `Uint8List.address`, so Rust reads the Dart heap directly. |
| outstation range reads | native buffer exposed with `Pointer.asTypedList(finalizer:)`. |
| file blocks | external typed data views. |

The external-vs-copy threshold defaults to **128 KiB**: the benchmarks below show that for
small buffers a copy into the Dart young generation is as cheap as the finalizer-based
transfer, while for large buffers zero-copy is up to 4× faster. Change it with
`Dnp3.zeroCopyThreshold = bytes` (`0` = always zero-copy).
