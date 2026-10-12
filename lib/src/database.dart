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

/// Event class a point reports its events in (`null` = no events)
enum EventClass {
  /// Class 1 (conventionally the highest priority)
  class1,

  /// Class 2
  class2,

  /// Class 3
  class3,
}

/// Point types stored in an outstation database
enum PointType {
  /// Binary input (groups 1/2)
  binaryInput(PointKind.binaryInput),

  /// Double-bit binary input (groups 3/4)
  doubleBitBinaryInput(PointKind.doubleBitBinaryInput),

  /// Binary output status (groups 10/11)
  binaryOutputStatus(PointKind.binaryOutputStatus),

  /// Counter (groups 20/22)
  counter(PointKind.counter),

  /// Frozen counter (groups 21/23)
  frozenCounter(PointKind.frozenCounter),

  /// Analog input (groups 30/32)
  analogInput(PointKind.analogInput),

  /// Analog output status (groups 40/42)
  analogOutputStatus(PointKind.analogOutputStatus),

  /// Octet string (groups 110/111)
  octetString(PointKind.octetString);

  /// Native point kind code ([PointKind])
  final int code;
  const PointType(this.code);
}

/// Default static (class 0) variation of a binary input (group 1)
enum StaticBinaryInputVariation {
  /// g1v1: packed format (state only, no flags)
  group1Var1(1),

  /// g1v2: with flags
  group1Var2(2);

  /// DNP3 variation number
  final int code;
  const StaticBinaryInputVariation(this.code);
}

/// Default event variation of a binary input (group 2)
enum EventBinaryInputVariation {
  /// g2v1: without time
  group2Var1(1),

  /// g2v2: with absolute time
  group2Var2(2),

  /// g2v3: with relative time
  group2Var3(3);

  /// DNP3 variation number
  final int code;
  const EventBinaryInputVariation(this.code);
}

/// Default static variation of a double-bit binary input (group 3)
enum StaticDoubleBitBinaryInputVariation {
  /// g3v1: packed format (state only, no flags)
  group3Var1(1),

  /// g3v2: with flags
  group3Var2(2);

  /// DNP3 variation number
  final int code;
  const StaticDoubleBitBinaryInputVariation(this.code);
}

/// Default event variation of a double-bit binary input (group 4)
enum EventDoubleBitBinaryInputVariation {
  /// g4v1: without time
  group4Var1(1),

  /// g4v2: with absolute time
  group4Var2(2),

  /// g4v3: with relative time
  group4Var3(3);

  /// DNP3 variation number
  final int code;
  const EventDoubleBitBinaryInputVariation(this.code);
}

/// Default static variation of a binary output status (group 10)
enum StaticBinaryOutputStatusVariation {
  /// g10v1: packed format (state only, no flags)
  group10Var1(1),

  /// g10v2: with flags
  group10Var2(2);

  /// DNP3 variation number
  final int code;
  const StaticBinaryOutputStatusVariation(this.code);
}

/// Default event variation of a binary output status (group 11)
enum EventBinaryOutputStatusVariation {
  /// g11v1: without time
  group11Var1(1),

  /// g11v2: with time
  group11Var2(2);

  /// DNP3 variation number
  final int code;
  const EventBinaryOutputStatusVariation(this.code);
}

/// Default static variation of a counter (group 20)
enum StaticCounterVariation {
  /// g20v1: 32-bit with flag
  group20Var1(1),

  /// g20v2: 16-bit with flag
  group20Var2(2),

  /// g20v5: 32-bit without flag
  group20Var5(5),

  /// g20v6: 16-bit without flag
  group20Var6(6);

  /// DNP3 variation number
  final int code;
  const StaticCounterVariation(this.code);
}

/// Default event variation of a counter (group 22)
enum EventCounterVariation {
  /// g22v1: 32-bit with flag
  group22Var1(1),

  /// g22v2: 16-bit with flag
  group22Var2(2),

  /// g22v5: 32-bit with flag and time
  group22Var5(5),

