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
  /// Milliseconds since 1970-01-01T00:00:00Z (DNP3 encodes this as an unsigned 48-bit value).
  final int millis;

  /// Whether the clock that produced the timestamp was synchronized.
  final TimeQuality quality;

  /// Timestamp from raw epoch milliseconds; [quality] defaults to synchronized.
  const Dnp3Time(this.millis, [this.quality = TimeQuality.synchronized]);

  /// Timestamp from [t] (any time zone; only its epoch milliseconds are kept).
  Dnp3Time.fromDateTime(DateTime t, [this.quality = TimeQuality.synchronized])
    : millis = t.millisecondsSinceEpoch;

  /// Timestamp of the current system time.
  factory Dnp3Time.now([TimeQuality quality = TimeQuality.synchronized]) =>
      Dnp3Time(DateTime.now().millisecondsSinceEpoch, quality);

  /// True when [quality] is [TimeQuality.synchronized].
  bool get isSynchronized => quality == TimeQuality.synchronized;

  /// The timestamp as a UTC [DateTime].
  DateTime toDateTime() => DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);

  /// native encoding: 0 none, 1 synchronized, 2 unsynchronized
  int get kind => quality == TimeQuality.synchronized ? 1 : 2;

  /// Decodes a native (time kind, millis) pair; returns null for kind 0 (no time) or any unknown kind.
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
extension type const Flags(
  /// The raw flag byte (bit 0 = ONLINE ... bit 7 = point-type specific)
  int value
) {
  /// No flag set (0x00); note that this means OFFLINE.
  static const Flags none = Flags(0);

  /// ONLINE (bit 0): the point is active and its value is valid.
  static const Flags online = Flags(0x01);

  /// RESTART (bit 1): the value has not been updated since the device restarted.
  static const Flags restart = Flags(0x02);

  /// COMM_LOST (bit 2): communication with the originating device was lost.
  static const Flags commLost = Flags(0x04);

  /// REMOTE_FORCED (bit 3): the value is forced by a downstream/remote device.
  static const Flags remoteForced = Flags(0x08);

  /// LOCAL_FORCED (bit 4): the value is forced at this device.
  static const Flags localForced = Flags(0x10);

  /// CHATTER_FILTER (bit 5, binary / double-bit inputs): the input is being filtered for chatter.
  static const Flags chatterFilter = Flags(0x20);

  /// OVER_RANGE (bit 5, analog inputs / outputs): the value exceeds the representable range.
  static const Flags overRange = Flags(0x20);

  /// ROLLOVER (bit 5, counters): obsolete counter rollover bit (same bit as [chatterFilter]).
  static const Flags rollOver = Flags(0x20);

  /// DISCONTINUITY (bit 6, counters): the counter value may not be continuous with the last report.
  static const Flags discontinuity = Flags(0x40);

  /// REFERENCE_ERR (bit 6, analogs): the reference or calibration of the value may be wrong.
  static const Flags referenceError = Flags(0x40);

  /// True when every bit of [other] is set in this value.
  bool has(Flags other) => (value & other.value) == other.value;

  /// Union of both flag sets.
  Flags operator |(Flags other) => Flags(value | other.value);

  /// Intersection of both flag sets.
  Flags operator &(Flags other) => Flags(value & other.value);
}

/// State of a double-bit binary input (g3 / g4), in wire-code order 0..3.
enum DoubleBit {
  /// 0: transitioning between states (in transit).
  intermediate,

  /// 1: determined OFF (open / tripped).
  determinedOff,

  /// 2: determined ON (closed).
  determinedOn,

  /// 3: state cannot be determined (abnormal / invalid).
  indeterminate;

  /// Decodes the two low bits of [code].
  static DoubleBit fromCode(int code) => values[code & 0x03];
}

/// Status code of a control operation (CROB / analog output)
enum CommandStatus {
  /// 0: the request was accepted, initiated or queued.
  success(0),

  /// 1: OPERATE arrived after the select timeout expired.
  timeout(1),

  /// 2: OPERATE without a matching prior SELECT.
  noSelect(2),

