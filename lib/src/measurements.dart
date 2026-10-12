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
  /// Zero-based DNP3 point index (0..65535).
  int get index;
}

/// Binary input value (group 1 static / group 2 event) with flags and optional time.
final class BinaryInput implements Indexed {
  @override
  final int index;

  /// Input state: true = on (1), false = off (0).
  final bool value;

  /// Quality flags (ONLINE, RESTART, COMM_LOST, ...); defaults to ONLINE.
  final Flags flags;

  /// Outstation timestamp; null when the variation carries no time (e.g. g1v2, g2v1).
  final Dnp3Time? time;

  /// Creates a binary input at [index] with state [value].
  const BinaryInput(this.index, this.value, {this.flags = Flags.online, this.time});
  @override
  String toString() => 'BinaryInput[$index]($value, flags: 0x${flags.value.toRadixString(16)}, $time)';
}

/// Double-bit binary input value (group 3 static / group 4 event) with flags and optional time.
final class DoubleBitBinaryInput implements Indexed {
  @override
  final int index;

  /// Double-bit state: intermediate, determined off, determined on or indeterminate.
  final DoubleBit value;

  /// Quality flags (ONLINE, RESTART, COMM_LOST, ...); defaults to ONLINE.
  final Flags flags;

  /// Outstation timestamp; null when the variation carries no time (e.g. g3v2, g4v1).
  final Dnp3Time? time;

  /// Creates a double-bit binary input at [index] with state [value].
  const DoubleBitBinaryInput(this.index, this.value, {this.flags = Flags.online, this.time});
  @override
  String toString() => 'DoubleBitBinaryInput[$index]($value, $time)';
}

/// Binary output status value (group 10 static / group 11 event) with flags and optional time.
final class BinaryOutputStatus implements Indexed {
  @override
  final int index;

  /// Reported output state: true = on, false = off.
  final bool value;

  /// Quality flags (ONLINE, RESTART, COMM_LOST, ...); defaults to ONLINE.
  final Flags flags;

  /// Outstation timestamp; null when the variation carries no time (e.g. g10v2, g11v1).
  final Dnp3Time? time;

  /// Creates a binary output status at [index] with state [value].
  const BinaryOutputStatus(this.index, this.value, {this.flags = Flags.online, this.time});
  @override
  String toString() => 'BinaryOutputStatus[$index]($value, $time)';
}

/// Counter value (group 20 static / group 22 event) with flags and optional time.
final class Counter implements Indexed {
  @override
  final int index;

  /// Counter value, unsigned 32-bit (0..4294967295); 16-bit variations are widened.
  final int value;

  /// Quality flags (ONLINE, RESTART, COMM_LOST, ...); defaults to ONLINE.
  final Flags flags;

  /// Outstation timestamp; null when the variation carries no time (e.g. g20v1, g22v1).
  final Dnp3Time? time;

  /// Creates a counter at [index] with [value].
  const Counter(this.index, this.value, {this.flags = Flags.online, this.time});
  @override
  String toString() => 'Counter[$index]($value, $time)';
}

/// Frozen counter value (group 21 static / group 23 event): a counter captured by a freeze.
final class FrozenCounter implements Indexed {
  @override
  final int index;

  /// Frozen counter value, unsigned 32-bit (0..4294967295); 16-bit variations are widened.
  final int value;

  /// Quality flags (ONLINE, RESTART, COMM_LOST, ...); defaults to ONLINE.
  final Flags flags;

  /// Freeze or event time; null when the variation carries no time (e.g. g21v1, g23v1).
  final Dnp3Time? time;

  /// Creates a frozen counter at [index] with [value].
  const FrozenCounter(this.index, this.value, {this.flags = Flags.online, this.time});
  @override
  String toString() => 'FrozenCounter[$index]($value, $time)';
}

/// Analog input value (group 30 static / group 32 event) with flags and optional time.
final class AnalogInput implements Indexed {
  @override
  final int index;

  /// Value widened to double, whatever the wire variation (16/32-bit int, single/double float).
  final double value;

  /// Quality flags (ONLINE, RESTART, COMM_LOST, ...); defaults to ONLINE.
  final Flags flags;

  /// Outstation timestamp; null when the variation carries no time (e.g. g30v1, g32v1).
  final Dnp3Time? time;

  /// Creates an analog input at [index] with [value].
  const AnalogInput(this.index, this.value, {this.flags = Flags.online, this.time});
  @override
  String toString() => 'AnalogInput[$index]($value, $time)';
}

