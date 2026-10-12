import 'dart:async';

import 'package:dnp3/dnp3.dart';

/// Wait until `predicate` becomes true or fail after `timeout`
Future<void> eventually(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 10),
  String? reason,
}) async {
  final end = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(end)) {
      throw TimeoutException(reason ?? 'condition not met', timeout);
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// An outstation server + master pair connected over TCP on localhost
class Pair {
  final OutstationServer server;
  final Outstation outstation;
  final MasterChannel master;
  final Association association;
  final List<MeasurementFragment> fragments;

  Pair(this.server, this.outstation, this.master, this.association, this.fragments);

  static Future<Pair> create({
    OutstationHandlers handlers = const OutstationHandlers(),
    AssociationConfig associationConfig = const AssociationConfig(),
    OutstationConfig? outstationConfig,
    void Function(DatabaseTransaction tx)? database,
    bool information = false,
  }) async {
    final server = OutstationServer.tcp('127.0.0.1:0');
    final outstation = server.addOutstation(
      config: outstationConfig ?? const OutstationConfig(outstationAddress: 10, masterAddress: 1),
      handlers: handlers,
    );
    outstation.transaction(database ?? defaultDatabase);
    final addr = await server.bind();

    final master = MasterChannel.tcpClient(
      config: const MasterChannelConfig(masterAddress: 1),
      endpoints: [addr],
    );
    final assoc = await master.addAssociation(10, config: associationConfig, information: information);
    final fragments = <MeasurementFragment>[];
    assoc.measurements.listen(fragments.add);
    await master.enable();
    await eventually(
      () => master.clientState?.state == ClientState.connected,
      reason: 'master did not connect',
    );
    return Pair(server, outstation, master, assoc, fragments);
  }

  void close() {
    master.destroy();
    server.destroy();
  }
}

void defaultDatabase(DatabaseTransaction tx) {
  for (var i = 0; i < 10; i++) {
    tx
      ..addBinaryInput(i)
      ..addDoubleBitBinaryInput(i)
      ..addBinaryOutputStatus(i)
      ..addCounter(i)
      ..addFrozenCounter(i)
      ..addAnalogInput(
        i,
        staticVariation: StaticAnalogInputVariation.group30Var6,
        eventVariation: EventAnalogInputVariation.group32Var8,
      )
      ..addAnalogOutputStatus(i, staticVariation: StaticAnalogOutputStatusVariation.group40Var4)
      ..addOctetString(i);
  }
}
