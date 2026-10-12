/// Configuration objects. They serialize to the JSON understood by native/src/config.rs.
library;

import 'types.dart';

/// Application-layer decoding written to the log
enum AppDecodeLevel {
  /// nothing is decoded
  nothing,

  /// function code and IIN bits only
  header,

  /// function code, IIN bits and object headers
  objectHeaders,

  /// function code, IIN bits, object headers and object values
  objectValues,
}

/// Transport-layer decoding written to the log
enum TransportDecodeLevel {
  /// nothing is decoded
  nothing,

  /// transport header (FIR / FIN / sequence) only
  header,

  /// transport header and segment payload
  payload,
}

/// Link-layer decoding written to the log
enum LinkDecodeLevel {
  /// nothing is decoded
  nothing,

  /// link header (function, addresses) only
  header,

  /// link header and frame payload
  payload,
}

/// Physical-layer (raw I/O) logging
enum PhysDecodeLevel {
  /// nothing is logged
  nothing,

  /// number of bytes read / written
  length,

  /// number of bytes and a hex dump of the data
  data,
}

/// Controls protocol decoding written to the log
final class DecodeLevel {
  /// Application-layer decoding
  final AppDecodeLevel application;

  /// Transport-layer decoding
  final TransportDecodeLevel transport;

  /// Link-layer decoding
  final LinkDecodeLevel link;

  /// Physical-layer (raw bytes) logging
  final PhysDecodeLevel physical;

  /// Per-layer decode levels; every layer defaults to `nothing`
  const DecodeLevel({
    this.application = AppDecodeLevel.nothing,
    this.transport = TransportDecodeLevel.nothing,
    this.link = LinkDecodeLevel.nothing,
    this.physical = PhysDecodeLevel.nothing,
  });

  /// No decoding on any layer
  const DecodeLevel.nothing() : this();

  /// Application-layer object values (most useful for debugging)
  const DecodeLevel.objectValues() : this(application: AppDecodeLevel.objectValues);

  /// JSON representation expected by the native library
  Map<String, Object?> toJson() => {
    'application': application.name,
    'transport': transport.name,
    'link': link.name,
    'physical': physical.name,
  };

  /// Parses the JSON produced by [toJson] (or reported by the native library)
  factory DecodeLevel.fromJson(Map<String, Object?> json) => DecodeLevel(
    application: AppDecodeLevel.values.byName(json['application'] as String),
    transport: TransportDecodeLevel.values.byName(json['transport'] as String),
    link: LinkDecodeLevel.values.byName(json['link'] as String),
    physical: PhysDecodeLevel.values.byName(json['physical'] as String),
  );

  @override
  String toString() => 'DecodeLevel(${application.name}, ${transport.name}, ${link.name}, ${physical.name})';
}

/// What to do when a malformed link frame is received on a stream
enum LinkErrorMode {
  /// close the connection
  close,

  /// discard bytes and resynchronize
  discard,
}

/// How link frames are read from UDP
enum LinkReadMode {
  /// each datagram must contain whole link frames (as required by the standard)
  datagram,

  /// frames may span datagrams (non-conformant peers)
  stream,
}

/// Exponential back-off between retries of failed automatic tasks
final class RetryStrategy {
  /// First retry delay; doubles on each failure up to [maxDelay]
  final Duration minDelay;

  /// Upper bound of the retry delay
  final Duration maxDelay;

  /// Defaults: 1 s doubling up to 10 s
  const RetryStrategy({
    this.minDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 10),
  });

  /// JSON representation expected by the native library
  Map<String, Object?> toJson() => {
    'minDelayMs': minDelay.inMilliseconds,
    'maxDelayMs': maxDelay.inMilliseconds,
  };
}

/// Reconnect behaviour of TCP/TLS clients
final class ConnectStrategy {
  /// Delay after the first failed connection attempt; doubles up to [maxConnectDelay]
  final Duration minConnectDelay;

