/// DNP3 outstation: creation on every transport, TCP/TLS servers, callbacks and events.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'config.dart';
import 'database.dart';
import 'master.dart' show ClientEvents;
import 'measurements.dart';
import 'native/bindings.dart';
import 'native/protocol.dart';
import 'native/runtime.dart';
import 'requests.dart';
import 'types.dart';

// ---------------------------------------------------------------------------------------
// control requests (callback mode)
// ---------------------------------------------------------------------------------------

enum ControlPhase { select, operate }

/// How the master requested the operation
enum OperateType { selectBeforeOperate, directOperate, directOperateNoAck }

/// A SELECT or OPERATE of one control point
final class ControlRequest {
  final ControlPhase phase;

  /// null for SELECT
  final OperateType? operateType;
  final int index;

  /// [Crob] or [AnalogOutput]
  final Object command;

  /// status (only meaningful for executed-control notifications)
  final CommandStatus status;

  const ControlRequest(this.phase, this.operateType, this.index, this.command, this.status);

  bool get isCrob => command is Crob;
  Crob get crob => command as Crob;
  AnalogOutput get analog => command as AnalogOutput;

  static ControlRequest decode(Uint8List data) {
    final d = ByteData.sublistView(data);
    final phase = d.getUint8(0) == 0 ? ControlPhase.select : ControlPhase.operate;
    final op = d.getUint8(1);
    final type = d.getUint8(2);
    final status = CommandStatus.fromCode(d.getUint8(3));
    final index = d.getUint16(4, Endian.little);
    final Object command;
    if (type == 0) {
      command = Crob(
        ControlCode.fromByte(d.getUint8(8)),
        count: d.getUint8(9),
        onTimeMs: d.getUint32(12, Endian.little),
        offTimeMs: d.getUint32(16, Endian.little),
      );
    } else {
      final v = d.getFloat64(8, Endian.little);
      command = switch (type) {
        1 => AnalogOutputInt32(v.toInt()),
        2 => AnalogOutputInt16(v.toInt()),
        3 => AnalogOutputFloat32(v),
        _ => AnalogOutputDouble64(v),
      };
    }
    return ControlRequest(phase, op < 3 ? OperateType.values[op] : null, index, command, status);
  }

  @override
  String toString() => 'ControlRequest($phase, $operateType, index: $index, $command)';
}

/// Answer to a control request in callback mode. Database operations recorded in
/// [database] are applied atomically by the protocol thread before the response is sent.
final class ControlResponse {
  final CommandStatus status;
  final DatabaseTransaction? database;
  const ControlResponse(this.status, [this.database]);
  static const success = ControlResponse(CommandStatus.success);
  static const notSupported = ControlResponse(CommandStatus.notSupported);
}

typedef ControlCallback = FutureOr<ControlResponse> Function(ControlRequest request);

/// Freeze request received by an outstation with [FreezeMode.callback]
final class FreezeRequest {
  /// null = all counters
  final (int, int)? range;
  final bool clear;

  /// set for FREEZE_AT_TIME
  final Dnp3Time? time;
  final int intervalMs;
  final bool atTime;

  const FreezeRequest(this.range, this.clear, this.atTime, this.time, this.intervalMs);

  static FreezeRequest decode(Uint8List data) {
    final d = ByteData.sublistView(data);
    final all = d.getUint8(1) == 0;
    final ft = d.getUint8(2);
    return FreezeRequest(
      all ? null : (d.getUint16(4, Endian.little), d.getUint16(6, Endian.little)),
      ft == 1,
      ft == 2,
      ft == 2 ? Dnp3Time(d.getUint64(8, Endian.little)) : null,
      d.getUint32(16, Endian.little),
    );
  }

  @override
  String toString() => 'FreezeRequest(range: $range, clear: $clear, atTime: $atTime)';
}

enum RequestResult { ok, parameterError, notSupported }

sealed class RestartDelay {
  const RestartDelay();
  const factory RestartDelay.seconds(int value) = _Seconds;
  const factory RestartDelay.milliseconds(int value) = _Millis;
  int get _status;
  int get _value;
}

final class _Seconds extends RestartDelay {
  final int value;
  const _Seconds(this.value);
  @override
  int get _status => 1;
  @override
  int get _value => value;
}

final class _Millis extends RestartDelay {
  final int value;
  const _Millis(this.value);
  @override
  int get _status => 2;
  @override
  int get _value => value;
}

