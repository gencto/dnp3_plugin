// A TCP master polling an outstation and printing every received value.
//
//   dart run example/master.dart [outstation-endpoint]   (default 127.0.0.1:20000)
import 'dart:io';

import 'package:dnp3/dnp3.dart';

Future<void> main(List<String> args) async {
  final channel = MasterChannel.tcpClient(
    config: const MasterChannelConfig(masterAddress: 1),
    endpoints: [args.isNotEmpty ? args.first : '127.0.0.1:20000'],
  );
  channel.clientStates.listen((s) => stdout.writeln('client: $s'));

  final assoc = await channel.addAssociation(
    1024,
    config: const AssociationConfig(autoTimeSync: TimeSyncProcedure.lan),
  );

  // Zero-copy processing: the visitor reads values straight out of the native buffer
  assoc.measurements.listen((fragment) => fragment.visit(_Printer()));

  await assoc.addPoll(const ReadRequest.events(), const Duration(seconds: 1));
  await assoc.addPoll(const ReadRequest.integrity(), const Duration(seconds: 30));
  await channel.enable();

  if (stdin.hasTerminal) stdin.lineMode = true;
  stdout.writeln('commands: on <i> | off <i> | ao <i> <value> | integrity | attrs | quit');
  await for (final line in stdin.transform(const SystemEncoding().decoder)) {
    final p = line.trim().split(RegExp(r'\s+'));
    try {
      switch (p) {
        case ['on', final i]:
          await assoc.operate(CommandSet.crob(int.parse(i), const Crob.latchOn()));
        case ['off', final i]:
          await assoc.operate(CommandSet.crob(int.parse(i), const Crob.latchOff()));
        case ['ao', final i, final v]:
          await assoc.operate(CommandSet.analog(int.parse(i), AnalogOutput.double64(double.parse(v))));
        case ['integrity']:
          await assoc.read(const ReadRequest.integrity());
        case ['attrs']:
          final f = await assoc.readWithHandler(
            ReadRequest.deviceAttribute(AttributeVariation.allAttributesRequest),
          );
          for (final b in f.expand((x) => x.blocks).whereType<DeviceAttributeBlock>()) {
            stdout.writeln(b.attribute);
          }
        case ['quit']:
          channel.destroy();
          Dnp3.shutdown();
          exit(0);
      }
      stdout.writeln('ok');
    } on Dnp3Exception catch (e) {
      stdout.writeln('error: $e');
    }
  }
}

class _Printer extends MeasurementVisitor {
  @override
  void analogInputs(AnalogInputBlock block) {
    for (var i = 0; i < block.count; i++) {
      stdout.writeln(
        'AI[${block.indexAt(i)}] = ${block.valueAt(i).toStringAsFixed(2)} ${block.timeAt(i) ?? ''}',
      );
    }
  }

  @override
  void binaryInputs(BinaryInputBlock block) => block.forEach(stdout.writeln);

  @override
  void counters(CounterBlock block) => block.forEach(stdout.writeln);

  @override
  void binaryOutputStatuses(BinaryOutputStatusBlock block) => block.forEach(stdout.writeln);

  @override
  void analogOutputStatuses(AnalogOutputStatusBlock block) => block.forEach(stdout.writeln);
}
