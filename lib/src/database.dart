/// Outstation database: point definitions, batched updates and reads.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart' show malloc;

import 'config.dart';
import 'measurements.dart';
import 'native/bindings.dart';
import 'native/protocol.dart';
import 'native/runtime.dart';
import 'native/writer.dart';
import 'requests.dart' show encodeAttribute;
import 'types.dart';

enum EventClass { class1, class2, class3 }

/// Point types stored in an outstation database
enum PointType {
  binaryInput(PointKind.binaryInput),
  doubleBitBinaryInput(PointKind.doubleBitBinaryInput),
  binaryOutputStatus(PointKind.binaryOutputStatus),
  counter(PointKind.counter),
  frozenCounter(PointKind.frozenCounter),
  analogInput(PointKind.analogInput),
  analogOutputStatus(PointKind.analogOutputStatus),
  octetString(PointKind.octetString);

  final int code;
  const PointType(this.code);
}

enum StaticBinaryInputVariation {
  group1Var1(1),
  group1Var2(2);

  final int code;
  const StaticBinaryInputVariation(this.code);
}

enum EventBinaryInputVariation {
  group2Var1(1),
  group2Var2(2),
  group2Var3(3);

  final int code;
  const EventBinaryInputVariation(this.code);
}

enum StaticDoubleBitBinaryInputVariation {
  group3Var1(1),
  group3Var2(2);

  final int code;
  const StaticDoubleBitBinaryInputVariation(this.code);
}

enum EventDoubleBitBinaryInputVariation {
  group4Var1(1),
  group4Var2(2),
  group4Var3(3);

  final int code;
  const EventDoubleBitBinaryInputVariation(this.code);
}

enum StaticBinaryOutputStatusVariation {
  group10Var1(1),
  group10Var2(2);

  final int code;
  const StaticBinaryOutputStatusVariation(this.code);
}

enum EventBinaryOutputStatusVariation {
  group11Var1(1),
  group11Var2(2);

  final int code;
  const EventBinaryOutputStatusVariation(this.code);
}

enum StaticCounterVariation {
  group20Var1(1),
  group20Var2(2),
  group20Var5(5),
  group20Var6(6);

  final int code;
  const StaticCounterVariation(this.code);
}

enum EventCounterVariation {
  group22Var1(1),
  group22Var2(2),
  group22Var5(5),
  group22Var6(6);

  final int code;
  const EventCounterVariation(this.code);
}

enum StaticFrozenCounterVariation {
  group21Var1(1),
  group21Var2(2),
  group21Var5(5),
  group21Var6(6),
  group21Var9(9),
  group21Var10(10);

  final int code;
  const StaticFrozenCounterVariation(this.code);
}

enum EventFrozenCounterVariation {
  group23Var1(1),
  group23Var2(2),
  group23Var5(5),
  group23Var6(6);

  final int code;
  const EventFrozenCounterVariation(this.code);
}

enum StaticAnalogInputVariation {
  group30Var1(1),
  group30Var2(2),
  group30Var3(3),
  group30Var4(4),
  group30Var5(5),
  group30Var6(6);

  final int code;
  const StaticAnalogInputVariation(this.code);
}

enum EventAnalogInputVariation {
  group32Var1(1),
  group32Var2(2),
  group32Var3(3),
  group32Var4(4),
  group32Var5(5),
  group32Var6(6),
  group32Var7(7),
  group32Var8(8);

  final int code;
  const EventAnalogInputVariation(this.code);
}

enum StaticAnalogOutputStatusVariation {
  group40Var1(1),
  group40Var2(2),
  group40Var3(3),
  group40Var4(4);

  final int code;
  const StaticAnalogOutputStatusVariation(this.code);
}

enum EventAnalogOutputStatusVariation {
  group42Var1(1),
  group42Var2(2),
  group42Var3(3),
  group42Var4(4),
  group42Var5(5),
  group42Var6(6),
  group42Var7(7),
  group42Var8(8);

  final int code;
  const EventAnalogOutputStatusVariation(this.code);
}

/// Result of an operation in a [DatabaseTransaction]
enum UpdateStatus {
  /// the point does not exist / the operation failed
  noPoint,

  /// applied, no event was generated
  noEvent,

  /// applied and an event was created ([UpdateResult.eventId])
  created,

  /// applied, an event was created and another one discarded because the buffer was full
  overflow,
}

