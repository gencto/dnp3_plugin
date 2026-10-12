# Outstation API

A tour of the outstation side. Every member is documented in the
[API reference](https://pub.dev/documentation/dnp3/latest/).

## Overview

```dart
Outstation.tcpClient(..., masterAddress: 1, connectionPolicy: ...) / tlsClient(...)
Outstation.serial(path:, retry: RetryStrategy()) / Outstation.udp(...)
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

## Handlers

Handler configuration (`OutstationHandlers`):

| Concern | Native modes | Dart callback |
|---|---|---|
| SELECT / OPERATE | `ControlMode.accept` (mirror into BOS / AOS, notify), `ControlMode.reject` + `rejectStatus` | `ControlMode.callback` + `onControl: (req) => ControlResponse(status, tx)` |
| cold / warm restart | `RestartMode.notSupported`, `seconds` / `milliseconds` + `coldRestartDelay` / `warmRestartDelay` | `RestartMode.callback` → `OutstationApplication.coldRestart()` |
| time write | `notSupported`, `accept` (+ event) | `TimeWriteMode.callback` |
| counter freeze | `notSupported`, `auto` (counter → frozen counter, freeze & clear, and FREEZE_AT_TIME: once, periodic, periodic relative to the hour — scheduled natively) | `FreezeMode.callback` → `(result, tx)` |
| request with controls | in `accept` mode all mirrored values are written in one transaction | `onControlFragmentBegin` / `onControlFragmentEnd` → `DatabaseTransaction` applied before the response |
| attribute write | `accept` (+ event), `reject` | `AttributeWriteMode.callback` (async) |
| dead band writes / confirms | notifications | — |

Callback mode parks one protocol worker per pending request. Do not `await` operations on
the *same* outstation (enable/disable/decode level) inside a control callback: they are
queued behind the callback and only run after it returns (or times out).