  /// g22v6: 16-bit with flag and time
  group22Var6(6);

  /// DNP3 variation number
  final int code;
  const EventCounterVariation(this.code);
}

/// Default static variation of a frozen counter (group 21)
enum StaticFrozenCounterVariation {
  /// g21v1: 32-bit with flag
  group21Var1(1),

  /// g21v2: 16-bit with flag
  group21Var2(2),

  /// g21v5: 32-bit with flag and time of freeze
  group21Var5(5),

  /// g21v6: 16-bit with flag and time of freeze
  group21Var6(6),

  /// g21v9: 32-bit without flag
  group21Var9(9),

  /// g21v10: 16-bit without flag
  group21Var10(10);

  /// DNP3 variation number
  final int code;
  const StaticFrozenCounterVariation(this.code);
}

/// Default event variation of a frozen counter (group 23)
enum EventFrozenCounterVariation {
  /// g23v1: 32-bit with flag
  group23Var1(1),

  /// g23v2: 16-bit with flag
  group23Var2(2),

  /// g23v5: 32-bit with flag and time
  group23Var5(5),

  /// g23v6: 16-bit with flag and time
  group23Var6(6);

  /// DNP3 variation number
  final int code;
  const EventFrozenCounterVariation(this.code);
}

/// Default static variation of an analog input (group 30)
enum StaticAnalogInputVariation {
  /// g30v1: 32-bit integer with flag
  group30Var1(1),

  /// g30v2: 16-bit integer with flag
  group30Var2(2),

  /// g30v3: 32-bit integer without flag
  group30Var3(3),

  /// g30v4: 16-bit integer without flag
  group30Var4(4),

  /// g30v5: single-precision float with flag
  group30Var5(5),

  /// g30v6: double-precision float with flag
  group30Var6(6);

  /// DNP3 variation number
  final int code;
  const StaticAnalogInputVariation(this.code);
}

/// Default event variation of an analog input (group 32)
enum EventAnalogInputVariation {
  /// g32v1: 32-bit integer without time
  group32Var1(1),

  /// g32v2: 16-bit integer without time
  group32Var2(2),

  /// g32v3: 32-bit integer with time
  group32Var3(3),

  /// g32v4: 16-bit integer with time
  group32Var4(4),

  /// g32v5: single-precision float without time
  group32Var5(5),

  /// g32v6: double-precision float without time
  group32Var6(6),

  /// g32v7: single-precision float with time
  group32Var7(7),

  /// g32v8: double-precision float with time
  group32Var8(8);

  /// DNP3 variation number
  final int code;
  const EventAnalogInputVariation(this.code);
}

/// Default static variation of an analog output status (group 40)
enum StaticAnalogOutputStatusVariation {
  /// g40v1: 32-bit integer with flag
  group40Var1(1),

  /// g40v2: 16-bit integer with flag
  group40Var2(2),

  /// g40v3: single-precision float with flag
  group40Var3(3),

  /// g40v4: double-precision float with flag
  group40Var4(4);

  /// DNP3 variation number
  final int code;
  const StaticAnalogOutputStatusVariation(this.code);
}

/// Default event variation of an analog output status (group 42)
enum EventAnalogOutputStatusVariation {
  /// g42v1: 32-bit integer without time
  group42Var1(1),

  /// g42v2: 16-bit integer without time
  group42Var2(2),

  /// g42v3: 32-bit integer with time
  group42Var3(3),

  /// g42v4: 16-bit integer with time
  group42Var4(4),

  /// g42v5: single-precision float without time
  group42Var5(5),

  /// g42v6: double-precision float without time
  group42Var6(6),

  /// g42v7: single-precision float with time
  group42Var7(7),

  /// g42v8: double-precision float with time
  group42Var8(8);

  /// DNP3 variation number
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

/// Outcome of one operation of a [DatabaseTransaction] applied with results
final class UpdateResult {
  /// Whether the operation applied and whether it created an event
  final UpdateStatus status;