final class UpdateResult {
  final UpdateStatus status;
  final int eventId;
  final int discardedId;
  const UpdateResult(this.status, this.eventId, this.discardedId);
  bool get ok => status != UpdateStatus.noPoint;
  @override
  String toString() => 'UpdateResult($status, $eventId)';
}

int _eventClass(EventClass? c) => c == null ? 0 : c.index + 1;

int _timeKind(Dnp3Time? t) => t?.kind ?? 0;

/// Records database operations. All operations of a transaction are executed natively
/// under a single database lock and produce a single change notification.
///
/// The operations are encoded into a reusable buffer that the native side reads in place
/// (no copy).
final class DatabaseTransaction {
  final ByteWriter _w;
  int _count = 0;

  DatabaseTransaction._(this._w);

  /// A detached transaction that can be built anywhere (e.g. in a worker isolate) and
  /// applied later with `Outstation.apply`
  DatabaseTransaction() : this._(ByteWriter(1024));

  int get operationCount => _count;

  /// Encoded operations (view; valid until the next mutation)
  Uint8List get bytes => _w.bytes;

  void clear() {
    _w.reset();
    _count = 0;
  }

  void _header(int op, int type, int index) {
    RangeError.checkValueInInterval(index, 0, 0xFFFF, 'index');
    _w.u32(op | (type << 8) | (index << 16));
    _count++;
  }

  void _add(int type, int index, EventClass? eventClass, int s, int e, double deadband) {
    _header(2, type, index);
    _w
      ..u8(_eventClass(eventClass))
      ..u8(s)
      ..u8(e)
      ..u8(0)
      ..f64(deadband);
  }

  // ----------------------------------------------------------------- add

  void addBinaryInput(
    int index, {
    EventClass? eventClass = EventClass.class1,
    StaticBinaryInputVariation staticVariation = StaticBinaryInputVariation.group1Var1,
    EventBinaryInputVariation eventVariation = EventBinaryInputVariation.group2Var1,
  }) => _add(PointKind.binaryInput, index, eventClass, staticVariation.code, eventVariation.code, 0);

  void addDoubleBitBinaryInput(
    int index, {
    EventClass? eventClass = EventClass.class1,
    StaticDoubleBitBinaryInputVariation staticVariation = StaticDoubleBitBinaryInputVariation.group3Var1,
    EventDoubleBitBinaryInputVariation eventVariation = EventDoubleBitBinaryInputVariation.group4Var1,
  }) => _add(PointKind.doubleBitBinaryInput, index, eventClass, staticVariation.code, eventVariation.code, 0);

  void addBinaryOutputStatus(
    int index, {
    EventClass? eventClass = EventClass.class1,
    StaticBinaryOutputStatusVariation staticVariation = StaticBinaryOutputStatusVariation.group10Var1,
    EventBinaryOutputStatusVariation eventVariation = EventBinaryOutputStatusVariation.group11Var1,
  }) => _add(PointKind.binaryOutputStatus, index, eventClass, staticVariation.code, eventVariation.code, 0);

  void addCounter(
    int index, {
    EventClass? eventClass = EventClass.class1,
    StaticCounterVariation staticVariation = StaticCounterVariation.group20Var1,
    EventCounterVariation eventVariation = EventCounterVariation.group22Var1,
    int deadband = 0,
  }) => _add(
    PointKind.counter,
    index,
    eventClass,
    staticVariation.code,
    eventVariation.code,
    RangeError.checkValueInInterval(deadband, 0, 0xFFFFFFFF, 'deadband').toDouble(),
  );

  void addFrozenCounter(
    int index, {
    EventClass? eventClass = EventClass.class1,
    StaticFrozenCounterVariation staticVariation = StaticFrozenCounterVariation.group21Var1,
    EventFrozenCounterVariation eventVariation = EventFrozenCounterVariation.group23Var1,
    int deadband = 0,
  }) => _add(
    PointKind.frozenCounter,
    index,
    eventClass,
    staticVariation.code,
    eventVariation.code,
    RangeError.checkValueInInterval(deadband, 0, 0xFFFFFFFF, 'deadband').toDouble(),
  );

