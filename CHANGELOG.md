# Changelog

## Unreleased

* `MasterServer` releases the channel of an accepted connection when its session ends and
  calls the new `MasterServerHandler.closed`; a failing `start` releases the channel too.
* Requests addressed to an object that was destroyed in Dart (e.g. controls for a
  server-hosted outstation) fall back to the native timeout behavior instead of being
  answered with success.
* Database batches are all-or-nothing: an invalid op no longer leaves the earlier ops
  applied.
* Values that would wrap on the wire (point indices, flags, CROB count / times, analog
  output integers, dead bands, file parameters, processing / restart delays) throw
  `RangeError`; the native side rejects out-of-range attribute integers and g34v1 dead
  bands instead of truncating them.
* FREEZE_AT_TIME periods below 100 ms are raised to 100 ms.
* `Dnp3.closeIsolate` / `Dnp3.shutdown` close the event streams of the isolate's objects;
  later calls fail with `ShutdownException`.
* `MeasurementWorker` acknowledges a fragment even if the handler throws.
* Internal helpers (`decodeResults`, `decodeAssociationMessage`, `decodeAttribute`,
  `encodeAttribute`, the `ClientEvents` dispatch methods) are no longer part of the
  public API.
* A Dart restart callback that throws is answered as "not supported" (it was reported to
  the master as a restart in 0 ms); unknown application requests use the native fallback.
* `Database.getRange` on a destroyed outstation throws `InvalidHandleException`.
* `AssociationEvent.iin2` keeps the IIN2 byte of `rejectedByIin2` task failures.
* `ReadHeader.range` and `DeadBandHeader` validate their indices and values in Dart.
* `OutstationInfo`: `requestControl`, `broadcastAction` (new `BroadcastAction` enum),
  `unsupportedFunction`, `unsolicited`; `sequence` of `unexpectedConfirm` events is the
  confirm's sequence number (it returned the unsolicited flag).
* `RestartRequested` is also emitted when a restart callback accepted the restart.
* `Outstation.enable/disable/setDecodeLevel/setApplicationIin/setProcessingDelay` throw
  `StateError` after `destroy()`, like `MasterChannel`.
* `CommandSet.crob/analog(oneByteIndex:)`; `CommandException.statusCode` keeps status codes
  that `CommandStatus` does not know.
* Removing a poll also removes it from its association's bookkeeping.
* Every public API member is documented; `public_member_api_docs` is enforced.
* The native library is built only as a dynamic library; ABI version 3
  (`dnp3_association_set_time_offset` was removed, `Association.setTimeOffset` stays).

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
