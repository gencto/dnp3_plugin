import 'dart:async';

import 'package:dnp3/dnp3.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

class _Policy extends ConnectionPolicy {
  final String target;
  final contexts = <ConnectContext>[];
  final disconnects = <String>[];
  _Policy(this.target);

  @override
  ConnectDecision? next(ConnectContext context) {
    contexts.add(context);
    return ConnectDecision.connect(target);
  }

  @override
  Duration? disconnected(String address, String? hostname) {
    disconnects.add(address);
    return const Duration(milliseconds: 50);
  }
}

class _SlowPolicy extends ConnectionPolicy {
  @override
  Duration get callbackTimeout => const Duration(milliseconds: 100);

  @override
  Future<ConnectDecision?> next(ConnectContext context) => Completer<ConnectDecision?>().future;
}

class _LinkIdHandler extends MasterServerHandler {
  final linkIds = <(int, int)>[];
  final started = Completer<void>();

  @override
  AcceptAction accept(String remoteAddress) => const AcceptAction.identifyByLinkAddress();

  @override
  AcceptConfig? acceptLinkId(String remoteAddress, int source, int destination) {
    linkIds.add((source, destination));
    return AcceptConfig(channel: MasterChannelConfig(masterAddress: destination));
  }

  @override
  Future<void> start(MasterChannel channel, String remoteAddress) async {
    await channel.addAssociation(10);
    await channel.enable();
    if (!started.isCompleted) started.complete();
  }
}

class _TimeApp extends OutstationApplication {
  final times = <Dnp3Time>[];
  @override
  RequestResult writeAbsoluteTime(Dnp3Time time) {
    times.add(time);
    return RequestResult.ok;
  }
}

