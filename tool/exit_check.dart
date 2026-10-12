// Sanity check: a program exits by itself once every object has been destroyed.
import 'package:dnp3/dnp3.dart';

Future<void> main() async {
  final server = OutstationServer.tcp('127.0.0.1:0');
  final o = server.addOutstation(config: const OutstationConfig(outstationAddress: 10, masterAddress: 1));
  o.transaction((tx) => tx.addAnalogInput(0));
  final addr = await server.bind();
  final m = MasterChannel.tcpClient(config: const MasterChannelConfig(masterAddress: 1), endpoints: [addr]);
  final a = await m.addAssociation(10);
  await m.enable();
  await Future<void>.delayed(const Duration(milliseconds: 300));
  await a.read(const ReadRequest.integrity());
  m.destroy();
  server.destroy();
  print('done');
}