  /// Upper bound of the delay between failed connection attempts
  final Duration maxConnectDelay;

  /// Delay before reconnecting after an established connection is lost
  final Duration reconnectDelay;

  /// Defaults: 1 s doubling up to 10 s between attempts, 1 s after a disconnect
  const ConnectStrategy({
    this.minConnectDelay = const Duration(seconds: 1),
    this.maxConnectDelay = const Duration(seconds: 10),
    this.reconnectDelay = const Duration(seconds: 1),
  });

  /// JSON representation expected by the native library
  Map<String, Object?> toJson() => {
    'minConnectDelayMs': minConnectDelay.inMilliseconds,
    'maxConnectDelayMs': maxConnectDelay.inMilliseconds,
    'reconnectDelayMs': reconnectDelay.inMilliseconds,
  };
}

/// Socket options of TCP/TLS client connection attempts
final class ConnectOptions {
  /// local address to bind before connecting, e.g. `192.168.0.10:0`
  final String? localEndpoint;

  /// Timeout of a single TCP connect attempt; `null` uses the OS default
  final Duration? connectTimeout;

  /// Both options unset by default
  const ConnectOptions({this.localEndpoint, this.connectTimeout});

  /// JSON representation expected by the native library
  Map<String, Object?> toJson() => {
    if (localEndpoint != null) 'localEndpoint': localEndpoint,
    if (connectTimeout != null) 'connectTimeoutMs': connectTimeout!.inMilliseconds,
  };
}

/// How the peer certificate of a TLS connection is verified
enum TlsMode {
  /// full PKI: the peer certificate is validated against an authority
  authority,

  /// the peer must present exactly the configured self-signed certificate
  selfSigned,
}

/// Minimum TLS protocol version accepted during the handshake
enum MinTlsVersion {
  /// allow TLS 1.2 and TLS 1.3
  v12,

  /// TLS 1.3 only
  v13,
}

/// TLS settings of a client or server (PEM files)
final class TlsConfig {
  /// Certificate verification mode
  final TlsMode mode;

  /// Expected subject name of the peer (authority mode); `null` disables name verification
  final String? subjectName;

  /// PEM file of the CA certificate(s) (authority mode) or the expected peer certificate
  /// (self-signed mode)
  final String peerCertPath;

  /// PEM file of the local certificate (chain) presented to the peer
  final String localCertPath;

  /// PEM file of the private key of the local certificate
  final String privateKeyPath;

  /// Password of an encrypted private key; `null` if the key is not encrypted
  final String? password;

  /// Minimum TLS version (default TLS 1.2)
  final MinTlsVersion minTlsVersion;

  /// Defaults to [TlsMode.authority] without name verification and TLS >= 1.2
  const TlsConfig({
    this.mode = TlsMode.authority,
    this.subjectName,
    required this.peerCertPath,
    required this.localCertPath,
    required this.privateKeyPath,
    this.password,
    this.minTlsVersion = MinTlsVersion.v12,
  });

  /// JSON representation expected by the native library
  Map<String, Object?> toJson() => {
    'mode': mode.name,
    'subjectName': subjectName,
    'peerCertPath': peerCertPath,
    'localCertPath': localCertPath,
    'privateKeyPath': privateKeyPath,
    'password': password,
    'minTlsVersion': minTlsVersion.name,
  };
}

/// Serial port flow control
enum FlowControl {
  /// no flow control
  none,

  /// XON / XOFF
  software,

  /// RTS / CTS
  hardware,
}

/// Serial port parity
enum Parity {
  /// no parity bit
  none,

  /// odd parity
  odd,

  /// even parity
  even,
}

/// Serial port settings (default 9600 8N1, no flow control)
final class SerialSettings {
  /// Baud rate in bit/s
  final int baudRate;

  /// Data bits per character: 5, 6, 7 or 8
  final int dataBits;

  /// Flow control
  final FlowControl flowControl;

  /// Stop bits: 1 or 2
  final int stopBits;