  void addAnalogInput(
    int index, {
    EventClass? eventClass = EventClass.class1,
    StaticAnalogInputVariation staticVariation = StaticAnalogInputVariation.group30Var1,
    EventAnalogInputVariation eventVariation = EventAnalogInputVariation.group32Var1,
    double deadband = 0,
  }) => _add(PointKind.analogInput, index, eventClass, staticVariation.code, eventVariation.code, deadband);

  void addAnalogOutputStatus(
    int index, {
    EventClass? eventClass = EventClass.class1,
    StaticAnalogOutputStatusVariation staticVariation = StaticAnalogOutputStatusVariation.group40Var1,
    EventAnalogOutputStatusVariation eventVariation = EventAnalogOutputStatusVariation.group42Var1,
    double deadband = 0,
  }) => _add(
    PointKind.analogOutputStatus,
    index,
    eventClass,
    staticVariation.code,
    eventVariation.code,
    deadband,
  );

  void addOctetString(int index, {EventClass? eventClass = EventClass.class1}) =>
      _add(PointKind.octetString, index, eventClass, 0, 0, 0);

  // ----------------------------------------------------------------- remove

  void remove(PointType type, int index) => _header(3, type.code, index);
  void removeBinaryInput(int index) => remove(PointType.binaryInput, index);
  void removeDoubleBitBinaryInput(int index) => remove(PointType.doubleBitBinaryInput, index);
  void removeBinaryOutputStatus(int index) => remove(PointType.binaryOutputStatus, index);
  void removeCounter(int index) => remove(PointType.counter, index);
  void removeFrozenCounter(int index) => remove(PointType.frozenCounter, index);
  void removeAnalogInput(int index) => remove(PointType.analogInput, index);
  void removeAnalogOutputStatus(int index) => remove(PointType.analogOutputStatus, index);
  void removeOctetString(int index) => remove(PointType.octetString, index);

  // ----------------------------------------------------------------- update

  void _upd(int type, int index, int flags, Dnp3Time? time, EventMode mode, bool updateStatic, int bits) {
    _count++;
    _w.dbUpdate(
      type,
      index,
      flags,
      _timeKind(time),
      mode.index,
      updateStatic ? 1 : 0,
      bits,
      time?.millis ?? 0,
    );
  }

  void _updD(int type, int index, int flags, Dnp3Time? time, EventMode mode, bool updateStatic, double v) {
    _count++;
    _w.dbUpdateDouble(
      type,
      index,
      flags,
      _timeKind(time),
      mode.index,
      updateStatic ? 1 : 0,
      v,
      time?.millis ?? 0,
    );
  }

  void updateBinaryInput(
    int index,
    bool value, {
    Flags flags = Flags.online,
    Dnp3Time? time,
    EventMode mode = EventMode.detect,
    bool updateStatic = true,
  }) => _upd(PointKind.binaryInput, index, flags.value, time, mode, updateStatic, value ? 1 : 0);

  void updateDoubleBitBinaryInput(
    int index,
    DoubleBit value, {
    Flags flags = Flags.online,
    Dnp3Time? time,
    EventMode mode = EventMode.detect,
    bool updateStatic = true,
  }) => _upd(PointKind.doubleBitBinaryInput, index, flags.value, time, mode, updateStatic, value.index);

  void updateBinaryOutputStatus(
    int index,
    bool value, {
    Flags flags = Flags.online,
    Dnp3Time? time,
    EventMode mode = EventMode.detect,
    bool updateStatic = true,
  }) => _upd(PointKind.binaryOutputStatus, index, flags.value, time, mode, updateStatic, value ? 1 : 0);

  void updateCounter(
    int index,
    int value, {
    Flags flags = Flags.online,
    Dnp3Time? time,
    EventMode mode = EventMode.detect,
    bool updateStatic = true,
  }) => _upd(PointKind.counter, index, flags.value, time, mode, updateStatic, value & 0xFFFFFFFF);

  void updateFrozenCounter(
    int index,
    int value, {
    Flags flags = Flags.online,
    Dnp3Time? time,
    EventMode mode = EventMode.detect,
    bool updateStatic = true,
  }) => _upd(PointKind.frozenCounter, index, flags.value, time, mode, updateStatic, value & 0xFFFFFFFF);

  void updateAnalogInput(
    int index,
    double value, {
    Flags flags = Flags.online,
    Dnp3Time? time,
    EventMode mode = EventMode.detect,
    bool updateStatic = true,
  }) => _updD(PointKind.analogInput, index, flags.value, time, mode, updateStatic, value);

