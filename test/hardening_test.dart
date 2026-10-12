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