  /// 3: the request was not accepted because of formatting errors.
  formatError(3),

  /// 4: the operation is not supported for this point.
  notSupported(4),

  /// 5: the request is already in progress / queue is full.
  alreadyActive(5),

  /// 6: the request failed because of a hardware problem.
  hardwareError(6),

  /// 7: the outstation is in local control mode.
  local(7),

  /// 8: too many objects in the request.
  tooManyOps(8),

  /// 9: the master is not authorized for this operation.
  notAuthorized(9),

  /// 10: inhibited by a local automation process.
  automationInhibit(10),

  /// 11: the device cannot process the request because of limited processing resources.
  processingLimited(11),

  /// 12: the value is outside the permitted range.
  outOfRange(12),

  /// 13: a downstream device is in local control mode.
  downstreamLocal(13),

  /// 14: the requested operation has already been completed.
  alreadyComplete(14),

  /// 15: the operation is blocked by another condition or interlock.
  blocked(15),

  /// 16: the operation was canceled before completion.
  canceled(16),

  /// 17: another master holds the point (blocked by other master).
  blockedOtherMaster(17),

  /// 18: a downstream device failed to accept or complete the request.
  downstreamFail(18),

  /// 126: (deprecated) the point does not participate in this operation.
  nonParticipating(126),

  /// 127: undefined; also returned by [fromCode] for any unlisted code.
  unknown(127);

  /// Numeric status code on the wire.
  final int code;
  const CommandStatus(this.code);

  /// Status for [code]; any unlisted code maps to [unknown].
  static CommandStatus fromCode(int code) =>
      values.firstWhere((s) => s.code == code, orElse: () => CommandStatus.unknown);
}

/// Operation type of a CROB control code (low nibble of the g12v1 control byte).
enum OpType {
  /// 0: no operation (null).
  nul(0),

  /// 1: PULSE_ON, using the CROB on/off times.
  pulseOn(1),

  /// 2: PULSE_OFF (obsolete in IEEE 1815-2012).
  pulseOff(2),

  /// 3: LATCH_ON.
  latchOn(3),

  /// 4: LATCH_OFF.
  latchOff(4);

  /// Numeric operation type code.
  final int code;
  const OpType(this.code);

  /// Op type for [code]; unknown codes map to [nul].
  static OpType fromCode(int code) => values.firstWhere((x) => x.code == code, orElse: () => OpType.nul);
}

/// Trip/close code of a CROB control code (top two bits of the g12v1 control byte).
enum TripCloseCode {
  /// 0: no trip/close pairing (single-point control).
  nul(0),

  /// 1: CLOSE (select the close coil of a paired output).
  close(1),

  /// 2: TRIP (select the trip coil of a paired output).
  trip(2),

  /// 3: reserved by IEEE 1815.
  reserved(3);

  /// Numeric trip/close code (0..3).
  final int code;
  const TripCloseCode(this.code);

  /// Decodes the two low bits of [code].
  static TripCloseCode fromCode(int code) => values[code & 0x03];
}

/// Control code of a CROB (g12v1)
final class ControlCode {
  /// Trip/close code (bits 7..6).
  final TripCloseCode tcc;

  /// CLEAR bit (0x20): cancel queued / in-progress operations.
  final bool clear;

  /// QUEUE bit (0x10, obsolete): queue the operation.
  final bool queue;

  /// Operation type (bits 3..0).
  final OpType opType;

  /// Control code from its individual fields; only [opType] is required.
  const ControlCode({
    this.tcc = TripCloseCode.nul,
    this.clear = false,
    this.queue = false,
    required this.opType,
  });

  /// LATCH_ON with no trip/close code.
  const ControlCode.latchOn() : this(opType: OpType.latchOn);

  /// LATCH_OFF with no trip/close code.
  const ControlCode.latchOff() : this(opType: OpType.latchOff);

  /// PULSE_ON with no trip/close code.
  const ControlCode.pulseOn() : this(opType: OpType.pulseOn);