  /// Parity
  final Parity parity;

  /// Defaults: 9600 baud, 8 data bits, no parity, 1 stop bit, no flow control
  const SerialSettings({
    this.baudRate = 9600,
    this.dataBits = 8,
    this.flowControl = FlowControl.none,
    this.stopBits = 1,
    this.parity = Parity.none,
  });

  /// JSON representation expected by the native library
  Map<String, Object?> toJson() => {
    'baudRate': baudRate,
    'dataBits': dataBits,
    'flowControl': flowControl.name,
    'stopBits': stopBits,
    'parity': parity.name,
  };
}

// ---------------------------------------------------------------------------------------
// master
// ---------------------------------------------------------------------------------------

/// Channel-level settings of a master
final class MasterChannelConfig {
  /// DNP3 link address of the master (0..65519; reserved/broadcast addresses are rejected)
  final int masterAddress;

  /// Initial protocol decoding written to the log
  final DecodeLevel decodeLevel;

  /// Size in bytes of the transmit buffer, i.e. the largest request fragment (min 249, default 2048)
  final int txBufferSize;

  /// Size in bytes of the transport reassembly buffer, i.e. the largest response fragment
  /// (min 2048, default 2048)
  final int rxBufferSize;

  /// Configuration with no decoding and 2048-byte buffers
  const MasterChannelConfig({
    required this.masterAddress,
    this.decodeLevel = const DecodeLevel(),
    this.txBufferSize = 2048,
    this.rxBufferSize = 2048,
  });

  /// JSON representation expected by the native library
  Map<String, Object?> toJson() => {
    'masterAddress': masterAddress,
    'decodeLevel': decodeLevel.toJson(),
    'txBufferSize': txBufferSize,
    'rxBufferSize': rxBufferSize,
  };
}

/// Procedure used by the master to synchronize the outstation clock
enum TimeSyncProcedure {
  /// RECORD_CURRENT_TIME followed by WRITE g50v3 (LAN procedure)
  lan,

  /// DELAY_MEASURE followed by WRITE g50v1 (non-LAN procedure)
  nonLan,

  /// WRITE g50v1 without delay measurement (non-conformant, ignores latency)
  directWriteAbsTime,
}

/// Per-outstation settings of a master association
final class AssociationConfig {
  /// Timeout for responses to requests on this association (1 ms .. 1 h, default 5 s)
  final Duration responseTimeout;

  /// Event classes for which unsolicited reporting is disabled at startup (default all)
  final EventClasses disableUnsolClasses;

  /// Event classes for which unsolicited reporting is enabled after the startup integrity
  /// scan (default all)
  final EventClasses enableUnsolClasses;

  /// Classes read in the integrity scan at startup and when the outstation restarts
  /// (default class 0123, required for conformance)
  final Classes startupIntegrityClasses;

  /// Time sync performed automatically when the outstation sets IIN1.4 NEED_TIME;
  /// `null` disables it
  final TimeSyncProcedure? autoTimeSync;

  /// Back-off used to retry failed automatic (startup / time sync / scan) tasks
  final RetryStrategy autoTasksRetryStrategy;

  /// period of inactivity after which a REQUEST_LINK_STATUS is sent (null = disabled)
  final Duration? keepAliveTimeout;

  /// Perform an integrity scan when the outstation reports IIN2.3 EVENT_BUFFER_OVERFLOW
  final bool autoIntegrityScanOnBufferOverflow;

  /// Event classes read automatically when the matching IIN1.1-1.3 "class N events" bit is
  /// set (default none)
  final EventClasses eventScanOnEventsAvailable;

  /// Maximum number of queued user requests (reads, commands, ...) before new ones fail
  /// with "too many requests" (default 16)
  final int maxQueuedUserRequests;