void main() {
  group('connection policy', () {
    test('Dart decides the endpoint and the reconnect delay', () async {
      final server = OutstationServer.tcp('127.0.0.1:0');
      server.addOutstation(config: const OutstationConfig(outstationAddress: 10, masterAddress: 1));
      final addr = await server.bind();
      final policy = _Policy(addr);
      final master = MasterChannel.tcpClient(
        config: const MasterChannelConfig(masterAddress: 1),
        endpoints: ['127.0.0.1:1'], // never used: the policy redirects
        connectionPolicy: policy,
      );
      try {
        await master.addAssociation(10);
        await master.enable();
        await eventually(() => master.clientState?.state == ClientState.connected);
        expect(policy.contexts.first.failures, 0);
        expect(policy.contexts.first.endpoints, ['127.0.0.1:1']);

        server.destroy();
        await eventually(() => policy.disconnects.isNotEmpty);
        expect(policy.disconnects.first, addr);
      } finally {
        master.destroy();
        server.destroy();
      }
    });

    test('native policy takes over when Dart does not answer in time', () async {
      final server = OutstationServer.tcp('127.0.0.1:0');
      server.addOutstation(config: const OutstationConfig(outstationAddress: 10, masterAddress: 1));
      final addr = await server.bind();
      final master = MasterChannel.tcpClient(
        config: const MasterChannelConfig(masterAddress: 1),
        endpoints: [addr],
        connectionPolicy: _SlowPolicy(),
      );
      try {
        await master.addAssociation(10);
        await master.enable();
        await eventually(() => master.clientState?.state == ClientState.connected);
      } finally {
        master.destroy();
        server.destroy();
      }
    });

    test('outstation client overrides the master address per connection', () async {
      for (final viaPolicy in [false, true]) {
        final handler = _LinkIdHandler();
        final server = await MasterServer.bind('127.0.0.1:0', handler);
        final outstation = Outstation.tcpClient(
          // configured master address 99 is overridden with 1 for this connection
          config: const OutstationConfig(outstationAddress: 10, masterAddress: 99),
          endpoints: [server.localAddress],
          masterAddress: viaPolicy ? null : 1,
          connectionPolicy: viaPolicy ? _MasterAddressPolicy(server.localAddress) : null,
        );
        await outstation.enable();
        try {
          await handler.started.future.timeout(const Duration(seconds: 10));
          expect(handler.linkIds.first, (10, 1), reason: 'viaPolicy: $viaPolicy');
        } finally {
          outstation.destroy();
          server.destroy();
        }
      }
    });
  });

  test('control fragment hooks batch the effect of several controls', () async {
    var begins = 0;
    var ends = 0;
    final pair = await Pair.create(
      handlers: OutstationHandlers(
        onControlFragmentBegin: () => begins++,
        onControlFragmentEnd: () async {
          ends++;
          return DatabaseTransaction()..updateAnalogInput(0, ends.toDouble());
        },
      ),
    );
    try {
      final set = CommandSet()
        ..addCrob(1, const Crob.latchOn())
        ..addCrob(2, const Crob.latchOn())
        ..addCrob(3, const Crob.latchOn());
      await pair.association.operate(set, mode: CommandMode.directOperate);
      expect(begins, 1);
      expect(ends, 1);
      final db = pair.outstation.database;
      for (final i in [1, 2, 3]) {
        expect(db.getBinaryOutputStatus(i)!.value, isTrue);
      }
      // applied before the response was sent
      expect(db.getAnalogInput(0)!.value, 1.0);
    } finally {
      pair.close();
    }
  });

  group('time source', () {
    test('unavailable time makes synchronization fail', () async {
      final pair = await Pair.create(
        handlers: OutstationHandlers(
          application: const ApplicationConfig(writeAbsoluteTime: TimeWriteMode.callback),
          applicationCallbacks: _TimeApp(),
        ),
      );
      try {
        pair.association.setTimeSource(const TimeSource.unavailable());
        await expectLater(
          pair.association.synchronizeTime(TimeSyncProcedure.directWriteAbsTime),
          throwsA(
            isA<TimeSyncException>().having((e) => e.error, 'error', TimeSyncError.systemTimeNotAvailable),
          ),
        );
      } finally {
        pair.close();
      }
    });

    test('manual time keeps running', () async {
      final app = _TimeApp();
      final pair = await Pair.create(
        handlers: OutstationHandlers(
          application: const ApplicationConfig(writeAbsoluteTime: TimeWriteMode.callback),
          applicationCallbacks: app,
        ),
      );
      try {
        final base = DateTime.utc(2020, 1, 1).millisecondsSinceEpoch;
        pair.association.setTimeSource(TimeSource.manual(Dnp3Time(base)));
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await pair.association.synchronizeTime(TimeSyncProcedure.directWriteAbsTime);
        final written = app.times.single.millis - base;
        expect(written, inInclusiveRange(150, 5000));

        pair.association.setTimeSource(TimeSource.system(const Duration(hours: 1)));
        await pair.association.synchronizeTime(TimeSyncProcedure.directWriteAbsTime);
        final ahead = app.times.last.millis - DateTime.now().millisecondsSinceEpoch;
        expect(ahead, inInclusiveRange(3590000, 3610000));
      } finally {
        pair.close();
      }
    });
  });

  group('native freeze-at-time scheduler', () {
    test('freeze once at a given time', () async {
      final pair = await Pair.create(
        handlers: const OutstationHandlers(application: ApplicationConfig(freeze: FreezeMode.auto)),
      );
      final frozen = <CountersFrozen>[];
      pair.outstation.events.listen((e) {
        if (e is CountersFrozen) frozen.add(e);
      });
      try {
        pair.outstation.transaction((tx) => tx.updateCounter(2, 55));
        final at = Dnp3Time(DateTime.now().millisecondsSinceEpoch + 300);
        await pair.association.sendAndExpectEmptyResponse(
          FunctionCode.freezeAtTime,
          RequestHeaders()
            ..timeAndInterval(at, 0)
            ..allObjects(Variation.group20Var0),
        );
        expect(pair.outstation.database.getFrozenCounter(2)!.value, 0);
        await eventually(() => frozen.isNotEmpty);
        expect(pair.outstation.database.getFrozenCounter(2)!.value, 55);
        expect(frozen.single.request.atTime, isTrue);
      } finally {
        pair.close();
      }
    });

    test('periodic freeze', () async {
      final pair = await Pair.create(
        handlers: const OutstationHandlers(application: ApplicationConfig(freeze: FreezeMode.auto)),
      );
      var fires = 0;
      pair.outstation.events.listen((e) {
        if (e is CountersFrozen) fires++;
      });
      try {
        await pair.association.sendAndExpectEmptyResponse(
          FunctionCode.freezeAtTime,
          RequestHeaders()
            ..timeAndInterval(Dnp3Time.now(), 100)
            ..allObjects(Variation.group20Var0),
        );
        for (var v = 1; v <= 3; v++) {
          pair.outstation.transaction((tx) => tx.updateCounter(0, v * 10));
          await eventually(() => pair.outstation.database.getFrozenCounter(0)!.value == v * 10);
        }
        expect(fires, greaterThanOrEqualTo(3));
      } finally {
        pair.close();
      }
    });
  });

  test('measurement back-pressure holds the master until fragments are acknowledged', () async {
    final server = OutstationServer.tcp('127.0.0.1:0');
    final o = server.addOutstation(config: const OutstationConfig(outstationAddress: 10, masterAddress: 1));
    o.transaction(defaultDatabase);
    final addr = await server.bind();
    final master = MasterChannel.tcpClient(
      config: const MasterChannelConfig(masterAddress: 1),
      endpoints: [addr],
    );
    try {
      final assoc = await master.addAssociation(
        10,
        config: const AssociationConfig.quiet(),
        maxInFlightFragments: 2,
        manualAck: true,
      );
      final received = <MeasurementFragment>[];
      assoc.measurements.listen(received.add);
      await master.enable();
      await assoc.addPoll(const ReadRequest.integrity(), const Duration(milliseconds: 10));
      await eventually(() => received.length >= 2);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(received.length, 2, reason: 'window of 2 fragments is full');

      expect(assoc.acknowledge(2), 0);
      await eventually(() => received.length >= 4);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(received.length, 4);
      assoc.acknowledge(2);
    } finally {
      master.destroy();
      server.destroy();
    }
  });

  test('automatic acknowledgement keeps data flowing', () async {
    final server = OutstationServer.tcp('127.0.0.1:0');
    final o = server.addOutstation(config: const OutstationConfig(outstationAddress: 10, masterAddress: 1));
    o.transaction(defaultDatabase);
    final addr = await server.bind();
    final master = MasterChannel.tcpClient(
      config: const MasterChannelConfig(masterAddress: 1),
      endpoints: [addr],
    );
    try {
      final assoc = await master.addAssociation(
        10,
        config: const AssociationConfig.quiet(),
        maxInFlightFragments: 1,
      );
      var n = 0;
      assoc.measurements.listen((_) => n++);
      await master.enable();
      await assoc.addPoll(const ReadRequest.integrity(), const Duration(milliseconds: 10));
      await eventually(() => n >= 10);
    } finally {
      master.destroy();
      server.destroy();
    }
  });

  test('errors carry the structured library detail', () async {
    final pair = await Pair.create();
    try {
      await pair.association.coldRestart();
      fail('expected an exception');
    } on TaskException catch (e) {
      expect(e.error, TaskError.rejectedByIin2);
      expect(e.detail, startsWith('RejectedByIin2'));
      expect(e.toString(), contains('[RejectedByIin2'));
    } finally {
      pair.close();
    }
  });
}

class _MasterAddressPolicy extends ConnectionPolicy {
  final String endpoint;
  _MasterAddressPolicy(this.endpoint);
  @override
  ConnectDecision next(ConnectContext context) => ConnectDecision.connect(endpoint, masterAddress: 1);
}
