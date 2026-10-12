/// Zero-copy views over measurement fragments produced by the native read handler.
///
/// A [MeasurementFragment] wraps the `Uint8List` that the native library moved into the
/// Dart heap (external typed data — no copy). Blocks and records are decoded lazily on
/// access: use the raw accessors (`indexAt`, `valueAt`, ...) for allocation-free
/// processing, or iterate the block as a `List` of value objects for convenience.
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'native/protocol.dart';
import 'types.dart';
import 'variation.dart';

const _le = Endian.little;

// ---------------------------------------------------------------------------------------
// value objects
// ---------------------------------------------------------------------------------------

/// Common shape of indexed measurement values
abstract interface class Indexed {
  int get index;
}

final class BinaryInput implements Indexed {
  @override
  final int index;
  final bool value;
  final Flags flags;
  final Dnp3Time? time;
  const BinaryInput(this.index, this.value, {this.flags = Flags.online, this.time});
  @override
  String toString() => 'BinaryInput[$index]($value, flags: 0x${flags.value.toRadixString(16)}, $time)';
}

final class DoubleBitBinaryInput implements Indexed {
  @override
  final int index;
  final DoubleBit value;
  final Flags flags;
  final Dnp3Time? time;
  const DoubleBitBinaryInput(this.index, this.value, {this.flags = Flags.online, this.time});
  @override
  String toString() => 'DoubleBitBinaryInput[$index]($value, $time)';
}

final class BinaryOutputStatus implements Indexed {
  @override
  final int index;
  final bool value;
  final Flags flags;
  final Dnp3Time? time;
  const BinaryOutputStatus(this.index, this.value, {this.flags = Flags.online, this.time});
  @override
  String toString() => 'BinaryOutputStatus[$index]($value, $time)';
}

final class Counter implements Indexed {
  @override
  final int index;
  final int value;
  final Flags flags;
  final Dnp3Time? time;
  const Counter(this.index, this.value, {this.flags = Flags.online, this.time});
  @override
  String toString() => 'Counter[$index]($value, $time)';
}

final class FrozenCounter implements Indexed {
  @override
  final int index;
  final int value;
  final Flags flags;
  final Dnp3Time? time;
  const FrozenCounter(this.index, this.value, {this.flags = Flags.online, this.time});
  @override
  String toString() => 'FrozenCounter[$index]($value, $time)';
}

final class AnalogInput implements Indexed {
  @override
  final int index;
  final double value;
  final Flags flags;
  final Dnp3Time? time;
  const AnalogInput(this.index, this.value, {this.flags = Flags.online, this.time});
  @override
  String toString() => 'AnalogInput[$index]($value, $time)';
}

final class FrozenAnalogInput implements Indexed {
  @override
  final int index;
  final double value;
  final Flags flags;
  final Dnp3Time? time;
  const FrozenAnalogInput(this.index, this.value, {this.flags = Flags.online, this.time});
  @override
  String toString() => 'FrozenAnalogInput[$index]($value, $time)';
}

final class AnalogOutputStatus implements Indexed {
  @override
  final int index;
  final double value;
  final Flags flags;
  final Dnp3Time? time;
  const AnalogOutputStatus(this.index, this.value, {this.flags = Flags.online, this.time});
  @override
  String toString() => 'AnalogOutputStatus[$index]($value, $time)';
}

enum DeadBandType { u16, u32, f32 }

final class AnalogInputDeadBand implements Indexed {
  @override
  final int index;
  final double value;
  final DeadBandType type;
  const AnalogInputDeadBand(this.index, this.value, this.type);
  @override
  String toString() => 'AnalogInputDeadBand[$index]($value, $type)';
}

enum AnalogCommandType { i16, i32, f32, f64 }

final class AnalogOutputCommandEvent implements Indexed {
  @override
  final int index;
  final CommandStatus status;
  final double commandedValue;
  final AnalogCommandType valueType;
  final Dnp3Time? time;
  const AnalogOutputCommandEvent(this.index, this.status, this.commandedValue, this.valueType, this.time);
  @override
  String toString() => 'AnalogOutputCommandEvent[$index]($commandedValue, $status)';
}