  /// Defaults follow the `dnp3` crate: 5 s response timeout, unsolicited disable/enable for
  /// all classes, class 0123 startup integrity scan
  const AssociationConfig({
    this.responseTimeout = const Duration(seconds: 5),
    this.disableUnsolClasses = const EventClasses.all(),
    this.enableUnsolClasses = const EventClasses.all(),
    this.startupIntegrityClasses = const Classes.all(),
    this.autoTimeSync,
    this.autoTasksRetryStrategy = const RetryStrategy(),
    this.keepAliveTimeout,
    this.autoIntegrityScanOnBufferOverflow = true,
    this.eventScanOnEventsAvailable = const EventClasses.none(),
    this.maxQueuedUserRequests = 16,
  });

  /// No startup tasks (no unsolicited enable/disable, no integrity scan)
  const AssociationConfig.quiet({Duration responseTimeout = const Duration(seconds: 5)})
    : this(
        responseTimeout: responseTimeout,
        disableUnsolClasses: const EventClasses.none(),
        enableUnsolClasses: const EventClasses.none(),
        startupIntegrityClasses: const Classes.none(),
        autoIntegrityScanOnBufferOverflow: false,
      );

  /// JSON representation expected by the native library
  Map<String, Object?> toJson() => {
    'responseTimeoutMs': responseTimeout.inMilliseconds,
    'disableUnsolClasses': disableUnsolClasses.toJson(),
    'enableUnsolClasses': enableUnsolClasses.toJson(),
    'startupIntegrityClasses': startupIntegrityClasses.toJson(),
    'autoTimeSync': autoTimeSync?.name,
    'autoTasksRetryStrategy': autoTasksRetryStrategy.toJson(),
    'keepAliveTimeoutMs': keepAliveTimeout?.inMilliseconds,
    'autoIntegrityScanOnBufferOverflow': autoIntegrityScanOnBufferOverflow,
    'eventScanOnEventsAvailable': eventScanOnEventsAvailable.toJson(),
    'maxQueuedUserRequests': maxQueuedUserRequests,
  };
}

/// Accept parameters for connections handled by a [MasterServer]
final class AcceptConfig {
  /// Handling of malformed link frames on the accepted connection (default close)
  final LinkErrorMode linkErrorMode;

  /// Channel settings of the master created for the connection
  final MasterChannelConfig channel;

  /// Closes the connection on link errors by default
  const AcceptConfig({this.linkErrorMode = LinkErrorMode.close, required this.channel});

  /// JSON representation expected by the native library
  Map<String, Object?> toJson() => {'linkErrorMode': linkErrorMode.name, 'channel': channel.toJson()};
}

/// How a [MasterServer] reads the first link frame to identify an outstation
final class LinkIdConfig {
  /// Maximum number of connections identified concurrently; further ones wait (must be > 0)
  final int maxTasks;

  /// How long to wait for the first link frame from the outstation (1 ms .. 1 h)
  final Duration timeout;

  /// Physical-layer logging during identification
  final PhysDecodeLevel decodeLevel;

  /// Defaults: 16 tasks, 5 s timeout, no logging
  const LinkIdConfig({
    this.maxTasks = 16,
    this.timeout = const Duration(seconds: 5),
    this.decodeLevel = PhysDecodeLevel.nothing,
  });

  /// JSON representation expected by the native library
  Map<String, Object?> toJson() => {
    'maxTasks': maxTasks,
    'timeoutMs': timeout.inMilliseconds,
    'decodeLevel': decodeLevel.name,
  };
}

// ---------------------------------------------------------------------------------------
// outstation
// ---------------------------------------------------------------------------------------

/// Maximum number of buffered events per type
final class EventBufferConfig {
  /// Binary input events (g2); 0 disables events of this type (max 65535)
  final int maxBinary;

  /// Double-bit binary input events (g4)
  final int maxDoubleBinary;

  /// Binary output status events (g11)
  final int maxBinaryOutputStatus;

  /// Counter events (g22)
  final int maxCounter;

  /// Frozen counter events (g23)
  final int maxFrozenCounter;

  /// Analog input events (g32)
  final int maxAnalog;