/// Frozen analog input value (group 31 static / group 33 event) with flags and optional time.
final class FrozenAnalogInput implements Indexed {
  @override
  final int index;

  /// Frozen value widened to double, whatever the wire variation.
  final double value;

  /// Quality flags (ONLINE, RESTART, COMM_LOST, ...); defaults to ONLINE.
  final Flags flags;

  /// Freeze or event time; null when the variation carries no time (e.g. g31v1, g33v1).
  final Dnp3Time? time;

  /// Creates a frozen analog input at [index] with [value].
  const FrozenAnalogInput(this.index, this.value, {this.flags = Flags.online, this.time});
  @override
  String toString() => 'FrozenAnalogInput[$index]($value, $time)';
}

/// Analog output status value (group 40 static / group 42 event) with flags and optional time.
final class AnalogOutputStatus implements Indexed {
  @override
  final int index;

  /// Reported output value widened to double, whatever the wire variation.
  final double value;

  /// Quality flags (ONLINE, RESTART, COMM_LOST, ...); defaults to ONLINE.
  final Flags flags;

  /// Outstation timestamp; null when the variation carries no time (e.g. g40v1, g42v1).
  final Dnp3Time? time;

  /// Creates an analog output status at [index] with [value].
  const AnalogOutputStatus(this.index, this.value, {this.flags = Flags.online, this.time});
  @override
  String toString() => 'AnalogOutputStatus[$index]($value, $time)';
}

/// Wire encoding of an analog input dead band (group 34 variation).
enum DeadBandType {
  /// g34v1: 16-bit unsigned integer.
  u16,

  /// g34v2: 32-bit unsigned integer.
  u32,

  /// g34v3: 32-bit float.
  f32,
}

/// Analog input dead band (group 34): minimum change of an analog input that produces an event.
final class AnalogInputDeadBand implements Indexed {
  @override
  final int index;

  /// Dead band magnitude in the units of the analog input, widened to double.
  final double value;

  /// Wire encoding (g34 variation) the dead band was reported with.
  final DeadBandType type;

  /// Creates a dead band for analog input [index].
  const AnalogInputDeadBand(this.index, this.value, this.type);
  @override
  String toString() => 'AnalogInputDeadBand[$index]($value, $type)';
}

/// Wire encoding of the value of an analog output command event (group 43 variation).
enum AnalogCommandType {
  /// 16-bit signed integer (g43v2, g43v4).
  i16,

  /// 32-bit signed integer (g43v1, g43v3).
  i32,

  /// Single-precision float (g43v5, g43v7).
  f32,

  /// Double-precision float (g43v6, g43v8).
  f64,
}

/// Analog output command event (group 43): a command the outstation received and its result.
final class AnalogOutputCommandEvent implements Indexed {
  @override
  final int index;

  /// Status the outstation returned for the command.
  final CommandStatus status;

  /// Commanded value widened to double; see [valueType] for the wire encoding.
  final double commandedValue;

  /// Encoding of the commanded value on the wire.
  final AnalogCommandType valueType;

  /// Time of the command; null for variations without time (g43v1, v2, v5, v6).
  final Dnp3Time? time;

  /// Creates an analog output command event for point [index].
  const AnalogOutputCommandEvent(this.index, this.status, this.commandedValue, this.valueType, this.time);
  @override
  String toString() => 'AnalogOutputCommandEvent[$index]($commandedValue, $status)';
}

/// Binary output command event (group 13): a CROB the outstation received and its result.
final class BinaryOutputCommandEvent implements Indexed {
  @override
  final int index;

  /// Commanded state: true = on/close, false = off/trip.
  final bool commandedState;

  /// Status the outstation returned for the command.
  final CommandStatus status;

  /// Time of the command; null for g13v1.
  final Dnp3Time? time;

  /// Creates a binary output command event for point [index].
  const BinaryOutputCommandEvent(this.index, this.commandedState, this.status, this.time);
  @override
  String toString() => 'BinaryOutputCommandEvent[$index]($commandedState, $status)';
}

/// Unsigned integer value (group 102 variation 1, 8-bit).
final class UnsignedInteger implements Indexed {
  @override
  final int index;

  /// Value in the range 0..255.
  final int value;

  /// Creates an unsigned integer at [index] with [value].
  const UnsignedInteger(this.index, this.value);
  @override
  String toString() => 'UnsignedInteger[$index]($value)';
}

/// Octet string value (group 110 static / group 111 event).
final class OctetString implements Indexed {
  @override
  final int index;

  /// view into the fragment buffer (not copied)
  final Uint8List value;