final class BinaryOutputCommandEvent implements Indexed {
  @override
  final int index;
  final bool commandedState;
  final CommandStatus status;
  final Dnp3Time? time;
  const BinaryOutputCommandEvent(this.index, this.commandedState, this.status, this.time);
  @override
  String toString() => 'BinaryOutputCommandEvent[$index]($commandedState, $status)';
}

final class UnsignedInteger implements Indexed {
  @override
  final int index;
  final int value;
  const UnsignedInteger(this.index, this.value);
  @override
  String toString() => 'UnsignedInteger[$index]($value)';
}

final class OctetString implements Indexed {
  @override
  final int index;

  /// view into the fragment buffer (not copied)
  final Uint8List value;
  const OctetString(this.index, this.value);
  @override
  String toString() => 'OctetString[$index](${value.length} bytes)';
}

/// Data type of a device attribute value
enum AttributeType {
  visibleString(1),
  unsignedInt(2),
  signedInt(3),
  floatingPoint(4),
  octetString(5),
  bitString(6),
  dnp3Time(7),
  attributeList(254);

  final int code;
  const AttributeType(this.code);

  static AttributeType fromCode(int c) =>
      values.firstWhere((x) => x.code == c, orElse: () => AttributeType.octetString);
}

/// A device attribute (group 0)
final class DeviceAttribute {
  /// attribute set: 0 = default set, otherwise a private set
  final int set;
  final int variation;
  final AttributeType type;

  /// `String`, `int`, `double`, `Uint8List`, `Dnp3Time` or `List<AttributeListItem>`
  final Object value;

  /// for floating point values: true if encoded as 64-bit
  final bool isDouble;

  const DeviceAttribute(this.set, this.variation, this.type, this.value, {this.isDouble = true});

  DeviceAttribute.string(int variation, String value, {int set = 0})
    : this(set, variation, AttributeType.visibleString, value);
  DeviceAttribute.uint(int variation, int value, {int set = 0})
    : this(set, variation, AttributeType.unsignedInt, value);
  DeviceAttribute.integer(int variation, int value, {int set = 0})
    : this(set, variation, AttributeType.signedInt, value);
  DeviceAttribute.boolean(int variation, bool value, {int set = 0})
    : this(set, variation, AttributeType.signedInt, value ? 1 : 0);
  DeviceAttribute.float(int variation, double value, {int set = 0, bool isDouble = true})
    : this(set, variation, AttributeType.floatingPoint, value, isDouble: isDouble);
  DeviceAttribute.octets(int variation, Uint8List value, {int set = 0})
    : this(set, variation, AttributeType.octetString, value);
  DeviceAttribute.time(int variation, Dnp3Time value, {int set = 0})
    : this(set, variation, AttributeType.dnp3Time, value);

  /// Name of well known attributes of the default set
  String? get name => set == 0 ? attributeNames[variation] : null;

  @override
  String toString() => 'DeviceAttribute(set: $set, var: $variation${name != null ? ' $name' : ''}, $value)';
}

final class AttributeListItem {
  final int variation;
  final bool writable;
  const AttributeListItem(this.variation, this.writable);
  @override
  String toString() => 'g0v$variation${writable ? ' (rw)' : ''}';
}