/// Callbacks for the application modes configured as `callback` in [ApplicationConfig]
abstract class OutstationApplication {
  const OutstationApplication();

  FutureOr<RequestResult> writeAbsoluteTime(Dnp3Time time) => RequestResult.notSupported;
  FutureOr<RestartDelay?> coldRestart() => null;
  FutureOr<RestartDelay?> warmRestart() => null;

  /// Return the result and (optionally) database operations to apply atomically
  FutureOr<(RequestResult, DatabaseTransaction?)> freeze(FreezeRequest request) =>
      (RequestResult.notSupported, null);

  /// Return true to accept the attribute write
  FutureOr<bool> writeAttribute(DeviceAttribute attribute) => true;
}

// ---------------------------------------------------------------------------------------
// notifications
// ---------------------------------------------------------------------------------------

sealed class OutstationEvent {
  const OutstationEvent();
}

/// A control executed in [ControlMode.accept]
final class ControlExecuted extends OutstationEvent {
  final ControlRequest request;
  const ControlExecuted(this.request);
  @override
  String toString() => 'ControlExecuted($request)';
}

final class TimeWritten extends OutstationEvent {
  final Dnp3Time time;
  const TimeWritten(this.time);
  @override
  String toString() => 'TimeWritten($time)';
}

final class DeadBandsWritten extends OutstationEvent {
  final Map<int, double> deadBands;
  const DeadBandsWritten(this.deadBands);
  @override
  String toString() => 'DeadBandsWritten($deadBands)';
}

final class AttributeWritten extends OutstationEvent {
  final DeviceAttribute attribute;
  const AttributeWritten(this.attribute);
  @override
  String toString() => 'AttributeWritten($attribute)';
}

final class CountersFrozen extends OutstationEvent {
  final FreezeRequest request;
  const CountersFrozen(this.request);
  @override
  String toString() => 'CountersFrozen($request)';
}

final class RestartRequested extends OutstationEvent {
  final bool cold;
  const RestartRequested(this.cold);
  @override
  String toString() => 'RestartRequested(cold: $cold)';
}

/// The master confirmed events (requires `notifyConfirm`)
final class EventsConfirmed extends OutstationEvent {
  final List<int> clearedEventIds;
  final int remainingClass1;
  final int remainingClass2;
  final int remainingClass3;

  /// remaining events per type: binary, doubleBit, binaryOutputStatus, counter,
  /// frozenCounter, analog, analogOutputStatus, octetString
  final List<int> remainingByType;

  const EventsConfirmed(
    this.clearedEventIds,
    this.remainingClass1,
    this.remainingClass2,
    this.remainingClass3,
    this.remainingByType,
  );

  @override
  String toString() =>
      'EventsConfirmed(${clearedEventIds.length} cleared, '
      'remaining: $remainingClass1/$remainingClass2/$remainingClass3)';
}

enum OutstationInfoType {
  processRequestFromIdle,
  broadcastReceived,
  enterSolicitedConfirmWait,
  solicitedConfirmTimeout,
  solicitedConfirmReceived,
  solicitedConfirmWaitNewRequest,
  wrongSolicitedConfirmSeq,
  unexpectedConfirm,
  enterUnsolicitedConfirmWait,
  unsolicitedConfirmTimeout,
  unsolicitedConfirmed,
  clearRestartIin,
}

/// `OutstationInformation` callbacks (enable with `information: true`)
final class OutstationInfo {
  final OutstationInfoType type;

  /// packed value; see the accessors
  final int raw;
  const OutstationInfo(this.type, this.raw);

  /// function code for processRequestFromIdle / broadcastReceived
  FunctionCode? get functionCode => FunctionCode.fromCode(raw & 0xFF);

  /// sequence number (ecsn) for confirm related events
  int get sequence => raw & 0xFF;

  /// second sequence number (wrongSolicitedConfirmSeq) / unexpectedConfirm seq
  int get otherSequence => (raw >> 8) & 0xFF;

  /// unsolicitedConfirmTimeout: whether a retry follows
  bool get retry => (raw >> 8) & 1 != 0;

  @override
  String toString() => 'OutstationInfo($type, 0x${raw.toRadixString(16)})';
}

// ---------------------------------------------------------------------------------------
// outstation
// ---------------------------------------------------------------------------------------

/// Bundle of the handler configuration passed to every outstation factory
final class OutstationHandlers {
  final ControlHandlerConfig control;
  final ApplicationConfig application;