  /// Analog output status events (g42)
  final int maxAnalogOutputStatus;

  /// Octet string events (g111)
  final int maxOctetString;

  /// Every type defaults to 0 (no events buffered)
  const EventBufferConfig({
    this.maxBinary = 0,
    this.maxDoubleBinary = 0,
    this.maxBinaryOutputStatus = 0,
    this.maxCounter = 0,
    this.maxFrozenCounter = 0,
    this.maxAnalog = 0,
    this.maxAnalogOutputStatus = 0,
    this.maxOctetString = 0,
  });

  /// Same capacity (0..65535) for every event type
  const EventBufferConfig.allTypes(int max)
    : this(
        maxBinary: max,
        maxDoubleBinary: max,
        maxBinaryOutputStatus: max,
        maxCounter: max,
        maxFrozenCounter: max,
        maxAnalog: max,
        maxAnalogOutputStatus: max,
        maxOctetString: max,
      );

  /// No events are buffered for any type
  const EventBufferConfig.noEvents() : this();

  /// JSON representation expected by the native library
  Map<String, Object?> toJson() => {
    'maxBinary': maxBinary,
    'maxDoubleBinary': maxDoubleBinary,
    'maxBinaryOutputStatus': maxBinaryOutputStatus,
    'maxCounter': maxCounter,
    'maxFrozenCounter': maxFrozenCounter,
    'maxAnalog': maxAnalog,
    'maxAnalogOutputStatus': maxAnalogOutputStatus,
    'maxOctetString': maxOctetString,
  };
}

/// Optional outstation features
final class OutstationFeatures {
  /// Respond to requests sent to the self address 0xFFFC (default off)
  final bool selfAddress;

  /// Process broadcast requests (addresses 0xFFFD..0xFFFF) (default on)
  final bool broadcast;

  /// Process ENABLE/DISABLE_UNSOLICITED and send unsolicited responses (default on)
  final bool unsolicited;

  /// Treat every request as if it came from the configured master address (default off;
  /// do not combine with unsolicited reporting)
  final bool respondToAnyMaster;

  /// Defaults match the `dnp3` crate
  const OutstationFeatures({
    this.selfAddress = false,
    this.broadcast = true,
    this.unsolicited = true,
    this.respondToAnyMaster = false,
  });

  /// JSON representation expected by the native library
  Map<String, Object?> toJson() => {
    'selfAddress': selfAddress,
    'broadcast': broadcast,
    'unsolicited': unsolicited,
    'respondToAnyMaster': respondToAnyMaster,
  };
}

/// Point types reported in a class 0 (static) read
final class ClassZeroConfig {
  /// Binary inputs (g1)
  final bool binary;

  /// Double-bit binary inputs (g3)
  final bool doubleBitBinary;

  /// Binary output status (g10)
  final bool binaryOutputStatus;

  /// Counters (g20)
  final bool counter;

  /// Frozen counters (g21)
  final bool frozenCounter;

  /// Analog inputs (g30)
  final bool analog;

  /// Analog output status (g40)
  final bool analogOutputStatus;

  /// Octet strings (g110); off by default for conformance with the standard
  final bool octetString;

  /// Every type except octet strings is reported by default
  const ClassZeroConfig({
    this.binary = true,
    this.doubleBitBinary = true,
    this.binaryOutputStatus = true,
    this.counter = true,
    this.frozenCounter = true,
    this.analog = true,
    this.analogOutputStatus = true,
    this.octetString = false,
  });

  /// JSON representation expected by the native library
  Map<String, Object?> toJson() => {
    'binary': binary,
    'doubleBitBinary': doubleBitBinary,
    'binaryOutputStatus': binaryOutputStatus,
    'counter': counter,
    'frozenCounter': frozenCounter,
    'analog': analog,
    'analogOutputStatus': analogOutputStatus,
    'octetString': octetString,
  };
}