  /// PULSE_OFF with no trip/close code.
  const ControlCode.pulseOff() : this(opType: OpType.pulseOff);

  /// CLOSE + PULSE_ON (paired close output).
  const ControlCode.close() : this(tcc: TripCloseCode.close, opType: OpType.pulseOn);

  /// TRIP + PULSE_ON (paired trip output).
  const ControlCode.trip() : this(tcc: TripCloseCode.trip, opType: OpType.pulseOn);

  /// Decodes a g12v1 control byte (TCC bits 7..6, CLEAR 0x20, QUEUE 0x10, op type bits 3..0).
  factory ControlCode.fromByte(int b) => ControlCode(
    tcc: TripCloseCode.fromCode(b >> 6),
    clear: b & 0x20 != 0,
    queue: b & 0x10 != 0,
    opType: OpType.fromCode(b & 0x0F),
  );

  /// Encodes this control code as the g12v1 control byte.
  int toByte() => (tcc.code << 6) | (clear ? 0x20 : 0) | (queue ? 0x10 : 0) | (opType.code & 0x0F);

  @override
  String toString() => 'ControlCode($tcc, $opType, clear: $clear, queue: $queue)';
}

/// DNP3 application-layer function code.
enum FunctionCode {
  /// 0: confirm a received fragment.
  confirm(0),

  /// 1: read objects.
  read(1),

  /// 2: write objects.
  write(2),

  /// 3: select controls (first half of select-before-operate).
  select(3),

  /// 4: operate previously selected controls.
  operate(4),

  /// 5: operate controls without a prior select.
  directOperate(5),

  /// 6: direct operate without a response.
  directOperateNoResponse(6),

  /// 7: freeze counters.
  immediateFreeze(7),

  /// 8: freeze counters without a response.
  immediateFreezeNoResponse(8),

  /// 9: freeze counters and clear them.
  freezeClear(9),

  /// 10: freeze-and-clear without a response.
  freezeClearNoResponse(10),

  /// 11: freeze counters at a given time / interval.
  freezeAtTime(11),

  /// 12: freeze-at-time without a response.
  freezeAtTimeNoResponse(12),

  /// 13: full (cold) restart of the outstation.
  coldRestart(13),

  /// 14: partial (warm) restart of the outstation.
  warmRestart(14),

  /// 15: (obsolete) initialize data to initial values.
  initializeData(15),

  /// 16: prepare an application to start.
  initializeApplication(16),

  /// 17: start an application.
  startApplication(17),

  /// 18: stop an application.
  stopApplication(18),

  /// 19: (deprecated) save configuration.
  saveConfiguration(19),

  /// 20: enable unsolicited responses for the given classes.
  enableUnsolicited(20),

  /// 21: disable unsolicited responses for the given classes.
  disableUnsolicited(21),

  /// 22: assign points to event classes.
  assignClass(22),

  /// 23: measure the outstation response delay (non-LAN time sync).
  delayMeasure(23),

  /// 24: record the current time (LAN time sync).
  recordCurrentTime(24),

  /// 25: open a file.
  openFile(25),

  /// 26: close a file.
  closeFile(26),

  /// 27: delete a file.
  deleteFile(27),

  /// 28: get file information.
  getFileInfo(28),

  /// 29: obtain a file authentication key.
  authenticateFile(29),

  /// 30: abort a file transfer.
  abortFile(30),

  /// 129: solicited response from an outstation.
  response(129),

  /// 130: unsolicited response from an outstation.
  unsolicitedResponse(130);

  /// Numeric function code on the wire.
  final int code;
  const FunctionCode(this.code);

  /// Function code for [code], or null if it is not one of the listed codes.
  static FunctionCode? fromCode(int code) {
    for (final f in values) {
      if (f.code == code) return f;
    }
    return null;
  }
}

/// Object header qualifier code (how the objects of a header are addressed).
enum QualifierCode {
  /// 0x00: 8-bit start/stop index range.
  range8(0x00),

  /// 0x01: 16-bit start/stop index range.
  range16(0x01),

