# Changelog

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
