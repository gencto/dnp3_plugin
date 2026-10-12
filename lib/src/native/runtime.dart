import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../errors.dart';
import 'bindings.dart';
import 'protocol.dart';

/// Receives native messages addressed to one object (master channel, association,
/// outstation, ...). `kind` is the message kind, `b` the sub-type / token and `payload` the
/// message body.
typedef NativeEventHandler = void Function(int kind, int a, int b, Object? payload);

/// Per-isolate gateway to the native library.
///
/// Every isolate that uses the package owns one [NativeRuntime] with its own
/// `RawReceivePort`. The native runtime (tokio thread pool, protocol stacks, object handles)
/// is shared by all isolates of the process, so handles can be passed between isolates.
final class NativeRuntime {
  static NativeRuntime? _current;
  static int _workerThreads = 0;
  static bool _nativeReady = false;

  /// Number of tokio worker threads used when the native runtime is first started
  /// (0 = number of CPU cores). Must be set before first use.
  static set workerThreads(int value) => _workerThreads = value;

  /// The runtime of the current isolate
  static NativeRuntime get current => _current ??= NativeRuntime._();

  static bool get isInitialized => _current != null;

  final RawReceivePort _port;
  final Map<int, Completer<Object?>> _pending = {};
  final Map<int, NativeEventHandler> _targets = {};
  int _nextRequest = 1;
  void Function(int level, String message)? _logHandler;

  NativeRuntime._() : _port = RawReceivePort(null, 'dnp3') {
    ensureNative();
    _port.handler = _onMessage;
    _port.keepIsolateAlive = false;
  }

  /// Load and initialize the native library (process-wide, idempotent)
  static void ensureNative() {
    if (_nativeReady) return;
    final abi = dnp3_abi_version();
    if (abi != abiVersion) {
      throw StateError('native library ABI $abi does not match Dart bindings ABI $abiVersion');
    }
    check(dnp3_init(NativeApi.postCObject.cast()));
    check(dnp3_runtime_start(_workerThreads));
    _nativeReady = true;
  }

  /// Native port of this isolate (used as destination for results and events)
  int get port => _port.sendPort.nativePort;

  /// `SendPort` of this isolate's dispatcher
  SendPort get sendPort => _port.sendPort;

  void _updateKeepAlive() {
    _port.keepIsolateAlive = _pending.isNotEmpty || _targets.isNotEmpty;
  }

  void register(int id, NativeEventHandler handler) {
    _targets[id] = handler;
    _updateKeepAlive();
  }

  void unregister(int id) {
    _targets.remove(id);
    _updateKeepAlive();
  }

  set logHandler(void Function(int level, String message)? h) => _logHandler = h;

  void _onMessage(Object? message) {
    final m = message as List<Object?>;
    final kind = m[0] as int;
    final a = m[1] as int;
    final b = m[2] as int;
    final payload = m[3];
    switch (kind) {
      case Msg.result:
        final c = _pending.remove(a);
        if (_pending.isEmpty) _updateKeepAlive();
        if (c == null) return;
        if (b == ErrorCode.ok) {
          c.complete(payload);
        } else {
          c.completeError(decodeError(b, payload as String? ?? ''));
        }
      case Msg.log:
        _logHandler?.call(a, payload as String);
      case Msg.controlRequest || Msg.applicationRequest || Msg.masterServerRequest:
        // a = reply token, b = object id
        final t = _targets[b];
        if (t != null) {
          t(kind, a, b, payload);
        } else {
          reply(a, 0);
        }
      default:
        _targets[a]?.call(kind, a, b, payload);
    }
  }

  /// Start an asynchronous native operation. `invoke` receives the port and request id
  /// and must return the immediate status code of the native call.
  Future<Object?> call(int Function(int port, int request) invoke) {
    final id = _nextRequest++;
    final rc = invoke(port, id);
    if (rc < 0) return Future.error(lastError(rc));
    final c = Completer<Object?>.sync();
    _pending[id] = c;
    if (_pending.length == 1) _updateKeepAlive();
    return c.future;
  }

  /// Answer a request posted by native code (control, application, server callbacks)
  static void reply(int token, int status, [Uint8List? data]) {
    if (data == null || data.isEmpty) {
      dnp3_reply(token, status, nullptr, 0);
    } else {
      dnp3_reply(token, status, data.address, data.length);
    }
  }

  /// Called after the native runtime was shut down: the next use re-initializes it
  static void markNativeShutdown() => _nativeReady = false;

  /// Close the dispatcher of this isolate. Pending operations fail with [ShutdownException].
  void close() {
    for (final c in _pending.values) {
      c.completeError(const ShutdownException('runtime closed'));
    }
    _pending.clear();
    _targets.clear();
    _port.close();
    if (identical(_current, this)) _current = null;
  }
}

/// Decode an error payload (`"sub|message"`)
Dnp3Exception decodeError(int code, String payload) {
  final sep = payload.indexOf('|');
  final sub = sep > 0 ? int.tryParse(payload.substring(0, sep)) ?? 0 : 0;
  final msg = sep >= 0 ? payload.substring(sep + 1) : payload;
  return Dnp3Exception.fromNative(code, sub, msg);
}

/// Exception for a negative return code of a synchronous native call
Dnp3Exception lastError(int rc) {
  final ptr = dnp3_last_error();
  final msg = ptr == nullptr ? 'native error ${-rc}' : ptr.cast<Utf8>().toDartString();
  return Dnp3Exception.fromNative(-rc, 0, msg);
}

/// Throw if `rc` is negative, return it otherwise
int check(int rc) {
  if (rc < 0) throw lastError(rc);
  return rc;
}

/// UTF-8 encode a string into a Dart-heap buffer (passed to leaf calls via `.address`)
Uint8List utf8Bytes(String s) => utf8.encode(s);

/// Run `f` with a temporary native copy of `s` (for non-leaf calls)
T withNativeString<T>(String s, T Function(Pointer<Uint8> ptr, int len) f) {
  final bytes = utf8.encode(s);
  final ptr = malloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
  try {
    ptr.asTypedList(bytes.length).setAll(0, bytes);
    return f(ptr, bytes.length);
  } finally {
    malloc.free(ptr);
  }
}

/// JSON helper for configuration objects
String toJson(Object? value) => jsonEncode(value);

/// Utility to read the native version string
String nativeVersion_() => dnp3_version().cast<Utf8>().toDartString();