  /// forward `OutstationInformation` callbacks to [Outstation.information]
  final bool information;

  /// required when `control.mode` is [ControlMode.callback]
  final ControlCallback? onControl;

  /// required when any application mode is `callback`
  final OutstationApplication? applicationCallbacks;

  const OutstationHandlers({
    this.control = const ControlHandlerConfig(),
    this.application = const ApplicationConfig(),
    this.information = false,
    this.onControl,
    this.applicationCallbacks,
  });

  Map<String, Object?> toJson() => {
    'control': control.toJson(),
    'application': application.toJson(),
    'information': information,
  };
}

/// A DNP3 outstation
final class Outstation with ClientEvents {
  /// Opaque native handle (usable from any isolate, see [Outstation.attach])
  final int handle;
  final NativeRuntime _rt;
  final bool _owned;
  final OutstationHandlers? _handlers;
  late final Database database = Database(handle);
  bool _destroyed = false;

  final _events = StreamController<OutstationEvent>.broadcast();
  final _info = StreamController<OutstationInfo>.broadcast();
  final _connection = StreamController<ConnectionState>.broadcast();

  Outstation._(this.handle, this._rt, this._owned, this._handlers) {
    if (_owned) _rt.register(handle, _onEvent);
  }

  static Outstation _create(
    OutstationConfig config,
    OutstationHandlers handlers,
    Map<String, Object?> transport,
  ) {
    final rt = NativeRuntime.current;
    final json = toJson({'config': config.toJson(), 'handlers': handlers.toJson(), 'transport': transport});
    final id = withNativeString(json, (p, l) => dnp3_outstation_create(p, l, rt.port));
    return Outstation._(check(id), rt, true, handlers);
  }

  /// Outstation that connects to a master acting as a TCP server
  factory Outstation.tcpClient({
    required OutstationConfig config,
    required List<String> endpoints,
    OutstationHandlers handlers = const OutstationHandlers(),
    LinkErrorMode linkErrorMode = LinkErrorMode.close,
    ConnectStrategy connectStrategy = const ConnectStrategy(),
    ConnectOptions connectOptions = const ConnectOptions(),
  }) => _create(config, handlers, {
    'type': 'tcpClient',
    'endpoints': endpoints,
    'linkErrorMode': linkErrorMode.name,
    'connectStrategy': connectStrategy.toJson(),
    'connectOptions': connectOptions.toJson(),
  });

  factory Outstation.tlsClient({
    required OutstationConfig config,
    required List<String> endpoints,
    required TlsConfig tls,
    OutstationHandlers handlers = const OutstationHandlers(),
    LinkErrorMode linkErrorMode = LinkErrorMode.close,
    ConnectStrategy connectStrategy = const ConnectStrategy(),
    ConnectOptions connectOptions = const ConnectOptions(),
  }) => _create(config, handlers, {
    'type': 'tlsClient',
    'endpoints': endpoints,
    'linkErrorMode': linkErrorMode.name,
    'connectStrategy': connectStrategy.toJson(),
    'connectOptions': connectOptions.toJson(),
    'tls': tls.toJson(),
  });

  /// Serial outstation. With `retry` the port is re-opened after failures (fault tolerant).
  factory Outstation.serial({
    required OutstationConfig config,
    required String path,
    SerialSettings settings = const SerialSettings(),
    RetryStrategy? retry,
    OutstationHandlers handlers = const OutstationHandlers(),
  }) => _create(config, handlers, {
    'type': 'serial',
    'path': path,
    'settings': settings.toJson(),
    if (retry != null) 'retry': retry.toJson(),
  });

  factory Outstation.udp({
    required OutstationConfig config,
    required String localEndpoint,
    required String remoteEndpoint,
    bool oneToMany = false,
    LinkReadMode linkReadMode = LinkReadMode.datagram,
    Duration retryDelay = const Duration(seconds: 1),
    OutstationHandlers handlers = const OutstationHandlers(),
  }) => _create(config, handlers, {
    'type': 'udp',
    'localEndpoint': localEndpoint,
    'remoteEndpoint': remoteEndpoint,
    'socketMode': oneToMany ? 'oneToMany' : 'oneToOne',
    'linkReadMode': linkReadMode.name,
    'retryDelayMs': retryDelay.inMilliseconds,
  });

