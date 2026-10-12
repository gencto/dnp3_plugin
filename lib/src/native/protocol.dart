// Constants shared with native/src/core.rs. Keep in sync.

/// ABI version expected from the native library
const int abiVersion = 1;

abstract final class Msg {
  static const int result = 1;
  static const int log = 2;
  static const int clientState = 10;
  static const int portState = 11;
  static const int connectionState = 12;
  static const int connectionEvent = 13;
  static const int measurements = 20;
  static const int associationInfo = 21;
  static const int fileRead = 22;
  static const int controlRequest = 30;
  static const int applicationRequest = 31;
  static const int outstationInfo = 32;
  static const int outstationEvent = 33;
  static const int masterServerRequest = 40;
}

abstract final class ErrorCode {
  static const int ok = 0;
  static const int notInitialized = 1;
  static const int invalidHandle = 2;
  static const int invalidArgument = 3;
  static const int badConfig = 4;
  static const int shutdown = 5;
  static const int io = 6;
  static const int tls = 7;
  static const int notSupported = 8;
  static const int panic = 9;
  static const int association = 10;
  static const int task = 11;
  static const int command = 12;
  static const int timeSync = 13;
  static const int write = 14;
  static const int poll = 15;
  static const int file = 16;
  static const int filter = 17;
  static const int bufferTooSmall = 18;
  static const int attribute = 19;
}

/// Point / measurement kinds (native/src/measurement.rs `kind`)
abstract final class PointKind {
  static const int binaryInput = 1;
  static const int doubleBitBinaryInput = 2;
  static const int binaryOutputStatus = 3;
  static const int counter = 4;
  static const int frozenCounter = 5;
  static const int analogInput = 6;
  static const int frozenAnalogInput = 7;
  static const int analogInputDeadBand = 8;
  static const int analogOutputStatus = 9;
  static const int analogOutputCommandEvent = 10;
  static const int binaryOutputCommandEvent = 11;
  static const int unsignedInteger = 12;
  static const int octetString = 13;
  static const int deviceAttribute = 14;
  static const int absTime = 15;
}