  /// Creates an octet string at [index]; [value] is not copied.
  const OctetString(this.index, this.value);
  @override
  String toString() => 'OctetString[$index](${value.length} bytes)';
}

/// Data type of a device attribute value
enum AttributeType {
  /// VSTR (1): visible string, decoded as UTF-8 `String`.
  visibleString(1),

  /// UINT (2): unsigned integer, `int`.
  unsignedInt(2),

  /// INT (3): signed integer, `int`; also used for boolean attributes (0/1).
  signedInt(3),

  /// FLT (4): floating point, `double` (32- or 64-bit on the wire, see [DeviceAttribute.isDouble]).
  floatingPoint(4),

  /// OSTR (5): octet string, `Uint8List`.
  octetString(5),

  /// BSTR (6): bit string, `Uint8List`.
  bitString(6),

  /// DNP3TIME (7): `Dnp3Time`.
  dnp3Time(7),

  /// Attribute list (254): `List<AttributeListItem>` (used by g0v255).
  attributeList(254);

  /// DNP3 data type code of the attribute (as on the wire in group 0).
  final int code;
  const AttributeType(this.code);

  /// Returns the type for DNP3 data type code [c]; unknown codes map to [octetString].
  static AttributeType fromCode(int c) =>
      values.firstWhere((x) => x.code == c, orElse: () => AttributeType.octetString);
}

/// A device attribute (group 0)
final class DeviceAttribute {
  /// attribute set: 0 = default set, otherwise a private set
  final int set;

  /// Attribute variation (group 0 variation number, see [AttributeVariation]).
  final int variation;

  /// Data type of [value].
  final AttributeType type;

  /// `String`, `int`, `double`, `Uint8List`, `Dnp3Time` or `List<AttributeListItem>`
  final Object value;

  /// for floating point values: true if encoded as 64-bit
  final bool isDouble;

  /// Creates an attribute; [isDouble] only matters for [AttributeType.floatingPoint].
  const DeviceAttribute(this.set, this.variation, this.type, this.value, {this.isDouble = true});

  /// Visible string attribute (VSTR) in [set] (0 = default set).
  DeviceAttribute.string(int variation, String value, {int set = 0})
    : this(set, variation, AttributeType.visibleString, value);

  /// Unsigned integer attribute (UINT) in [set].
  DeviceAttribute.uint(int variation, int value, {int set = 0})
    : this(set, variation, AttributeType.unsignedInt, value);

  /// Signed integer attribute (INT) in [set].
  DeviceAttribute.integer(int variation, int value, {int set = 0})
    : this(set, variation, AttributeType.signedInt, value);

  /// Boolean attribute in [set], encoded as a signed integer 1 (true) or 0 (false).
  DeviceAttribute.boolean(int variation, bool value, {int set = 0})
    : this(set, variation, AttributeType.signedInt, value ? 1 : 0);

  /// Floating point attribute (FLT) in [set]; [isDouble] selects 64-bit (default) or 32-bit.
  DeviceAttribute.float(int variation, double value, {int set = 0, bool isDouble = true})
    : this(set, variation, AttributeType.floatingPoint, value, isDouble: isDouble);

  /// Octet string attribute (OSTR) in [set].
  DeviceAttribute.octets(int variation, Uint8List value, {int set = 0})
    : this(set, variation, AttributeType.octetString, value);

  /// DNP3 time attribute (DNP3TIME) in [set].
  DeviceAttribute.time(int variation, Dnp3Time value, {int set = 0})
    : this(set, variation, AttributeType.dnp3Time, value);

  /// Name of well known attributes of the default set
  String? get name => set == 0 ? attributeNames[variation] : null;

  @override
  String toString() => 'DeviceAttribute(set: $set, var: $variation${name != null ? ' $name' : ''}, $value)';
}

/// One entry of the list of attribute variations (g0v255).
final class AttributeListItem {
  /// Attribute variation supported by the outstation.
  final int variation;

  /// True if a master may write the attribute.
  final bool writable;

  /// Creates a list entry for [variation].
  const AttributeListItem(this.variation, this.writable);
  @override
  String toString() => 'g0v$variation${writable ? ' (rw)' : ''}';
}

/// Well-known default-set attribute variations
abstract final class AttributeVariation {
  /// g0v196: Configuration ID (VSTR).
  static const configId = 196;

  /// g0v197: Configuration version (VSTR).
  static const configVersion = 197;

  /// g0v198: Configuration build date (DNP3TIME).
  static const configBuildDate = 198;

  /// g0v199: Configuration last change date (DNP3TIME).
  static const configLastChangeDate = 199;

