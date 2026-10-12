# Master API

A tour of the master side. Every member is documented in the
[API reference](https://pub.dev/documentation/dnp3/latest/).

## Overview

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
    RequestHeaders()..timeAndInterval(Dnp3Time.now(), 60000)..allObjects(Variation.group20Var0));
await a.checkLinkStatus();
final poll = await a.addPoll(ReadRequest.events(), Duration(seconds: 1)); poll.demand(); poll.remove();
a.setTimeOffset(Duration(hours: -1));
a.setTimeSource(TimeSource.manual(gpsTime));   // or TimeSource.system(offset) / TimeSource.unavailable()

// files
final key = await a.getFileAuthKey('user', 'pass');
final f = await a.openFile('/log.txt', authKey: key, mode: FileMode.read);
a.readFile('/log.txt', onOpened: (size) => size < 1 << 20).blocks.listen(...);  // streaming, abortable
await a.writeFile('/cfg.bin', bytes);        // open + blocks + close
await a.readDirectory('/'); await a.getFileInfo('/x');

// reconnect logic in Dart (TCP / TLS masters and outstation clients)
MasterChannel.tcpClient(..., connectionPolicy: MyPolicy());   // next() → connect(endpoint) | wait(delay)

// master as TCP server (outstations connect to us)
final server = await MasterServer.bind('0.0.0.0:20000', MyHandler());   // accept / start / acceptLinkId
```

## Measurements

`MeasurementFragment` exposes the response header (`readType`, `iin`, `sequence`, `fir/fin/con/uns`)
and its object headers as typed `MeasurementBlock`s: `BinaryInputBlock`,
`DoubleBitBinaryInputBlock`, `BinaryOutputStatusBlock`, `CounterBlock`, `FrozenCounterBlock`,
`AnalogInputBlock`, `FrozenAnalogInputBlock`, `AnalogInputDeadBandBlock`,
`AnalogOutputStatusBlock`, `AnalogOutputCommandEventBlock`, `BinaryOutputCommandEventBlock`,
`UnsignedIntegerBlock`, `OctetStringBlock`, `DeviceAttributeBlock`, `AbsTimeBlock`. Each block
knows its variation, qualifier, `isEvent` and `hasFlags`, and is both a lazily decoded
`List<T>` and a flyweight with `indexAt / valueAt / flagsAt / timeAt` accessors. A
`MeasurementVisitor` dispatches all blocks of a fragment by type.

## Flow control (back-pressure)

```dart
final a = await channel.addAssociation(1024, maxInFlightFragments: 8, manualAck: true);
a.measurements.listen((f) async {
  await store(f);        // slow consumer
  a.acknowledge();       // releases one slot
});
```

With `maxInFlightFragments > 0` the native read handler suspends after posting that many
unacknowledged fragments. The master then stops reading the channel, so TCP flow control
slows the outstation down instead of letting fragments pile up in the Dart heap. Without
`manualAck` every fragment is acknowledged right after the synchronous listeners ran;
`MeasurementWorker` acknowledges after its callback. `backpressureTimeout` (default 30 s)
bounds the wait if a consumer stops acknowledging.

## Connection policy

```dart
class FailoverPolicy extends ConnectionPolicy {
  @override
  ConnectDecision next(ConnectContext c) => c.failures < 3
      ? const ConnectDecision.connect('10.0.0.1:20000')
      : const ConnectDecision.connect('10.0.0.2:20000', timeout: Duration(seconds: 2));

  @override
  Duration disconnected(String address, String? host) => const Duration(seconds: 5);
}
```

Every method may be async. If no answer arrives within `callbackTimeout` (default 1 s), or
a method returns null, the native round-robin policy with exponential back-off decides.
`ConnectDecision.connect` can also set the connect timeout, the local endpoint and, for
outstation clients, the master address of that connection.

## Error details

Every exception carries `detail` with the structured library error, e.g.
`Link(Stdio(ConnectionReset))`, `MalformedResponse(InsufficientBytes)`,
`RejectedByIin2(Iin { ... })`.

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
