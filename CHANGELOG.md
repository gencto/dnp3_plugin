# Changelog

## 0.2.0

* `ConnectionPolicy`: reconnect logic of TCP/TLS clients (masters and outstations) in Dart
  — endpoint, timeout, local endpoint and master address per attempt, delay after a
  disconnect — with a native fallback on timeout. Refused connections are now reported as
  `connectFailed` events.
* `Outstation.tcpClient/tlsClient(masterAddress:)`.
* `OutstationHandlers.onControlFragmentBegin / onControlFragmentEnd`; in accept mode all
  mirrored control values of a request are written in a single transaction.
* `TimeSource`: system clock with offset, unavailable, or manually supplied time.
* `FreezeMode.auto` handles FREEZE_AT_TIME (once, periodic, periodic relative to the hour)
  with a native scheduler.
* Measurement back-pressure: `maxInFlightFragments`, `Association.acknowledge`, automatic
  acknowledgement in `MeasurementWorker`.
* `Association.readFile(onOpened:)` decides whether to continue once the size is known.
* `Dnp3Exception.detail` with the structured library error. `TimeSyncException.detail`
  (int) was renamed to `value`.
* ABI version 2.

## 0.1.0

* Initial release on top of the `dnp3` Rust crate 1.7.0.
* Master: TCP / TLS / serial / UDP channels, master TCP server, associations, reads, polls,
  commands, time sync, restarts, dead bands, generic requests, device attributes, file
  transfer, association information.
* Outstation: TCP / TLS clients and servers, serial (one-shot and fault tolerant), UDP,
  complete database API with batched zero-copy transactions, native and Dart callback
  modes for controls and application requests, information callbacks.
* Zero-copy measurement delivery (external typed data, flyweight decoding), leaf FFI calls
  reading Dart buffers in place, isolate-friendly handles, `MeasurementWorker`.
* Build hook compiling the native bridge for Android, iOS, macOS, Linux and Windows, or
  consuming prebuilt libraries.
* Benchmarks, integration tests, CI workflows (as a patch).