  /// g0v200: Configuration digest (OSTR).
  static const configDigest = 200;

  /// g0v201: Configuration digest algorithm (VSTR).
  static const configDigestAlgorithm = 201;

  /// g0v202: Master resource ID (VSTR).
  static const masterResourceId = 202;

  /// g0v203: Device location altitude in meters (FLT).
  static const deviceLocationAltitude = 203;

  /// g0v204: Device location longitude in degrees (FLT).
  static const deviceLocationLongitude = 204;

  /// g0v205: Device location latitude in degrees (FLT).
  static const deviceLocationLatitude = 205;

  /// g0v206: User-assigned secondary operator name (VSTR).
  static const userAssignedSecondaryOperatorName = 206;

  /// g0v207: User-assigned primary operator name (VSTR).
  static const userAssignedPrimaryOperatorName = 207;

  /// g0v208: User-assigned system name (VSTR).
  static const userAssignedSystemName = 208;

  /// g0v209: Secure authentication version (UINT).
  static const secureAuthVersion = 209;

  /// g0v210: Number of security statistics per association (UINT).
  static const numSecurityStatsPerAssoc = 210;

  /// g0v211: Identification of support for user-specific attributes (VSTR).
  static const userSpecificAttributes = 211;

  /// g0v212: Number of master-defined data set prototypes (UINT).
  static const numMasterDefinedDataSetProto = 212;

  /// g0v213: Number of outstation-defined data set prototypes (UINT).
  static const numOutstationDefinedDataSetProto = 213;

  /// g0v214: Number of master-defined data sets (UINT).
  static const numMasterDefinedDataSets = 214;

  /// g0v215: Number of outstation-defined data sets (UINT).
  static const numOutstationDefinedDataSets = 215;

  /// g0v216: Maximum number of binary outputs per request (UINT).
  static const maxBinaryOutputPerRequest = 216;

  /// g0v217: Local timing accuracy in microseconds (UINT).
  static const localTimingAccuracy = 217;

  /// g0v218: Duration of time accuracy in seconds (UINT).
  static const durationOfTimeAccuracy = 218;

  /// g0v219: Support for analog output events (boolean).
  static const supportsAnalogOutputEvents = 219;

  /// g0v220: Maximum analog output index (UINT).
  static const maxAnalogOutputIndex = 220;

  /// g0v221: Number of analog output points (UINT).
  static const numAnalogOutput = 221;

  /// g0v222: Support for binary output events (boolean).
  static const supportsBinaryOutputEvents = 222;

  /// g0v223: Maximum binary output index (UINT).
  static const maxBinaryOutputIndex = 223;

  /// g0v224: Number of binary output points (UINT).
  static const numBinaryOutput = 224;

  /// g0v225: Support for frozen counter events (boolean).
  static const supportsFrozenCounterEvents = 225;

  /// g0v226: Support for frozen counters (boolean).
  static const supportsFrozenCounters = 226;

  /// g0v227: Support for counter events (boolean).
  static const supportsCounterEvents = 227;

  /// g0v228: Maximum counter index (UINT).
  static const maxCounterIndex = 228;

  /// g0v229: Number of counter points (UINT).
  static const numCounter = 229;

  /// g0v230: Support for frozen analog inputs (boolean).
  static const supportsFrozenAnalogInputs = 230;

  /// g0v231: Support for analog input events (boolean).
  static const supportsAnalogInputEvents = 231;

  /// g0v232: Maximum analog input index (UINT).
  static const maxAnalogInputIndex = 232;

  /// g0v233: Number of analog input points (UINT).
  static const numAnalogInput = 233;

  /// g0v234: Support for double-bit binary input events (boolean).
  static const supportsDoubleBitBinaryInputEvents = 234;

  /// g0v235: Maximum double-bit binary input index (UINT).
  static const maxDoubleBitBinaryInputIndex = 235;

  /// g0v236: Number of double-bit binary input points (UINT).
  static const numDoubleBitBinaryInput = 236;

  /// g0v237: Support for binary input events (boolean).
  static const supportsBinaryInputEvents = 237;

  /// g0v238: Maximum binary input index (UINT).
  static const maxBinaryInputIndex = 238;

  /// g0v239: Number of binary input points (UINT).
  static const numBinaryInput = 239;

  /// g0v240: Maximum transmit fragment size in bytes (UINT).
  static const maxTxFragmentSize = 240;

  /// g0v241: Maximum receive fragment size in bytes (UINT).
  static const maxRxFragmentSize = 241;

  /// g0v242: Device manufacturer software version (VSTR).
  static const deviceManufacturerSoftwareVersion = 242;