/// Well-known default-set attribute variations
abstract final class AttributeVariation {
  static const configId = 196;
  static const configVersion = 197;
  static const configBuildDate = 198;
  static const configLastChangeDate = 199;
  static const configDigest = 200;
  static const configDigestAlgorithm = 201;
  static const masterResourceId = 202;
  static const deviceLocationAltitude = 203;
  static const deviceLocationLongitude = 204;
  static const deviceLocationLatitude = 205;
  static const userAssignedSecondaryOperatorName = 206;
  static const userAssignedPrimaryOperatorName = 207;
  static const userAssignedSystemName = 208;
  static const secureAuthVersion = 209;
  static const numSecurityStatsPerAssoc = 210;
  static const userSpecificAttributes = 211;
  static const numMasterDefinedDataSetProto = 212;
  static const numOutstationDefinedDataSetProto = 213;
  static const numMasterDefinedDataSets = 214;
  static const numOutstationDefinedDataSets = 215;
  static const maxBinaryOutputPerRequest = 216;
  static const localTimingAccuracy = 217;
  static const durationOfTimeAccuracy = 218;
  static const supportsAnalogOutputEvents = 219;
  static const maxAnalogOutputIndex = 220;
  static const numAnalogOutput = 221;
  static const supportsBinaryOutputEvents = 222;
  static const maxBinaryOutputIndex = 223;
  static const numBinaryOutput = 224;
  static const supportsFrozenCounterEvents = 225;
  static const supportsFrozenCounters = 226;
  static const supportsCounterEvents = 227;
  static const maxCounterIndex = 228;
  static const numCounter = 229;
  static const supportsFrozenAnalogInputs = 230;
  static const supportsAnalogInputEvents = 231;
  static const maxAnalogInputIndex = 232;
  static const numAnalogInput = 233;
  static const supportsDoubleBitBinaryInputEvents = 234;
  static const maxDoubleBitBinaryInputIndex = 235;
  static const numDoubleBitBinaryInput = 236;
  static const supportsBinaryInputEvents = 237;
  static const maxBinaryInputIndex = 238;
  static const numBinaryInput = 239;
  static const maxTxFragmentSize = 240;
  static const maxRxFragmentSize = 241;
  static const deviceManufacturerSoftwareVersion = 242;
  static const deviceManufacturerHardwareVersion = 243;
  static const userAssignedOwnerName = 244;
  static const userAssignedLocation = 245;
  static const userAssignedId = 246;
  static const userAssignedDeviceName = 247;
  static const deviceSerialNumber = 248;
  static const deviceSubsetAndConformance = 249;
  static const productNameAndModel = 250;
  static const deviceManufacturerName = 252;
  static const allAttributesRequest = 254;
  static const listOfAttributeVariations = 255;
}

const Map<int, String> attributeNames = {
  196: 'configId',
  197: 'configVersion',
  198: 'configBuildDate',
  199: 'configLastChangeDate',
  200: 'configDigest',
  201: 'configDigestAlgorithm',
  202: 'masterResourceId',
  203: 'deviceLocationAltitude',
  204: 'deviceLocationLongitude',
  205: 'deviceLocationLatitude',
  206: 'userAssignedSecondaryOperatorName',
  207: 'userAssignedPrimaryOperatorName',
  208: 'userAssignedSystemName',
  209: 'secureAuthVersion',
  210: 'numSecurityStatsPerAssoc',
  211: 'userSpecificAttributes',
  212: 'numMasterDefinedDataSetProto',
  213: 'numOutstationDefinedDataSetProto',
  214: 'numMasterDefinedDataSets',
  215: 'numOutstationDefinedDataSets',
  216: 'maxBinaryOutputPerRequest',
  217: 'localTimingAccuracy',
  218: 'durationOfTimeAccuracy',
  219: 'supportsAnalogOutputEvents',
  220: 'maxAnalogOutputIndex',
  221: 'numAnalogOutput',
  222: 'supportsBinaryOutputEvents',
  223: 'maxBinaryOutputIndex',
  224: 'numBinaryOutput',
  225: 'supportsFrozenCounterEvents',
  226: 'supportsFrozenCounters',
  227: 'supportsCounterEvents',
  228: 'maxCounterIndex',
  229: 'numCounter',
  230: 'supportsFrozenAnalogInputs',
  231: 'supportsAnalogInputEvents',
  232: 'maxAnalogInputIndex',
  233: 'numAnalogInput',
  234: 'supportsDoubleBitBinaryInputEvents',
  235: 'maxDoubleBitBinaryInputIndex',
  236: 'numDoubleBitBinaryInput',
  237: 'supportsBinaryInputEvents',
  238: 'maxBinaryInputIndex',
  239: 'numBinaryInput',
  240: 'maxTxFragmentSize',
  241: 'maxRxFragmentSize',
  242: 'deviceManufacturerSoftwareVersion',
  243: 'deviceManufacturerHardwareVersion',
  244: 'userAssignedOwnerName',
  245: 'userAssignedLocation',
  246: 'userAssignedId',
  247: 'userAssignedDeviceName',
  248: 'deviceSerialNumber',
  249: 'deviceSubsetAndConformance',
  250: 'productNameAndModel',
  252: 'deviceManufacturerName',
  254: 'allAttributesRequest',
  255: 'listOfAttributeVariations',
};

