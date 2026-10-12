import 'dart:typed_data';

/// Growable little-endian byte writer used to build request / database-op buffers.
///
/// Buffers built here are handed to native leaf calls with `Uint8List.address`, i.e. the
/// native side reads them directly from the Dart heap without any copy.
final class ByteWriter {
  Uint8List _buf;
  ByteData _d;
  int _len = 0;

  ByteWriter([int capacity = 256]) : _buf = Uint8List(capacity), _d = ByteData(0) {
    _d = ByteData.sublistView(_buf);
  }

  int get length => _len;

  /// A view of the written bytes (no copy)
  Uint8List get bytes => Uint8List.sublistView(_buf, 0, _len);

  /// The backing buffer; valid bytes are `[0, length)`
  Uint8List get buffer => _buf;

  void reset() => _len = 0;

  void _ensure(int n) {
    final need = _len + n;
    if (need <= _buf.length) return;
    var cap = _buf.length * 2;
    while (cap < need) {
      cap *= 2;
    }
    final next = Uint8List(cap)..setRange(0, _len, _buf);
    _buf = next;
    _d = ByteData.sublistView(next);
  }

  void u8(int x) {
    _ensure(1);
    _buf[_len++] = x;
  }

  void u16(int x) {
    _ensure(2);
    _d.setUint16(_len, x, Endian.little);
    _len += 2;
  }

  void i16(int x) {
    _ensure(2);
    _d.setInt16(_len, x, Endian.little);
    _len += 2;
  }

  void u32(int x) {
    _ensure(4);
    _d.setUint32(_len, x, Endian.little);
    _len += 4;
  }

  void i32(int x) {
    _ensure(4);
    _d.setInt32(_len, x, Endian.little);
    _len += 4;
  }

  void f32(double x) {
    _ensure(4);
    _d.setFloat32(_len, x, Endian.little);
    _len += 4;
  }

  void u64(int x) {
    _ensure(8);
    _d.setUint64(_len, x, Endian.little);
    _len += 8;
  }

  void i64(int x) {
    _ensure(8);
    _d.setInt64(_len, x, Endian.little);
    _len += 8;
  }

  void f64(double x) {
    _ensure(8);
    _d.setFloat64(_len, x, Endian.little);
    _len += 8;
  }

  void zeros(int n) {
    _ensure(n);
    _buf.fillRange(_len, _len + n, 0);
    _len += n;
  }

  void bytesOf(List<int> data) {
    _ensure(data.length);
    _buf.setRange(_len, _len + data.length, data);
    _len += data.length;
  }

  void pad4() {
    final rem = _len % 4;
    if (rem != 0) zeros(4 - rem);
  }

  /// u32 length prefix + bytes + padding to 4
  void blob(List<int> data) {
    u32(data.length);
    bytesOf(data);
    pad4();
  }

  /// Write a 24-byte database update op directly: header, 4 option bytes, value, time.
  /// Hot path of outstation updates.
  void dbUpdate(
    int type,
    int index,
    int flags,
    int timeKind,
    int eventMode,
    int options,
    int valueBits,
    int time,
  ) {
    _ensure(24);
    final d = _d;
    final o = _len;
    d.setUint32(o, 1 | (type << 8) | (index << 16), Endian.little);
    d.setUint32(o + 4, flags | (timeKind << 8) | (eventMode << 16) | (options << 24), Endian.little);
    d.setUint64(o + 8, valueBits, Endian.little);
    d.setUint64(o + 16, time, Endian.little);
    _len = o + 24;
  }

  void dbUpdateDouble(
    int type,
    int index,
    int flags,
    int timeKind,
    int eventMode,
    int options,
    double value,
    int time,
  ) {
    _ensure(24);
    final d = _d;
    final o = _len;
    d.setUint32(o, 1 | (type << 8) | (index << 16), Endian.little);
    d.setUint32(o + 4, flags | (timeKind << 8) | (eventMode << 16) | (options << 24), Endian.little);
    d.setFloat64(o + 8, value, Endian.little);
    d.setUint64(o + 16, time, Endian.little);
    _len = o + 24;
  }
}
