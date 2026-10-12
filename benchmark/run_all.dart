// Benchmark suite for package:dnp3.
//
//   dart run benchmark/run_all.dart [--quick] [--out benchmark/results/<name>.md]
//
// Sections:
//   1. native -> Dart delivery of measurement fragments (zero-copy vs copied payloads)
//   2. decoding cost per point (flyweight accessors vs value objects vs a JSON baseline)
//   3. outstation database transactions (batch size scaling)
//   4. end-to-end over TCP loopback (integrity poll latency, command round trips)
//   5. event throughput outstation -> master (unsolicited)
//   6. delivery to a worker isolate
import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show NativePort;
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:dnp3/dnp3.dart';
import 'package:dnp3/src/native/bindings.dart' show dnp3_bench_emit, dnp3_set_external_threshold;
import 'package:dnp3/src/native/protocol.dart';
import 'package:dnp3/src/native/runtime.dart';

late final bool quick;
final rows = <String, List<List<String>>>{};
final json = <String, Object?>{};

void table(String section, List<String> row) => (rows[section] ??= []).add(row);

String fmt(num x, [int digits = 1]) {
  if (x >= 1e9) return '${(x / 1e9).toStringAsFixed(2)} G';
  if (x >= 1e6) return '${(x / 1e6).toStringAsFixed(2)} M';
  if (x >= 1e4) return '${(x / 1e3).toStringAsFixed(1)} k';
  return x.toStringAsFixed(digits);
}

class Stats {
  final List<double> us;
  Stats(List<double> v) : us = (List.of(v)..sort());
  double pct(double p) => us[min(us.length - 1, (p * us.length).floor())];
  double get p50 => pct(0.5);
  double get p99 => pct(0.99);
  double get mean => us.reduce((a, b) => a + b) / us.length;
}

Future<void> main(List<String> args) async {
  quick = args.contains('--quick');
  final outIdx = args.indexOf('--out');
  final out = outIdx >= 0 ? args[outIdx + 1] : null;

  Dnp3.initialize(workerThreads: Platform.numberOfProcessors.clamp(2, 8));
  stdout.writeln(
    'dnp3 ${Dnp3.nativeVersion} | Dart ${Platform.version.split(' ').first} | '
    '${Platform.operatingSystem} ${Platform.localHostname} | ${Platform.numberOfProcessors} CPUs',
  );

  await benchDelivery();
  benchDecoding();
  benchDatabase();
  await benchEndToEnd();
  await benchEventThroughput();
  await benchWorkerIsolate();

  final report = render();
  stdout.writeln(report);
  if (out != null) {
    File(out)
      ..createSync(recursive: true)
      ..writeAsStringSync(report);
    File(
      out.replaceAll(RegExp(r'\.md$'), '.json'),
    ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(json));
  }
  Dnp3.shutdown();
  exit(0);
}

// ---------------------------------------------------------------------------------------
// 1. delivery
// ---------------------------------------------------------------------------------------

/// Emits `fragments` fragments of `points` analog inputs natively and waits until Dart has
/// received them. Returns (wall time, native time, bytes per fragment).
Future<(Duration, Duration, int)> emit(int fragments, int points, {bool decode = false}) async {
  final rt = NativeRuntime.current;
  var received = 0;
  var bytes = 0;
  var sink = 0.0;
  final done = Completer<void>();
  rt.register(0, (kind, a, b, payload) {
    if (kind != Msg.measurements) return;
    final data = payload as Uint8List;
    bytes = data.length;
    if (decode) {
      final block = MeasurementFragment(data).blocks.first as AnalogInputBlock;
      var acc = 0.0;
      final n = block.count;
      for (var i = 0; i < n; i++) {
        acc += block.valueAt(i);
      }
      sink += acc;
    }
    if (++received == fragments) done.complete();
  });
  final sw = Stopwatch()..start();
  final nativeNs = await rt.call((p, r) => dnp3_bench_emit(p, fragments, points, r)) as int;
  await done.future;
  sw.stop();
  rt.unregister(0);
  if (sink.isNaN) stdout.write('');
  return (sw.elapsed, Duration(microseconds: nativeNs ~/ 1000), bytes);
}