// ---------------------------------------------------------------------------------------
// fragment & blocks
// ---------------------------------------------------------------------------------------

/// One response fragment (or unsolicited response) received by a master
final class MeasurementFragment {
  /// The raw buffer. For fragments delivered through a port this is native memory adopted
  /// by the Dart VM (external typed data).
  final Uint8List bytes;
  final ByteData _d;
  final int _base;

  MeasurementFragment._(this.bytes, this._d, this._base);

  factory MeasurementFragment(Uint8List bytes) =>
      MeasurementFragment._(bytes, ByteData.sublistView(bytes), 0);

  /// Split the concatenated fragments returned by `Association.readWithHandler`
  static List<MeasurementFragment> splitCollection(Uint8List data) {
    final out = <MeasurementFragment>[];
    final d = ByteData.sublistView(data);
    var pos = 0;
    while (pos + 4 <= data.length) {
      final len = d.getUint32(pos, _le);
      pos += 4;
      out.add(MeasurementFragment(Uint8List.sublistView(data, pos, pos + len)));
      pos += len;
      pos = (pos + 7) & ~7;
    }
    return out;
  }

  int get version => _d.getUint8(_base);

  ReadType get readType {
    final r = _d.getUint8(_base + 1);
    return r < 4 ? ReadType.values[r] : ReadType.local;
  }

  bool get isUnsolicited => _d.getUint8(_base + 2) == 1;
  int get _control => _d.getUint8(_base + 3);
  bool get fir => _control & 0x80 != 0;
  bool get fin => _control & 0x40 != 0;
  bool get con => _control & 0x20 != 0;
  bool get uns => _control & 0x10 != 0;
  int get sequence => _control & 0x0F;
  Iin get iin => Iin(_d.getUint8(_base + 4), _d.getUint8(_base + 5));
  int get blockCount => _d.getUint16(_base + 6, _le);
  int get length => _d.getUint32(_base + 8, _le);

  /// Lazily decoded object headers of this fragment
  Iterable<MeasurementBlock> get blocks sync* {
    var pos = _base + 16;
    final n = blockCount;
    for (var i = 0; i < n; i++) {
      final block = MeasurementBlock._create(_d, pos);
      yield block;
      pos += 16 + block.payloadLength;
    }
  }

  /// Visit every block with a callback per measurement type. Allocation-free except for
  /// the block objects themselves.
  void visit(MeasurementVisitor visitor) {
    for (final b in blocks) {
      b.accept(visitor);
    }
  }

  @override
  String toString() =>
      'MeasurementFragment($readType, seq: $sequence, $iin, blocks: $blockCount, $length bytes)';
}

/// Callback interface for [MeasurementFragment.visit]. Override what you need.
abstract class MeasurementVisitor {
  void binaryInputs(BinaryInputBlock block) {}
  void doubleBitBinaryInputs(DoubleBitBinaryInputBlock block) {}
  void binaryOutputStatuses(BinaryOutputStatusBlock block) {}
  void counters(CounterBlock block) {}
  void frozenCounters(FrozenCounterBlock block) {}
  void analogInputs(AnalogInputBlock block) {}
  void frozenAnalogInputs(FrozenAnalogInputBlock block) {}
  void analogInputDeadBands(AnalogInputDeadBandBlock block) {}
  void analogOutputStatuses(AnalogOutputStatusBlock block) {}
  void analogOutputCommandEvents(AnalogOutputCommandEventBlock block) {}
  void binaryOutputCommandEvents(BinaryOutputCommandEventBlock block) {}
  void unsignedIntegers(UnsignedIntegerBlock block) {}
  void octetStrings(OctetStringBlock block) {}
  void deviceAttribute(DeviceAttributeBlock block) {}
  void absoluteTime(AbsTimeBlock block) {}
}

