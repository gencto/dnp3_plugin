# dnp3

[![pub package](https://img.shields.io/pub/v/dnp3.svg)](https://pub.dev/packages/dnp3)
[![CI](https://github.com/gencto/dnp3_plugin/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/gencto/dnp3_plugin/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

DNP3 (IEEE 1815) **master** and **outstation** for Dart and Flutter, built on the
[`dnp3`](https://github.com/stepfunc/dnp3) Rust library by Step Function I/O (v1.7.0)
through a zero-copy FFI bridge.

- **Every transport:** TCP client/server, TLS client/server, serial, UDP, and a master
  acting as TCP server (outstations dial in, identified by IP or link address).
- **Complete master:** associations, class/range/attribute reads, periodic polls,
  SBO/DO commands (CROB, g41v1–v4), time sync, restarts, dead bands, generic requests,
  device attributes, file transfer, reconnect policy in Dart, measurement back-pressure.
- **Complete outstation:** database of all point types with event classes, dead bands and
  every variation, native or Dart control handling, application callbacks (time, restart,
  freeze, attributes), address filters, FREEZE_AT_TIME scheduling.
- **Fast:** measurements are read in place from native buffers (zero-copy flyweights),
  database updates are batched into one native call, handles work from any isolate.
- **Platforms:** Android, iOS, macOS, Linux, Windows. (Web is impossible: no sockets, no FFI.)

> [!IMPORTANT]
> **Licensing.** This package's own code is MIT licensed, but the `dnp3` Rust library it
> links is distributed by Step Function I/O under a **non-commercial license**. Production
> or commercial use requires a commercial license from Step Function I/O
> (<https://stepfunc.io>). Make sure you are licensed before shipping an app built with
> this package.

## Contents

- [Installation](#installation)
- [Quick start](#quick-start)
- [Examples](#examples)
- [Documentation](#documentation)
- [Platform support](#platform-support)
- [Contributing](#contributing)
- [Support and security](#support-and-security)

## Installation

```sh
dart pub add dnp3        # or: flutter pub add dnp3
```

The native library is built by the package's build hook (Dart native assets) for whatever
target `dart` or `flutter` builds for. You need **Dart ≥ 3.10 / Flutter ≥ 3.38** and either:

1. a **Rust toolchain** (<https://rustup.rs>); the hook runs `rustup target add` for the
   target automatically, or
2. **prebuilt libraries**: download `dnp3-native-prebuilt.zip` from a
   [GitHub release](https://github.com/gencto/dnp3_plugin/releases) and point the
   environment variable `DNP3_PREBUILT_DIR` (or the hook user-define `prebuilt_dir`) to the
   extracted folder. Layout: `<dir>/<rust-triple>/<libdnp3_dart.so | .dylib | dnp3_dart.dll>`.

## Quick start

```dart
import 'package:dnp3/dnp3.dart';

Future<void> main() async {
  // outstation: TCP server with a few points
  final server = OutstationServer.tcp('0.0.0.0:20000');
  final outstation = server.addOutstation(
    config: const OutstationConfig(outstationAddress: 1024, masterAddress: 1),
  );
  outstation.transaction((tx) => tx
    ..addAnalogInput(0, deadband: 0.5)
    ..addBinaryOutputStatus(0)
    ..updateAnalogInput(0, 42.0, time: Dnp3Time.now()));
  await server.bind();

  // master: TCP client polling the outstation
  final channel = MasterChannel.tcpClient(
    config: const MasterChannelConfig(masterAddress: 1),
    endpoints: ['127.0.0.1:20000'],
  );
  final assoc = await channel.addAssociation(1024);
  assoc.measurements.listen((fragment) {
    for (final block in fragment.blocks.whereType<AnalogInputBlock>()) {
      for (var i = 0; i < block.count; i++) {
        print('AI ${block.indexAt(i)} = ${block.valueAt(i)}'); // read in place, no copy
      }
    }
  });
  await assoc.addPoll(const ReadRequest.events(), const Duration(seconds: 1));
  await channel.enable();

  await assoc.operate(CommandSet.crob(0, const Crob.latchOn()));
}
```

## Examples

| Example | What it shows |
|---|---|
| [`example/example.dart`](example/example.dart) | Outstation and master in one process: read, decode, control. Runs to completion. |
| [`example/outstation.dart`](example/outstation.dart) | TCP outstation with changing values, native control handling, logging. |
| [`example/master.dart`](example/master.dart) | Interactive TCP master: polls, CROB / analog commands, device attributes. |
| [`example/worker_isolate.dart`](example/worker_isolate.dart) | Measurements delivered straight into a worker isolate. |
| [`example/flutter_app`](example/flutter_app) | Flutter UI: in-app outstation or remote master, live values, controls. |

```sh
dart run example/example.dart
dart run example/outstation.dart 127.0.0.1:20000     # terminal 1
dart run example/master.dart 127.0.0.1:20000         # terminal 2 (type: on 1, ao 2 12.5, attrs, quit)
```

## Documentation

- **[Master API](doc/master.md)** — channels, associations, reads, commands, polls, files,
  back-pressure, connection policy, master server, errors and logging.
- **[Outstation API](doc/outstation.md)** — servers and clients, database transactions,
  control and application handlers.
- **[Architecture](doc/architecture.md)** — how the FFI bridge works, isolates, zero-copy
  paths.
- **[Benchmarks](doc/benchmarks.md)** — delivery, decoding, database and end-to-end numbers.
- **[Wire format](doc/wire_format.md)** — binary formats exchanged with the native library.
- **[API reference](https://pub.dev/documentation/dnp3/latest/)** — every public member is
  documented.
- **[Changelog](CHANGELOG.md)**

## Platform support

| Platform | Targets built and tested in CI | Also mapped by the hook (untested) | Serial |
|---|---|---|---|
| Android | `aarch64`, `armv7`, `x86_64`, `i686` (`*-linux-android`) | — | ✓ |
| iOS | `aarch64-apple-ios`, `aarch64-apple-ios-sim`, `x86_64-apple-ios` | — | ✗ |
| macOS | `aarch64-apple-darwin`, `x86_64-apple-darwin` | — | ✓ |
| Linux | `x86_64-unknown-linux-gnu`, `aarch64-unknown-linux-gnu` | `armv7`, `i686`, `riscv64gc` | ✓ |
| Windows | `x86_64-pc-windows-msvc`, `aarch64-pc-windows-msvc` | `i686-pc-windows-msvc` | ✓ |

CI runs the Dart test suite on Linux x64/arm64, macOS and Windows, builds all native
targets, and builds the Flutter example for Android, iOS, macOS, Linux and Windows.
Android libraries are 16 KB page aligned.

## Contributing

Contributions are welcome: bug reports, documentation, tests, platform fixes and features.
Start with **[CONTRIBUTING.md](CONTRIBUTING.md)**: it covers the development setup, the
checks CI runs, how the Dart ↔ Rust ABI is kept in sync and how releases are made. Please
follow the [Code of Conduct](CODE_OF_CONDUCT.md).

Good first steps:

```sh
git clone https://github.com/gencto/dnp3_plugin && cd dnp3_plugin
dart pub get
dart test                     # builds native/ through the hook, runs the integration suite
(cd native && cargo test)     # Rust unit tests
```

## Support and security

- **Questions and bugs:** [open an issue](https://github.com/gencto/dnp3_plugin/issues/new/choose).
- **Security vulnerabilities:** please report privately, see [SECURITY.md](SECURITY.md).
- **Issues in the DNP3 stack itself** (protocol behavior of the Rust library): see
  [stepfunc/dnp3](https://github.com/stepfunc/dnp3).

## License

MIT for this package, see [LICENSE](LICENSE). The linked `dnp3` Rust library has its own
license, see the note at the top.