  /// Created event id ([UpdateStatus.created] / [UpdateStatus.overflow]); for `defineAttribute`
  /// failures the reason (1 already defined, 2 bad type, 3 reserved variation, 4 not writable),
  /// for `discardUnselectedEvents` the number of discarded events
  final int eventId;

  /// Id of the event dropped from the full buffer ([UpdateStatus.overflow] only)
  final int discardedId;

  /// Creates a result from its decoded fields
  const UpdateResult(this.status, this.eventId, this.discardedId);

  /// Whether the operation succeeded (status is not [UpdateStatus.noPoint])
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
  /// applied later with [Database.apply]
  DatabaseTransaction() : this._(ByteWriter(1024));

  /// Number of operations recorded so far
  int get operationCount => _count;

  /// Encoded operations (view; valid until the next mutation)
  Uint8List get bytes => _w.bytes;

  /// Removes all recorded operations so the transaction can be reused
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

  /// Defines a binary input at [index] (0..65535, else RangeError) reporting events in
  /// [eventClass] (`null` = none) and using the given variations for variation-0 requests.
  void addBinaryInput(
    int index, {
    EventClass? eventClass = EventClass.class1,
    StaticBinaryInputVariation staticVariation = StaticBinaryInputVariation.group1Var1,
    EventBinaryInputVariation eventVariation = EventBinaryInputVariation.group2Var1,
  }) => _add(PointKind.binaryInput, index, eventClass, staticVariation.code, eventVariation.code, 0);

  /// Defines a double-bit binary input at [index] (0..65535, else RangeError) reporting events in
  /// [eventClass] (`null` = none) and using the given variations for variation-0 requests.
  void addDoubleBitBinaryInput(
    int index, {
    EventClass? eventClass = EventClass.class1,
    StaticDoubleBitBinaryInputVariation staticVariation = StaticDoubleBitBinaryInputVariation.group3Var1,
    EventDoubleBitBinaryInputVariation eventVariation = EventDoubleBitBinaryInputVariation.group4Var1,
  }) => _add(PointKind.doubleBitBinaryInput, index, eventClass, staticVariation.code, eventVariation.code, 0);

  /// Defines a binary output status at [index] (0..65535, else RangeError) reporting events in
  /// [eventClass] (`null` = none) and using the given variations for variation-0 requests.
  void addBinaryOutputStatus(
    int index, {
    EventClass? eventClass = EventClass.class1,
    StaticBinaryOutputStatusVariation staticVariation = StaticBinaryOutputStatusVariation.group10Var1,
    EventBinaryOutputStatusVariation eventVariation = EventBinaryOutputStatusVariation.group11Var1,
  }) => _add(PointKind.binaryOutputStatus, index, eventClass, staticVariation.code, eventVariation.code, 0);

  /// Defines a counter at [index] (0..65535, else RangeError) reporting events in
  /// [eventClass] (`null` = none) and using the given variations for variation-0 requests.
  /// [deadband] is in counts (0..0xFFFFFFFF, else RangeError); only larger changes create events.
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

  /// Defines a frozen counter at [index] (0..65535, else RangeError) reporting events in
  /// [eventClass] (`null` = none) and using the given variations for variation-0 requests.
  /// [deadband] is in counts (0..0xFFFFFFFF, else RangeError); only larger changes create events.
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

  /// Defines an analog input at [index] (0..65535, else RangeError) reporting events in
  /// [eventClass] (`null` = none) and using the given variations for variation-0 requests.
  /// [deadband] is in the value's engineering units; only larger changes create events.
  void addAnalogInput(
    int index, {
    EventClass? eventClass = EventClass.class1,
    StaticAnalogInputVariation staticVariation = StaticAnalogInputVariation.group30Var1,
    EventAnalogInputVariation eventVariation = EventAnalogInputVariation.group32Var1,
    double deadband = 0,
  }) => _add(PointKind.analogInput, index, eventClass, staticVariation.code, eventVariation.code, deadband);

