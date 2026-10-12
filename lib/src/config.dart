/// Configuration objects. They serialize to the JSON understood by native/src/config.rs.
library;

import 'types.dart';

enum AppDecodeLevel { nothing, header, objectHeaders, objectValues }

enum TransportDecodeLevel { nothing, header, payload }

enum LinkDecodeLevel { nothing, header, payload }

enum PhysDecodeLevel { nothing, length, data }

/// Controls protocol decoding written to the log
final class DecodeLevel {
  final AppDecodeLevel application;
  final TransportDecodeLevel transport;
  final LinkDecodeLevel link;
  final PhysDecodeLevel physical;

  const DecodeLevel({
    this.application = AppDecodeLevel.nothing,
    this.transport = TransportDecodeLevel.nothing,
    this.link = LinkDecodeLevel.nothing,
    this.physical = PhysDecodeLevel.nothing,
  });

  const DecodeLevel.nothing() : this();

  /// Application-layer object values (most useful for debugging)
  const DecodeLevel.objectValues() : this(application: AppDecodeLevel.objectValues);

  Map<String, Object?> toJson() => {
    'application': application.name,
    'transport': transport.name,
    'link': link.name,
    'physical': physical.name,
  };

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
enum LinkReadMode { datagram, stream }

final class RetryStrategy {
  final Duration minDelay;
  final Duration maxDelay;
  const RetryStrategy({
    this.minDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 10),
  });

  Map<String, Object?> toJson() => {
    'minDelayMs': minDelay.inMilliseconds,
    'maxDelayMs': maxDelay.inMilliseconds,
  };
}

/// Reconnect behaviour of TCP/TLS clients
final class ConnectStrategy {
  final Duration minConnectDelay;
  final Duration maxConnectDelay;
  final Duration reconnectDelay;
  const ConnectStrategy({
    this.minConnectDelay = const Duration(seconds: 1),
    this.maxConnectDelay = const Duration(seconds: 10),
    this.reconnectDelay = const Duration(seconds: 1),
  });

  Map<String, Object?> toJson() => {
    'minConnectDelayMs': minConnectDelay.inMilliseconds,
    'maxConnectDelayMs': maxConnectDelay.inMilliseconds,
    'reconnectDelayMs': reconnectDelay.inMilliseconds,
  };
}

final class ConnectOptions {
  /// local address to bind before connecting, e.g. `192.168.0.10:0`
  final String? localEndpoint;
  final Duration? connectTimeout;
  const ConnectOptions({this.localEndpoint, this.connectTimeout});

  Map<String, Object?> toJson() => {
    if (localEndpoint != null) 'localEndpoint': localEndpoint,
    if (connectTimeout != null) 'connectTimeoutMs': connectTimeout!.inMilliseconds,
  };
}

enum TlsMode {
  /// full PKI: the peer certificate is validated against an authority
  authority,

  /// the peer must present exactly the configured self-signed certificate
  selfSigned,
}

enum MinTlsVersion { v12, v13 }

final class TlsConfig {
  final TlsMode mode;

  /// Expected subject name of the peer (authority mode); `null` disables name verification
  final String? subjectName;
  final String peerCertPath;
  final String localCertPath;
  final String privateKeyPath;
  final String? password;
  final MinTlsVersion minTlsVersion;

  const TlsConfig({
    this.mode = TlsMode.authority,
    this.subjectName,
    required this.peerCertPath,
    required this.localCertPath,
    required this.privateKeyPath,
    this.password,
    this.minTlsVersion = MinTlsVersion.v12,
  });

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

enum FlowControl { none, software, hardware }

enum Parity { none, odd, even }

final class SerialSettings {
  final int baudRate;
  final int dataBits;
  final FlowControl flowControl;
  final int stopBits;
  final Parity parity;

  const SerialSettings({
    this.baudRate = 9600,
    this.dataBits = 8,
    this.flowControl = FlowControl.none,
    this.stopBits = 1,
    this.parity = Parity.none,
  });

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

final class MasterChannelConfig {
  final int masterAddress;
  final DecodeLevel decodeLevel;
  final int txBufferSize;
  final int rxBufferSize;

  const MasterChannelConfig({
    required this.masterAddress,
    this.decodeLevel = const DecodeLevel(),
    this.txBufferSize = 2048,
    this.rxBufferSize = 2048,
  });

  Map<String, Object?> toJson() => {
    'masterAddress': masterAddress,
    'decodeLevel': decodeLevel.toJson(),
    'txBufferSize': txBufferSize,
    'rxBufferSize': rxBufferSize,
  };
}

enum TimeSyncProcedure { lan, nonLan, directWriteAbsTime }

final class AssociationConfig {
  final Duration responseTimeout;
  final EventClasses disableUnsolClasses;
  final EventClasses enableUnsolClasses;
  final Classes startupIntegrityClasses;
  final TimeSyncProcedure? autoTimeSync;
  final RetryStrategy autoTasksRetryStrategy;

