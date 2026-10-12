/// Shared DNP3 value types and enumerations.
library;

/// Quality of a DNP3 timestamp
enum TimeQuality {
  /// the outstation clock is synchronized
  synchronized,

  /// the outstation clock is not synchronized
  unsynchronized,
}

/// 48-bit DNP3 timestamp (milliseconds since the Unix epoch, UTC)
final class Dnp3Time {
  final int millis;
  final TimeQuality quality;

  const Dnp3Time(this.millis, [this.quality = TimeQuality.synchronized]);

  Dnp3Time.fromDateTime(DateTime t, [this.quality = TimeQuality.synchronized])
    : millis = t.millisecondsSinceEpoch;

  factory Dnp3Time.now([TimeQuality quality = TimeQuality.synchronized]) =>
      Dnp3Time(DateTime.now().millisecondsSinceEpoch, quality);

  bool get isSynchronized => quality == TimeQuality.synchronized;

  DateTime toDateTime() => DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);

  /// native encoding: 0 none, 1 synchronized, 2 unsynchronized
  int get kind => quality == TimeQuality.synchronized ? 1 : 2;

  static Dnp3Time? decode(int kind, int millis) => switch (kind) {
    1 => Dnp3Time(millis, TimeQuality.synchronized),
    2 => Dnp3Time(millis, TimeQuality.unsynchronized),
    _ => null,
  };

  @override
  bool operator ==(Object other) => other is Dnp3Time && other.millis == millis && other.quality == quality;

  @override
  int get hashCode => Object.hash(millis, quality);

  @override
  String toString() => '${toDateTime().toIso8601String()}${isSynchronized ? '' : ' (unsync)'}';
}

/// Measurement quality flags (bit field)
extension type const Flags(int value) {
  static const Flags none = Flags(0);
  static const Flags online = Flags(0x01);
  static const Flags restart = Flags(0x02);
  static const Flags commLost = Flags(0x04);
  static const Flags remoteForced = Flags(0x08);
  static const Flags localForced = Flags(0x10);
  static const Flags chatterFilter = Flags(0x20);
  static const Flags overRange = Flags(0x20);
  static const Flags rollOver = Flags(0x20);
  static const Flags discontinuity = Flags(0x40);
  static const Flags referenceError = Flags(0x40);

  bool has(Flags other) => (value & other.value) == other.value;
  Flags operator |(Flags other) => Flags(value | other.value);
  Flags operator &(Flags other) => Flags(value & other.value);
}

enum DoubleBit {
  intermediate,
  determinedOff,
  determinedOn,
  indeterminate;

  static DoubleBit fromCode(int code) => values[code & 0x03];
}

/// Status code of a control operation (CROB / analog output)
enum CommandStatus {
  success(0),
  timeout(1),
  noSelect(2),
  formatError(3),
  notSupported(4),
  alreadyActive(5),
  hardwareError(6),
  local(7),
  tooManyOps(8),
  notAuthorized(9),
  automationInhibit(10),
  processingLimited(11),
  outOfRange(12),
  downstreamLocal(13),
  alreadyComplete(14),
  blocked(15),
  canceled(16),
  blockedOtherMaster(17),
  downstreamFail(18),
  nonParticipating(126),
  unknown(127);

  final int code;
  const CommandStatus(this.code);

  static CommandStatus fromCode(int code) =>
      values.firstWhere((s) => s.code == code, orElse: () => CommandStatus.unknown);
}

enum OpType {
  nul(0),
  pulseOn(1),
  pulseOff(2),
  latchOn(3),
  latchOff(4);

  final int code;
  const OpType(this.code);

  static OpType fromCode(int code) => values.firstWhere((x) => x.code == code, orElse: () => OpType.nul);
}

enum TripCloseCode {
  nul(0),
  close(1),
  trip(2),
  reserved(3);

  final int code;
  const TripCloseCode(this.code);

  static TripCloseCode fromCode(int code) => values[code & 0x03];
}

/// Control code of a CROB (g12v1)
final class ControlCode {
  final TripCloseCode tcc;
  final bool clear;
  final bool queue;
  final OpType opType;

  const ControlCode({
    this.tcc = TripCloseCode.nul,
    this.clear = false,
    this.queue = false,
    required this.opType,
  });

  const ControlCode.latchOn() : this(opType: OpType.latchOn);
  const ControlCode.latchOff() : this(opType: OpType.latchOff);
  const ControlCode.pulseOn() : this(opType: OpType.pulseOn);
  const ControlCode.pulseOff() : this(opType: OpType.pulseOff);
  const ControlCode.close() : this(tcc: TripCloseCode.close, opType: OpType.pulseOn);
  const ControlCode.trip() : this(tcc: TripCloseCode.trip, opType: OpType.pulseOn);

  factory ControlCode.fromByte(int b) => ControlCode(
    tcc: TripCloseCode.fromCode(b >> 6),
    clear: b & 0x20 != 0,
    queue: b & 0x10 != 0,
    opType: OpType.fromCode(b & 0x0F),
  );

  int toByte() => (tcc.code << 6) | (clear ? 0x20 : 0) | (queue ? 0x10 : 0) | (opType.code & 0x0F);

  @override
  String toString() => 'ControlCode($tcc, $opType, clear: $clear, queue: $queue)';
}