Future<void> benchDelivery() async {
  const section = '1. Native → Dart delivery of measurement fragments';
  final fragments = quick ? 2000 : 20000;
  for (final points in [10, 100, 1000, 4000, 16000]) {
    for (final zeroCopy in [true, false]) {
      dnp3_set_external_threshold(zeroCopy ? 0 : 1 << 40);
      await emit(200, points); // warm up
      final n = max(200, fragments * 10 ~/ max(points, 10) ~/ (points >= 1000 ? 4 : 1));
      final (wall, native, size) = await emit(n, points);
      final perSec = n / wall.inMicroseconds * 1e6;
      table(section, [
        '$points',
        zeroCopy ? 'zero-copy (external typed data)' : 'copied (kTypedData)',
        fmt(size.toDouble(), 0),
        fmt(perSec),
        fmt(perSec * points),
        fmt(perSec * size / 1e6, 1),
        (wall.inMicroseconds / n).toStringAsFixed(2),
      ]);
      json['delivery_${points}_${zeroCopy ? 'zerocopy' : 'copy'}'] = {
        'fragments_per_s': perSec,
        'points_per_s': perSec * points,
        'native_us': native.inMicroseconds,
      };
    }
  }
  dnp3_set_external_threshold(128 * 1024);
  final (wall, _, _) = await emit(fragments ~/ 4, 1000, decode: true);
  final pps = fragments ~/ 4 * 1000 / wall.inMicroseconds * 1e6;
  table(section, ['1000', 'zero-copy + decode every value', '-', fmt(pps / 1000), fmt(pps), '-', '-']);
  json['delivery_1000_zerocopy_decoded_points_per_s'] = pps;
}

// ---------------------------------------------------------------------------------------
// 2. decoding
// ---------------------------------------------------------------------------------------

Uint8List buildFragment(int points) {
  // same layout as the native encoder (see doc/wire_format.md)
  final b = BytesBuilder();
  final h = ByteData(16)
    ..setUint8(0, 1)
    ..setUint8(1, 2)
    ..setUint16(6, 1, Endian.little)
    ..setUint32(8, 32 + points * 24, Endian.little);
  b.add(h.buffer.asUint8List());
  final bh = ByteData(16)
    ..setUint8(0, PointKind.analogInput)
    ..setUint8(1, 30)
    ..setUint8(2, 1)
    ..setUint8(3, 1)
    ..setUint8(4, 2)
    ..setUint8(5, 24)
    ..setUint32(8, points, Endian.little)
    ..setUint32(12, points * 24, Endian.little);
  b.add(bh.buffer.asUint8List());
  final r = ByteData(points * 24);
  for (var i = 0; i < points; i++) {
    r
      ..setUint16(i * 24, i, Endian.little)
      ..setUint8(i * 24 + 2, 1)
      ..setUint8(i * 24 + 3, 1)
      ..setFloat64(i * 24 + 8, i * 0.5, Endian.little)
      ..setUint64(i * 24 + 16, 1700000000000 + i, Endian.little);
  }
  b.add(r.buffer.asUint8List());
  return b.takeBytes();
}

double timeNsPerPoint(int points, void Function() body) {
  final iterations = quick ? 200 : 2000;
  for (var i = 0; i < 50; i++) {
    body();
  }
  final sw = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    body();
  }
  return sw.elapsedMicroseconds * 1000 / (iterations * points);
}