/// Protocol settings of an outstation
final class OutstationConfig {
  /// DNP3 link address of the outstation (0..65519)
  final int outstationAddress;

  /// DNP3 link address of the master the outstation talks to (0..65519)
  final int masterAddress;

  /// Event buffer capacity per type (default 100 of each)
  final EventBufferConfig eventBufferConfig;

  /// Size in bytes of the solicited response fragment buffer (min 249, default 2048)
  final int solicitedBufferSize;

  /// Size in bytes of the unsolicited response fragment buffer (min 249, default 2048)
  final int unsolicitedBufferSize;

  /// Size in bytes of the request reassembly buffer (min 249, default 2048)
  final int rxBufferSize;

  /// Initial protocol decoding written to the log
  final DecodeLevel decodeLevel;

  /// Time to wait for the master's application CONFIRM to a solicited or unsolicited
  /// response before giving up (1 ms .. 1 h, default 5 s)
  final Duration confirmTimeout;

  /// Maximum time between SELECT and the matching OPERATE; later operates fail with
  /// SELECT_TIMEOUT (1 ms .. 1 h, default 5 s)
  final Duration selectTimeout;

  /// Optional features (self address, broadcast, unsolicited, respond to any master)
  final OutstationFeatures features;

  /// null = retry forever
  final int? maxUnsolicitedRetries;

  /// Delay after a failed unsolicited response series before a new series starts (default 5 s)
  final Duration unsolicitedRetryDelay;

  /// null disables keep-alive link status requests
  final Duration? keepAliveTimeout;

  /// Maximum object headers processed in one READ (minimum and default 64); more sets
  /// IIN2.2 PARAMETER_ERROR
  final int? maxReadRequestHeaders;

  /// Maximum number of controls accepted in one request; `null` = unlimited
  final int? maxControlsPerRequest;

  /// Point types returned in a class 0 read
  final ClassZeroConfig classZero;

  /// Defaults follow the `dnp3` crate, except that each event type buffers 100 events
  const OutstationConfig({
    required this.outstationAddress,
    required this.masterAddress,
    this.eventBufferConfig = const EventBufferConfig.allTypes(100),
    this.solicitedBufferSize = 2048,
    this.unsolicitedBufferSize = 2048,
    this.rxBufferSize = 2048,
    this.decodeLevel = const DecodeLevel(),
    this.confirmTimeout = const Duration(seconds: 5),
    this.selectTimeout = const Duration(seconds: 5),
    this.features = const OutstationFeatures(),
    this.maxUnsolicitedRetries,
    this.unsolicitedRetryDelay = const Duration(seconds: 5),
    this.keepAliveTimeout = const Duration(seconds: 60),
    this.maxReadRequestHeaders,
    this.maxControlsPerRequest,
    this.classZero = const ClassZeroConfig(),
  });

  /// JSON representation expected by the native library
  Map<String, Object?> toJson() => {
    'outstationAddress': outstationAddress,
    'masterAddress': masterAddress,
    'eventBufferConfig': eventBufferConfig.toJson(),
    'solicitedBufferSize': solicitedBufferSize,
    'unsolicitedBufferSize': unsolicitedBufferSize,
    'rxBufferSize': rxBufferSize,
    'decodeLevel': decodeLevel.toJson(),
    'confirmTimeoutMs': confirmTimeout.inMilliseconds,
    'selectTimeoutMs': selectTimeout.inMilliseconds,
    'features': features.toJson(),
    'maxUnsolicitedRetries': maxUnsolicitedRetries,
    'unsolicitedRetryDelayMs': unsolicitedRetryDelay.inMilliseconds,
    'keepAliveTimeoutMs': keepAliveTimeout?.inMilliseconds,
    'maxReadRequestHeaders': maxReadRequestHeaders,
    'maxControlsPerRequest': maxControlsPerRequest,
    'classZero': classZero.toJson(),
  };
}

