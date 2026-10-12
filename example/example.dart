// Self-contained tour of package:dnp3: an outstation and a master in the same process,
// talking DNP3 over TCP loopback. Runs to completion, no external device needed.
//
//   dart run example/example.dart
//
// See also master.dart, outstation.dart and worker_isolate.dart in this folder.
import 'package:dnp3/dnp3.dart';

Future<void> main() async {
  // ---------------------------------------------------------------- outstation
  final server = OutstationServer.tcp('127.0.0.1:0'); // port 0: pick a free port
  final outstation = server.addOutstation(
    config: const OutstationConfig(outstationAddress: 1024, masterAddress: 1),
    // SELECT / OPERATE are executed natively and mirrored into the output status points
    handlers: const OutstationHandlers(
      control: ControlHandlerConfig(mode: ControlMode.accept, updateDatabase: true),
    ),
  );

  // One transaction = one native call and one lock, however many points it touches
  outstation.transaction((tx) {
    for (var i = 0; i < 5; i++) {
      tx
        ..addAnalogInput(i, staticVariation: StaticAnalogInputVariation.group30Var6)
        ..addBinaryOutputStatus(i)
        ..updateAnalogInput(i, 20.0 + i, time: Dnp3Time.now());
    }
  });
  final address = await server.bind();
  print('outstation listening on $address');

  // -------------------------------------------------------------------- master
  final channel = MasterChannel.tcpClient(
    config: const MasterChannelConfig(masterAddress: 1),
    endpoints: [address],
  );
  final association = await channel.addAssociation(1024);
  await channel.enable();

  // Responses are delivered as zero-copy fragments: values are read straight out of the
  // native buffer through flyweight accessors.
  final fragments = await association.readWithHandler(const ReadRequest.classScan(Classes.class0()));
  for (final block in fragments.expand((f) => f.blocks).whereType<AnalogInputBlock>()) {
    for (var i = 0; i < block.count; i++) {
      print('AI[${block.indexAt(i)}] = ${block.valueAt(i)}');
    }
  }

  // Control: latch on output 2; the outstation mirrors it into BinaryOutputStatus 2
  await association.operate(CommandSet.crob(2, const Crob.latchOn()));
  print('BOS[2] after LATCH_ON: ${outstation.database.getBinaryOutputStatus(2)?.value}');

  // -------------------------------------------------------------------- cleanup
  channel.destroy();
  server.destroy();
  Dnp3.shutdown();
}