void benchDecoding() {
  const section = '2. Decoding cost per point (1000 analog inputs per fragment)';
  const points = 1000;
  final data = buildFragment(points);
  var sink = 0.0;

  // accumulate into locals: a captured `double` would be boxed on every iteration
  final rawValue = timeNsPerPoint(points, () {
    final block = MeasurementFragment(data).blocks.first as AnalogInputBlock;
    var acc = 0.0;
    final n = block.count;
    for (var i = 0; i < n; i++) {
      acc += block.valueAt(i);
    }
    sink += acc;
  });
  final raw = timeNsPerPoint(points, () {
    final block = MeasurementFragment(data).blocks.first as AnalogInputBlock;
    var acc = 0.0;
    final n = block.count;
    for (var i = 0; i < n; i++) {
      acc += block.valueAt(i) + block.indexAt(i) + block.flagsAt(i).value + block.timeMillisAt(i);
    }
    sink += acc;
  });
  final visitor = _SumVisitor();
  final visited = timeNsPerPoint(points, () => MeasurementFragment(data).visit(visitor));
  final objects = timeNsPerPoint(points, () {
    final block = MeasurementFragment(data).blocks.first as AnalogInputBlock;
    var acc = 0.0;
    for (final a in block) {
      acc += a.value + a.index + a.flags.value + (a.time?.millis ?? 0);
    }
    sink += acc;
  });

  // Baseline: the same values shipped as JSON (typical MethodChannel / string protocol)
  final jsonText = jsonEncode([
    for (var i = 0; i < points; i++)
      {'index': i, 'value': i * 0.5, 'flags': 1, 'time': 1700000000000 + i, 'sync': true},
  ]);
  final jsonBytes = utf8.encode(jsonText);
  final jsonNs = timeNsPerPoint(points, () {
    final list = jsonDecode(utf8.decode(jsonBytes)) as List;
    var acc = 0.0;
    for (final m in list.cast<Map<String, Object?>>()) {
      final a = AnalogInput(
        m['index'] as int,
        (m['value'] as num).toDouble(),
        flags: Flags(m['flags'] as int),
        time: Dnp3Time(m['time'] as int),
      );
      acc += a.value + a.index + a.flags.value + a.time!.millis;
    }
    sink += acc;
  });
  if (sink.isNaN || visitor.sum.isNaN) stdout.write('');

  table(section, ['flyweight accessor: value only', rawValue.toStringAsFixed(2), fmt(1e9 / rawValue)]);
  table(section, ['MeasurementVisitor: value only', visited.toStringAsFixed(2), fmt(1e9 / visited)]);
  table(section, [
    'flyweight accessors: index + value + flags + time',
    raw.toStringAsFixed(2),
    fmt(1e9 / raw),
  ]);
  table(section, [
    'value objects (List<AnalogInput>), all fields',
    objects.toStringAsFixed(2),
    fmt(1e9 / objects),
  ]);
  table(section, [
    'baseline: JSON bytes → objects, all fields',
    jsonNs.toStringAsFixed(2),
    fmt(1e9 / jsonNs),
  ]);
  json['decode_ns_per_point'] = {
    'flyweight_value': rawValue,
    'visitor_value': visited,
    'flyweight_all': raw,
    'objects': objects,
    'json': jsonNs,
  };
}

class _SumVisitor extends MeasurementVisitor {
  double sum = 0;
  @override
  void analogInputs(AnalogInputBlock block) {
    var acc = 0.0;
    final n = block.count;
    for (var i = 0; i < n; i++) {
      acc += block.valueAt(i);
    }
    sum += acc;
  }
}

// ---------------------------------------------------------------------------------------
// 3. database
// ---------------------------------------------------------------------------------------

void benchDatabase() {
  const section = '3. Outstation database transactions (analog updates with event detection)';
  final server = OutstationServer.tcp('127.0.0.1:0');
  final o = server.addOutstation(
    config: const OutstationConfig(
      outstationAddress: 10,
      masterAddress: 1,
      eventBufferConfig: EventBufferConfig.allTypes(0),
    ),
  );
  o.transaction((tx) {
    for (var i = 0; i < 1000; i++) {
      tx.addAnalogInput(i, eventClass: null);
    }
  });
  final db = o.database;
  final total = quick ? 200000 : 2000000;
  for (final batch in [1, 10, 100, 1000]) {
    var v = 0.0;
    void run(int n) {
      for (var k = 0; k < n ~/ batch; k++) {
        db.transaction((tx) {
          for (var i = 0; i < batch; i++) {
            tx.updateAnalogInput(i, v += 1);
          }
        });
      }
    }

    run(min(total ~/ 10, 100000));
    final sw = Stopwatch()..start();
    run(total);
    sw.stop();
    final perSec = total / sw.elapsedMicroseconds * 1e6;
    table(section, [
      '$batch',
      fmt(perSec),
      (sw.elapsedMicroseconds * 1000 / total).toStringAsFixed(1),
      fmt(perSec / batch),
    ]);
    json['db_updates_per_s_batch_$batch'] = perSec;
  }
  final sw = Stopwatch()..start();
  var reads = 0;
  while (sw.elapsedMilliseconds < 300) {
    db.getAnalogInput(reads++ % 1000);
  }
  table(section, ['read (getAnalogInput)', fmt(reads / sw.elapsedMicroseconds * 1e6), '-', '-']);
  server.destroy();
}

// ---------------------------------------------------------------------------------------
// 4. end-to-end latency
// ---------------------------------------------------------------------------------------

