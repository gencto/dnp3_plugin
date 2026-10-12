import 'dart:isolate';
import 'dart:typed_data';

import 'package:dnp3/dnp3.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

// Closures sent to other isolates must not capture the test's context (which holds
// non-sendable objects such as the ReceivePort of the runtime): build them in top-level
// functions that only see sendable values.

void Function(MeasurementFragment) _countAnalogs(SendPort sink) => (fragment) {
  var analogs = 0;
  for (final b in fragment.blocks) {
    if (b is AnalogInputBlock) analogs += b.count;
  }
  sink.send(analogs);
};

Future<void> _updateFromIsolate(int outstation) => Isolate.run(() {
  Database(outstation).transaction((tx) {
    for (var i = 0; i < 10; i++) {
      tx.updateAnalogInput(i, 100.0 + i);
    }
  });
});

Future<int> _useAssociationFromIsolate(int association) => Isolate.run(() async {
  final assoc = Association.attach(association);
  final fragments = await assoc.readWithHandler(ReadRequest.allObjects(Variation.group20Var0));
  final block = fragments.expand((f) => f.blocks).whereType<CounterBlock>().first;
  await assoc.operate(CommandSet.crob(1, const Crob.latchOn()));
  return block.valueAt(3);
});

Future<Uint8List> _buildTransactionInIsolate() async {
  final t = await Isolate.run(() {
    final tx = DatabaseTransaction();
    for (var i = 0; i < 10; i++) {
      tx.updateBinaryInput(i, i.isEven);
    }
    return TransferableTypedData.fromList([tx.bytes]);
  });
  return t.materialize().asUint8List();
}

void main() {
  late Pair pair;

  setUp(() async => pair = await Pair.create());
  tearDown(() => pair.close());

  test('measurements are delivered straight to a worker isolate', () async {
    final results = ReceivePort();
    final worker = await MeasurementWorker.spawn(_countAnalogs(results.sendPort));
    final counts = <int>[];
    results.listen((x) => counts.add(x as int));

    // the outstation serves one master at a time: replace the pair's master
    pair.master.destroy();
    final master = MasterChannel.tcpClient(
      config: const MasterChannelConfig(masterAddress: 1),
      endpoints: [pair.server.localAddress!],
    );
    try {
      final assoc = await master.addAssociation(
        10,
        config: const AssociationConfig.quiet(),
        eventPort: worker.port,
      );
      await master.enable();
      await eventually(() => master.clientState?.state == ClientState.connected);
      await assoc.read(const ReadRequest.integrity());
      await eventually(() => counts.isNotEmpty);
      expect(counts.first, 10);
    } finally {
      master.destroy();
      worker.close();
      results.close();
    }
  });

  test('outstation database can be updated from another isolate', () async {
    await _updateFromIsolate(pair.outstation.handle);
    expect(pair.outstation.database.getAnalogInput(5)!.value, 105.0);
    final fragments = await pair.association.readWithHandler(const ReadRequest.integrity());
    final block = fragments.expand((f) => f.blocks).whereType<AnalogInputBlock>().first;
    expect(block.valueAt(9), 109.0);
  });

  test('association handle works from another isolate', () async {
    pair.outstation.transaction((tx) => tx.updateCounter(3, 333));
    expect(await _useAssociationFromIsolate(pair.association.handle), 333);
    expect(pair.outstation.database.getBinaryOutputStatus(1)!.value, isTrue);
  });

  test('transactions built in a worker are applied as bytes', () async {
    final bytes = await _buildTransactionInIsolate();
    expect(pair.outstation.database.applyBytes(bytes), 10);
    expect(pair.outstation.database.getBinaryInput(2)!.value, isTrue);
    expect(pair.outstation.database.getBinaryInput(3)!.value, isFalse);
  });
}