  /// 0x06: all objects (no range field).
  allObjects(0x06),

  /// 0x07: 8-bit object count, no index prefix.
  count8(0x07),

  /// 0x08: 16-bit object count, no index prefix.
  count16(0x08),

  /// 0x17: 8-bit count, each object prefixed with an 8-bit index.
  countAndPrefix8(0x17),

  /// 0x28: 16-bit count, each object prefixed with a 16-bit index.
  countAndPrefix16(0x28),

  /// 0x5B: 16-bit count of free-format objects, each prefixed with a 16-bit size.
  freeFormat16(0x5B);

  /// Numeric qualifier byte.
  final int code;
  const QualifierCode(this.code);

  /// Qualifier for [code], or null if it is not one of the listed codes.
  static QualifierCode? fromCode(int code) {
    for (final q in values) {
      if (q.code == code) return q;
    }
    return null;
  }
}

/// Internal indications (IIN1 / IIN2)
final class Iin {
  /// Raw IIN1 byte.
  final int iin1;

  /// Raw IIN2 byte.
  final int iin2;

  /// IIN from the raw IIN1 and IIN2 bytes.
  const Iin(this.iin1, this.iin2);

  /// IIN1.0: a broadcast message was received.
  bool get broadcast => iin1 & 0x01 != 0;

  /// IIN1.1: class 1 events are available.
  bool get class1Events => iin1 & 0x02 != 0;

  /// IIN1.2: class 2 events are available.
  bool get class2Events => iin1 & 0x04 != 0;

  /// IIN1.3: class 3 events are available.
  bool get class3Events => iin1 & 0x08 != 0;

  /// IIN1.4: the outstation requires time synchronization.
  bool get needTime => iin1 & 0x10 != 0;

  /// IIN1.5: some output points are in local control mode.
  bool get localControl => iin1 & 0x20 != 0;

  /// IIN1.6: an abnormal device-specific condition exists.
  bool get deviceTrouble => iin1 & 0x40 != 0;

  /// IIN1.7: the outstation has restarted.
  bool get deviceRestart => iin1 & 0x80 != 0;

  /// IIN2.0: the function code is not supported.
  bool get noFuncCodeSupport => iin2 & 0x01 != 0;

  /// IIN2.1: the requested object(s) are unknown or do not exist.
  bool get objectUnknown => iin2 & 0x02 != 0;

  /// IIN2.2: invalid qualifier, range or other parameter in the request.
  bool get parameterError => iin2 & 0x04 != 0;

  /// IIN2.3: the event buffer overflowed and events were lost.
  bool get eventBufferOverflow => iin2 & 0x08 != 0;

  /// IIN2.4: the requested operation is already executing.
  bool get alreadyExecuting => iin2 & 0x10 != 0;

  /// IIN2.5: the outstation configuration is corrupt.
  bool get configCorrupt => iin2 & 0x20 != 0;

  @override
  String toString() =>
      'Iin(0x${iin1.toRadixString(16).padLeft(2, '0')}, 0x${iin2.toRadixString(16).padLeft(2, '0')})';
}

/// What triggered a measurement fragment
enum ReadType {
  /// Integrity poll performed when the association starts up.
  startupIntegrity,

  /// Unsolicited response sent by the outstation.
  unsolicited,

  /// One-off read requested by the application.
  singlePoll,

  /// Read issued by a configured periodic poll.
  periodicPoll,

  /// Not from a received response, e.g. values read back from a local outstation database.
  local,
}

/// Event classes 1..3
final class EventClasses {
  /// Class 1 events selected.
  final bool class1;

  /// Class 2 events selected.
  final bool class2;

  /// Class 3 events selected.
  final bool class3;

  /// Selection of individual event classes; all default to false.
  const EventClasses({this.class1 = false, this.class2 = false, this.class3 = false});

  /// Classes 1, 2 and 3.
  const EventClasses.all() : this(class1: true, class2: true, class3: true);

  /// No event class.
  const EventClasses.none() : this();

