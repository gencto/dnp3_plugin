/// Master acting as a TCP server: outstations connect to the master.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'config.dart';
import 'master.dart';
import 'native/bindings.dart';
import 'native/protocol.dart';
import 'native/runtime.dart';

/// Decision for an incoming connection based on the remote address only
sealed class AcceptAction {
  /// Base constructor for subclasses
  const AcceptAction();

  /// Reject the connection
  const factory AcceptAction.reject() = _Reject;

  /// Read the first link frame to learn the outstation's DNP3 addresses, then call
  /// [MasterServerHandler.acceptLinkId]
  const factory AcceptAction.identifyByLinkAddress() = _Identify;

  /// Accept with the given channel configuration, then call [MasterServerHandler.start]
  const factory AcceptAction.accept(AcceptConfig config) = _Accept;

  /// JSON reply sent to the native library
  Map<String, Object?> toJson();
}

final class _Reject extends AcceptAction {
  const _Reject();
  @override
  Map<String, Object?> toJson() => {'action': 'reject'};
}

final class _Identify extends AcceptAction {
  const _Identify();
  @override
  Map<String, Object?> toJson() => {'action': 'getLinkIdentity'};
}

final class _Accept extends AcceptAction {
  final AcceptConfig config;
  const _Accept(this.config);
  @override
  Map<String, Object?> toJson() => {'action': 'accept', 'config': config.toJson()};
}

/// Callbacks of a [MasterServer]. All of them may be asynchronous.
abstract class MasterServerHandler {
  /// Const constructor for subclasses
  const MasterServerHandler();

  /// Called for every accepted TCP connection
  FutureOr<AcceptAction> accept(String remoteAddress);

  /// Called after `accept` returned [AcceptAction.accept]. Add associations to `channel`
  /// and enable it; the server waits until the returned future completes.
  FutureOr<void> start(MasterChannel channel, String remoteAddress);

  /// Called after the link identity was read. Return null to reject.
  FutureOr<AcceptConfig?> acceptLinkId(String remoteAddress, int source, int destination) => null;

  /// Like [start], for connections identified by link address
  FutureOr<void> startWithLinkId(MasterChannel channel, String remoteAddress, int source, int destination) =>
      start(channel, remoteAddress);

  /// Called after the TCP session of an accepted channel ended. The channel has already
  /// been destroyed and removed from [MasterServer.channels].
  void closed(MasterChannel channel, String remoteAddress) {}
}

/// A master that listens for TCP connections initiated by outstations
final class MasterServer {
  /// Native handle of the server
  final int handle;

  /// Address the server is bound to (`ip:port`, with the actual port when bound to port 0)
  final String localAddress;
  final NativeRuntime _rt;
  final MasterServerHandler _handler;
  final _channels = <MasterChannel>[];
  bool _destroyed = false;

  MasterServer._(this.handle, this.localAddress, this._rt, this._handler) {
    // on runtime close the channels are released through their own registrations
    _rt.register(handle, _onRequest, _channels.clear);
  }

  /// Channels created for accepted connections
  List<MasterChannel> get channels => List.unmodifiable(_channels);

  /// Listen on `address` (`ip:port`); [handler] decides for every incoming connection.
  ///
  /// [callbackTimeout] bounds each [handler] callback; on expiry the connection is rejected.
  static Future<MasterServer> bind(
    String address,
    MasterServerHandler handler, {
    LinkIdConfig linkIdConfig = const LinkIdConfig(),
    Duration callbackTimeout = const Duration(seconds: 5),
  }) async {
    final rt = NativeRuntime.current;
    final json = toJson({
      'address': address,
      'linkIdConfig': linkIdConfig.toJson(),
      'callbackTimeoutMs': callbackTimeout.inMilliseconds,
    });
    // A connection accepted before this isolate has processed the creation result is
    // rejected (no handler registered yet); the outstation simply reconnects.
    final result =
        await rt.call(
              (p, r) =>
                  withNativeString(json, (ptr, len) => dnp3_master_server_create(ptr, len, rt.port, p, r)),
            )
            as String;
    final sep = result.indexOf('|');
    final id = int.parse(result.substring(0, sep));
    return MasterServer._(id, result.substring(sep + 1), rt, handler);
  }

  Future<void> _onRequest(int kind, int token, int b, Object? payload) async {
    if (kind != Msg.masterServerRequest) return;
    final data = payload as Uint8List;
    final d = ByteData.sublistView(data);
    final type = d.getUint8(0);
    final source = d.getUint16(2, Endian.little);
    final destination = d.getUint16(4, Endian.little);
    final channelId = d.getUint64(8, Endian.little);
    final len = d.getUint32(16, Endian.little);
    final addr = utf8.decode(Uint8List.sublistView(data, 20, 20 + len));
    try {
      switch (type) {
        case 0:
          final action = await _handler.accept(addr);
          NativeRuntime.reply(token, 1, utf8.encode(jsonEncode(action.toJson())));
        case 1:
          await _start(channelId, (ch) => _handler.start(ch, addr));
          NativeRuntime.reply(token, 1);
        case 2:
          final cfg = await _handler.acceptLinkId(addr, source, destination);
          if (cfg == null) {
            NativeRuntime.reply(token, 0);
          } else {
            NativeRuntime.reply(token, 1, utf8.encode(jsonEncode(cfg.toJson())));
          }
        case 3:
          await _start(channelId, (ch) => _handler.startWithLinkId(ch, addr, source, destination));
          NativeRuntime.reply(token, 1);
        case 4:
          // session ended; the native side already released the channel (no reply)
          final i = _channels.indexWhere((c) => c.handle == channelId);
          if (i < 0) return;
          final ch = _channels.removeAt(i)..destroy();
          _handler.closed(ch, addr);
          return;
      }
    } catch (_) {
      NativeRuntime.reply(token, 0);
    }
  }

  /// Run a start callback for a newly adopted channel; the channel is destroyed again if
  /// the callback fails
  Future<void> _start(int channelId, FutureOr<void> Function(MasterChannel channel) start) async {
    final ch = MasterChannel.adopt(channelId);
    _channels.add(ch);
    try {
      await start(ch);
    } catch (_) {
      _channels.remove(ch);
      ch.destroy();
      rethrow;
    }
  }

  /// Stop listening and shut down every accepted channel
  void destroy() {
    if (_destroyed) return;
    _destroyed = true;
    _rt.unregister(handle);
    for (final c in _channels) {
      c.destroy();
    }
    _channels.clear();
    dnp3_master_server_destroy(handle);
  }
}
