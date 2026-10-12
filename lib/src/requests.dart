/// Request builders for master operations (reads, commands, generic headers, dead bands).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'measurements.dart';
import 'native/writer.dart';
import 'types.dart';
import 'variation.dart';

// ---------------------------------------------------------------------------------------
// read requests
// ---------------------------------------------------------------------------------------

/// A single object header of a READ request
final class ReadHeader {
  /// 0 all objects, 1 one-byte range, 2 two-byte range, 3 one-byte count, 4 two-byte count
  final int _kind;

  /// Object group and variation requested
  final Variation variation;
  final int _a;
  final int _b;

  const ReadHeader._(this._kind, this.variation, this._a, this._b);

  /// qualifier 0x06
  const ReadHeader.allObjects(Variation variation) : this._(0, variation, 0, 0);

  /// qualifier 0x00
  ReadHeader.range8(Variation variation, int start, int stop) : this._(1, variation, _u8(start), _u8(stop));

  /// qualifier 0x01
  ReadHeader.range16(Variation variation, int start, int stop)
    : this._(2, variation, _u16(start), _u16(stop));

  /// Range with the smallest qualifier that fits
  factory ReadHeader.range(Variation variation, int start, int stop) {
    RangeError.checkValueInInterval(start, 0, stop, 'start');
    return stop <= 0xFF
        ? ReadHeader.range8(variation, start, stop)
        : ReadHeader.range16(variation, start, stop);
  }

  /// qualifier 0x07
  ReadHeader.limitedCount8(Variation variation, int count) : this._(3, variation, _u8(count), 0);

  /// qualifier 0x08
  ReadHeader.limitedCount16(Variation variation, int count) : this._(4, variation, _u16(count), 0);

  void _encode(ByteWriter w) {
    w.u8(_kind);
    w.u8(variation.group);
    w.u8(variation.variation);
    w.u8(0);
    w.u16(_a);
    w.u16(_b);
  }

  @override
  String toString() => 'ReadHeader($variation, kind: $_kind, $_a..$_b)';
}

int _u8(int x) {
  RangeError.checkValueInInterval(x, 0, 0xFF);
  return x;
}

int _u16(int x) {
  RangeError.checkValueInInterval(x, 0, 0xFFFF);
  return x;
}

/// What a master asks the outstation for
sealed class ReadRequest {
  /// Base constructor of the request kinds
  const ReadRequest();

  /// Class scan, e.g. `ReadRequest.classScan(const Classes.all())` for an integrity poll
  const factory ReadRequest.classScan(Classes classes) = _ClassScan;

  /// Integrity poll (class 1, 2, 3 and 0)
  const factory ReadRequest.integrity() = _Integrity;

  /// Event poll (class 1, 2 and 3)
  const factory ReadRequest.events() = _EventScan;

  /// Read with explicit object headers (at least one, checked when encoded)
  const factory ReadRequest.headers(List<ReadHeader> headers) = _Headers;

  /// Read all objects of [variation] (qualifier 0x06)
  factory ReadRequest.allObjects(Variation variation) =>
      ReadRequest.headers([ReadHeader.allObjects(variation)]);

  /// Read indices [start]..[stop] of [variation] (qualifier 0x00 or 0x01, see [ReadHeader.range])
  factory ReadRequest.range(Variation variation, int start, int stop) =>
      ReadRequest.headers([ReadHeader.range(variation, start, stop)]);

  /// Read a device attribute (group 0). Use [AttributeVariation.allAttributesRequest] for all.
  factory ReadRequest.deviceAttribute(int variation, {int set = 0}) =>
      ReadRequest.headers([ReadHeader.range8(Variation.group0(variation), set, set)]);

  /// Writes the request in the native read request format
  void encode(ByteWriter w);

  /// The request encoded in the native read request format
  Uint8List toBytes() {
    final w = ByteWriter(64);
    encode(w);
    return w.bytes;
  }
}

