// Measurement processing in a dedicated isolate. Fragments are posted by native code
// directly to the worker's port: the main (UI) isolate never sees them.
//
//   dart run example/worker_isolate.dart [outstation-endpoint]
import 'dart:io';
import 'dart:isolate';

import 'package:dnp3/dnp3.dart';

/// Builds the worker callback; only sendable values are captured.
void Function(MeasurementFragment) statistics(SendPort report) {
  var count = 0;
  var sum = 0.0;
  return (fragment) {
    for (final block in fragment.blocks) {
      if (block is AnalogInputBlock) {
        for (var i = 0; i < block.count; i++) {
          sum += block.valueAt(i);
          count++;
        }
      }
    }
    report.send('values: $count, mean: ${(sum / (count == 0 ? 1 : count)).toStringAsFixed(3)}');
  };
}

Future<void> main(List<String> args) async {
  final reports = ReceivePort()..listen((m) => stdout.writeln('[worker] $m'));
  final worker = await MeasurementWorker.spawn(statistics(reports.sendPort));

  final channel = MasterChannel.tcpClient(
    config: const MasterChannelConfig(masterAddress: 1),
    endpoints: [args.isNotEmpty ? args.first : '127.0.0.1:20000'],
  );
  final assoc = await channel.addAssociation(1024, eventPort: worker.port);
  await assoc.addPoll(const ReadRequest.integrity(), const Duration(seconds: 1));
  await channel.enable();

  // Database writes can also come from any isolate: only the integer handle is needed.
  // e.g. Isolate.run(() => Database(outstationHandle).transaction((tx) => ...));

  await ProcessSignal.sigint.watch().first;
  channel.destroy();
  worker.close();
  reports.close();
  Dnp3.shutdown();
}
