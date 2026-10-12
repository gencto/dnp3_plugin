/// User-defined reconnect logic for TCP / TLS clients (masters and outstations).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'native/runtime.dart';

/// Information passed to [ConnectionPolicy.next]
final class ConnectContext {
  /// consecutive failed attempts since the last successful connection
  final int failures;

  /// index of the endpoint the native round-robin policy would try next
  final int nextIndex;

  /// configured endpoints
  final List<String> endpoints;

  /// Creates a context (normally done by the library)
  const ConnectContext(this.failures, this.nextIndex, this.endpoints);

  @override
  String toString() => 'ConnectContext(failures: $failures, next: $nextIndex)';
}

/// Decision of a [ConnectionPolicy]
sealed class ConnectDecision {
  /// Base constructor for subclasses
  const ConnectDecision();

  /// Connect to `endpoint` (`host:port` or `ip:port`). Unset options fall back to the
  /// channel configuration.
  const factory ConnectDecision.connect(
    String endpoint, {
    Duration? timeout,
    String? localEndpoint,
    int? masterAddress,
  }) = ConnectTo;

  /// Wait before asking again
  const factory ConnectDecision.wait(Duration delay) = WaitBeforeConnect;
}

/// Decision to connect to [endpoint] now
final class ConnectTo extends ConnectDecision {
  /// `host:port` or `ip:port` to connect to
  final String endpoint;

  /// TCP connect timeout of this attempt; `null` uses the configured connect timeout
  final Duration? timeout;

  /// Local address to bind before connecting; `null` uses the configured one
  final String? localEndpoint;

  /// outstation clients: master address used for this connection
  final int? masterAddress;
  /// See [ConnectDecision.connect]
  const ConnectTo(this.endpoint, {this.timeout, this.localEndpoint, this.masterAddress});
}

/// Decision to wait [delay] before [ConnectionPolicy.next] is called again
final class WaitBeforeConnect extends ConnectDecision {
  /// Time to wait before the next decision is requested
  final Duration delay;

  /// See [ConnectDecision.wait]
  const WaitBeforeConnect(this.delay);
}

/// Decides which endpoint a client connects to and how long it waits between attempts.
///
/// Every method may be asynchronous. If an answer does not arrive within the configured
/// `callbackTimeout` (or a method returns null) the native round-robin / exponential
/// back-off policy decides instead, so a slow or busy isolate never stalls the channel.
abstract class ConnectionPolicy {
  /// Const constructor for subclasses
  const ConnectionPolicy();

  /// Called whenever the client needs a new connection
  FutureOr<ConnectDecision?> next(ConnectContext context) => null;

  /// Called when an established connection is lost; return the delay before reconnecting
  FutureOr<Duration?> disconnected(String address, String? hostname) => null;

  /// How long the native side waits for an answer
  Duration get callbackTimeout => const Duration(seconds: 1);
}

/// Answer a `CONNECTION_REQUEST` (kind 41) from native code
Future<void> handleConnectionRequest(
  ConnectionPolicy? policy,
  List<String> endpoints,
  int token,
  Uint8List data,
) async {
  if (policy == null) {
    NativeRuntime.reply(token, 0);
    return;
  }
  final d = ByteData.sublistView(data);
  try {
    if (data[0] == 0) {
      final ctx = ConnectContext(d.getUint32(4, Endian.little), d.getUint32(8, Endian.little), endpoints);
      final decision = await policy.next(ctx);
      switch (decision) {
        case null:
          NativeRuntime.reply(token, 0);
        case ConnectTo(:final endpoint, :final timeout, :final localEndpoint, :final masterAddress):
          NativeRuntime.reply(
            token,
            1,
            utf8.encode(
              jsonEncode({
                'endpoint': endpoint,
                'timeoutMs': ?timeout?.inMilliseconds,
                'localEndpoint': ?localEndpoint,
                'masterAddress': ?masterAddress,
              }),
            ),
          );
        case WaitBeforeConnect(:final delay):
          NativeRuntime.reply(token, 2, _u64(delay.inMilliseconds));
      }
    } else {
      final len = d.getUint32(4, Endian.little);
      final text = utf8.decode(Uint8List.sublistView(data, 8, 8 + len));
      final sep = text.indexOf('|');
      final host = text.substring(sep + 1);
      final delay = await policy.disconnected(text.substring(0, sep), host.isEmpty ? null : host);
      if (delay == null) {
        NativeRuntime.reply(token, 0);
      } else {
        NativeRuntime.reply(token, 2, _u64(delay.inMilliseconds));
      }
    }
  } catch (_) {
    NativeRuntime.reply(token, 0);
  }
}

Uint8List _u64(int v) => (ByteData(8)..setUint64(0, v, Endian.little)).buffer.asUint8List();