  /// Access an outstation created in another isolate (database, enable/disable, ...)
  factory Outstation.attach(int handle) => Outstation._(handle, NativeRuntime.current, false, null);

  /// Notifications (executed controls, time writes, confirms, ...)
  Stream<OutstationEvent> get events => _events.stream;

  /// OutstationInformation callbacks
  Stream<OutstationInfo> get information => _info.stream;

  /// Connection state for outstations attached to an [OutstationServer]
  Stream<ConnectionState> get connectionStates => _connection.stream;

  void _onEvent(int kind, int a, int b, Object? payload) {
    switch (kind) {
      case Msg.controlRequest:
        _handleControl(a, payload as Uint8List);
      case Msg.applicationRequest:
        _handleApplication(a, payload as Uint8List);
      case Msg.outstationEvent:
        final e = _decodeEvent(b, payload);
        if (e != null) _events.add(e);
      case Msg.outstationInfo:
        _info.add(OutstationInfo(OutstationInfoType.values[b.clamp(0, 11)], payload as int));
      case Msg.connectionState:
        _connection.add(b == 1 ? ConnectionState.connected : ConnectionState.disconnected);
      default:
        handleClientEvent(kind, b, payload);
    }
  }

  void _handleControl(int token, Uint8List data) {
    final cb = _handlers?.onControl;
    if (cb == null) {
      NativeRuntime.reply(token, CommandStatus.notSupported.code);
      return;
    }
    final req = ControlRequest.decode(data);
    void send(ControlResponse r) => NativeRuntime.reply(token, r.status.code, r.database?.bytes);
    try {
      final res = cb(req);
      if (res is ControlResponse) {
        send(res);
      } else {
        res.then(send, onError: (Object _) => NativeRuntime.reply(token, CommandStatus.hardwareError.code));
      }
    } catch (_) {
      NativeRuntime.reply(token, CommandStatus.hardwareError.code);
    }
  }

  Future<void> _handleApplication(int token, Uint8List data) async {
    final app = _handlers?.applicationCallbacks;
    final type = data[0];
    try {
      switch (type) {
        case 1: // write time
          final t = ByteData.sublistView(data).getUint64(8, Endian.little);
          final r = await (app?.writeAbsoluteTime(Dnp3Time(t)) ?? RequestResult.notSupported);
          NativeRuntime.reply(token, r.index);
        case 2 || 3: // cold / warm restart
          final d = await (type == 2 ? app?.coldRestart() : app?.warmRestart());
          if (d == null) {
            NativeRuntime.reply(token, 0);
          } else {
            final b = ByteData(2)..setUint16(0, d._value, Endian.little);
            NativeRuntime.reply(token, d._status, b.buffer.asUint8List());
          }
        case 4: // freeze
          if (app == null) {
            NativeRuntime.reply(token, RequestResult.notSupported.index);
          } else {
            final (RequestResult r, DatabaseTransaction? tx) = await app.freeze(FreezeRequest.decode(data));
            NativeRuntime.reply(token, r.index, tx?.bytes);
          }
        case 5: // write attribute
          final (attr, _) = decodeAttribute(ByteData.sublistView(data), 8);
          final ok = await (app?.writeAttribute(attr) ?? true);
          NativeRuntime.reply(token, ok ? 1 : 0);
        default:
          NativeRuntime.reply(token, 2);
      }
    } catch (_) {
      NativeRuntime.reply(token, type == 5 ? 0 : 2);
    }
  }

  static OutstationEvent? _decodeEvent(int type, Object? payload) {
    switch (type) {
      case 0:
        return ControlExecuted(ControlRequest.decode(payload as Uint8List));
      case 1:
        return TimeWritten(Dnp3Time(payload as int));
      case 2:
        final data = payload as Uint8List;
        final d = ByteData.sublistView(data);
        return DeadBandsWritten({
          for (var o = 0; o + 16 <= data.length; o += 16)
            d.getUint16(o, Endian.little): d.getFloat64(o + 8, Endian.little),
        });
      case 3:
        return AttributeWritten(decodeAttribute(ByteData.sublistView(payload as Uint8List), 0).$1);
      case 4:
        final data = payload as Uint8List;
        final d = ByteData.sublistView(data);
        final counts = [for (var i = 0; i < 11; i++) d.getUint32(i * 4, Endian.little)];
        final n = d.getUint32(44, Endian.little);
        return EventsConfirmed(
          [for (var i = 0; i < n; i++) d.getUint64(48 + i * 8, Endian.little)],
          counts[0],
          counts[1],
          counts[2],
          counts.sublist(3),
        );
      case 5:
        return CountersFrozen(FreezeRequest.decode(payload as Uint8List));
      case 6:
        return RestartRequested(payload == 1);
    }
    return null;
  }

