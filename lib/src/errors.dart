import 'native/protocol.dart';
import 'types.dart';

/// Base class of every error raised by this package
sealed class Dnp3Exception implements Exception {
  /// Native error code (see [ErrorCode])
  final int code;

  /// Native sub-code (meaning depends on [code])
  final int subCode;

  final String message;

  const Dnp3Exception(this.code, this.subCode, this.message);

  /// Map a native (code, sub, message) triple to the most specific exception type
  factory Dnp3Exception.fromNative(int code, int sub, String message) => switch (code) {
    ErrorCode.task => TaskException(TaskError.fromCode(sub & 0xFF), sub, message),
    ErrorCode.command => CommandException(sub, message),
    ErrorCode.timeSync => TimeSyncException(sub, message),
    ErrorCode.write => WriteException(sub, message),
    ErrorCode.file => FileException(sub, message),
    ErrorCode.association => AssociationException(sub, message),
    ErrorCode.shutdown => ShutdownException(message),
    ErrorCode.invalidHandle => InvalidHandleException(message),
    ErrorCode.badConfig || ErrorCode.invalidArgument => ConfigException(code, message),
    _ => NativeException(code, sub, message),
  };

  @override
  String toString() => '$runtimeType: $message';
}

/// Generic native failure (I/O, TLS, unsupported platform feature, ...)
final class NativeException extends Dnp3Exception {
  const NativeException(super.code, super.subCode, super.message);
}

/// Invalid configuration or argument
final class ConfigException extends Dnp3Exception {
  const ConfigException(int code, String message) : super(code, 0, message);
}

/// The object was destroyed or the handle is not valid in this process
final class InvalidHandleException extends Dnp3Exception {
  const InvalidHandleException(String message) : super(ErrorCode.invalidHandle, 0, message);
}

/// The channel / runtime has been shut down
final class ShutdownException extends Dnp3Exception {
  const ShutdownException(String message) : super(ErrorCode.shutdown, 0, message);
}

/// Errors of master tasks (mirrors `dnp3::master::TaskError`)
enum TaskError {
  unknown,
  tooManyRequests,
  link,
  transport,
  rejectedByIin2,
  malformedResponse,
  unexpectedResponseHeaders,
  nonFinWithoutCon,
  neverReceivedFir,
  unexpectedFir,
  multiFragmentResponse,
  responseTimeout,
  writeError,
  badEncoding,
  noSuchAssociation,
  noConnection,
  shutdown,
  disabled;

  static TaskError fromCode(int code) => code >= 0 && code < values.length ? values[code] : TaskError.unknown;
}

final class TaskException extends Dnp3Exception {
  final TaskError error;
  const TaskException(this.error, int sub, String message) : super(ErrorCode.task, sub, message);

  /// IIN2 byte for [TaskError.rejectedByIin2]
  int get iin2 => subCode >> 8;
}

enum CommandResponseError {
  unknown,
  badStatus,
  headerCountMismatch,
  headerTypeMismatch,
  objectCountMismatch,
  objectValueMismatch,
}

/// The outstation answered a command with something other than an echo + success
final class CommandException extends Dnp3Exception {
  const CommandException(int sub, String message) : super(ErrorCode.command, sub, message);

  CommandResponseError get error {
    final c = subCode & 0xFF;
    return c < CommandResponseError.values.length
        ? CommandResponseError.values[c]
        : CommandResponseError.unknown;
  }

  /// Status returned by the outstation when [error] is [CommandResponseError.badStatus]
  CommandStatus? get status =>
      error == CommandResponseError.badStatus ? CommandStatus.fromCode(subCode >> 8) : null;
}

enum TimeSyncError {
  unknown,
  clockRollback,
  systemTimeNotUnix,
  badOutstationTimeDelay,
  overflow,
  stillNeedsTime,
  systemTimeNotAvailable,
  iinError,
}

final class TimeSyncException extends Dnp3Exception {
  const TimeSyncException(int sub, String message) : super(ErrorCode.timeSync, sub, message);

  TimeSyncError get error {
    final c = subCode & 0xFF;
    return c < TimeSyncError.values.length ? TimeSyncError.values[c] : TimeSyncError.unknown;
  }

  /// value attached to the error (outstation delay or IIN2 byte)
  int get detail => subCode >> 8;
}

/// The outstation set an IIN2 error bit in response to a WRITE / FREEZE / ...
final class WriteException extends Dnp3Exception {
  const WriteException(int iin2, String message) : super(ErrorCode.write, iin2, message);

  int get iin2 => subCode;
}

enum FileError {
  unknown,
  badResponse,
  badStatus,
  wrongHandle,
  noPermission,
  badBlockNum,
  abortByUser,
  maxLengthExceeded,
}

final class FileException extends Dnp3Exception {
  const FileException(int sub, String message) : super(ErrorCode.file, sub, message);

  FileError get error {
    final c = subCode & 0xFF;
    return c < FileError.values.length ? FileError.values[c] : FileError.unknown;
  }

  /// DNP3 file status code when [error] is [FileError.badStatus]
  int get fileStatus => subCode >> 8;
}

final class AssociationException extends Dnp3Exception {
  const AssociationException(int sub, String message) : super(ErrorCode.association, sub, message);

  bool get duplicateAddress => subCode == 1;
  bool get wrongChannelType => subCode == 2;
}