final class _ClassScan extends ReadRequest {
  final Classes classes;
  const _ClassScan(this.classes);
  @override
  void encode(ByteWriter w) => w
    ..u8(0)
    ..u8(classes.mask);
}

final class _Integrity extends ReadRequest {
  const _Integrity();
  @override
  void encode(ByteWriter w) => w
    ..u8(0)
    ..u8(0x0F);
}

final class _EventScan extends ReadRequest {
  const _EventScan();
  @override
  void encode(ByteWriter w) => w
    ..u8(0)
    ..u8(0x0E);
}

final class _Headers extends ReadRequest {
  final List<ReadHeader> headers;
  const _Headers(this.headers);
  @override
  void encode(ByteWriter w) {
    if (headers.isEmpty) throw ArgumentError('at least one header is required');
    w
      ..u8(1)
      ..u16(headers.length)
      ..u8(0);
    for (final h in headers) {
      h._encode(w);
    }
  }
}

// ---------------------------------------------------------------------------------------
// commands
// ---------------------------------------------------------------------------------------

/// Control Relay Output Block (g12v1)
final class Crob {
  /// Control code: operation type, trip/close code, queue and clear bits
  final ControlCode code;

  /// Number of times to execute the operation (0..255)
  final int count;

  /// Duration of the on (active) part of a pulse, in milliseconds
  final int onTimeMs;

  /// Duration of the off (inactive) part of a pulse, in milliseconds
  final int offTimeMs;

  /// CROB executing [code] [count] times with the given pulse timings
  const Crob(this.code, {this.count = 1, this.onTimeMs = 0, this.offTimeMs = 0});

  /// LATCH_ON executed once
  const Crob.latchOn() : this(const ControlCode.latchOn());

  /// LATCH_OFF executed once
  const Crob.latchOff() : this(const ControlCode.latchOff());

  @override
  String toString() => 'Crob($code, count: $count, on: $onTimeMs, off: $offTimeMs)';
}

/// Analog output command (g41)
sealed class AnalogOutput {
  /// Base constructor of the g41 variations
  const AnalogOutput();

  /// g41v1: 32-bit signed integer
  const factory AnalogOutput.int32(int value) = AnalogOutputInt32;

  /// g41v2: 16-bit signed integer
  const factory AnalogOutput.int16(int value) = AnalogOutputInt16;

  /// g41v3: single-precision float
  const factory AnalogOutput.float32(double value) = AnalogOutputFloat32;

  /// g41v4: double-precision float
  const factory AnalogOutput.double64(double value) = AnalogOutputDouble64;

  int get _type;
  void _encode(ByteWriter w);

  /// Requested output value
  num get value;
}

/// g41v1
final class AnalogOutputInt32 extends AnalogOutput {
  @override
  final int value;

  /// Command with [value] (-2^31..2^31-1, checked when encoded)
  const AnalogOutputInt32(this.value);
  @override
  int get _type => 1;
  @override
  void _encode(ByteWriter w) => w
    ..u16(0)
    ..i32(value);
}

/// g41v2
final class AnalogOutputInt16 extends AnalogOutput {
  @override
  final int value;

  /// Command with [value] (-32768..32767, checked when encoded)
  const AnalogOutputInt16(this.value);
  @override
  int get _type => 2;
  @override
  void _encode(ByteWriter w) => w.i16(value);
}

/// g41v3
final class AnalogOutputFloat32 extends AnalogOutput {
  @override
  final double value;

  /// Command with [value], sent as a single-precision float
  const AnalogOutputFloat32(this.value);
  @override
  int get _type => 3;
  @override
  void _encode(ByteWriter w) => w
    ..u16(0)
    ..f32(value);
}

/// g41v4
final class AnalogOutputDouble64 extends AnalogOutput {
  @override
  final double value;

  /// Command with [value]
  const AnalogOutputDouble64(this.value);
  @override
  int get _type => 4;
  @override
  void _encode(ByteWriter w) => w
    ..zeros(6)
    ..f64(value);
}