  /// Defines an analog output status at [index] (0..65535, else RangeError) reporting events in
  /// [eventClass] (`null` = none) and using the given variations for variation-0 requests.
  /// [deadband] is in the value's engineering units; only larger changes create events.
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

  /// Defines an octet string at [index] (0..65535, else RangeError) reporting events in [eventClass]
  /// (`null` = none)
  void addOctetString(int index, {EventClass? eventClass = EventClass.class1}) =>
      _add(PointKind.octetString, index, eventClass, 0, 0, 0);

  // ----------------------------------------------------------------- remove

  /// Removes the point of [type] at [index] (0..65535, else RangeError); fails if it is not defined
  void remove(PointType type, int index) => _header(3, type.code, index);

  /// Removes the binary input at [index]; see [remove]
  void removeBinaryInput(int index) => remove(PointType.binaryInput, index);

  /// Removes the double-bit binary input at [index]; see [remove]
  void removeDoubleBitBinaryInput(int index) => remove(PointType.doubleBitBinaryInput, index);

  /// Removes the binary output status at [index]; see [remove]
  void removeBinaryOutputStatus(int index) => remove(PointType.binaryOutputStatus, index);

  /// Removes the counter at [index]; see [remove]
  void removeCounter(int index) => remove(PointType.counter, index);

  /// Removes the frozen counter at [index]; see [remove]
  void removeFrozenCounter(int index) => remove(PointType.frozenCounter, index);

  /// Removes the analog input at [index]; see [remove]
  void removeAnalogInput(int index) => remove(PointType.analogInput, index);

  /// Removes the analog output status at [index]; see [remove]
  void removeAnalogOutputStatus(int index) => remove(PointType.analogOutputStatus, index);

  /// Removes the octet string at [index]; see [remove]
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

  /// Sets the binary input at [index] to [value] with [flags] and optional [time].
  /// [mode] controls event creation; [updateStatic] = false leaves the stored static value unchanged.
  void updateBinaryInput(
    int index,
    bool value, {
    Flags flags = Flags.online,
    Dnp3Time? time,
    EventMode mode = EventMode.detect,
    bool updateStatic = true,
  }) => _upd(PointKind.binaryInput, index, flags.value, time, mode, updateStatic, value ? 1 : 0);

  /// Sets the double-bit binary input at [index] to [value] with [flags] and optional [time].
  /// [mode] controls event creation; [updateStatic] = false leaves the stored static value unchanged.
  void updateDoubleBitBinaryInput(
    int index,
    DoubleBit value, {
    Flags flags = Flags.online,
    Dnp3Time? time,
    EventMode mode = EventMode.detect,
    bool updateStatic = true,
  }) => _upd(PointKind.doubleBitBinaryInput, index, flags.value, time, mode, updateStatic, value.index);

  /// Sets the binary output status at [index] to [value] with [flags] and optional [time].
  /// [mode] controls event creation; [updateStatic] = false leaves the stored static value unchanged.
  void updateBinaryOutputStatus(
    int index,
    bool value, {
    Flags flags = Flags.online,
    Dnp3Time? time,
    EventMode mode = EventMode.detect,
    bool updateStatic = true,
  }) => _upd(PointKind.binaryOutputStatus, index, flags.value, time, mode, updateStatic, value ? 1 : 0);

  /// Sets the counter at [index] to [value] with [flags] and optional [time].
  /// [mode] controls event creation; [updateStatic] = false leaves the stored static value unchanged.
  /// [value] is truncated to 32 bits.
  void updateCounter(
    int index,
    int value, {
    Flags flags = Flags.online,
    Dnp3Time? time,
    EventMode mode = EventMode.detect,
    bool updateStatic = true,
  }) => _upd(PointKind.counter, index, flags.value, time, mode, updateStatic, value & 0xFFFFFFFF);

  /// Sets the frozen counter at [index] to [value] with [flags] and optional [time].
  /// [mode] controls event creation; [updateStatic] = false leaves the stored static value unchanged.
  /// [value] is truncated to 32 bits.
  void updateFrozenCounter(
    int index,
    int value, {
    Flags flags = Flags.online,
    Dnp3Time? time,
    EventMode mode = EventMode.detect,
    bool updateStatic = true,
  }) => _upd(PointKind.frozenCounter, index, flags.value, time, mode, updateStatic, value & 0xFFFFFFFF);