/// An object header of a fragment and its values
sealed class MeasurementBlock {
  final ByteData _d;

  /// offset of the block header
  final int _h;

  MeasurementBlock._(this._d, this._h);

  static MeasurementBlock _create(ByteData d, int pos) {
    return switch (d.getUint8(pos)) {
      PointKind.binaryInput => BinaryInputBlock._(d, pos),
      PointKind.doubleBitBinaryInput => DoubleBitBinaryInputBlock._(d, pos),
      PointKind.binaryOutputStatus => BinaryOutputStatusBlock._(d, pos),
      PointKind.counter => CounterBlock._(d, pos),
      PointKind.frozenCounter => FrozenCounterBlock._(d, pos),
      PointKind.analogInput => AnalogInputBlock._(d, pos),
      PointKind.frozenAnalogInput => FrozenAnalogInputBlock._(d, pos),
      PointKind.analogInputDeadBand => AnalogInputDeadBandBlock._(d, pos),
      PointKind.analogOutputStatus => AnalogOutputStatusBlock._(d, pos),
      PointKind.analogOutputCommandEvent => AnalogOutputCommandEventBlock._(d, pos),
      PointKind.binaryOutputCommandEvent => BinaryOutputCommandEventBlock._(d, pos),
      PointKind.unsignedInteger => UnsignedIntegerBlock._(d, pos),
      PointKind.octetString => OctetStringBlock._(d, pos),
      PointKind.deviceAttribute => DeviceAttributeBlock._(d, pos),
      PointKind.absTime => AbsTimeBlock._(d, pos),
      final k => throw FormatException('unknown measurement block kind $k'),
    };
  }

  int get kind => _d.getUint8(_h);
  int get group => _d.getUint8(_h + 1);
  int get variationNumber => _d.getUint8(_h + 2);

  /// Variation received on the wire
  Variation? get variation => Variation.lookup(group, variationNumber);

  QualifierCode? get qualifier => QualifierCode.fromCode(_d.getUint8(_h + 3));
  bool get isEvent => _d.getUint8(_h + 4) & 1 != 0;
  bool get hasFlags => _d.getUint8(_h + 4) & 2 != 0;
  int get recordSize => _d.getUint8(_h + 5);

  /// number of values in this block
  int get count => _d.getUint32(_h + 8, _le);
  int get payloadLength => _d.getUint32(_h + 12, _le);

  /// offset of the first record
  int get _p => _h + 16;

  void accept(MeasurementVisitor v);
}

/// Base for blocks of fixed-size records, exposed as a lazily decoded `List<T>`
sealed class _FixedBlock<T> extends MeasurementBlock with ListMixin<T> {
  final int _size;
  _FixedBlock(super.d, super.h, this._size) : super._();

  @override
  int get length => count;

  @override
  set length(int _) => throw UnsupportedError('measurement blocks are read-only');

  @override
  void operator []=(int index, T value) => throw UnsupportedError('measurement blocks are read-only');

  @override
  T operator [](int i) {
    RangeError.checkValidIndex(i, this, 'index', count);
    return _decode(_p + i * _size);
  }

  T _decode(int o);

  /// point index of record `i`
  int indexAt(int i) => _d.getUint16(_p + i * _size, _le);
}

/// Shared layout of binary-like records: `u16 index, u8 value, u8 flags, u8 tk, pad, u64 time`
sealed class _BinaryLike<T> extends _FixedBlock<T> {
  _BinaryLike(ByteData d, int h) : super(d, h, 16);

  int _rawValueAt(int i) => _d.getUint8(_p + i * 16 + 2);
  Flags flagsAt(int i) => Flags(_d.getUint8(_p + i * 16 + 3));
  int timeKindAt(int i) => _d.getUint8(_p + i * 16 + 4);
  int timeMillisAt(int i) => _d.getUint64(_p + i * 16 + 8, _le);
  Dnp3Time? timeAt(int i) => Dnp3Time.decode(timeKindAt(i), timeMillisAt(i));
}