  /// g0v243: Device manufacturer hardware version (VSTR).
  static const deviceManufacturerHardwareVersion = 243;

  /// g0v244: User-assigned owner name (VSTR).
  static const userAssignedOwnerName = 244;

  /// g0v245: User-assigned location name (VSTR).
  static const userAssignedLocation = 245;

  /// g0v246: User-assigned ID code/number (VSTR).
  static const userAssignedId = 246;

  /// g0v247: User-assigned device name (VSTR).
  static const userAssignedDeviceName = 247;

  /// g0v248: Device serial number (VSTR).
  static const deviceSerialNumber = 248;

  /// g0v249: DNP3 subset and conformance (VSTR).
  static const deviceSubsetAndConformance = 249;

  /// g0v250: Device manufacturer product name and model (VSTR).
  static const productNameAndModel = 250;

  /// g0v252: Device manufacturer name (VSTR).
  static const deviceManufacturerName = 252;

  /// g0v254: Read request for all attributes of a set (request only, no value).
  static const allAttributesRequest = 254;

  /// g0v255: List of attribute variations supported by the outstation.
  static const listOfAttributeVariations = 255;
}

/// Names of the well-known default-set attributes keyed by variation (same names as [AttributeVariation]).
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

  /// Wraps one encoded fragment (16-byte header followed by blocks) without copying.
  MeasurementFragment(this.bytes) : _d = ByteData.sublistView(bytes);

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

  /// Version of the native fragment encoding (currently 1).
  int get version => _d.getUint8(0);

  /// Kind of read that produced this fragment; codes >= 4 (e.g. 255) map to [ReadType.local].
  ReadType get readType {
    final r = _d.getUint8(1);
    return r < 4 ? ReadType.values[r] : ReadType.local;
  }

  /// True for an UNSOLICITED_RESPONSE function code, false for a solicited RESPONSE.
  bool get isUnsolicited => _d.getUint8(2) == 1;
  int get _control => _d.getUint8(3);

  /// FIR bit of the application control field: first fragment of the response.
  bool get fir => _control & 0x80 != 0;

  /// FIN bit of the application control field: final fragment of the response.
  bool get fin => _control & 0x40 != 0;

  /// CON bit of the application control field: the outstation requests a confirm.
  bool get con => _control & 0x20 != 0;

  /// UNS bit of the application control field: fragment belongs to an unsolicited response.
  bool get uns => _control & 0x10 != 0;

  /// Application layer sequence number (0..15).
  int get sequence => _control & 0x0F;

  /// Internal indications (IIN1/IIN2) reported by the outstation.
  Iin get iin => Iin(_d.getUint8(4), _d.getUint8(5));

  /// Number of blocks (object headers) in this fragment.
  int get blockCount => _d.getUint16(6, _le);

  /// Total encoded length in bytes, including the 16-byte fragment header.
  int get length => _d.getUint32(8, _le);

  /// Lazily decoded object headers of this fragment
  Iterable<MeasurementBlock> get blocks sync* {
    var pos = 16;
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
  /// Const constructor for subclasses.
  const MeasurementVisitor();

  /// Called for each binary input block (g1/g2); does nothing by default.
  void binaryInputs(BinaryInputBlock block) {}

  /// Called for each double-bit binary input block (g3/g4); does nothing by default.
  void doubleBitBinaryInputs(DoubleBitBinaryInputBlock block) {}

  /// Called for each binary output status block (g10/g11); does nothing by default.
  void binaryOutputStatuses(BinaryOutputStatusBlock block) {}

  /// Called for each counter block (g20/g22); does nothing by default.
  void counters(CounterBlock block) {}

  /// Called for each frozen counter block (g21/g23); does nothing by default.
  void frozenCounters(FrozenCounterBlock block) {}

  /// Called for each analog input block (g30/g32); does nothing by default.
  void analogInputs(AnalogInputBlock block) {}

  /// Called for each frozen analog input block (g31/g33); does nothing by default.
  void frozenAnalogInputs(FrozenAnalogInputBlock block) {}

  /// Called for each analog input dead band block (g34); does nothing by default.
  void analogInputDeadBands(AnalogInputDeadBandBlock block) {}

  /// Called for each analog output status block (g40/g42); does nothing by default.
  void analogOutputStatuses(AnalogOutputStatusBlock block) {}

  /// Called for each analog output command event block (g43); does nothing by default.
  void analogOutputCommandEvents(AnalogOutputCommandEventBlock block) {}

  /// Called for each binary output command event block (g13); does nothing by default.
  void binaryOutputCommandEvents(BinaryOutputCommandEventBlock block) {}

  /// Called for each unsigned integer block (g102); does nothing by default.
  void unsignedIntegers(UnsignedIntegerBlock block) {}

  /// Called for each octet string block (g110/g111); does nothing by default.
  void octetStrings(OctetStringBlock block) {}

  /// Called for each device attribute block (g0); does nothing by default.
  void deviceAttribute(DeviceAttributeBlock block) {}

  /// Called for each absolute time block (g50v1); does nothing by default.
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

  /// Native block kind code identifying the measurement type of the records.
  int get kind => _d.getUint8(_h);

  /// DNP3 object group of the object header as received.
  int get group => _d.getUint8(_h + 1);

  /// DNP3 variation number of the object header as received.
  int get variationNumber => _d.getUint8(_h + 2);

  /// Variation received on the wire
  Variation? get variation => Variation.lookup(group, variationNumber);

  /// Qualifier code of the object header; null if not one of the known [QualifierCode]s.
  QualifierCode? get qualifier => QualifierCode.fromCode(_d.getUint8(_h + 3));

  /// True if the records are events (e.g. g2, g32) rather than static values.
  bool get isEvent => _d.getUint8(_h + 4) & 1 != 0;

  /// True if the wire variation carries per-point flags; otherwise flags were filled in by the decoder.
  bool get hasFlags => _d.getUint8(_h + 4) & 2 != 0;

  /// Size of one record in bytes; 0 for variable-size records (octet strings, attributes).
  int get recordSize => _d.getUint8(_h + 5);

  /// number of values in this block
  int get count => _d.getUint32(_h + 8, _le);

  /// Size of the records in bytes, excluding the 16-byte block header.
  int get payloadLength => _d.getUint32(_h + 12, _le);

  /// offset of the first record
  int get _p => _h + 16;

  /// Calls the [MeasurementVisitor] method matching this block type.
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

// Record decoders shared by the blocks and `Database.getX` (not exported)

/// Internal: decodes the [BinaryInput] record at byte offset [o] of [d].
BinaryInput readBinaryInput(ByteData d, int o) => BinaryInput(
  d.getUint16(o, _le),
  d.getUint8(o + 2) != 0,
  flags: Flags(d.getUint8(o + 3)),
  time: Dnp3Time.decode(d.getUint8(o + 4), d.getUint64(o + 8, _le)),
);

/// Internal: decodes the [DoubleBitBinaryInput] record at byte offset [o] of [d].
DoubleBitBinaryInput readDoubleBitBinaryInput(ByteData d, int o) => DoubleBitBinaryInput(
  d.getUint16(o, _le),
  DoubleBit.fromCode(d.getUint8(o + 2)),
  flags: Flags(d.getUint8(o + 3)),
  time: Dnp3Time.decode(d.getUint8(o + 4), d.getUint64(o + 8, _le)),
);

/// Internal: decodes the [BinaryOutputStatus] record at byte offset [o] of [d].
BinaryOutputStatus readBinaryOutputStatus(ByteData d, int o) => BinaryOutputStatus(
  d.getUint16(o, _le),
  d.getUint8(o + 2) != 0,
  flags: Flags(d.getUint8(o + 3)),
  time: Dnp3Time.decode(d.getUint8(o + 4), d.getUint64(o + 8, _le)),
);

/// Internal: decodes the [Counter] record at byte offset [o] of [d].
Counter readCounter(ByteData d, int o) => Counter(
  d.getUint16(o, _le),
  d.getUint32(o + 4, _le),
  flags: Flags(d.getUint8(o + 2)),
  time: Dnp3Time.decode(d.getUint8(o + 3), d.getUint64(o + 8, _le)),
);

/// Internal: decodes the [FrozenCounter] record at byte offset [o] of [d].
FrozenCounter readFrozenCounter(ByteData d, int o) => FrozenCounter(
  d.getUint16(o, _le),
  d.getUint32(o + 4, _le),
  flags: Flags(d.getUint8(o + 2)),
  time: Dnp3Time.decode(d.getUint8(o + 3), d.getUint64(o + 8, _le)),
);

/// Internal: decodes the [AnalogInput] record at byte offset [o] of [d].
AnalogInput readAnalogInput(ByteData d, int o) => AnalogInput(
  d.getUint16(o, _le),
  d.getFloat64(o + 8, _le),
  flags: Flags(d.getUint8(o + 2)),
  time: Dnp3Time.decode(d.getUint8(o + 3), d.getUint64(o + 16, _le)),
);

/// Internal: decodes the [FrozenAnalogInput] record at byte offset [o] of [d].
FrozenAnalogInput readFrozenAnalogInput(ByteData d, int o) => FrozenAnalogInput(
  d.getUint16(o, _le),
  d.getFloat64(o + 8, _le),
  flags: Flags(d.getUint8(o + 2)),
  time: Dnp3Time.decode(d.getUint8(o + 3), d.getUint64(o + 16, _le)),
);

/// Internal: decodes the [AnalogOutputStatus] record at byte offset [o] of [d].
AnalogOutputStatus readAnalogOutputStatus(ByteData d, int o) => AnalogOutputStatus(
  d.getUint16(o, _le),
  d.getFloat64(o + 8, _le),
  flags: Flags(d.getUint8(o + 2)),
  time: Dnp3Time.decode(d.getUint8(o + 3), d.getUint64(o + 16, _le)),
);

/// Shared layout of binary-like records: `u16 index, u8 value, u8 flags, u8 tk, pad, u64 time`
sealed class _BinaryLike<T> extends _FixedBlock<T> {
  _BinaryLike(ByteData d, int h) : super(d, h, 16);

  int _rawValueAt(int i) => _d.getUint8(_p + i * 16 + 2);

  /// Quality flags of record [i] (all-zero flags when the variation carries none).
  Flags flagsAt(int i) => Flags(_d.getUint8(_p + i * 16 + 3));

  /// Time kind of record [i]: 0 no time, 1 synchronized, 2 unsynchronized.
  int timeKindAt(int i) => _d.getUint8(_p + i * 16 + 4);

  /// Raw timestamp of record [i] in ms since the Unix epoch (0 when it carries no time).
  int timeMillisAt(int i) => _d.getUint64(_p + i * 16 + 8, _le);

  /// Timestamp of record [i], or null when the variation carries no time.
  Dnp3Time? timeAt(int i) => Dnp3Time.decode(timeKindAt(i), timeMillisAt(i));
}

/// Block of binary inputs (g1/g2): lazily decoded read-only `List` plus raw accessors.
final class BinaryInputBlock extends _BinaryLike<BinaryInput> {
  BinaryInputBlock._(super.d, super.h);

  /// State of record [i] (true = on), read without allocating.
  bool valueAt(int i) => _rawValueAt(i) != 0;
  @override
  BinaryInput _decode(int o) => readBinaryInput(_d, o);
  @override
  void accept(MeasurementVisitor v) => v.binaryInputs(this);
}

/// Block of double-bit binary inputs (g3/g4): lazily decoded read-only `List` plus raw accessors.
final class DoubleBitBinaryInputBlock extends _BinaryLike<DoubleBitBinaryInput> {
  DoubleBitBinaryInputBlock._(super.d, super.h);

  /// Double-bit state of record [i], read without allocating.
  DoubleBit valueAt(int i) => DoubleBit.fromCode(_rawValueAt(i));
  @override
  DoubleBitBinaryInput _decode(int o) => readDoubleBitBinaryInput(_d, o);
  @override
  void accept(MeasurementVisitor v) => v.doubleBitBinaryInputs(this);
}

/// Block of binary output statuses (g10/g11): lazily decoded read-only `List` plus raw accessors.
final class BinaryOutputStatusBlock extends _BinaryLike<BinaryOutputStatus> {
  BinaryOutputStatusBlock._(super.d, super.h);

  /// Output state of record [i] (true = on), read without allocating.
  bool valueAt(int i) => _rawValueAt(i) != 0;
  @override
  BinaryOutputStatus _decode(int o) => readBinaryOutputStatus(_d, o);
  @override
  void accept(MeasurementVisitor v) => v.binaryOutputStatuses(this);
}

/// `u16 index, u8 flags, u8 tk, u32 value, u64 time`
sealed class _CounterLike<T> extends _FixedBlock<T> {
  _CounterLike(ByteData d, int h) : super(d, h, 16);

  /// Value of record [i], read without allocating.
  int valueAt(int i) => _d.getUint32(_p + i * 16 + 4, _le);

  /// Quality flags of record [i] (all-zero flags when the variation carries none).
  Flags flagsAt(int i) => Flags(_d.getUint8(_p + i * 16 + 2));

  /// Time kind of record [i]: 0 no time, 1 synchronized, 2 unsynchronized.
  int timeKindAt(int i) => _d.getUint8(_p + i * 16 + 3);

  /// Raw timestamp of record [i] in ms since the Unix epoch (0 when it carries no time).
  int timeMillisAt(int i) => _d.getUint64(_p + i * 16 + 8, _le);

  /// Timestamp of record [i], or null when the variation carries no time.
  Dnp3Time? timeAt(int i) => Dnp3Time.decode(timeKindAt(i), timeMillisAt(i));
}

/// Block of counters (g20/g22): lazily decoded read-only `List` plus raw accessors.
final class CounterBlock extends _CounterLike<Counter> {
  CounterBlock._(super.d, super.h);
  @override
  Counter _decode(int o) => readCounter(_d, o);
  @override
  void accept(MeasurementVisitor v) => v.counters(this);
}

/// Block of frozen counters (g21/g23): lazily decoded read-only `List` plus raw accessors.
final class FrozenCounterBlock extends _CounterLike<FrozenCounter> {
  FrozenCounterBlock._(super.d, super.h);
  @override
  FrozenCounter _decode(int o) => readFrozenCounter(_d, o);
  @override
  void accept(MeasurementVisitor v) => v.frozenCounters(this);
}

/// `u16 index, u8 flags, u8 tk, u32 pad, f64 value, u64 time`
sealed class _AnalogLike<T> extends _FixedBlock<T> {
  _AnalogLike(ByteData d, int h) : super(d, h, 24);

  /// Value of record [i], read without allocating.
  double valueAt(int i) => _d.getFloat64(_p + i * 24 + 8, _le);

  /// Quality flags of record [i] (all-zero flags when the variation carries none).
  Flags flagsAt(int i) => Flags(_d.getUint8(_p + i * 24 + 2));

  /// Time kind of record [i]: 0 no time, 1 synchronized, 2 unsynchronized.
  int timeKindAt(int i) => _d.getUint8(_p + i * 24 + 3);

  /// Raw timestamp of record [i] in ms since the Unix epoch (0 when it carries no time).
  int timeMillisAt(int i) => _d.getUint64(_p + i * 24 + 16, _le);

  /// Timestamp of record [i], or null when the variation carries no time.
  Dnp3Time? timeAt(int i) => Dnp3Time.decode(timeKindAt(i), timeMillisAt(i));
}

/// Block of analog inputs (g30/g32): lazily decoded read-only `List` plus raw accessors.
final class AnalogInputBlock extends _AnalogLike<AnalogInput> {
  AnalogInputBlock._(super.d, super.h);
  @override
  AnalogInput _decode(int o) => readAnalogInput(_d, o);
  @override
  void accept(MeasurementVisitor v) => v.analogInputs(this);
}

/// Block of frozen analog inputs (g31/g33): lazily decoded read-only `List` plus raw accessors.
final class FrozenAnalogInputBlock extends _AnalogLike<FrozenAnalogInput> {
  FrozenAnalogInputBlock._(super.d, super.h);
  @override
  FrozenAnalogInput _decode(int o) => readFrozenAnalogInput(_d, o);
  @override
  void accept(MeasurementVisitor v) => v.frozenAnalogInputs(this);
}

/// Block of analog output statuses (g40/g42): lazily decoded read-only `List` plus raw accessors.
final class AnalogOutputStatusBlock extends _AnalogLike<AnalogOutputStatus> {
  AnalogOutputStatusBlock._(super.d, super.h);
  @override
  AnalogOutputStatus _decode(int o) => readAnalogOutputStatus(_d, o);
  @override
  void accept(MeasurementVisitor v) => v.analogOutputStatuses(this);
}

/// Block of analog input dead bands (g34): lazily decoded read-only `List` plus raw accessors.
final class AnalogInputDeadBandBlock extends _FixedBlock<AnalogInputDeadBand> {
  AnalogInputDeadBandBlock._(ByteData d, int h) : super(d, h, 16);

  /// Dead band of record [i] widened to double, read without allocating.
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

/// Block of analog output command events (g43): lazily decoded read-only `List` plus raw accessors.
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

/// Block of binary output command events (g13): lazily decoded read-only `List` plus raw accessors.
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

/// Block of unsigned integers (g102): lazily decoded read-only `List` plus raw accessors.
final class UnsignedIntegerBlock extends _FixedBlock<UnsignedInteger> {
  UnsignedIntegerBlock._(ByteData d, int h) : super(d, h, 4);

  /// Value (0..255) of record [i], read without allocating.
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

  /// The decoded attribute; string and byte values are decoded on each access.
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

  /// Absolute time reported by the outstation (ms since epoch; quality synchronized).
  Dnp3Time get time => Dnp3Time(_d.getUint64(_p, _le));
  @override
  void accept(MeasurementVisitor v) => v.absoluteTime(this);
}