/// How a [CommandSet] is sent
enum CommandMode {
  /// DIRECT_OPERATE (function code 0x05): executed in a single request
  directOperate,

  /// SELECT (0x03) followed by OPERATE (0x04)
  selectBeforeOperate,
}

/// Collection of commands sent in one SELECT/OPERATE or DIRECT_OPERATE request.
///
/// Consecutive commands of the same type are packed into one object header.
final class CommandSet {
  final _headers = <_CommandHeader>[];
  _CommandHeader? _current;

  /// Use 1-byte index prefixes (qualifier 0x17) instead of 2-byte (0x28)
  final bool oneByteIndex;

  /// Empty command set
  CommandSet({this.oneByteIndex = false});

  /// Single CROB
  factory CommandSet.crob(int index, Crob crob, {bool oneByteIndex = false}) =>
      CommandSet(oneByteIndex: oneByteIndex)..addCrob(index, crob);

  /// Single analog output
  factory CommandSet.analog(int index, AnalogOutput value, {bool oneByteIndex = false}) =>
      CommandSet(oneByteIndex: oneByteIndex)..addAnalog(index, value);

  void _add(int type, int index, Object cmd) {
    if (oneByteIndex) _u8(index);
    _u16(index);
    final c = _current;
    if (c != null && c.type == type) {
      c.items.add((index, cmd));
    } else {
      final h = _CommandHeader(type)..items.add((index, cmd));
      _headers.add(h);
      _current = h;
    }
  }

  /// Adds a g12v1 CROB for point [index] (RangeError if it does not fit the index prefix)
  void addCrob(int index, Crob crob) => _add(0, index, crob);

  /// Adds a g41 analog output command for point [index], variation given by the value type
  void addAnalog(int index, AnalogOutput value) => _add(value._type, index, value);

  /// Start a new object header even if the next command has the same type
  void finishHeader() => _current = null;

  /// Whether no command has been added
  bool get isEmpty => _headers.isEmpty;

  /// Writes the commands in the native command format (StateError if empty)
  void encode(ByteWriter w, CommandMode mode) {
    if (_headers.isEmpty) throw StateError('empty command set');
    w
      ..u8(mode == CommandMode.directOperate ? 0 : 1)
      ..u8(0)
      ..u16(_headers.length);
    for (final h in _headers) {
      w
        ..u8(h.type)
        ..u8(oneByteIndex ? 1 : 2)
        ..u16(h.items.length);
      for (final (index, cmd) in h.items) {
        w.u16(index);
        if (cmd is Crob) {
          w
            ..u8(cmd.code.toByte())
            ..u8(cmd.count)
            ..u32(cmd.onTimeMs)
            ..u32(cmd.offTimeMs);
        } else {
          (cmd as AnalogOutput)._encode(w);
        }
      }
    }
  }
}

final class _CommandHeader {
  final int type;
  final items = <(int, Object)>[];
  _CommandHeader(this.type);
}

// ---------------------------------------------------------------------------------------
// generic headers (FREEZE, WRITE of attributes, ...)
// ---------------------------------------------------------------------------------------

/// Object headers for `Association.sendAndExpectEmptyResponse`
final class RequestHeaders {
  final ByteWriter _w = ByteWriter(64);

  /// Adds an all-objects header (qualifier 0x06)
  RequestHeaders allObjects(Variation v) => _read(ReadHeader.allObjects(v));

  /// Adds a one-byte start/stop range header (qualifier 0x00)
  RequestHeaders range8(Variation v, int start, int stop) => _read(ReadHeader.range8(v, start, stop));

  /// Adds a two-byte start/stop range header (qualifier 0x01)
  RequestHeaders range16(Variation v, int start, int stop) => _read(ReadHeader.range16(v, start, stop));

  /// Adds a one-byte limited count header (qualifier 0x07)
  RequestHeaders limitedCount8(Variation v, int count) => _read(ReadHeader.limitedCount8(v, count));