final class BinaryInputBlock extends _BinaryLike<BinaryInput> {
  BinaryInputBlock._(super.d, super.h);
  bool valueAt(int i) => _rawValueAt(i) != 0;
  @override
  BinaryInput _decode(int o) => BinaryInput(
    _d.getUint16(o, _le),
    _d.getUint8(o + 2) != 0,
    flags: Flags(_d.getUint8(o + 3)),
    time: Dnp3Time.decode(_d.getUint8(o + 4), _d.getUint64(o + 8, _le)),
  );
  @override
  void accept(MeasurementVisitor v) => v.binaryInputs(this);
}

final class DoubleBitBinaryInputBlock extends _BinaryLike<DoubleBitBinaryInput> {
  DoubleBitBinaryInputBlock._(super.d, super.h);
  DoubleBit valueAt(int i) => DoubleBit.fromCode(_rawValueAt(i));
  @override
  DoubleBitBinaryInput _decode(int o) => DoubleBitBinaryInput(
    _d.getUint16(o, _le),
    DoubleBit.fromCode(_d.getUint8(o + 2)),
    flags: Flags(_d.getUint8(o + 3)),
    time: Dnp3Time.decode(_d.getUint8(o + 4), _d.getUint64(o + 8, _le)),
  );
  @override
  void accept(MeasurementVisitor v) => v.doubleBitBinaryInputs(this);
}

final class BinaryOutputStatusBlock extends _BinaryLike<BinaryOutputStatus> {
  BinaryOutputStatusBlock._(super.d, super.h);
  bool valueAt(int i) => _rawValueAt(i) != 0;
  @override
  BinaryOutputStatus _decode(int o) => BinaryOutputStatus(
    _d.getUint16(o, _le),
    _d.getUint8(o + 2) != 0,
    flags: Flags(_d.getUint8(o + 3)),
    time: Dnp3Time.decode(_d.getUint8(o + 4), _d.getUint64(o + 8, _le)),
  );
  @override
  void accept(MeasurementVisitor v) => v.binaryOutputStatuses(this);
}

/// `u16 index, u8 flags, u8 tk, u32 value, u64 time`
sealed class _CounterLike<T> extends _FixedBlock<T> {
  _CounterLike(ByteData d, int h) : super(d, h, 16);
  int valueAt(int i) => _d.getUint32(_p + i * 16 + 4, _le);
  Flags flagsAt(int i) => Flags(_d.getUint8(_p + i * 16 + 2));
  int timeKindAt(int i) => _d.getUint8(_p + i * 16 + 3);
  int timeMillisAt(int i) => _d.getUint64(_p + i * 16 + 8, _le);
  Dnp3Time? timeAt(int i) => Dnp3Time.decode(timeKindAt(i), timeMillisAt(i));
}

final class CounterBlock extends _CounterLike<Counter> {
  CounterBlock._(super.d, super.h);
  @override
  Counter _decode(int o) => Counter(
    _d.getUint16(o, _le),
    _d.getUint32(o + 4, _le),
    flags: Flags(_d.getUint8(o + 2)),
    time: Dnp3Time.decode(_d.getUint8(o + 3), _d.getUint64(o + 8, _le)),
  );
  @override
  void accept(MeasurementVisitor v) => v.counters(this);
}

final class FrozenCounterBlock extends _CounterLike<FrozenCounter> {
  FrozenCounterBlock._(super.d, super.h);
  @override
  FrozenCounter _decode(int o) => FrozenCounter(
    _d.getUint16(o, _le),
    _d.getUint32(o + 4, _le),
    flags: Flags(_d.getUint8(o + 2)),
    time: Dnp3Time.decode(_d.getUint8(o + 3), _d.getUint64(o + 8, _le)),
  );
  @override
  void accept(MeasurementVisitor v) => v.frozenCounters(this);
}