/// How SELECT / OPERATE requests received by an outstation are handled
enum ControlMode {
  /// Executed natively: every control succeeds and (optionally) the commanded value is
  /// mirrored into BinaryOutputStatus / AnalogOutputStatus. Dart is notified asynchronously.
  accept,

  /// Every control is rejected with [ControlHandlerConfig.rejectStatus]
  reject,

  /// Each SELECT / OPERATE is forwarded to `OutstationHandlers.onControl` and the protocol
  /// thread waits for its answer (bounded by [ControlHandlerConfig.timeout]).
  callback,
}

/// How a generated event is treated when a point is updated
enum EventMode {
  /// create an event if the value / flags changed (respecting dead bands)
  detect,

  /// always create an event
  force,

  /// never create an event
  suppress,
}

/// Handling of control requests (CROB g12, analog outputs g41) by an outstation
final class ControlHandlerConfig {
  /// Handling strategy (default [ControlMode.accept])
  final ControlMode mode;

  /// Status returned for every control in [ControlMode.reject] (default NOT_SUPPORTED)
  final CommandStatus rejectStatus;

  /// In [ControlMode.accept], write the commanded value into the matching
  /// BinaryOutputStatus / AnalogOutputStatus point on OPERATE
  final bool updateDatabase;

  /// Event mode of the mirrored output status update
  final EventMode eventMode;

  /// In [ControlMode.accept], notify Dart asynchronously of every executed OPERATE
  final bool notify;

  /// In [ControlMode.callback], maximum time to wait for the Dart answer (default 2 s)
  final Duration timeout;

  /// Status returned when the Dart answer does not arrive within [timeout]
  final CommandStatus timeoutStatus;

  /// Defaults: accept, mirror into the database with event detection, notify Dart
  const ControlHandlerConfig({
    this.mode = ControlMode.accept,
    this.rejectStatus = CommandStatus.notSupported,
    this.updateDatabase = true,
    this.eventMode = EventMode.detect,
    this.notify = true,
    this.timeout = const Duration(seconds: 2),
    this.timeoutStatus = CommandStatus.timeout,
  });

  /// JSON representation expected by the native library
  Map<String, Object?> toJson() => {
    'mode': mode.name,
    'rejectStatus': rejectStatus.code,
    'updateDatabase': updateDatabase,
    'eventMode': eventMode.index,
    'notify': notify,
    'timeoutMs': timeout.inMilliseconds,
    'timeoutStatus': timeoutStatus.code,
  };
}

/// Response of an outstation to COLD_RESTART / WARM_RESTART
enum RestartMode {
  /// restart not supported (IIN2.0 NO_FUNC_CODE_SUPPORT)
  notSupported,

  /// report the configured delay in seconds (g52v1)
  seconds,

  /// report the configured delay in milliseconds (g52v2)
  milliseconds,

  /// ask the Dart application handler for the delay
  callback,
}

/// Response of an outstation to a WRITE of absolute time (g50v1)
enum TimeWriteMode {
  /// the write is rejected (IIN2.0 NO_FUNC_CODE_SUPPORT)
  notSupported,

  /// the time is accepted and Dart is notified asynchronously
  accept,

  /// the Dart application handler decides synchronously
  callback,
}

/// Response of an outstation to counter FREEZE requests
enum FreezeMode {
  /// freeze requests are rejected (IIN2.0 NO_FUNC_CODE_SUPPORT)
  notSupported,

  /// counters are copied into frozen counters natively (immediate freeze / freeze & clear)
  auto,

  /// the Dart application handler performs the freeze
  callback,
}

/// Response of an outstation to WRITE of device attributes (g0)
enum AttributeWriteMode {
  /// accept the write and notify Dart asynchronously
  accept,

  /// reject the write
  reject,

  /// the Dart application handler decides
  callback,
}

/// Behaviour of the outstation application callbacks
final class ApplicationConfig {
  /// Processing delay in ms reported in DELAY_MEASURE responses (0..65535, normally 0)
  final int processingDelayMs;