Future<(OutstationServer, Outstation, MasterChannel, Association)> pair({
  OutstationHandlers handlers = const OutstationHandlers(),
  int points = 1000,
  int events = 0,
  bool unsolicited = false,
}) async {
  final server = OutstationServer.tcp('127.0.0.1:0');
  final o = server.addOutstation(
    config: OutstationConfig(
      outstationAddress: 10,
      masterAddress: 1,
      eventBufferConfig: EventBufferConfig(maxAnalog: events),
      unsolicitedBufferSize: 2048,
      solicitedBufferSize: 2048,
    ),
    handlers: handlers,
  );
  o.transaction((tx) {
    for (var i = 0; i < points; i++) {
      tx
        ..addAnalogInput(
          i,
          staticVariation: StaticAnalogInputVariation.group30Var6,
          eventVariation: EventAnalogInputVariation.group32Var6,
        )
        ..updateAnalogInput(i, i.toDouble());
    }
    tx.addBinaryOutputStatus(0);
  });
  final addr = await server.bind();
  final m = MasterChannel.tcpClient(config: const MasterChannelConfig(masterAddress: 1), endpoints: [addr]);
  final a = await m.addAssociation(
    10,
    config: unsolicited
        ? const AssociationConfig(
            startupIntegrityClasses: Classes.none(),
            enableUnsolClasses: EventClasses.all(),
          )
        : const AssociationConfig.quiet(),
  );
  await m.enable();
  while (m.clientState?.state != ClientState.connected) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  return (server, o, m, a);
}

Future<Stats> measure(int n, Future<void> Function() op) async {
  for (var i = 0; i < 20; i++) {
    await op();
  }
  final samples = <double>[];
  for (var i = 0; i < n; i++) {
    final sw = Stopwatch()..start();
    await op();
    samples.add(sw.elapsedMicroseconds.toDouble());
  }
  return Stats(samples);
}

Future<void> benchEndToEnd() async {
  const section = '4. End-to-end over TCP loopback (master and outstation in the same process)';
  final n = quick ? 100 : 1000;
  void row(String name, Stats s) {
    table(section, [name, s.p50.toStringAsFixed(0), s.p99.toStringAsFixed(0), fmt(1e6 / s.mean)]);
    json['e2e_$name'] = {'p50_us': s.p50, 'p99_us': s.p99};
  }

  var (server, o, m, a) = await pair(points: 1000);
  var sink = 0.0;
  row(
    'integrity poll, 1000 analogs (g30v6), decoded',
    await measure(n, () async {
      final f = await a.readWithHandler(const ReadRequest.integrity());
      var acc = 0.0;
      for (final fr in f) {
        for (final b in fr.blocks) {
          if (b is AnalogInputBlock) {
            final n = b.count;
            for (var i = 0; i < n; i++) {
              acc += b.valueAt(i);
            }
          }
        }
      }
      sink += acc;
    }),
  );
  row(
    'read 10 analogs (range)',
    await measure(n, () => a.read(ReadRequest.range(Variation.group30Var6, 0, 9))),
  );
  row(
    'direct operate CROB (accept mode, native)',
    await measure(
      n,
      () => a.operate(CommandSet.crob(0, const Crob.latchOn()), mode: CommandMode.directOperate),
    ),
  );
  row(
    'select-before-operate CROB (accept mode)',
    await measure(n, () => a.operate(CommandSet.crob(0, const Crob.latchOn()))),
  );
  m.destroy();
  server.destroy();

  (server, o, m, a) = await pair(
    points: 10,
    handlers: OutstationHandlers(
      control: const ControlHandlerConfig(mode: ControlMode.callback),
      onControl: (r) => ControlResponse.success,
    ),
  );
  row(
    'direct operate CROB (Dart callback round trip)',
    await measure(
      n,
      () => a.operate(CommandSet.crob(0, const Crob.latchOn()), mode: CommandMode.directOperate),
    ),
  );
  row(
    'select-before-operate CROB (2 Dart callbacks)',
    await measure(n, () => a.operate(CommandSet.crob(0, const Crob.latchOn()))),
  );
  m.destroy();
  server.destroy();
  if (sink.isNaN) stdout.write('');
}

// ---------------------------------------------------------------------------------------
// 5. event throughput
// ---------------------------------------------------------------------------------------

