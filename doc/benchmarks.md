# Benchmarks

`dart run benchmark/run_all.dart [--quick] [--out benchmark/results/<name>.md]`

Results below: Linux x64 VM, 4 vCPUs, Dart 3.13.5, release build with LTO
([`benchmark/results/linux-x64.md`](../benchmark/results/linux-x64.md)). CI runs the
same suite on Linux x64/arm64, macOS and Windows and publishes the tables in the job summary.

## 1. Native → Dart delivery of measurement fragments

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

## 2. Decoding cost per point (1000 analog inputs per fragment)

| method | ns / point | points / s |
|---|---|---|
| flyweight accessor: value only | 2.64 | 378.43 M |
| MeasurementVisitor: value only | 2.85 | 350.82 M |
| flyweight accessors: index + value + flags + time | 7.75 | 129.07 M |
| value objects (List<AnalogInput>), all fields | 31.36 | 31.89 M |
| baseline: JSON bytes → objects, all fields | 693.14 | 1.44 M |

The binary flyweight path is **~90× faster** than a JSON based bridge (as used by typical
`MethodChannel` plugins) for the same information, and allocation-free.

## 3. Outstation database transactions (analog updates with event detection)

| updates / transaction | updates / s | ns / update | transactions / s |
|---|---|---|---|
| 1 | 9.23 M | 108.3 | 9.23 M |
| 10 | 31.50 M | 31.7 | 3.15 M |
| 100 | 34.78 M | 28.8 | 347.8 k |
| 1000 | 26.60 M | 37.6 | 26.6 k |
| read (getAnalogInput) | 5.96 M | - | - |

## 4. End-to-end over TCP loopback (master and outstation in the same process)

| operation | p50 µs | p99 µs | ops / s |
|---|---|---|---|
| integrity poll, 1000 analogs (g30v6), decoded | 536 | 1261 | 1738.2 |
| read 10 analogs (range) | 92 | 221 | 9946.9 |
| direct operate CROB (accept mode, native) | 112 | 310 | 8212.9 |
| select-before-operate CROB (accept mode) | 121 | 386 | 7103.1 |
| direct operate CROB (Dart callback round trip) | 137 | 370 | 6616.8 |
| select-before-operate CROB (2 Dart callbacks) | 243 | 721 | 3567.0 |

A synchronous Dart control callback adds ~25 µs (p50) per SELECT/OPERATE.

## 5. Event throughput outstation → master (unsolicited, TCP loopback)

| events | ms | events / s |
|---|---|---|
| 200.0 k | 134 | 1.49 M |

## 6. Delivery straight into a worker isolate (1000 points per fragment, decoded)

| receiver | fragments / s | points / s |
|---|---|---|
| worker isolate | 69.1 k | 69.06 M |
