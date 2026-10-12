# dnp3 — DNP3 (IEEE 1815) for Dart & Flutter

A complete DNP3 **master** and **outstation** for Dart and Flutter, built on the
[`dnp3`](https://github.com/stepfunc/dnp3) Rust library by Step Function I/O (v1.7.0).

* every transport of the library: **TCP client/server, TLS client/server, serial, UDP**, and a
  **master acting as TCP server** (outstations dial in, identified by IP or link address)
* the full master feature set: associations, class/range/attribute reads, periodic polls,
  SBO/DO/DO-no-ack commands (CROB, g41v1–v4), time sync (LAN, non-LAN, direct write), cold/warm
  restart, dead band writes, freeze/write/enable-/disable-unsolicited via generic requests,
  link status, device attributes (group 0), file transfer (auth, open, read stream, write
  blocks, close, directory listing, file info), association information callbacks
* the full outstation feature set: database of BI, DBBI, BOS, counters, frozen counters, AI,
  AOS and octet strings with event classes, dead bands and every static/event variation,
  flag updates, device attributes, control handling (native or Dart callbacks), application
  callbacks (time write, restarts, freeze, attribute writes, dead bands, confirmations),
  application IIN, information callbacks, address filters on TCP/TLS servers
* **zero-copy** data paths in both directions and **isolate-friendly** handles
* Android, iOS, macOS, Linux, Windows (Web is not possible: no sockets / FFI)

> **Licensing.** This package's own code is MIT licensed, but the `dnp3` Rust library it
> links is distributed by Step Function I/O under a **non-commercial license**. Production
> or commercial use requires a commercial license from Step Function I/O
> (<https://stepfunc.io>). Make sure you are licensed before shipping an app built with this
> package.

---

## Contents

- [Architecture](#architecture)
- [Installation & platforms](#installation--platforms)
- [Quick start](#quick-start)
- [Master API](#master-api)
- [Outstation API](#outstation-api)
- [Isolates](#isolates)
- [Zero-copy in detail](#zero-copy-in-detail)
- [Logging & errors](#logging--errors)
- [Benchmarks](#benchmarks)
- [Testing](#testing)
- [CI/CD](#cicd)
- [Repository layout](#repository-layout)

## Architecture

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
  formats documented in [`doc/wire_format.md`](doc/wire_format.md).

## Installation & platforms

```yaml
dependencies:
  dnp3:
    git: https://github.com/gencto/dnp3_plugin
```

The native library is produced by the package's **build hook** (`hook/build.dart`, Dart
native assets) for whatever target `dart` or `flutter` is building for:

| Platform | Targets (Rust triples) | Serial | Notes |
|---|---|---|---|
| Android | `aarch64-linux-android`, `armv7-linux-androideabi`, `x86_64-linux-android`, `i686-linux-android` | ✓ | NDK linker from the Flutter tool, 16 KB page aligned |
| iOS | `aarch64-apple-ios`, `aarch64-apple-ios-sim`, `x86_64-apple-ios` | ✗ | serial ports do not exist on iOS |
| macOS | `aarch64-apple-darwin`, `x86_64-apple-darwin` | ✓ | |
| Linux | `x86_64`, `aarch64`, `armv7`, `i686`, `riscv64gc` | ✓ | |
| Windows | `x86_64-pc-windows-msvc`, `aarch64-pc-windows-msvc`, `i686` | ✓ | |
| Web | — | — | impossible (no sockets, no FFI) |

Requirements: Dart ≥ 3.10 / Flutter ≥ 3.38 (build hooks), and either

1. a Rust toolchain (`rustup target add <triple>` is done automatically when rustup is
   present), **or**
2. prebuilt libraries: unzip `dnp3-native-prebuilt.zip` from a GitHub release (built by the
   `release` workflow) into `native/prebuilt/`, or point the environment variable
   `DNP3_PREBUILT_DIR` (or the hook user-define `prebuilt_dir`) to it. Layout:
   `<dir>/<rust-triple>/<libdnp3_dart.so | libdnp3_dart.dylib | dnp3_dart.dll>`.

## Quick start

```dart
import 'package:dnp3/dnp3.dart';

Future<void> main() async {
  // --- outstation (TCP server) ---
  final server = OutstationServer.tcp('0.0.0.0:20000');
  final outstation = server.addOutstation(
    config: const OutstationConfig(outstationAddress: 1024, masterAddress: 1),
  );
  outstation.transaction((tx) {
    tx
      ..addAnalogInput(0, deadband: 0.5)
      ..addBinaryOutputStatus(0)
      ..updateAnalogInput(0, 42.0, time: Dnp3Time.now());
  });
  await server.bind();

  // --- master (TCP client) ---
  final channel = MasterChannel.tcpClient(
    config: const MasterChannelConfig(masterAddress: 1),
    endpoints: ['127.0.0.1:20000'],
  );
  final assoc = await channel.addAssociation(1024);
  assoc.measurements.listen((fragment) {
    for (final block in fragment.blocks) {
      if (block is AnalogInputBlock) {
        for (var i = 0; i < block.count; i++) {
          print('AI ${block.indexAt(i)} = ${block.valueAt(i)}'); // read in place, no copy
        }
      }
    }
  });
  await assoc.addPoll(const ReadRequest.events(), const Duration(seconds: 1));
  await channel.enable();

  await assoc.operate(CommandSet.crob(0, const Crob.latchOn()));
}
```

More: [`example/master.dart`](example/master.dart), [`example/outstation.dart`](example/outstation.dart),
[`example/worker_isolate.dart`](example/worker_isolate.dart) and the Flutter app in
[`example/flutter_app`](example/flutter_app).

## Master API

```dart
// channels
MasterChannel.tcpClient(config:, endpoints:, linkErrorMode:, connectStrategy:, connectOptions:)
MasterChannel.tlsClient(config:, endpoints:, tls: TlsConfig(...))
MasterChannel.serial(config:, path: '/dev/ttyUSB0', settings: SerialSettings(baudRate: 9600))
MasterChannel.udp(config:, localEndpoint: '0.0.0.0:20000')
channel.clientStates / portStates / connectionEvents          // streams
channel.enable() / disable() / setDecodeLevel() / getDecodeLevel() / destroy()

// associations
final a = await channel.addAssociation(1024,
    config: AssociationConfig(autoTimeSync: TimeSyncProcedure.lan, keepAliveTimeout: ...),
    udpDestination: '10.0.0.5:20000',   // UDP channels only
    information: true,                   // task start/success/fail, unsolicited events
    eventPort: worker.port);             // deliver to another isolate

a.measurements                // Stream<MeasurementFragment> (zero-copy)
a.information                 // Stream<AssociationEvent>
await a.read(ReadRequest.integrity() | .events() | .classScan(Classes(...))
             | .range(Variation.group30Var5, 0, 9) | .headers([...]) | .deviceAttribute(v));
await a.readWithHandler(request)                 // returns List<MeasurementFragment>
await a.operate(CommandSet()..addCrob(0, Crob(ControlCode.latchOn()))..addAnalog(1, AnalogOutput.float32(5)),
                mode: CommandMode.selectBeforeOperate | directOperate);
await a.synchronizeTime(TimeSyncProcedure.nonLan);
await a.coldRestart() / warmRestart();           // → Duration reported by the outstation
await a.writeDeadBands([DeadBandHeader.g34v3({0: 1.5})]);
await a.freezeCounters(clear: true);
await a.enableUnsolicited(EventClasses.all()) / disableUnsolicited(...);
await a.writeAttribute(DeviceAttribute.string(AttributeVariation.userAssignedLocation, 'Kyiv'));
await a.sendAndExpectEmptyResponse(FunctionCode.freezeAtTime,
    RequestHeaders()..allObjects(Variation.group20Var0)..timeAndInterval(Dnp3Time.now(), 60000));
await a.checkLinkStatus();
final poll = await a.addPoll(ReadRequest.events(), Duration(seconds: 1)); poll.demand(); poll.remove();
a.setTimeOffset(Duration(hours: -1));

// files
final key = await a.getFileAuthKey('user', 'pass');
final f = await a.openFile('/log.txt', authKey: key, mode: FileMode.read);
a.readFile('/log.txt').blocks.listen(...);   // streaming, abortable
await a.writeFile('/cfg.bin', bytes);        // open + blocks + close
await a.readDirectory('/'); await a.getFileInfo('/x');

// master as TCP server (outstations connect to us)
final server = await MasterServer.bind('0.0.0.0:20000', MyHandler());   // accept / start / acceptLinkId
```

`MeasurementFragment` exposes the response header (`readType`, `iin`, `sequence`, `fir/fin/con/uns`)
and its object headers as typed `MeasurementBlock`s: `BinaryInputBlock`,
`DoubleBitBinaryInputBlock`, `BinaryOutputStatusBlock`, `CounterBlock`, `FrozenCounterBlock`,
`AnalogInputBlock`, `FrozenAnalogInputBlock`, `AnalogInputDeadBandBlock`,
`AnalogOutputStatusBlock`, `AnalogOutputCommandEventBlock`, `BinaryOutputCommandEventBlock`,
`UnsignedIntegerBlock`, `OctetStringBlock`, `DeviceAttributeBlock`, `AbsTimeBlock`. Each block
knows its variation, qualifier, `isEvent` and `hasFlags`, and is both a lazily decoded
`List<T>` and a flyweight with `indexAt / valueAt / flagsAt / timeAt` accessors. A
`MeasurementVisitor` dispatches all blocks of a fragment by type.

## Outstation API

```dart
Outstation.tcpClient(...) / tlsClient(...) / serial(path:, retry: RetryStrategy()) / udp(...)
final server = OutstationServer.tcp('0.0.0.0:20000');           // or .tls(address, TlsConfig)
final o = server.addOutstation(config: ..., handlers: ..., filter: AddressFilter.wildcard('10.0.0.*'));
await server.bind();

o.transaction((tx) {               // one native call, one lock, one change notification
  tx.addCounter(0, eventClass: EventClass.class2, staticVariation: StaticCounterVariation.group20Var5);
  tx.updateAnalogInput(3, 1.5, flags: Flags.online, time: Dnp3Time.now(), mode: EventMode.force);
  tx.updateFlags(PointType.analogInput, 3, Flags.commLost);
  tx.defineAttribute(DeviceAttribute.string(AttributeVariation.deviceManufacturerName, 'ACME'));
  tx.removeBinaryInput(7);
});
o.database.transactionWithResults(...)   // per-op UpdateResult (event ids, overflow)
o.database.getAnalogInput(3)             // point reads; getRange(PointType.counter, 0, 99) → zero-copy block
o.setApplicationIin(needTime: true, deviceTrouble: false);
o.events        // ControlExecuted, TimeWritten, DeadBandsWritten, AttributeWritten, CountersFrozen, RestartRequested, EventsConfirmed
o.information   // OutstationInformation callbacks
o.connectionStates / clientStates / portStates / connectionEvents
```

Handler configuration (`OutstationHandlers`):

| Concern | Native modes | Dart callback |
|---|---|---|
| SELECT / OPERATE | `ControlMode.accept` (mirror into BOS / AOS, notify), `reject(status)` | `ControlMode.callback` + `onControl: (req) => ControlResponse(status, tx)` |
| cold / warm restart | `notSupported`, `seconds(n)`, `milliseconds(n)` | `RestartMode.callback` → `OutstationApplication.coldRestart()` |
| time write | `notSupported`, `accept` (+ event) | `TimeWriteMode.callback` |
| counter freeze | `notSupported`, `auto` (counter → frozen counter, optional clear) | `FreezeMode.callback` → `(result, tx)` |
| attribute write | `accept` (+ event), `reject` | `AttributeWriteMode.callback` (async) |
| dead band writes / confirms | notifications | — |

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

## Logging & errors

```dart
Dnp3.logger.onRecord.listen(print);                 // package:logging
Dnp3.enableLogging(level: Dnp3LogLevel.info);
channel.setDecodeLevel(const DecodeLevel(application: AppDecodeLevel.objectValues));
```

Errors are typed: `TaskException(TaskError.responseTimeout, ...)`, `CommandException`
(`status` for rejected controls), `TimeSyncException`, `WriteException` (IIN2),
`FileException`, `AssociationException`, `ConfigException`, `ShutdownException`,
`InvalidHandleException`, `NativeException`.

## Benchmarks

`dart run benchmark/run_all.dart [--quick] [--out benchmark/results/<name>.md]`

Results below: Linux x64 VM, 4 vCPUs, Dart 3.13.5, release build with LTO
([`benchmark/results/linux-x64.md`](benchmark/results/linux-x64.md)). The CI patch runs the
same suite on Linux x64/arm64, macOS and Windows and publishes the tables in the job summary.

### 1. Native → Dart delivery of measurement fragments

| points / fragment | transfer | bytes / fragment | fragments / s | points / s | MB / s | µs / fragment |
|---|---|---|---|---|---|---|
| 10 | zero-copy (external typed data) | 272 | 161.6 k | 1.62 M | 44.0 | 6.19 |
| 10 | copied (kTypedData) | 272 | 150.3 k | 1.50 M | 40.9 | 6.65 |
| 100 | zero-copy (external typed data) | 2432 | 97.7 k | 9.77 M | 237.7 | 10.23 |
| 100 | copied (kTypedData) | 2432 | 64.7 k | 6.47 M | 157.3 | 15.46 |
| 1000 | zero-copy (external typed data) | 24.0 k | 29.8 k | 29.77 M | 715.3 | 33.59 |
| 1000 | copied (kTypedData) | 24.0 k | 36.5 k | 36.50 M | 877.2 | 27.39 |
| 4000 | zero-copy (external typed data) | 96.0 k | 16.2 k | 64.62 M | 1551.3 | 61.91 |
| 4000 | copied (kTypedData) | 96.0 k | 16.3 k | 65.11 M | 1563.1 | 61.44 |
| 16000 | zero-copy (external typed data) | 384.0 k | 7058.9 | 112.94 M | 2710.8 | 141.66 |
| 16000 | copied (kTypedData) | 384.0 k | 1705.0 | 27.28 M | 654.8 | 586.50 |
| 1000 | zero-copy + decode every value | - | 47.4 k | 47.37 M | - | - |

(“µs / fragment” includes native encoding, the port hop and Dart dispatch. Up to ~100 KB
both transfers are within noise of each other; at 384 KB zero-copy is 4× faster.)

### 2. Decoding cost per point (1000 analog inputs per fragment)

| method | ns / point | points / s |
|---|---|---|
| flyweight accessor: value only | 2.64 | 378.43 M |
| MeasurementVisitor: value only | 2.85 | 350.82 M |
| flyweight accessors: index + value + flags + time | 7.75 | 129.07 M |
| value objects (List<AnalogInput>), all fields | 31.36 | 31.89 M |
| baseline: JSON bytes → objects, all fields | 693.14 | 1.44 M |

The binary flyweight path is **~90× faster** than a JSON based bridge (as used by typical
`MethodChannel` plugins) for the same information, and allocation-free.

### 3. Outstation database transactions (analog updates with event detection)

| updates / transaction | updates / s | ns / update | transactions / s |
|---|---|---|---|
| 1 | 9.23 M | 108.3 | 9.23 M |
| 10 | 31.50 M | 31.7 | 3.15 M |
| 100 | 34.78 M | 28.8 | 347.8 k |
| 1000 | 26.60 M | 37.6 | 26.6 k |
| read (getAnalogInput) | 5.96 M | - | - |

### 4. End-to-end over TCP loopback (master and outstation in the same process)

| operation | p50 µs | p99 µs | ops / s |
|---|---|---|---|
| integrity poll, 1000 analogs (g30v6), decoded | 536 | 1261 | 1738.2 |
| read 10 analogs (range) | 92 | 221 | 9946.9 |
| direct operate CROB (accept mode, native) | 112 | 310 | 8212.9 |
| select-before-operate CROB (accept mode) | 121 | 386 | 7103.1 |
| direct operate CROB (Dart callback round trip) | 137 | 370 | 6616.8 |
| select-before-operate CROB (2 Dart callbacks) | 243 | 721 | 3567.0 |

A synchronous Dart control callback adds ~25 µs (p50) per SELECT/OPERATE.

### 5. Event throughput outstation → master (unsolicited, TCP loopback)

| events | ms | events / s |
|---|---|---|
| 200.0 k | 134 | 1.49 M |

### 6. Delivery straight into a worker isolate (1000 points per fragment, decoded)

| receiver | fragments / s | points / s |
|---|---|---|
| worker isolate | 69.1 k | 69.06 M |

## Testing

```sh
dart test                    # builds native/ through the hook, 42 tests
(cd native && cargo test)    # Rust unit tests
```

The integration suite runs real master/outstation pairs over TCP, TLS (self-signed
certificates generated with `openssl`), UDP, serial (a Python pty null-modem on Linux) and the
master-server mode, plus callbacks, device attributes, isolates, logging and handle cleanup.

## CI/CD

The GitHub Actions workflows are delivered as a patch: [`ci/0001-ci-add-github-actions-workflows.patch`](ci/).
Apply it with:

```sh
git am ci/0001-ci-add-github-actions-workflows.patch
```

It adds:

* `ci.yml` — Rust fmt/clippy/tests; Dart analyze/format/tests + a quick benchmark on Linux
  x64/arm64, macOS and Windows; native cross builds; Flutter example builds for Android,
  iOS, macOS, Linux and Windows.
* `native-build.yml` — reusable matrix building all 13 native targets.
* `release.yml` — on `v*` tags: builds all targets, publishes `dnp3-native-prebuilt.zip`.
* `benchmark.yml` — weekly / manual full benchmark on all desktop OSes.
* `dependabot.yml`.

## Repository layout

```
hook/build.dart            build hook (cargo / prebuilt resolution)
native/                    Rust bridge crate (C ABI over dnp3 1.7.0)
lib/dnp3.dart              public API
lib/src/native/            @Native bindings, runtime dispatcher, binary writer
lib/src/measurements.dart  zero-copy fragment / block views
benchmark/                 benchmark suite and recorded results
test/                      integration tests
example/                   Dart CLI examples and a Flutter app
doc/wire_format.md         binary formats exchanged with native code
tool/                      code generators (variation tables)
ci/                        GitHub Actions workflows as a git patch
```