  void updateAnalogOutputStatus(
    int index,
    double value, {
    Flags flags = Flags.online,
    Dnp3Time? time,
    EventMode mode = EventMode.detect,
    bool updateStatic = true,
  }) => _updD(PointKind.analogOutputStatus, index, flags.value, time, mode, updateStatic, value);

  void updateOctetString(
    int index,
    List<int> value, {
    EventMode mode = EventMode.detect,
    bool updateStatic = true,
  }) {
    if (value.length > 255) throw ArgumentError('octet strings are limited to 255 bytes');
    _header(1, PointKind.octetString, index);
    _w
      ..u8(mode.index)
      ..u8(updateStatic ? 1 : 0)
      ..u16(value.length)
      ..bytesOf(value)
      ..pad4();
  }

  /// Update only the flags of a point (keeps the value)
  void updateFlags(
    PointType type,
    int index,
    Flags flags, {
    Dnp3Time? time,
    EventMode mode = EventMode.detect,
    bool updateStatic = true,
  }) {
    if (type == PointType.octetString) throw ArgumentError('octet strings have no flags');
    _header(4, type.code, index);
    _w
      ..u8(flags.value)
      ..u8(_timeKind(time))
      ..u8(mode.index)
      ..u8(updateStatic ? 1 : 0)
      ..u64(time?.millis ?? 0);
  }

  /// Define a device attribute (group 0) served by the outstation
  void defineAttribute(DeviceAttribute attribute, {bool writable = false}) {
    _header(5, 0, 0);
    _w
      ..u8(writable ? 1 : 0)
      ..zeros(3);
    encodeAttribute(_w, attribute);
  }

  /// Discard events of the given classes that are not currently selected for a response
  void discardUnselectedEvents(EventClasses classes) {
    final mask = (classes.class1 ? 2 : 0) | (classes.class2 ? 4 : 0) | (classes.class3 ? 8 : 0);
    _header(6, mask, 0);
  }
}

/// Decode the 24-byte result records written by `dnp3_outstation_transaction`
List<UpdateResult> decodeResults(Uint8List out, int count) {
  final d = ByteData.sublistView(out);
  return [
    for (var i = 0; i < count; i++)
      UpdateResult(
        UpdateStatus.values[d.getUint32(i * 24, Endian.little).clamp(0, 3)],
        d.getUint64(i * 24 + 8, Endian.little),
        d.getUint64(i * 24 + 16, Endian.little),
      ),
  ];
}

/// Synchronous access to the database of an outstation. Usable from any isolate: it only
/// needs the outstation handle.
final class Database {
  final int handle;
  final DatabaseTransaction _tx = DatabaseTransaction();
  final Uint8List _scratch = Uint8List(512);
  bool _inTransaction = false;

  Database(this.handle);

  /// Run `build` and apply the recorded operations atomically. Returns the number of
  /// operations, or the per-operation results when `results` is true.
  int transaction(void Function(DatabaseTransaction tx) build) {
    if (_inTransaction) throw StateError('nested transaction');
    _inTransaction = true;
    try {
      _tx.clear();
      build(_tx);
      return apply(_tx);
    } finally {
      _inTransaction = false;
    }
  }

  /// Like [transaction] but returns a result per operation
  List<UpdateResult> transactionWithResults(void Function(DatabaseTransaction tx) build) {
    if (_inTransaction) throw StateError('nested transaction');
    _inTransaction = true;
    try {
      _tx.clear();
      build(_tx);
      return applyWithResults(_tx);
    } finally {
      _inTransaction = false;
    }
  }

  /// Apply a transaction built elsewhere
  int apply(DatabaseTransaction tx) {
    final buf = tx._w.buffer;
    return check(dnp3_outstation_transaction(handle, buf.address, tx._w.length, nullptr, 0));
  }

  List<UpdateResult> applyWithResults(DatabaseTransaction tx) {
    final out = Uint8List(tx.operationCount * 24);
    final buf = tx._w.buffer;
    final n = check(dnp3_outstation_transaction(handle, buf.address, tx._w.length, out.address, out.length));
    return decodeResults(out, n);
  }

  /// Apply raw encoded operations (e.g. `DatabaseTransaction.bytes` sent from another isolate)
  int applyBytes(Uint8List ops) =>
      check(dnp3_outstation_transaction(handle, ops.address, ops.length, nullptr, 0));