  /// Sets the analog input at [index] to [value] with [flags] and optional [time].
  /// [mode] controls event creation; [updateStatic] = false leaves the stored static value unchanged.
  void updateAnalogInput(
    int index,
    double value, {
    Flags flags = Flags.online,
    Dnp3Time? time,
    EventMode mode = EventMode.detect,
    bool updateStatic = true,
  }) => _updD(PointKind.analogInput, index, flags.value, time, mode, updateStatic, value);

  /// Sets the analog output status at [index] to [value] with [flags] and optional [time].
  /// [mode] controls event creation; [updateStatic] = false leaves the stored static value unchanged.
  void updateAnalogOutputStatus(
    int index,
    double value, {
    Flags flags = Flags.online,
    Dnp3Time? time,
    EventMode mode = EventMode.detect,
    bool updateStatic = true,
  }) => _updD(PointKind.analogOutputStatus, index, flags.value, time, mode, updateStatic, value);

  /// Sets the octet string at [index] to [value] (at most 255 bytes, else ArgumentError).
  /// [mode] controls event creation; [updateStatic] = false leaves the stored static value unchanged.
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
  /// Native handle of the outstation owning the database
  final int handle;
  final DatabaseTransaction _tx = DatabaseTransaction();
  final Uint8List _scratch = Uint8List(512);
  bool _inTransaction = false;

  /// Accesses the database of the outstation with [handle]
  Database(this.handle);

  /// Run `build` and apply the recorded operations atomically. Returns the number of
  /// operations (see [transactionWithResults] for per-operation results).
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

  /// Like [apply] but returns one [UpdateResult] per operation
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

  /// Current binary input at [index] (0..65535, else RangeError), or `null` if not defined
  BinaryInput? getBinaryInput(int index) =>
      _get(PointKind.binaryInput, index) == 0 ? null : readBinaryInput(_sd, 0);

  /// Current double-bit binary input at [index], or `null` if not defined
  DoubleBitBinaryInput? getDoubleBitBinaryInput(int index) =>
      _get(PointKind.doubleBitBinaryInput, index) == 0 ? null : readDoubleBitBinaryInput(_sd, 0);

  /// Current binary output status at [index], or `null` if not defined
  BinaryOutputStatus? getBinaryOutputStatus(int index) =>
      _get(PointKind.binaryOutputStatus, index) == 0 ? null : readBinaryOutputStatus(_sd, 0);

  /// Current counter at [index], or `null` if not defined
  Counter? getCounter(int index) => _get(PointKind.counter, index) == 0 ? null : readCounter(_sd, 0);

  /// Current frozen counter at [index], or `null` if not defined
  FrozenCounter? getFrozenCounter(int index) =>
      _get(PointKind.frozenCounter, index) == 0 ? null : readFrozenCounter(_sd, 0);

  /// Current analog input at [index], or `null` if not defined
  AnalogInput? getAnalogInput(int index) =>
      _get(PointKind.analogInput, index) == 0 ? null : readAnalogInput(_sd, 0);

  /// Current analog output status at [index], or `null` if not defined
  AnalogOutputStatus? getAnalogOutputStatus(int index) =>
      _get(PointKind.analogOutputStatus, index) == 0 ? null : readAnalogOutputStatus(_sd, 0);

  /// Copy of the octet string at [index], or `null` if not defined
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
    if (ptr == nullptr) throw lastError(-lenPtr.value); // error code in the length slot
    final len = lenPtr.value;
    final bytes = ptr.asTypedList(len, finalizer: dnp3BufferFreePtr);
    return MeasurementFragment(bytes).blocks.first;
  }

  /// one process-lifetime slot per isolate for the length out-parameter
  static final Pointer<Size> _lenSlot = malloc<Size>();
}
