import 'dart:async';
import 'dart:io';

import 'package:dnp3/dnp3.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

Future<int> freeUdpPort() async {
  final s = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  final p = s.port;
  s.close();
  return p;
}

double? analogValue(List<MeasurementFragment> fragments, int index) {
  for (final f in fragments) {
    for (final b in f.blocks) {
      if (b is AnalogInputBlock) {
        for (final a in b) {
          if (a.index == index) return a.value;
        }
      }
    }
  }
  return null;
}

void main() {
  test('UDP master <-> UDP outstation', () async {
    final outPort = await freeUdpPort();
    final masterPort = await freeUdpPort();
    // start the master first: a connected UDP socket of the outstation backs off for
    // `retryDelay` after an ICMP "port unreachable"
    final master = MasterChannel.udp(
      config: const MasterChannelConfig(masterAddress: 1),
      localEndpoint: '127.0.0.1:$masterPort',
    );
    final assoc = await master.addAssociation(
      10,
      udpDestination: '127.0.0.1:$outPort',
      config: const AssociationConfig.quiet(responseTimeout: Duration(milliseconds: 500)),
    );
    await master.enable();
    final outstation = Outstation.udp(
      config: const OutstationConfig(outstationAddress: 10, masterAddress: 1),
      localEndpoint: '127.0.0.1:$outPort',
      remoteEndpoint: '127.0.0.1:$masterPort',
      retryDelay: const Duration(milliseconds: 50),
    );
    outstation.transaction(
      (tx) => tx
        ..addAnalogInput(0)
        ..updateAnalogInput(0, 3.25),
    );
    try {
      List<MeasurementFragment>? fragments;
      for (var attempt = 0; fragments == null && attempt < 10; attempt++) {
        try {
          fragments = await assoc.readWithHandler(const ReadRequest.integrity());
        } on TaskException {
          // the outstation may still be completing its unsolicited startup exchange
        }
      }
      expect(analogValue(fragments!, 0), 3); // g30v1 is a 32-bit integer variation
    } finally {
      master.destroy();
      outstation.destroy();
    }
  });

  test('stream association on a UDP channel is rejected', () async {
    final master = MasterChannel.udp(
      config: const MasterChannelConfig(masterAddress: 1),
      localEndpoint: '127.0.0.1:${await freeUdpPort()}',
    );
    try {
      await expectLater(
        master.addAssociation(10),
        throwsA(isA<AssociationException>().having((e) => e.wrongChannelType, 'wrongChannelType', isTrue)),
      );
    } finally {
      master.destroy();
    }
  });

  group('TLS', () {
    late Directory dir;
    var skip = false;

    setUpAll(() async {
      dir = await Directory.systemTemp.createTemp('dnp3_tls');
      for (final name in ['master', 'outstation']) {
        final r = await Process.run('openssl', [
          'req',
          '-x509',
          '-newkey',
          'ec',
          '-pkeyopt',
          'ec_paramgen_curve:prime256v1',
          '-nodes',
          '-keyout',
          '${dir.path}/$name.key',
          '-out',
          '${dir.path}/$name.pem',
          '-days',
          '2',
          '-subj',
          '/CN=$name',
          '-addext',
          'subjectAltName=DNS:$name',
        ]);
        if (r.exitCode != 0) skip = true;
      }
    });

    tearDownAll(() => dir.delete(recursive: true));

    test('self-signed TLS session', () async {
      if (skip) return markTestSkipped('openssl not available');
      final server = OutstationServer.tls(
        '127.0.0.1:0',
        TlsConfig(
          mode: TlsMode.selfSigned,
          peerCertPath: '${dir.path}/master.pem',
          localCertPath: '${dir.path}/outstation.pem',
          privateKeyPath: '${dir.path}/outstation.key',
        ),
      );
      final outstation = server.addOutstation(
        config: const OutstationConfig(outstationAddress: 10, masterAddress: 1),
      );
      outstation.transaction(
        (tx) => tx
          ..addBinaryInput(0)
          ..updateBinaryInput(0, true),
      );
      final addr = await server.bind();
      final master = MasterChannel.tlsClient(
        config: const MasterChannelConfig(masterAddress: 1),
        endpoints: [addr],
        tls: TlsConfig(
          mode: TlsMode.selfSigned,
          peerCertPath: '${dir.path}/outstation.pem',
          localCertPath: '${dir.path}/master.pem',
          privateKeyPath: '${dir.path}/master.key',
        ),
      );
      try {
        final assoc = await master.addAssociation(10);
        await master.enable();
        await eventually(() => master.clientState?.state == ClientState.connected);
        final fragments = await assoc.readWithHandler(const ReadRequest.integrity());
        final bi = fragments.expand((f) => f.blocks).whereType<BinaryInputBlock>().first;
        expect(bi.valueAt(0), isTrue);
      } finally {
        master.destroy();
        server.destroy();
      }
    });

    test('invalid certificate paths are reported', () {
      expect(
        () => MasterChannel.tlsClient(
          config: const MasterChannelConfig(masterAddress: 1),
          endpoints: ['127.0.0.1:1'],
          tls: const TlsConfig(peerCertPath: '/nope', localCertPath: '/nope', privateKeyPath: '/nope'),
        ),
        throwsA(isA<NativeException>()),
      );
    });
  });

  test('master server accepts an outstation acting as TCP client', () async {
    final handler = _Handler();
    final server = await MasterServer.bind('127.0.0.1:0', handler);
    final outstation = Outstation.tcpClient(
      config: const OutstationConfig(outstationAddress: 10, masterAddress: 1),
      endpoints: [server.localAddress],
    );
    outstation.transaction(
      (tx) => tx
        ..addAnalogInput(0, staticVariation: StaticAnalogInputVariation.group30Var6)
        ..updateAnalogInput(0, 7.5),
    );
    final states = <ClientStateEvent>[];
    final events = <ConnectionEvent>[];
    outstation.clientStates.listen(states.add);
    outstation.connectionEvents.listen(events.add);
    await outstation.enable();
    try {
      final assoc = await handler.association.future.timeout(const Duration(seconds: 10));
      final fragments = await assoc.readWithHandler(const ReadRequest.integrity());
      expect(analogValue(fragments, 0), 7.5);
      expect(handler.accepted, hasLength(1));
      await eventually(() => states.any((s) => s.state == ClientState.connected));
      expect(events.map((e) => e.type), contains(ConnectionEventType.connected));
    } finally {
      outstation.destroy();
      server.destroy();
    }
  });

  test('master server identifies outstations by link address', () async {
    final handler = _Handler(identify: true);
    final server = await MasterServer.bind('127.0.0.1:0', handler);
    final outstation = Outstation.tcpClient(
      config: const OutstationConfig(outstationAddress: 10, masterAddress: 1),
      endpoints: [server.localAddress],
    );
    await outstation.enable();
    try {
      await handler.association.future.timeout(const Duration(seconds: 10));
      expect(handler.linkIds, [(10, 1)]);
    } finally {
      outstation.destroy();
      server.destroy();
    }
  });

  test('client reports connection failures and retries', () async {
    final master = MasterChannel.tcpClient(
      config: const MasterChannelConfig(masterAddress: 1),
      endpoints: ['127.0.0.1:1'],
      connectStrategy: const ConnectStrategy(
        minConnectDelay: Duration(milliseconds: 20),
        maxConnectDelay: Duration(milliseconds: 40),
      ),
    );
    final events = <ConnectionEvent>[];
    master.connectionEvents.listen(events.add);
    await master.enable();
    try {
      await eventually(() => events.where((e) => e.type == ConnectionEventType.connectFailed).length >= 2);
      expect(master.clientState?.state, isNot(ClientState.connected));
    } finally {
      master.destroy();
    }
  });

  test('native logging is forwarded to package:logging', () async {
    final records = <LogRecord>[];
    final sub = Dnp3.logger.onRecord.listen(records.add);
    Dnp3.enableLogging(level: Dnp3LogLevel.info);
    final pair = await Pair.create(
      outstationConfig: const OutstationConfig(
        outstationAddress: 10,
        masterAddress: 1,
        decodeLevel: DecodeLevel(application: AppDecodeLevel.header),
      ),
    );
    try {
      await pair.association.read(const ReadRequest.integrity());
      await eventually(() => records.isNotEmpty);
      expect(records.map((r) => r.message).join('\n'), contains('func: Read'));
    } finally {
      pair.close();
      Dnp3.disableLogging();
      await sub.cancel();
    }
  });

  test('serial master <-> serial outstation over a virtual null-modem', () async {
    if (!Platform.isLinux) return markTestSkipped('pty bridge only on Linux');
    final bridge = await _PtyBridge.start();
    if (bridge == null) return markTestSkipped('python3 pty bridge not available');
    final outstation = Outstation.serial(
      config: const OutstationConfig(outstationAddress: 10, masterAddress: 1),
      path: bridge.b,
      settings: const SerialSettings(baudRate: 115200),
      retry: const RetryStrategy(minDelay: Duration(milliseconds: 50)),
    );
    outstation.transaction(
      (tx) => tx
        ..addCounter(0)
        ..updateCounter(0, 4242),
    );
    final master = MasterChannel.serial(
      config: const MasterChannelConfig(masterAddress: 1),
      path: bridge.a,
      settings: const SerialSettings(baudRate: 115200),
      retryDelay: const Duration(milliseconds: 50),
    );
    final ports = <PortStateEvent>[];
    master.portStates.listen(ports.add);
    try {
      final assoc = await master.addAssociation(10, config: const AssociationConfig.quiet());
      await master.enable();
      await eventually(() => ports.any((p) => p.state == PortState.open));
      final fragments = await assoc.readWithHandler(ReadRequest.allObjects(Variation.group20Var0));
      final counter = fragments.expand((f) => f.blocks).whereType<CounterBlock>().first;
      expect(counter.valueAt(0), 4242);
    } finally {
      master.destroy();
      outstation.destroy();
      bridge.stop();
    }
  });
}