  int _get(int kind, int index) {
    RangeError.checkValueInInterval(index, 0, 0xFFFF, 'index');
    final buf = _scratch;
    return check(dnp3_outstation_get(handle, kind, index, buf.address, buf.length));
  }

  ByteData get _sd => ByteData.sublistView(_scratch);

  BinaryInput? getBinaryInput(int index) {
    if (_get(PointKind.binaryInput, index) == 0) return null;
    final d = _sd;
    return BinaryInput(
      index,
      d.getUint8(2) != 0,
      flags: Flags(d.getUint8(3)),
      time: Dnp3Time.decode(d.getUint8(4), d.getUint64(8, Endian.little)),
    );
  }

  DoubleBitBinaryInput? getDoubleBitBinaryInput(int index) {
    if (_get(PointKind.doubleBitBinaryInput, index) == 0) return null;
    final d = _sd;
    return DoubleBitBinaryInput(
      index,
      DoubleBit.fromCode(d.getUint8(2)),
      flags: Flags(d.getUint8(3)),
      time: Dnp3Time.decode(d.getUint8(4), d.getUint64(8, Endian.little)),
    );
  }

  BinaryOutputStatus? getBinaryOutputStatus(int index) {
    if (_get(PointKind.binaryOutputStatus, index) == 0) return null;
    final d = _sd;
    return BinaryOutputStatus(
      index,
      d.getUint8(2) != 0,
      flags: Flags(d.getUint8(3)),
      time: Dnp3Time.decode(d.getUint8(4), d.getUint64(8, Endian.little)),
    );
  }

  Counter? getCounter(int index) {
    if (_get(PointKind.counter, index) == 0) return null;
    final d = _sd;
    return Counter(
      index,
      d.getUint32(4, Endian.little),
      flags: Flags(d.getUint8(2)),
      time: Dnp3Time.decode(d.getUint8(3), d.getUint64(8, Endian.little)),
    );
  }

  FrozenCounter? getFrozenCounter(int index) {
    if (_get(PointKind.frozenCounter, index) == 0) return null;
    final d = _sd;
    return FrozenCounter(
      index,
      d.getUint32(4, Endian.little),
      flags: Flags(d.getUint8(2)),
      time: Dnp3Time.decode(d.getUint8(3), d.getUint64(8, Endian.little)),
    );
  }

  AnalogInput? getAnalogInput(int index) {
    if (_get(PointKind.analogInput, index) == 0) return null;
    final d = _sd;
    return AnalogInput(
      index,
      d.getFloat64(8, Endian.little),
      flags: Flags(d.getUint8(2)),
      time: Dnp3Time.decode(d.getUint8(3), d.getUint64(16, Endian.little)),
    );
  }

  AnalogOutputStatus? getAnalogOutputStatus(int index) {
    if (_get(PointKind.analogOutputStatus, index) == 0) return null;
    final d = _sd;
    return AnalogOutputStatus(
      index,
      d.getFloat64(8, Endian.little),
      flags: Flags(d.getUint8(2)),
      time: Dnp3Time.decode(d.getUint8(3), d.getUint64(16, Endian.little)),
    );
  }

  Uint8List? getOctetString(int index) {
    if (_get(PointKind.octetString, index) == 0) return null;
    final len = ByteData.sublistView(_scratch).getUint16(2, Endian.little);
    return Uint8List.fromList(Uint8List.sublistView(_scratch, 4, 4 + len));
  }

  /// All defined points of one kind in `[start, stop]` as a zero-copy block view backed by
  /// native memory (released by a finalizer).
  MeasurementBlock getRange(PointType type, int start, int stop) {
    RangeError.checkValueInInterval(start, 0, 0xFFFF, 'start');
    RangeError.checkValueInInterval(stop, 0, 0xFFFF, 'stop');
    final lenPtr = _lenSlot;
    final ptr = dnp3_outstation_get_range(handle, type.code, start, stop, lenPtr);
    if (ptr == nullptr) throw lastError(-ErrorCode.invalidArgument);
    final len = lenPtr.value;
    final bytes = ptr.asTypedList(len, finalizer: dnp3BufferFreePtr);
    return MeasurementFragment(bytes).blocks.first;
  }

  /// one process-lifetime slot per isolate for the length out-parameter
  static final Pointer<Size> _lenSlot = malloc<Size>();
}