Future<void> benchEventThroughput() async {
  const section = '5. Event throughput outstation → master (unsolicited, TCP loopback)';
  final (server, o, m, a) = await pair(points: 100, events: 10000, unsolicited: true);
  var received = 0;
  a.measurements.listen((f) {
    for (final b in f.blocks) {
      if (b is AnalogInputBlock && b.isEvent) received += b.count;
    }
  });
  await Future<void>.delayed(const Duration(milliseconds: 300));
  received = 0;
  final total = quick ? 20000 : 200000;
  const batch = 1000;
  var v = 0.0;
  final sw = Stopwatch()..start();
  var sent = 0;
  while (sent < total) {
    // keep at most ~5000 events in flight so the buffer never overflows
    if (sent - received > 5000) {
      await Future<void>.delayed(Duration.zero);
      continue;
    }
    o.transaction((tx) {
      for (var i = 0; i < batch; i++) {
        tx.updateAnalogInput(i % 100, v += 1);
      }
    });
    sent += batch;
  }
  while (received < total) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
    if (sw.elapsed > const Duration(seconds: 60)) break;
  }
  sw.stop();
  final perSec = received / sw.elapsedMicroseconds * 1e6;
  table(section, [fmt(received.toDouble(), 0), '${sw.elapsedMilliseconds}', fmt(perSec)]);
  json['events_per_s'] = perSec;
  m.destroy();
  server.destroy();
}

// ---------------------------------------------------------------------------------------
// 6. worker isolate
// ---------------------------------------------------------------------------------------

void Function(MeasurementFragment) _counter(SendPort done, int expected) {
  var n = 0;
  var sum = 0.0;
  return (f) {
    final b = f.blocks.first as AnalogInputBlock;
    for (var i = 0; i < b.count; i++) {
      sum += b.valueAt(i);
    }
    if (++n == expected) done.send(sum);
  };
}

Future<void> benchWorkerIsolate() async {
  const section = '6. Delivery straight into a worker isolate (1000 points per fragment, decoded)';
  final fragments = quick ? 1000 : 10000;
  final done = ReceivePort();
  final worker = await MeasurementWorker.spawn(_counter(done.sendPort, fragments));
  final sw = Stopwatch()..start();
  // fragments (and the completion message, ignored by the worker) go straight to the worker
  check(dnp3_bench_emit(worker.port.nativePort, fragments, 1000, 0));
  await done.first;
  sw.stop();
  final pps = fragments * 1000 / sw.elapsedMicroseconds * 1e6;
  table(section, ['worker isolate', fmt(fragments / sw.elapsedMicroseconds * 1e6), fmt(pps)]);
  json['worker_points_per_s'] = pps;
  worker.close();
}

// ---------------------------------------------------------------------------------------

String render() {
  final headers = {
    '1. Native → Dart delivery of measurement fragments': [
      'points / fragment',
      'transfer',
      'bytes / fragment',
      'fragments / s',
      'points / s',
      'MB / s',
      'µs / fragment',
    ],
    '2. Decoding cost per point (1000 analog inputs per fragment)': ['method', 'ns / point', 'points / s'],
    '3. Outstation database transactions (analog updates with event detection)': [
      'updates / transaction',
      'updates / s',
      'ns / update',
      'transactions / s',
    ],
    '4. End-to-end over TCP loopback (master and outstation in the same process)': [
      'operation',
      'p50 µs',
      'p99 µs',
      'ops / s',
    ],
    '5. Event throughput outstation → master (unsolicited, TCP loopback)': ['events', 'ms', 'events / s'],
    '6. Delivery straight into a worker isolate (1000 points per fragment, decoded)': [
      'receiver',
      'fragments / s',
      'points / s',
    ],
  };
  final b = StringBuffer()
    ..writeln('# dnp3 benchmark results')
    ..writeln()
    ..writeln('- native: `${Dnp3.nativeVersion}`')
    ..writeln('- Dart: `${Platform.version}`')
    ..writeln('- OS: `${Platform.operatingSystem} ${Platform.operatingSystemVersion}`')
    ..writeln('- CPUs: ${Platform.numberOfProcessors}')
    ..writeln('- mode: ${quick ? 'quick' : 'full'}')
    ..writeln();
  for (final MapEntry(key: section, value: data) in rows.entries) {
    final h = headers[section]!;
    b
      ..writeln('## $section')
      ..writeln()
      ..writeln('| ${h.join(' | ')} |')
      ..writeln('|${h.map((_) => '---').join('|')}|');
    for (final r in data) {
      b.writeln('| ${r.join(' | ')} |');
    }
    b.writeln();
  }
  return b.toString();
}
