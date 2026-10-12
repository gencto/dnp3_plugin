import 'dart:async';
import 'dart:math';

import 'package:dnp3/dnp3.dart';
import 'package:flutter/material.dart';

void main() => runApp(const Dnp3App());

class Dnp3App extends StatelessWidget {
  const Dnp3App({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'DNP3',
        theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
        home: const HomePage(),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _endpoint = TextEditingController(text: '127.0.0.1:20000');
  OutstationServer? _server;
  Outstation? _outstation;
  Timer? _simulation;
  MasterChannel? _channel;
  Association? _association;
  ClientStateEvent? _state;
  final _analogs = <int, double>{};
  final _binaries = <int, bool>{};
  final _outputs = <int, bool>{};
  int _fragments = 0;
  String? _error;

  Future<void> _startDemoOutstation() async {
    final server = OutstationServer.tcp('127.0.0.1:20000');
    final outstation = server.addOutstation(
      config: const OutstationConfig(outstationAddress: 1024, masterAddress: 1),
    );
    outstation.transaction((tx) {
      for (var i = 0; i < 8; i++) {
        tx
          ..addAnalogInput(i, staticVariation: StaticAnalogInputVariation.group30Var5)
          ..addBinaryInput(i)
          ..addBinaryOutputStatus(i);
      }
    });
    await server.bind();
    final rnd = Random();
    _simulation = Timer.periodic(const Duration(milliseconds: 500), (_) {
      outstation.transaction((tx) {
        for (var i = 0; i < 8; i++) {
          tx.updateAnalogInput(i, 50 + rnd.nextDouble() * 10, time: Dnp3Time.now());
        }
        tx.updateBinaryInput(rnd.nextInt(8), rnd.nextBool(), time: Dnp3Time.now());
      });
    });
    setState(() {
      _server = server;
      _outstation = outstation;
    });
  }

  Future<void> _connect() async {
    try {
      final channel = MasterChannel.tcpClient(
        config: const MasterChannelConfig(masterAddress: 1),
        endpoints: [_endpoint.text.trim()],
      );
      channel.clientStates.listen((s) => setState(() => _state = s));
      final assoc = await channel.addAssociation(1024);
      // zero-copy decoding straight from the native buffer
      assoc.measurements.listen((f) {
        f.visit(_Collector(this));
        setState(() => _fragments++);
      });
      await assoc.addPoll(const ReadRequest.events(), const Duration(milliseconds: 500));
      await assoc.addPoll(const ReadRequest.integrity(), const Duration(seconds: 10));
      await channel.enable();
      setState(() {
        _channel = channel;
        _association = assoc;
        _error = null;
      });
    } on Dnp3Exception catch (e) {
      setState(() => _error = e.toString());
    }
  }

  Future<void> _toggle(int index) async {
    final assoc = _association;
    if (assoc == null) return;
    final on = !(_outputs[index] ?? false);
    try {
      await assoc.operate(CommandSet.crob(index, on ? const Crob.latchOn() : const Crob.latchOff()));
      await assoc.read(ReadRequest.allObjects(Variation.group10Var0));
    } on Dnp3Exception catch (e) {
      setState(() => _error = e.toString());
    }
  }

  void _disconnect() {
    _channel?.destroy();
    setState(() {
      _channel = null;
      _association = null;
      _state = null;
    });
  }

  @override
  void dispose() {
    _simulation?.cancel();
    _channel?.destroy();
    _server?.destroy();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connected = _channel != null;
    return Scaffold(
      appBar: AppBar(title: Text('DNP3 · ${_state?.state.name ?? 'idle'} · $_fragments fragments')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(children: [
            Expanded(
              child: TextField(
                controller: _endpoint,
                decoration: const InputDecoration(labelText: 'Outstation endpoint'),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: connected ? _disconnect : _connect,
              child: Text(connected ? 'Disconnect' : 'Connect'),
            ),
          ]),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _outstation == null ? _startDemoOutstation : null,
            child: Text(_outstation == null ? 'Start in-app demo outstation' : 'Demo outstation running'),
          ),
          if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
          const Divider(),
          for (final e in (_analogs.entries.toList()..sort((a, b) => a.key - b.key)))
            ListTile(dense: true, title: Text('Analog ${e.key}'), trailing: Text(e.value.toStringAsFixed(2))),
          for (final e in (_binaries.entries.toList()..sort((a, b) => a.key - b.key)))
            ListTile(
              dense: true,
              title: Text('Binary ${e.key}'),
              trailing: Icon(e.value ? Icons.circle : Icons.circle_outlined),
            ),
          for (final e in (_outputs.entries.toList()..sort((a, b) => a.key - b.key)))
            SwitchListTile(
              dense: true,
              title: Text('Output ${e.key} (CROB)'),
              value: e.value,
              onChanged: (_) => _toggle(e.key),
            ),
        ],
      ),
    );
  }
}

class _Collector extends MeasurementVisitor {
  final _HomePageState s;
  _Collector(this.s);

  @override
  void analogInputs(AnalogInputBlock block) {
    for (var i = 0; i < block.count; i++) {
      s._analogs[block.indexAt(i)] = block.valueAt(i);
    }
  }

  @override
  void binaryInputs(BinaryInputBlock block) {
    for (var i = 0; i < block.count; i++) {
      s._binaries[block.indexAt(i)] = block.valueAt(i);
    }
  }

  @override
  void binaryOutputStatuses(BinaryOutputStatusBlock block) {
    for (var i = 0; i < block.count; i++) {
      s._outputs[block.indexAt(i)] = block.valueAt(i);
    }
  }
}