  /// JSON form passed to the native layer (`class1`..`class3` booleans).
  Map<String, Object?> toJson() => {'class1': class1, 'class2': class2, 'class3': class3};
}

/// Classes 0..3 (class 0 = static data)
final class Classes {
  /// Class 0 (static / current values) selected.
  final bool class0;

  /// Selected event classes 1..3.
  final EventClasses events;

  /// Selection of class 0 and event classes; nothing selected by default.
  const Classes({this.class0 = false, this.events = const EventClasses.none()});

  /// Classes 0, 1, 2 and 3 (integrity poll).
  const Classes.all() : this(class0: true, events: const EventClasses.all());

  /// Class 0 (static data) only.
  const Classes.class0() : this(class0: true);

  /// Event classes 1, 2 and 3 only (event poll).
  const Classes.class123() : this(events: const EventClasses.all());

  /// No class.
  const Classes.none() : this();

  /// Bit mask: bit 0 = class 0, bit 1 = class 1, bit 2 = class 2, bit 3 = class 3.
  int get mask =>
      (class0 ? 1 : 0) | (events.class1 ? 2 : 0) | (events.class2 ? 4 : 0) | (events.class3 ? 8 : 0);

  /// JSON form passed to the native layer (`class0`..`class3` booleans).
  Map<String, Object?> toJson() => {
    'class0': class0,
    'class1': events.class1,
    'class2': events.class2,
    'class3': events.class3,
  };
}

/// Connection state of TCP / TLS clients
enum ClientState {
  /// The client is disabled and not trying to connect.
  disabled,

  /// A connection attempt is in progress.
  connecting,

  /// The client is connected.
  connected,

  /// Waiting before retrying after a failed connection attempt.
  waitAfterFailedConnect,

  /// Waiting before reconnecting after the connection was lost.
  waitAfterDisconnect,

  /// The client has been shut down permanently.
  shutdown,
}

/// State change of a client together with the retry delay (if any)
final class ClientStateEvent {
  /// New client state.
  final ClientState state;

  /// Delay before the next attempt for the wait states; null when no delay applies.
  final Duration? retryDelay;

  /// State event with an optional retry delay.
  const ClientStateEvent(this.state, this.retryDelay);

  @override
  String toString() => retryDelay == null ? '$state' : '$state (${retryDelay!.inMilliseconds} ms)';
}

/// State of a serial port
enum PortState {
  /// The port is disabled.
  disabled,

  /// Waiting before trying to (re)open the port.
  wait,

  /// The port is open.
  open,

  /// The port has been shut down permanently.
  shutdown,
}

/// State change of a serial port together with the retry delay (if any).
final class PortStateEvent {
  /// New port state.
  final PortState state;

  /// Delay before the next open attempt in [PortState.wait]; null otherwise.
  final Duration? retryDelay;

  /// State event with an optional retry delay.
  const PortStateEvent(this.state, this.retryDelay);

  @override
  String toString() => '$state';
}

/// Connection state of an outstation attached to a TCP / TLS server
enum ConnectionState {
  /// No master is connected.
  disconnected,

  /// A master is connected.
  connected,
}

/// Detailed connection events of TCP / TLS clients
enum ConnectionEventType {
  /// A connection attempt to [ConnectionEvent.address] started.
  connecting,

  /// The connection to [ConnectionEvent.address] was established.
  connected,

  /// The connection attempt to [ConnectionEvent.address] failed.
  connectFailed,

  /// An established connection was closed.
  disconnected,

  /// Name resolution of [ConnectionEvent.hostname] failed (no address).
  resolutionFailed,
}

/// A single connection event of a TCP / TLS client.
final class ConnectionEvent {
  /// What happened.
  final ConnectionEventType type;

  /// resolved socket address, e.g. `127.0.0.1:20000`
  final String? address;

  /// host name if the endpoint was configured by name
  final String? hostname;

  /// Event with optional address and host name.
  const ConnectionEvent(this.type, this.address, this.hostname);

  @override
  String toString() => 'ConnectionEvent($type, $address${hostname != null ? ', $hostname' : ''})';
}
