# Examples

| File | What it shows |
|---|---|
| [`example.dart`](example.dart) | Outstation and master in one process over TCP loopback: read, zero-copy decode, control. Runs to completion. |
| [`outstation.dart`](outstation.dart) | TCP outstation with points that change every second, native control handling, logging. |
| [`master.dart`](master.dart) | Interactive TCP master: event and integrity polls, CROB / analog commands, device attributes. |
| [`worker_isolate.dart`](worker_isolate.dart) | Measurements posted by native code straight into a worker isolate. |
| [`flutter_app/`](flutter_app) | Flutter UI: in-app outstation (demo mode) or a master connected to any device. |

```sh
dart run example/example.dart

# two terminals
dart run example/outstation.dart 127.0.0.1:20000
dart run example/master.dart 127.0.0.1:20000      # then type: on 1 | off 1 | ao 2 12.5 | integrity | attrs | quit

dart run example/worker_isolate.dart 127.0.0.1:20000
```

To ship a CLI tool, `dart build cli -t example/master.dart` produces a self-contained bundle
with the native library next to the executable.

The first run compiles the native library (Rust toolchain required, see the
[package README](../README.md#installation)); later runs reuse it.