  /// Adds a two-byte limited count header (qualifier 0x08)
  RequestHeaders limitedCount16(Variation v, int count) => _read(ReadHeader.limitedCount16(v, count));

  RequestHeaders _read(ReadHeader h) {
    h._encode(_w);
    return this;
  }

  /// g50v2 time and interval (used by FREEZE_AT_TIME). Must precede the counter headers.
  RequestHeaders timeAndInterval(Dnp3Time time, int intervalMs) {
    _w
      ..u8(5)
      ..zeros(3)
      ..u32(intervalMs)
      ..u64(time.millis);
    return this;
  }

  /// A device attribute to WRITE
  RequestHeaders attribute(DeviceAttribute attribute) {
    _w
      ..u8(6)
      ..zeros(3);
    encodeAttribute(_w, attribute);
    return this;
  }

  /// Headers encoded in the native generic header format (view; valid until the next addition)
  Uint8List get bytes => _w.bytes;
}

/// Encode an attribute in the native "owned attribute" format
void encodeAttribute(ByteWriter w, DeviceAttribute a) {
  w
    ..u8(a.set == 0 ? 0 : 1)
    ..u8(a.set)
    ..u8(a.variation)
    ..u8(a.type.code)
    ..u8(a.isDouble ? 1 : 0)
    ..zeros(3);
  final v = a.value;
  switch (a.type) {
    case AttributeType.visibleString:
      w.blob(utf8.encode(v as String));
    case AttributeType.octetString || AttributeType.bitString:
      w.blob(v as List<int>);
    case AttributeType.unsignedInt || AttributeType.signedInt:
      w.i64(v as int);
    case AttributeType.floatingPoint:
      w.f64((v as num).toDouble());
    case AttributeType.dnp3Time:
      w.u64((v as Dnp3Time).millis);
    case AttributeType.attributeList:
      throw ArgumentError('attribute lists cannot be written');
  }
}

// ---------------------------------------------------------------------------------------
// dead bands
// ---------------------------------------------------------------------------------------

/// One header of analog input dead bands (group 34)
final class DeadBandHeader {
  final int _type;

  /// Use 1-byte index prefixes (qualifier 0x17) instead of 2-byte (0x28)
  final bool oneByteIndex;

  /// Dead band per analog input index
  final Map<int, num> values;

  const DeadBandHeader._(this._type, this.values, this.oneByteIndex);

  /// g34v1 (16-bit)
  const DeadBandHeader.g34v1(Map<int, int> values, {bool oneByteIndex = false})
    : this._(1, values, oneByteIndex);

  /// g34v2 (32-bit)
  const DeadBandHeader.g34v2(Map<int, int> values, {bool oneByteIndex = false})
    : this._(2, values, oneByteIndex);

  /// g34v3 (single precision)
  const DeadBandHeader.g34v3(Map<int, double> values, {bool oneByteIndex = false})
    : this._(3, values, oneByteIndex);

  /// Encodes [headers] in the native dead band format (for a WRITE of group 34)
  static Uint8List encodeAll(List<DeadBandHeader> headers) {
    final w = ByteWriter(64);
    final tmp = ByteData(4);
    for (final h in headers) {
      w
        ..u8(h._type)
        ..u8(h.oneByteIndex ? 1 : 2)
        ..u16(h.values.length);
      for (final MapEntry(:key, :value) in h.values.entries) {
        RangeError.checkValueInInterval(key, 0, h.oneByteIndex ? 0xFF : 0xFFFF, 'index');
        if (h._type == 1) RangeError.checkValueInInterval(value.toInt(), 0, 0xFFFF, 'g34v1 dead band');
        w
          ..u16(key)
          ..u16(0);
        if (h._type == 3) {
          tmp.setFloat32(0, value.toDouble(), Endian.little);
          w.u32(tmp.getUint32(0, Endian.little));
        } else {
          w.u32(value.toInt());
        }
      }
    }
    return w.bytes;
  }
}
