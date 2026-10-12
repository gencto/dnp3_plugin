import 'dart:typed_data';

import 'package:dnp3/dnp3.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  setUpAll(() {
    Dnp3.initialize(workerThreads: 4);
  });

  test('native library loads', () {
    expect(Dnp3.nativeVersion, contains('dnp3-1.7.0'));
  });

  group('master <-> outstation over TCP', () {
    late Pair pair;

    setUp(() async {
      pair = await Pair.create(information: true);
    });

    tearDown(() => pair.close());

    test('integrity poll returns the static database', () async {
      pair.outstation.transaction((tx) {
        tx
          ..updateBinaryInput(3, true)
          ..updateAnalogInput(2, 42.5, time: Dnp3Time(1700000000000))
          ..updateCounter(1, 1234)
          ..updateDoubleBitBinaryInput(4, DoubleBit.determinedOn)
          ..updateOctetString(5, [1, 2, 3]);
      });

      final fragments = await pair.association.readWithHandler(const ReadRequest.integrity());
      expect(fragments, isNotEmpty);

      final analogs = <AnalogInput>[];
      final binaries = <BinaryInput>[];
      final counters = <Counter>[];
      final dbbi = <DoubleBitBinaryInput>[];
      final octets = <OctetString>[];
      for (final f in fragments) {
        for (final b in f.blocks) {
          switch (b) {
            case AnalogInputBlock():
              analogs.addAll(b);
            case BinaryInputBlock():
              binaries.addAll(b);
            case CounterBlock():
              counters.addAll(b);
            case DoubleBitBinaryInputBlock():
              dbbi.addAll(b);
            case OctetStringBlock():
              octets.addAll(b);
            default:
          }
        }
      }
      expect(analogs.firstWhere((x) => x.index == 2).value, 42.5);
      expect(binaries.firstWhere((x) => x.index == 3).value, isTrue);
      expect(counters.firstWhere((x) => x.index == 1).value, 1234);
      expect(dbbi.firstWhere((x) => x.index == 4).value, DoubleBit.determinedOn);
    });

    test('events are reported through the measurement stream', () async {
      pair.fragments.clear();
      pair.outstation.transaction((tx) => tx.updateAnalogInput(7, 99.25));
      await pair.association.read(const ReadRequest.events());
      final events = [
        for (final f in pair.fragments)
          for (final b in f.blocks)
            if (b is AnalogInputBlock && b.isEvent) ...b,
      ];
      expect(events.map((e) => e.value), contains(99.25));
    });

    test('raw zero-copy accessors match decoded objects', () async {
      pair.outstation.transaction((tx) {
        for (var i = 0; i < 10; i++) {
          tx.updateAnalogInput(i, i * 1.5);
        }
      });
      final fragments = await pair.association.readWithHandler(ReadRequest.allObjects(Variation.group30Var0));
      final block = fragments.first.blocks.whereType<AnalogInputBlock>().first;
      expect(block.count, 10);
      for (var i = 0; i < block.count; i++) {
        expect(block.indexAt(i), block[i].index);
        expect(block.valueAt(i), block[i].value);
        expect(block.flagsAt(i), block[i].flags);
      }
    });

    test('CROB in accept mode mirrors into BinaryOutputStatus', () async {
      final events = <OutstationEvent>[];
      pair.outstation.events.listen(events.add);
      await pair.association.operate(CommandSet.crob(2, const Crob.latchOn()));
      await eventually(() => events.isNotEmpty);
      expect((events.first as ControlExecuted).request.index, 2);
      expect(pair.outstation.database.getBinaryOutputStatus(2)!.value, isTrue);
    });

    test('analog output direct operate mirrors into AnalogOutputStatus', () async {
      await pair.association.operate(
        CommandSet.analog(3, const AnalogOutput.double64(12.75)),
        mode: CommandMode.directOperate,
      );
      expect(pair.outstation.database.getAnalogOutputStatus(3)!.value, 12.75);
    });

    test('multiple commands in one request', () async {
      final set = CommandSet()
        ..addCrob(0, const Crob.latchOn())
        ..addCrob(1, const Crob.latchOn())
        ..addAnalog(0, const AnalogOutput.int32(5))
        ..addAnalog(1, const AnalogOutput.float32(1.5));
      await pair.association.operate(set);
      final db = pair.outstation.database;
      expect(db.getBinaryOutputStatus(1)!.value, isTrue);
      expect(db.getAnalogOutputStatus(0)!.value, 5);
      expect(db.getAnalogOutputStatus(1)!.value, 1.5);
    });

    test('periodic poll delivers fragments', () async {
      pair.fragments.clear();
      final poll = await pair.association.addPoll(
        const ReadRequest.integrity(),
        const Duration(milliseconds: 50),
      );
      await eventually(() => pair.fragments.length >= 3);
      await poll.demand();
      await poll.remove();
    });

    test('database transaction results', () {
      final results = pair.outstation.database.transactionWithResults((tx) {
        tx
          ..updateAnalogInput(0, 1000)
          ..updateAnalogInput(500, 1) // no such point
          ..addAnalogInput(600)
          ..removeAnalogInput(600);
      });
      expect(results[0].status, UpdateStatus.created);
      expect(results[1].status, UpdateStatus.noPoint);
      expect(results[2].ok, isTrue);
      expect(results[3].ok, isTrue);
    });

    test('database range read is a zero-copy block', () {
      pair.outstation.transaction((tx) {
        for (var i = 0; i < 10; i++) {
          tx.updateCounter(i, i * 10);
        }
      });
      final block = pair.outstation.database.getRange(PointType.counter, 0, 9) as CounterBlock;
      expect(block.count, 10);
      expect(block.map((c) => c.value).toList(), [for (var i = 0; i < 10; i++) i * 10]);
    });

    test('time synchronization fails cleanly when not supported', () async {
      await expectLater(
        pair.association.synchronizeTime(TimeSyncProcedure.lan),
        throwsA(isA<Dnp3Exception>()),
      );
    });

    test('restart not supported returns error', () async {
      await expectLater(pair.association.coldRestart(), throwsA(isA<TaskException>()));
    });

    test('link status', () async {
      await pair.association.checkLinkStatus();
    });

    test('association information events', () async {
      final infos = <AssociationEvent>[];
      pair.association.information.listen(infos.add);
      await pair.association.read(const ReadRequest.integrity());
      await eventually(() => infos.any((e) => e.type == AssociationEventType.taskSuccess));
    });

    test('decode level round trip', () async {
      await pair.master.setDecodeLevel(const DecodeLevel.objectValues());
      final level = await pair.master.getDecodeLevel();
      expect(level.application, AppDecodeLevel.objectValues);
      await pair.master.setDecodeLevel(const DecodeLevel());
    });

    test('device attributes', () async {
      pair.outstation.transaction(
        (tx) => tx
          ..defineAttribute(DeviceAttribute.string(AttributeVariation.deviceManufacturerName, 'Acme'))
          ..defineAttribute(
            DeviceAttribute.string(AttributeVariation.userAssignedLocation, 'here'),
            writable: true,
          ),
      );
      final fragments = await pair.association.readWithHandler(
        ReadRequest.deviceAttribute(AttributeVariation.deviceManufacturerName),
      );
      final attr = fragments.first.blocks.whereType<DeviceAttributeBlock>().first.attribute;
      expect(attr.value, 'Acme');
      expect(attr.name, 'deviceManufacturerName');

      await pair.association.writeAttribute(
        DeviceAttribute.string(AttributeVariation.userAssignedLocation, 'there'),
      );
    });

    test('octet strings', () async {
      pair.outstation.transaction((tx) => tx.updateOctetString(1, Uint8List.fromList([9, 8, 7])));
      expect(pair.outstation.database.getOctetString(1), [9, 8, 7]);
    });
  });

  group('more master features', () {
    late Pair pair;

    setUp(() async {
      pair = await Pair.create(
        handlers: const OutstationHandlers(
          application: ApplicationConfig(
            supportWriteAnalogDeadBands: true,
            warmRestart: RestartMode.milliseconds,
            warmRestartDelay: 250,
          ),
          information: true,
        ),
      );
    });

    tearDown(() => pair.close());

    test('dead band writes are reported to the outstation', () async {
      final events = <OutstationEvent>[];
      pair.outstation.events.listen(events.add);
      await pair.association.writeDeadBands([
        const DeadBandHeader.g34v3({0: 1.5, 1: 2.5}),
        const DeadBandHeader.g34v1({2: 7}),
      ]);
      await eventually(() => events.whereType<DeadBandsWritten>().length == 2);
      final all = {for (final e in events.whereType<DeadBandsWritten>()) ...e.deadBands};
      expect(all, {0: 1.5, 1: 2.5, 2: 7.0});
    });

    test('warm restart with configured delay', () async {
      expect(await pair.association.warmRestart(), const Duration(milliseconds: 250));
    });

    test('unsolicited responses deliver events', () async {
      await pair.association.enableUnsolicited(const EventClasses.all());
      pair.fragments.clear();
      pair.outstation.transaction((tx) => tx.updateBinaryInput(6, true));
      await eventually(() => pair.fragments.any((f) => f.isUnsolicited && f.blockCount > 0));
      await pair.association.disableUnsolicited(const EventClasses.all());
    });

    test('application IIN bits reach the master', () async {
      pair.outstation.setApplicationIin(deviceTrouble: true);
      final f = await pair.association.readWithHandler(const ReadRequest.classScan(Classes.class0()));
      expect(f.first.iin.deviceTrouble, isTrue);
      pair.outstation.setApplicationIin();
    });

    test('outstation information events', () async {
      final infos = <OutstationInfo>[];
      pair.outstation.information.listen(infos.add);
      await pair.association.read(const ReadRequest.integrity());
      await eventually(() => infos.any((i) => i.type == OutstationInfoType.processRequestFromIdle));
    });

    test('file operations against an outstation without file support fail cleanly', () async {
      await expectLater(pair.association.getFileInfo('/x.txt'), throwsA(isA<Dnp3Exception>()));
    });

    test('freeze at time header is encoded', () async {
      final headers = RequestHeaders()
        ..timeAndInterval(Dnp3Time.now(), 1000)
        ..allObjects(Variation.group20Var0);
      await expectLater(
        pair.association.sendAndExpectEmptyResponse(FunctionCode.freezeAtTime, headers),
        throwsA(isA<Dnp3Exception>()), // freeze not supported by this outstation
      );
    });

    test('poll and association removal', () async {
      final poll = await pair.association.addPoll(const ReadRequest.events(), const Duration(seconds: 1));
      expect(Dnp3.objectCounts.$3, greaterThan(0));
      await poll.remove();
      await pair.association.remove();
      await expectLater(
        pair.association.read(const ReadRequest.integrity()),
        throwsA(isA<InvalidHandleException>()),
      );
    });

    test('invalid configuration is rejected synchronously', () {
      expect(
        () => MasterChannel.tcpClient(
          config: const MasterChannelConfig(masterAddress: 0xFFFF),
          endpoints: ['127.0.0.1:1'],
        ),
        throwsA(isA<ConfigException>()),
      );
    });
  });

  group('callback mode', () {
    test('control callback decides and updates the database atomically', () async {
      final requests = <ControlRequest>[];
      final pair = await Pair.create(
        handlers: OutstationHandlers(
          control: const ControlHandlerConfig(mode: ControlMode.callback),
          onControl: (req) {
            requests.add(req);
            if (req.index == 9) return const ControlResponse(CommandStatus.notAuthorized);
            if (req.phase == ControlPhase.select) return ControlResponse.success;
            final tx = DatabaseTransaction()..updateBinaryOutputStatus(req.index, true);
            return ControlResponse(CommandStatus.success, tx);
          },
        ),
      );
      try {
        await pair.association.operate(CommandSet.crob(4, const Crob.latchOn()));
        expect(requests.map((r) => r.phase), [ControlPhase.select, ControlPhase.operate]);
        expect(requests.last.crob.code.opType, OpType.latchOn);
        expect(pair.outstation.database.getBinaryOutputStatus(4)!.value, isTrue);

        await expectLater(
          pair.association.operate(CommandSet.crob(9, const Crob.latchOn())),
          throwsA(isA<CommandException>().having((e) => e.status, 'status', CommandStatus.notAuthorized)),
        );
      } finally {
        pair.close();
      }
    });

    test('application callbacks: restart and time write', () async {
      final app = _App();
      final pair = await Pair.create(
        handlers: OutstationHandlers(
          application: const ApplicationConfig(
            coldRestart: RestartMode.callback,
            writeAbsoluteTime: TimeWriteMode.callback,
            freeze: FreezeMode.auto,
          ),
          applicationCallbacks: app,
        ),
      );
      try {
        expect(await pair.association.coldRestart(), const Duration(seconds: 3));
        await pair.association.synchronizeTime(TimeSyncProcedure.directWriteAbsTime);
        expect(app.times, hasLength(1));

        pair.outstation.transaction((tx) => tx.updateCounter(2, 77));
        await pair.association.freezeCounters();
        expect(pair.outstation.database.getFrozenCounter(2)!.value, 77);
      } finally {
        pair.close();
      }
    });
  });

  test('destroying a channel releases its associations', () async {
    final pair = await Pair.create();
    final assoc = pair.association;
    pair.close();
    await expectLater(assoc.read(const ReadRequest.integrity()), throwsA(isA<InvalidHandleException>()));
    expect(await assoc.measurements.isEmpty, isTrue); // stream is closed
  });

  test('handles are released', () async {
    final pair = await Pair.create();
    pair.close();
    // object counts are process-wide and test files run concurrently: check these handles
    await expectLater(
      MasterChannel.attach(pair.master.handle).enable(),
      throwsA(isA<InvalidHandleException>()),
    );
    expect(() => Database(pair.outstation.handle).getCounter(0), throwsA(isA<InvalidHandleException>()));
  });
}

class _App extends OutstationApplication {
  final times = <Dnp3Time>[];
  @override
  RestartDelay? coldRestart() => const RestartDelay.seconds(3);
  @override
  RequestResult writeAbsoluteTime(Dnp3Time time) {
    times.add(time);
    return RequestResult.ok;
  }
}