/// `u16 index, u8 flags, u8 tk, u32 pad, f64 value, u64 time`
sealed class _AnalogLike<T> extends _FixedBlock<T> {
  _AnalogLike(ByteData d, int h) : super(d, h, 24);
  double valueAt(int i) => _d.getFloat64(_p + i * 24 + 8, _le);
  Flags flagsAt(int i) => Flags(_d.getUint8(_p + i * 24 + 2));
  int timeKindAt(int i) => _d.getUint8(_p + i * 24 + 3);
  int timeMillisAt(int i) => _d.getUint64(_p + i * 24 + 16, _le);
  Dnp3Time? timeAt(int i) => Dnp3Time.decode(timeKindAt(i), timeMillisAt(i));
}

final class AnalogInputBlock extends _AnalogLike<AnalogInput> {
  AnalogInputBlock._(super.d, super.h);
  @override
  AnalogInput _decode(int o) => AnalogInput(
    _d.getUint16(o, _le),
    _d.getFloat64(o + 8, _le),
    flags: Flags(_d.getUint8(o + 2)),
    time: Dnp3Time.decode(_d.getUint8(o + 3), _d.getUint64(o + 16, _le)),
  );
  @override
  void accept(MeasurementVisitor v) => v.analogInputs(this);
}

final class FrozenAnalogInputBlock extends _AnalogLike<FrozenAnalogInput> {
  FrozenAnalogInputBlock._(super.d, super.h);
  @override
  FrozenAnalogInput _decode(int o) => FrozenAnalogInput(
    _d.getUint16(o, _le),
    _d.getFloat64(o + 8, _le),
    flags: Flags(_d.getUint8(o + 2)),
    time: Dnp3Time.decode(_d.getUint8(o + 3), _d.getUint64(o + 16, _le)),
  );
  @override
  void accept(MeasurementVisitor v) => v.frozenAnalogInputs(this);
}

final class AnalogOutputStatusBlock extends _AnalogLike<AnalogOutputStatus> {
  AnalogOutputStatusBlock._(super.d, super.h);
  @override
  AnalogOutputStatus _decode(int o) => AnalogOutputStatus(
    _d.getUint16(o, _le),
    _d.getFloat64(o + 8, _le),
    flags: Flags(_d.getUint8(o + 2)),
    time: Dnp3Time.decode(_d.getUint8(o + 3), _d.getUint64(o + 16, _le)),
  );
  @override
  void accept(MeasurementVisitor v) => v.analogOutputStatuses(this);
}

final class AnalogInputDeadBandBlock extends _FixedBlock<AnalogInputDeadBand> {
  AnalogInputDeadBandBlock._(ByteData d, int h) : super(d, h, 16);
  double valueAt(int i) => _d.getFloat64(_p + i * 16 + 8, _le);
  @override
  AnalogInputDeadBand _decode(int o) => AnalogInputDeadBand(
    _d.getUint16(o, _le),
    _d.getFloat64(o + 8, _le),
    DeadBandType.values[_d.getUint8(o + 2) % 3],
  );
  @override
  void accept(MeasurementVisitor v) => v.analogInputDeadBands(this);
}

final class AnalogOutputCommandEventBlock extends _FixedBlock<AnalogOutputCommandEvent> {
  AnalogOutputCommandEventBlock._(ByteData d, int h) : super(d, h, 24);
  @override
  AnalogOutputCommandEvent _decode(int o) => AnalogOutputCommandEvent(
    _d.getUint16(o, _le),
    CommandStatus.fromCode(_d.getUint8(o + 2)),
    _d.getFloat64(o + 8, _le),
    AnalogCommandType.values[_d.getUint8(o + 3) & 3],
    Dnp3Time.decode(_d.getUint8(o + 4), _d.getUint64(o + 16, _le)),
  );
  @override
  void accept(MeasurementVisitor v) => v.analogOutputCommandEvents(this);
}

final class BinaryOutputCommandEventBlock extends _FixedBlock<BinaryOutputCommandEvent> {
  BinaryOutputCommandEventBlock._(ByteData d, int h) : super(d, h, 16);
  @override
  BinaryOutputCommandEvent _decode(int o) => BinaryOutputCommandEvent(
    _d.getUint16(o, _le),
    _d.getUint8(o + 2) != 0,
    CommandStatus.fromCode(_d.getUint8(o + 3)),
    Dnp3Time.decode(_d.getUint8(o + 4), _d.getUint64(o + 8, _le)),
  );
  @override
  void accept(MeasurementVisitor v) => v.binaryOutputCommandEvents(this);
}