class _Handler extends MasterServerHandler {
  final bool identify;
  final accepted = <String>[];
  final linkIds = <(int, int)>[];
  final association = Completer<Association>();
  _Handler({this.identify = false});

  @override
  AcceptAction accept(String remoteAddress) {
    accepted.add(remoteAddress);
    return identify
        ? const AcceptAction.identifyByLinkAddress()
        : const AcceptAction.accept(AcceptConfig(channel: MasterChannelConfig(masterAddress: 1)));
  }

  @override
  AcceptConfig? acceptLinkId(String remoteAddress, int source, int destination) {
    linkIds.add((source, destination));
    return AcceptConfig(channel: MasterChannelConfig(masterAddress: destination));
  }

  @override
  Future<void> start(MasterChannel channel, String remoteAddress) async {
    final a = await channel.addAssociation(10);
    await channel.enable();
    if (!association.isCompleted) association.complete(a);
  }
}

/// Two pseudo terminals relayed into each other (a software null-modem cable)
class _PtyBridge {
  final Process process;
  final String a;
  final String b;
  _PtyBridge(this.process, this.a, this.b);

  static const _script = r'''
import os, pty, select, sys, tty
m1, s1 = pty.openpty(); m2, s2 = pty.openpty()
for fd in (s1, s2): tty.setraw(fd)
print(os.ttyname(s1)); print(os.ttyname(s2)); sys.stdout.flush()
while True:
    r, _, _ = select.select([m1, m2], [], [])
    for fd in r:
        try: data = os.read(fd, 4096)
        except OSError: continue
        os.write(m2 if fd == m1 else m1, data)
''';

  static Future<_PtyBridge?> start() async {
    try {
      final p = await Process.start('python3', ['-c', _script]);
      final lines = <String>[];
      final done = Completer<void>();
      p.stdout.transform(const SystemEncoding().decoder).listen((s) {
        lines.addAll(s.split('\n').where((x) => x.isNotEmpty));
        if (lines.length >= 2 && !done.isCompleted) done.complete();
      });
      await done.future.timeout(const Duration(seconds: 5));
      return _PtyBridge(p, lines[0], lines[1]);
    } catch (_) {
      return null;
    }
  }

  void stop() => process.kill();
}