enum FunctionCode {
  confirm(0),
  read(1),
  write(2),
  select(3),
  operate(4),
  directOperate(5),
  directOperateNoResponse(6),
  immediateFreeze(7),
  immediateFreezeNoResponse(8),
  freezeClear(9),
  freezeClearNoResponse(10),
  freezeAtTime(11),
  freezeAtTimeNoResponse(12),
  coldRestart(13),
  warmRestart(14),
  initializeData(15),
  initializeApplication(16),
  startApplication(17),
  stopApplication(18),
  saveConfiguration(19),
  enableUnsolicited(20),
  disableUnsolicited(21),
  assignClass(22),
  delayMeasure(23),
  recordCurrentTime(24),
  openFile(25),
  closeFile(26),
  deleteFile(27),
  getFileInfo(28),
  authenticateFile(29),
  abortFile(30),
  response(129),
  unsolicitedResponse(130);

  final int code;
  const FunctionCode(this.code);

  static FunctionCode? fromCode(int code) {
    for (final f in values) {
      if (f.code == code) return f;
    }
    return null;
  }
}

enum QualifierCode {
  range8(0x00),
  range16(0x01),
  allObjects(0x06),
  count8(0x07),
  count16(0x08),
  countAndPrefix8(0x17),
  countAndPrefix16(0x28),
  freeFormat16(0x5B);

  final int code;
  const QualifierCode(this.code);

  static QualifierCode? fromCode(int code) {
    for (final q in values) {
      if (q.code == code) return q;
    }
    return null;
  }
}

/// Internal indications (IIN1 / IIN2)
final class Iin {
  final int iin1;
  final int iin2;
  const Iin(this.iin1, this.iin2);

  bool get broadcast => iin1 & 0x01 != 0;
  bool get class1Events => iin1 & 0x02 != 0;
  bool get class2Events => iin1 & 0x04 != 0;
  bool get class3Events => iin1 & 0x08 != 0;
  bool get needTime => iin1 & 0x10 != 0;
  bool get localControl => iin1 & 0x20 != 0;
  bool get deviceTrouble => iin1 & 0x40 != 0;
  bool get deviceRestart => iin1 & 0x80 != 0;
  bool get noFuncCodeSupport => iin2 & 0x01 != 0;
  bool get objectUnknown => iin2 & 0x02 != 0;
  bool get parameterError => iin2 & 0x04 != 0;
  bool get eventBufferOverflow => iin2 & 0x08 != 0;
  bool get alreadyExecuting => iin2 & 0x10 != 0;
  bool get configCorrupt => iin2 & 0x20 != 0;

  @override
  String toString() =>
      'Iin(0x${iin1.toRadixString(16).padLeft(2, '0')}, 0x${iin2.toRadixString(16).padLeft(2, '0')})';
}

/// What triggered a measurement fragment
enum ReadType { startupIntegrity, unsolicited, singlePoll, periodicPoll, local }

/// Event classes 1..3
final class EventClasses {
  final bool class1;
  final bool class2;
  final bool class3;

  const EventClasses({this.class1 = false, this.class2 = false, this.class3 = false});
  const EventClasses.all() : this(class1: true, class2: true, class3: true);
  const EventClasses.none() : this();

  Map<String, Object?> toJson() => {'class1': class1, 'class2': class2, 'class3': class3};
}

/// Classes 0..3 (class 0 = static data)
final class Classes {
  final bool class0;
  final EventClasses events;

  const Classes({this.class0 = false, this.events = const EventClasses.none()});
  const Classes.all() : this(class0: true, events: const EventClasses.all());
  const Classes.class0() : this(class0: true);
  const Classes.class123() : this(events: const EventClasses.all());
  const Classes.none() : this();

  int get mask =>
      (class0 ? 1 : 0) | (events.class1 ? 2 : 0) | (events.class2 ? 4 : 0) | (events.class3 ? 8 : 0);

  Map<String, Object?> toJson() => {
    'class0': class0,
    'class1': events.class1,
    'class2': events.class2,
    'class3': events.class3,
  };
}

/// Connection state of TCP / TLS clients
enum ClientState { disabled, connecting, connected, waitAfterFailedConnect, waitAfterDisconnect, shutdown }

/// State change of a client together with the retry delay (if any)
final class ClientStateEvent {
  final ClientState state;
  final Duration? retryDelay;
  const ClientStateEvent(this.state, this.retryDelay);

  @override
  String toString() => retryDelay == null ? '$state' : '$state (${retryDelay!.inMilliseconds} ms)';
}

/// State of a serial port
enum PortState { disabled, wait, open, shutdown }

final class PortStateEvent {
  final PortState state;
  final Duration? retryDelay;
  const PortStateEvent(this.state, this.retryDelay);

  @override
  String toString() => '$state';
}

/// Connection state of an outstation attached to a TCP / TLS server
enum ConnectionState { disconnected, connected }

/// Detailed connection events of TCP / TLS clients
enum ConnectionEventType { connecting, connected, connectFailed, disconnected, resolutionFailed }

final class ConnectionEvent {
  final ConnectionEventType type;

  /// resolved socket address, e.g. `127.0.0.1:20000`
  final String? address;

  /// host name if the endpoint was configured by name
  final String? hostname;

  const ConnectionEvent(this.type, this.address, this.hostname);

  @override
  String toString() => 'ConnectionEvent($type, $address${hostname != null ? ', $hostname' : ''})';
}