  /// Response to COLD_RESTART
  final RestartMode coldRestart;

  /// Restart delay reported for COLD_RESTART, in the unit selected by [coldRestart] (0..65535)
  final int coldRestartDelay;

  /// Response to WARM_RESTART
  final RestartMode warmRestart;

  /// Restart delay reported for WARM_RESTART, in the unit selected by [warmRestart] (0..65535)
  final int warmRestartDelay;

  /// Response to WRITE of absolute time
  final TimeWriteMode writeAbsoluteTime;

  /// Response to counter FREEZE requests
  final FreezeMode freeze;

  /// Accept WRITEs of analog input dead bands (g34); Dart is notified with the new values
  final bool supportWriteAnalogDeadBands;

  /// Response to WRITE of device attributes
  final AttributeWriteMode writeDeviceAttributes;

  /// Notify Dart when the master confirms events (with the ids of the cleared events)
  final bool notifyConfirm;

  /// Maximum time to wait for a Dart answer in callback modes (default 2 s)
  final Duration callbackTimeout;

  /// Defaults: optional functions unsupported, attribute writes accepted
  const ApplicationConfig({
    this.processingDelayMs = 0,
    this.coldRestart = RestartMode.notSupported,
    this.coldRestartDelay = 0,
    this.warmRestart = RestartMode.notSupported,
    this.warmRestartDelay = 0,
    this.writeAbsoluteTime = TimeWriteMode.notSupported,
    this.freeze = FreezeMode.notSupported,
    this.supportWriteAnalogDeadBands = false,
    this.writeDeviceAttributes = AttributeWriteMode.accept,
    this.notifyConfirm = false,
    this.callbackTimeout = const Duration(seconds: 2),
  });

  /// JSON representation expected by the native library
  Map<String, Object?> toJson() => {
    'processingDelayMs': processingDelayMs,
    'coldRestart': coldRestart.name,
    'coldRestartDelay': coldRestartDelay,
    'warmRestart': warmRestart.name,
    'warmRestartDelay': warmRestartDelay,
    'writeAbsoluteTime': writeAbsoluteTime.name,
    'freeze': freeze.name,
    'supportWriteAnalogDeadBands': supportWriteAnalogDeadBands,
    'writeDeviceAttr': writeDeviceAttributes.name,
    'notifyConfirm': notifyConfirm,
    'callbackTimeoutMs': callbackTimeout.inMilliseconds,
  };
}

/// Restricts which master IP addresses may connect to an outstation of a TCP server
sealed class AddressFilter {
  /// Base constructor for subclasses
  const AddressFilter();

  /// Accept any address
  const factory AddressFilter.any() = _AnyFilter;

  /// Accept only this IP address (IPv4 or IPv6)
  const factory AddressFilter.exact(String address) = _ExactFilter;

  /// Accept any of these IP addresses
  const factory AddressFilter.anyOf(List<String> addresses) = _AnyOfFilter;

  /// IPv4 wildcard such as `192.168.0.*`
  const factory AddressFilter.wildcard(String pattern) = _WildcardFilter;

  /// JSON representation expected by the native library
  Map<String, Object?> toJson();
}

final class _AnyFilter extends AddressFilter {
  const _AnyFilter();
  @override
  Map<String, Object?> toJson() => {'type': 'any'};
}

final class _ExactFilter extends AddressFilter {
  final String address;
  const _ExactFilter(this.address);
  @override
  Map<String, Object?> toJson() => {'type': 'exact', 'address': address};
}

final class _AnyOfFilter extends AddressFilter {
  final List<String> addresses;
  const _AnyOfFilter(this.addresses);
  @override
  Map<String, Object?> toJson() => {'type': 'anyOf', 'addresses': addresses};
}

final class _WildcardFilter extends AddressFilter {
  final String pattern;
  const _WildcardFilter(this.pattern);
  @override
  Map<String, Object?> toJson() => {'type': 'wildcard', 'pattern': pattern};
}
