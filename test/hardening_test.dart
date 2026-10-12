import 'dart:async';
import 'dart:typed_data';

import 'package:dnp3/dnp3.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  test('an invalid batch leaves the database untouched', () async {
    final pair = await Pair.create();
    try {
      final db = pair.outstation.database;
      final tx = DatabaseTransaction()..updateCounter(0, 5);
      // a valid op followed by an unknown one (op code 99)
      final ops = Uint8List.fromList([...tx.bytes, 99, 0, 0, 0]);
      expect(() => db.applyBytes(ops), throwsA(isA<Dnp3Exception>()));
      expect(db.getCounter(0)!.value, 0);

      // fast path of plain updates: a bad point type in the second update
      final bad = Uint8List.fromList(tx.bytes)..[1] = 200;
      final both = Uint8List.fromList([...tx.bytes, ...bad]);
      expect(() => db.applyBytes(both), throwsA(isA<Dnp3Exception>()));
      expect(db.getCounter(0)!.value, 0);
    } finally {
      pair.close();
    }
  });

  test('out-of-range values are rejected instead of wrapping', () async {
    final pair = await Pair.create();
    try {
      expect(() => DatabaseTransaction().updateCounter(70000, 1), throwsRangeError);
      expect(() => DatabaseTransaction().addCounter(1, deadband: -1), throwsRangeError);
      expect(() => pair.outstation.database.getCounter(70000), throwsRangeError);
      expect(() => pair.outstation.setProcessingDelay(70000), throwsRangeError);
      await expectLater(
        () => pair.association.operate(CommandSet.crob(0, const Crob(ControlCode.latchOn(), count: 256))),
        throwsRangeError,
      );
    } finally {
      pair.close();
    }
  });

  test('controls for an outstation destroyed in Dart are not reported as successful', () async {
    final pair = await Pair.create(
      handlers: OutstationHandlers(
        control: const ControlHandlerConfig(mode: ControlMode.callback),
        onControl: (_) => ControlResponse.success,
      ),
    );
    try {
      await pair.association.operate(CommandSet.crob(1, const Crob.latchOn()));
      // a server-hosted outstation keeps running natively until its server is destroyed
      pair.outstation.destroy();
      await expectLater(
        pair.association.operate(CommandSet.crob(1, const Crob.latchOn())),
        throwsA(isA<CommandException>().having((e) => e.status, 'status', CommandStatus.timeout)),
      );
    } finally {
      pair.close();
    }
  });

  test('master server releases the channel of a closed session', () async {
    final handler = _Handler();
    final server = await MasterServer.bind('127.0.0.1:0', handler);
    final outstation = Outstation.tcpClient(
      config: const OutstationConfig(outstationAddress: 10, masterAddress: 1),
      endpoints: [server.localAddress],
    );
    try {
      await outstation.enable();
      await handler.started.future.timeout(const Duration(seconds: 10));
      expect(server.channels, hasLength(1));

      outstation.destroy();
      await eventually(() => handler.closedAddresses.isNotEmpty);
      expect(server.channels, isEmpty);
      // the native channel is gone as well (object counts are process-wide, so check the handle)
      expect(
        () => MasterChannel.attach(handler.channel!.handle).enable(),
        throwsA(isA<InvalidHandleException>()),
      );
    } finally {
      outstation.destroy();
      server.destroy();
    }
  });

  test('task failures keep the IIN2 byte in association events', () async {
    final pair = await Pair.create(information: true);
    final events = <AssociationEvent>[];
    pair.association.information.listen(events.add);
    try {
      // cold restart is not supported by default: rejected with IIN2.0 (no func code support)
      await expectLater(pair.association.coldRestart(), throwsA(isA<TaskException>()));
      await eventually(() => events.any((e) => e.error == TaskError.rejectedByIin2));
      final failed = events.firstWhere((e) => e.error == TaskError.rejectedByIin2);
      expect(failed.iin2 & 0x01, 1);
    } finally {
      pair.close();
    }
  });

  test('a failing restart callback is reported as not supported, not as an immediate restart', () async {
    final pair = await Pair.create(
      handlers: OutstationHandlers(
        application: const ApplicationConfig(coldRestart: RestartMode.callback),
        applicationCallbacks: _ThrowingApp(),
      ),
    );
    try {
      await expectLater(
        pair.association.coldRestart(),
        throwsA(isA<TaskException>().having((e) => e.error, 'error', TaskError.rejectedByIin2)),
      );
    } finally {
      pair.close();
    }
  });

  test('restart callbacks are reported as RestartRequested events', () async {
    final pair = await Pair.create(
      handlers: OutstationHandlers(
        application: const ApplicationConfig(coldRestart: RestartMode.callback),
        applicationCallbacks: _DelayApp(),
      ),
    );
    final events = <OutstationEvent>[];
    pair.outstation.events.listen(events.add);
    try {
      expect(await pair.association.coldRestart(), const Duration(seconds: 2));
      await eventually(() => events.whereType<RestartRequested>().any((e) => e.cold));
    } finally {
      pair.close();
    }
  });

  test('single commands can use one-byte indices', () async {
    final pair = await Pair.create();
    try {
      await pair.association.operate(
        CommandSet.crob(5, const Crob.latchOn(), oneByteIndex: true),
        mode: CommandMode.directOperate,
      );
      expect(pair.outstation.database.getBinaryOutputStatus(5)!.value, isTrue);
      expect(() => CommandSet.crob(300, const Crob.latchOn(), oneByteIndex: true), throwsRangeError);
    } finally {
      pair.close();
    }
  });

  test('outstation operations fail after destroy', () async {
    final pair = await Pair.create();
    try {
      pair.outstation.destroy();
      expect(() => pair.outstation.enable(), throwsStateError);
      expect(() => pair.outstation.setProcessingDelay(1), throwsStateError);
    } finally {
      pair.close();
    }
  });

  test('request headers validate their ranges', () {
    expect(() => ReadHeader.range(Variation.group30Var0, 5, 4), throwsRangeError);
    expect(
      () => DeadBandHeader.encodeAll([
        const DeadBandHeader.g34v1({0: 70000}),
      ]),
      throwsRangeError,
    );
    expect(
      () => DeadBandHeader.encodeAll([
        const DeadBandHeader.g34v2({300: 1}, oneByteIndex: true),
      ]),
      throwsRangeError,
    );
  });

  test('a range read on a destroyed outstation reports an invalid handle', () async {
    final pair = await Pair.create();
    final db = pair.outstation.database;
    pair.close();
    expect(() => db.getRange(PointType.counter, 0, 9), throwsA(isA<InvalidHandleException>()));
  });

  test('closing the isolate runtime completes streams and fails later calls', () async {
    final pair = await Pair.create();
    final done = Completer<void>();
    pair.association.measurements.listen(null, onDone: done.complete);
    Dnp3.closeIsolate();
    try {
      await done.future.timeout(const Duration(seconds: 5));
      await expectLater(
        pair.association.read(const ReadRequest.integrity()),
        throwsA(isA<ShutdownException>()),
      );
    } finally {
      pair.close();
    }
  });
}

class _Handler extends MasterServerHandler {
  final started = Completer<void>();
  MasterChannel? channel;
  final closedAddresses = <String>[];

  @override
  AcceptAction accept(String remoteAddress) =>
      const AcceptAction.accept(AcceptConfig(channel: MasterChannelConfig(masterAddress: 1)));

  @override
  Future<void> start(MasterChannel channel, String remoteAddress) async {
    this.channel = channel;
    await channel.addAssociation(10);
    await channel.enable();
    if (!started.isCompleted) started.complete();
  }

  @override
  void closed(MasterChannel channel, String remoteAddress) => closedAddresses.add(remoteAddress);
}

class _ThrowingApp extends OutstationApplication {
  @override
  RestartDelay? coldRestart() => throw StateError('broken');
}

class _DelayApp extends OutstationApplication {
  @override
  RestartDelay? coldRestart() => const RestartDelay.seconds(2);
}