  /// period of inactivity after which a REQUEST_LINK_STATUS is sent (null = disabled)
  final Duration? keepAliveTimeout;
  final bool autoIntegrityScanOnBufferOverflow;
  final EventClasses eventScanOnEventsAvailable;
  final int maxQueuedUserRequests;

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
  const AssociationConfig.quiet()
    : this(
        disableUnsolClasses: const EventClasses.none(),
        enableUnsolClasses: const EventClasses.none(),
        startupIntegrityClasses: const Classes.none(),
        autoIntegrityScanOnBufferOverflow: false,
      );

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
  final LinkErrorMode linkErrorMode;
  final MasterChannelConfig channel;
  const AcceptConfig({this.linkErrorMode = LinkErrorMode.close, required this.channel});

  Map<String, Object?> toJson() => {'linkErrorMode': linkErrorMode.name, 'channel': channel.toJson()};
}

final class LinkIdConfig {
  final int maxTasks;
  final Duration timeout;
  final PhysDecodeLevel decodeLevel;
  const LinkIdConfig({
    this.maxTasks = 16,
    this.timeout = const Duration(seconds: 5),
    this.decodeLevel = PhysDecodeLevel.nothing,
  });

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
  final int maxBinary;
  final int maxDoubleBinary;
  final int maxBinaryOutputStatus;
  final int maxCounter;
  final int maxFrozenCounter;
  final int maxAnalog;
  final int maxAnalogOutputStatus;
  final int maxOctetString;

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

  const EventBufferConfig.noEvents() : this();

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

final class OutstationFeatures {
  final bool selfAddress;
  final bool broadcast;
  final bool unsolicited;
  final bool respondToAnyMaster;
  const OutstationFeatures({
    this.selfAddress = false,
    this.broadcast = true,
    this.unsolicited = true,
    this.respondToAnyMaster = false,
  });

  Map<String, Object?> toJson() => {
    'selfAddress': selfAddress,
    'broadcast': broadcast,
    'unsolicited': unsolicited,
    'respondToAnyMaster': respondToAnyMaster,
  };
}

/// Point types reported in a class 0 (static) read
final class ClassZeroConfig {
  final bool binary;
  final bool doubleBitBinary;
  final bool binaryOutputStatus;
  final bool counter;
  final bool frozenCounter;
  final bool analog;
  final bool analogOutputStatus;
  final bool octetString;
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

final class OutstationConfig {
  final int outstationAddress;
  final int masterAddress;
  final EventBufferConfig eventBufferConfig;
  final int solicitedBufferSize;
  final int unsolicitedBufferSize;
  final int rxBufferSize;
  final DecodeLevel decodeLevel;
  final Duration confirmTimeout;
  final Duration selectTimeout;
  final OutstationFeatures features;

  /// null = retry forever
  final int? maxUnsolicitedRetries;
  final Duration unsolicitedRetryDelay;

  /// null disables keep-alive link status requests
  final Duration? keepAliveTimeout;
  final int? maxReadRequestHeaders;
  final int? maxControlsPerRequest;
  final ClassZeroConfig classZero;

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

  /// Each SELECT / OPERATE is forwarded to the Dart `ControlHandler` and the protocol
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

final class ControlHandlerConfig {
  final ControlMode mode;
  final CommandStatus rejectStatus;
  final bool updateDatabase;
  final EventMode eventMode;
  final bool notify;
  final Duration timeout;
  final CommandStatus timeoutStatus;

  const ControlHandlerConfig({
    this.mode = ControlMode.accept,
    this.rejectStatus = CommandStatus.notSupported,
    this.updateDatabase = true,
    this.eventMode = EventMode.detect,
    this.notify = true,
    this.timeout = const Duration(seconds: 2),
    this.timeoutStatus = CommandStatus.timeout,
  });

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

enum RestartMode { notSupported, seconds, milliseconds, callback }

enum TimeWriteMode { notSupported, accept, callback }

enum FreezeMode {
  notSupported,

  /// counters are copied into frozen counters natively (immediate freeze / freeze & clear)
  auto,
  callback,
}

enum AttributeWriteMode { accept, reject, callback }

/// Behaviour of the outstation application callbacks
final class ApplicationConfig {
  final int processingDelayMs;
  final RestartMode coldRestart;
  final int coldRestartDelay;
  final RestartMode warmRestart;
  final int warmRestartDelay;
  final TimeWriteMode writeAbsoluteTime;
  final FreezeMode freeze;
  final bool supportWriteAnalogDeadBands;
  final AttributeWriteMode writeDeviceAttributes;
  final bool notifyConfirm;
  final Duration callbackTimeout;

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
  const AddressFilter();
  const factory AddressFilter.any() = _AnyFilter;
  const factory AddressFilter.exact(String address) = _ExactFilter;
  const factory AddressFilter.anyOf(List<String> addresses) = _AnyOfFilter;

  /// IPv4 wildcard such as `192.168.0.*`
  const factory AddressFilter.wildcard(String pattern) = _WildcardFilter;

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