  // ---------------------------------------------------------------- operations

  /// Atomically apply database operations. See [DatabaseTransaction].
  int transaction(void Function(DatabaseTransaction tx) build) => database.transaction(build);

  Future<void> enable() => _rt.call((p, r) => dnp3_outstation_enable(handle, 1, p, r));

  Future<void> disable() => _rt.call((p, r) => dnp3_outstation_enable(handle, 0, p, r));

  Future<void> setDecodeLevel(DecodeLevel level) {
    final json = utf8Bytes(toJson(level.toJson()));
    return _rt.call((p, r) => dnp3_outstation_set_decode_level(handle, json.address, json.length, p, r));
  }

  /// Application-controlled IIN bits reported in every response
  void setApplicationIin({
    bool needTime = false,
    bool localControl = false,
    bool deviceTrouble = false,
    bool configCorrupt = false,
  }) {
    final bits =
        (needTime ? 1 : 0) | (localControl ? 2 : 0) | (deviceTrouble ? 4 : 0) | (configCorrupt ? 8 : 0);
    check(dnp3_outstation_set_application_iin(handle, bits));
  }

  /// Processing delay reported in non-LAN time synchronization (g52v2)
  void setProcessingDelay(int milliseconds) =>
      check(dnp3_outstation_set_processing_delay(handle, milliseconds));

  /// Shut down the outstation (client / serial / UDP outstations stop immediately;
  /// server outstations stop when their server is destroyed)
  void destroy() {
    if (_destroyed) return;
    _destroyed = true;
    if (_owned) {
      _rt.unregister(handle);
      _events.close();
      _info.close();
      _connection.close();
      closeClientEvents();
    }
    dnp3_outstation_destroy(handle);
  }
}

/// A TCP or TLS server hosting one or more outstations (distinguished by master IP)
final class OutstationServer {
  final int handle;
  final NativeRuntime _rt;
  final _outstations = <Outstation>[];
  String? _localAddress;

  OutstationServer._(this.handle, this._rt);

  static OutstationServer _create(Map<String, Object?> json) {
    final id = withNativeString(toJson(json), (p, l) => dnp3_outstation_server_create(p, l));
    return OutstationServer._(check(id), NativeRuntime.current);
  }

  /// TCP server listening on `address`, e.g. `0.0.0.0:20000`
  factory OutstationServer.tcp(String address, {LinkErrorMode linkErrorMode = LinkErrorMode.close}) =>
      _create({'type': 'tcp', 'address': address, 'linkErrorMode': linkErrorMode.name});

  factory OutstationServer.tls(
    String address,
    TlsConfig tls, {
    LinkErrorMode linkErrorMode = LinkErrorMode.close,
  }) =>
      _create({'type': 'tls', 'address': address, 'linkErrorMode': linkErrorMode.name, 'tls': tls.toJson()});

  /// Add an outstation. Must be called before [bind].
  Outstation addOutstation({
    required OutstationConfig config,
    OutstationHandlers handlers = const OutstationHandlers(),
    AddressFilter filter = const AddressFilter.any(),
  }) {
    final json = toJson({
      'config': config.toJson(),
      'handlers': handlers.toJson(),
      'filter': filter.toJson(),
    });
    final id = withNativeString(
      json,
      (p, l) => dnp3_outstation_server_add_outstation(handle, p, l, _rt.port),
    );
    final o = Outstation._(check(id), _rt, true, handlers);
    _outstations.add(o);
    return o;
  }

  /// Start accepting connections. Returns the bound local address (useful with port 0).
  Future<String> bind() async {
    final addr = await _rt.call((p, r) => dnp3_outstation_server_bind(handle, p, r)) as String;
    _localAddress = addr;
    return addr;
  }

  String? get localAddress => _localAddress;

  /// Stop the server and all of its outstations
  void destroy() {
    for (final o in _outstations) {
      o._destroyed = true;
      _rt.unregister(o.handle);
      o._events.close();
      o._info.close();
      o._connection.close();
      o.closeClientEvents();
    }
    _outstations.clear();
    dnp3_outstation_server_destroy(handle);
  }
}