final class UnsignedIntegerBlock extends _FixedBlock<UnsignedInteger> {
  UnsignedIntegerBlock._(ByteData d, int h) : super(d, h, 4);
  int valueAt(int i) => _d.getUint8(_p + i * 4 + 2);
  @override
  UnsignedInteger _decode(int o) => UnsignedInteger(_d.getUint16(o, _le), _d.getUint8(o + 2));
  @override
  void accept(MeasurementVisitor v) => v.unsignedIntegers(this);
}

/// Variable-size octet string records: `u16 index, u16 len, bytes, pad to 4`
final class OctetStringBlock extends MeasurementBlock with IterableMixin<OctetString> {
  OctetStringBlock._(super.d, super.h) : super._();

  @override
  Iterator<OctetString> get iterator => _iter().iterator;

  Iterable<OctetString> _iter() sync* {
    var pos = _p;
    final n = count;
    for (var i = 0; i < n; i++) {
      final index = _d.getUint16(pos, _le);
      final len = _d.getUint16(pos + 2, _le);
      yield OctetString(index, _d.buffer.asUint8List(_d.offsetInBytes + pos + 4, len));
      pos += 4 + ((len + 3) & ~3);
    }
  }

  @override
  void accept(MeasurementVisitor v) => v.octetStrings(this);
}

/// A single device attribute
final class DeviceAttributeBlock extends MeasurementBlock {
  DeviceAttributeBlock._(super.d, super.h) : super._();

  DeviceAttribute get attribute => decodeAttribute(_d, _p).$1;

  @override
  void accept(MeasurementVisitor v) => v.deviceAttribute(this);
}

/// Decode an attribute record; returns the attribute and the number of bytes consumed
(DeviceAttribute, int) decodeAttribute(ByteData d, int o) {
  final setKind = d.getUint8(o);
  final setValue = d.getUint8(o + 1);
  final variation = d.getUint8(o + 2);
  final typeCode = d.getUint8(o + 3);
  final floatKind = d.getUint8(o + 4);
  final set = setKind == 0 ? 0 : setValue;
  final type = AttributeType.fromCode(typeCode);
  final p = o + 8;
  Uint8List blob() => d.buffer.asUint8List(d.offsetInBytes + p + 4, d.getUint32(p, _le));
  int blobSize() => 4 + ((d.getUint32(p, _le) + 3) & ~3);
  switch (type) {
    case AttributeType.visibleString:
      return (
        DeviceAttribute(set, variation, type, utf8.decode(blob(), allowMalformed: true)),
        8 + blobSize(),
      );
    case AttributeType.octetString:
    case AttributeType.bitString:
      return (DeviceAttribute(set, variation, type, blob()), 8 + blobSize());
    case AttributeType.attributeList:
      final raw = blob();
      final items = [for (var i = 0; i + 1 < raw.length; i += 2) AttributeListItem(raw[i], raw[i + 1] != 0)];
      return (DeviceAttribute(set, variation, type, items), 8 + blobSize());
    case AttributeType.unsignedInt:
    case AttributeType.signedInt:
      return (DeviceAttribute(set, variation, type, d.getInt64(p, _le)), 16);
    case AttributeType.floatingPoint:
      return (DeviceAttribute(set, variation, type, d.getFloat64(p, _le), isDouble: floatKind == 1), 16);
    case AttributeType.dnp3Time:
      return (DeviceAttribute(set, variation, type, Dnp3Time(d.getUint64(p, _le))), 16);
  }
}

/// Group 50 variation 1 (absolute time) reported by the outstation
final class AbsTimeBlock extends MeasurementBlock {
  AbsTimeBlock._(super.d, super.h) : super._();
  Dnp3Time get time => Dnp3Time(_d.getUint64(_p, _le));
  @override
  void accept(MeasurementVisitor v) => v.absoluteTime(this);
}
