// A TCP outstation with a few points that change every second.
//
//   dart run example/outstation.dart [listen-address]   (default 0.0.0.0:20000)
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dnp3/dnp3.dart';

Future<void> main(List<String> args) async {
  Dnp3.logger.onRecord.listen((r) => stdout.writeln('[${r.level.name}] ${r.message}'));
  Dnp3.enableLogging(level: Dnp3LogLevel.info);

  final server = OutstationServer.tcp(args.isNotEmpty ? args.first : '0.0.0.0:20000');
  final outstation = server.addOutstation(
    config: const OutstationConfig(
      outstationAddress: 1024,
      masterAddress: 1,
      eventBufferConfig: EventBufferConfig.allTypes(100),
      decodeLevel: DecodeLevel(application: AppDecodeLevel.objectHeaders),
    ),
    handlers: const OutstationHandlers(
      // controls are executed natively and mirrored into the output status points
      control: ControlHandlerConfig(mode: ControlMode.accept, updateDatabase: true),
      application: ApplicationConfig(
        freeze: FreezeMode.auto,
        writeAbsoluteTime: TimeWriteMode.accept,
        coldRestart: RestartMode.seconds,
        coldRestartDelay: 5,
      ),
    ),
  );

  outstation.transaction((tx) {
    for (var i = 0; i < 10; i++) {
      tx
        ..addBinaryInput(i, staticVariation: StaticBinaryInputVariation.group1Var2)
        ..addAnalogInput(
          i,
          staticVariation: StaticAnalogInputVariation.group30Var5,
          eventVariation: EventAnalogInputVariation.group32Var7,
          deadband: 0.5,
        )
        ..addCounter(i)
        ..addFrozenCounter(i)
        ..addBinaryOutputStatus(i)
        ..addAnalogOutputStatus(i);
    }
    tx.defineAttribute(DeviceAttribute.string(AttributeVariation.deviceManufacturerName, 'gencto'));
  });

  outstation.events.listen((e) => stdout.writeln('event: $e'));
  stdout.writeln('listening on ${await server.bind()}');

  final rnd = Random();
  var counter = 0;
  final timer = Timer.periodic(const Duration(seconds: 1), (_) {
    outstation.transaction((tx) {
      for (var i = 0; i < 10; i++) {
        tx
          ..updateAnalogInput(i, 20 + rnd.nextDouble() * 5, time: Dnp3Time.now())
          ..updateCounter(i, counter);
      }
      tx.updateBinaryInput(0, counter.isEven, time: Dnp3Time.now());
    });
    counter++;
  });

  await ProcessSignal.sigint.watch().first;
  timer.cancel();
  server.destroy();
  Dnp3.shutdown();
}
