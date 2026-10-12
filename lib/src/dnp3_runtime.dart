/// Process / isolate level setup: native runtime, logging, diagnostics.
library;

import 'package:logging/logging.dart';

import 'native/bindings.dart';
import 'native/runtime.dart';

/// Log verbosity of the native library
enum Dnp3LogLevel {
  /// logging disabled
  off,

  /// errors only
  error,

  /// warnings and errors
  warn,

  /// informational messages and above
  info,

  /// debug messages and above
  debug,

  /// everything, including trace messages
  trace,
}

/// Entry point for global configuration. Calling these methods is optional: the native
/// library is initialized lazily on first use.
abstract final class Dnp3 {
  /// Logger receiving the native log output (when enabled with [enableLogging])
  static final Logger logger = Logger('dnp3');

  /// Configure the number of native worker threads (0 = one per CPU core). Must be called
  /// before any other API in the process.
  static void initialize({int workerThreads = 0}) {
    NativeRuntime.workerThreads = workerThreads;
    NativeRuntime.current;
  }

  /// Version of the native bridge and of the underlying `dnp3` crate
  static String get nativeVersion {
    NativeRuntime.ensureNative();
    return nativeVersionString();
  }

  /// Forward native log records to [logger] (in the calling isolate).
  ///
  /// Use `DecodeLevel` on channels / outstations to log protocol traffic.
  static void enableLogging({Dnp3LogLevel level = Dnp3LogLevel.info, bool withTarget = false}) {
    final rt = NativeRuntime.current;
    rt.logHandler = (lvl, message) => logger.log(_level(lvl), message);
    rt.register(-1, (_, _, _, _) {}); // keep the isolate alive while logging is enabled
    check(dnp3_logging_init(rt.port, level.index, withTarget ? 1 : 0));
  }

  /// Change the native log level after [enableLogging]
  static void setLogLevel(Dnp3LogLevel level) => dnp3_logging_set_level(level.index);

  /// Stop forwarding native log records and set the native level to [Dnp3LogLevel.off]
  static void disableLogging() {
    final rt = NativeRuntime.current;
    dnp3_logging_set_level(0);
    rt.logHandler = null;
    rt.unregister(-1);
  }

  /// Payloads at least this large are moved into the Dart heap without copying
  /// (external typed data); smaller payloads are copied into the young generation, which
  /// the benchmarks show is cheaper below ~100 KB. Default: 128 KiB. Use 0 to always
  /// transfer without copying.
  static set zeroCopyThreshold(int bytes) => dnp3_set_external_threshold(bytes);

  /// Disable Nagle's algorithm being turned off (TCP_NODELAY is enabled by default)
  static void disableTcpNoDelay({bool client = true, bool server = true}) =>
      dnp3_disable_tcp_no_delay(client ? 1 : 0, server ? 1 : 0);

  /// Number of live native objects: (masters, associations, polls, outstations)
  static (int, int, int, int) get objectCounts => (
    dnp3_debug_object_count(0),
    dnp3_debug_object_count(1),
    dnp3_debug_object_count(2),
    dnp3_debug_object_count(3),
  );

  /// Close this isolate's dispatcher port. Objects created in this isolate stop delivering
  /// events here.
  static void closeIsolate() {
    if (NativeRuntime.isInitialized) NativeRuntime.current.close();
  }

  /// Shut down every native object and the native thread pool of the process
  static void shutdown({Duration timeout = const Duration(seconds: 1)}) {
    closeIsolate();
    dnp3_runtime_shutdown(timeout.inMilliseconds);
    NativeRuntime.markNativeShutdown();
  }

  static Level _level(int l) => switch (l) {
    1 => Level.SEVERE,
    2 => Level.WARNING,
    3 => Level.INFO,
    4 => Level.FINE,
    _ => Level.FINEST,
  };
}
