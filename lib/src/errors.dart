import 'native/protocol.dart';
import 'types.dart';

/// Base class of every error raised by this package
sealed class Dnp3Exception implements Exception {
  /// Native error code (see [ErrorCode])
  final int code;

  /// Native sub-code (meaning depends on [code])
  final int subCode;

  /// Human-readable error message (the native library's `Display` text).
  final String message;

  /// Structured description of the underlying library error, e.g.
  /// `Link(Stdio(ConnectionReset))` or `MalformedResponse(InsufficientBytes)` (may be empty)
  final String detail;

  /// Creates an exception from its raw native fields.
  const Dnp3Exception(this.code, this.subCode, this.message, [this.detail = '']);

  /// Map a native (code, sub, message) triple to the most specific exception type
  factory Dnp3Exception.fromNative(int code, int sub, String message, [String detail = '']) => switch (code) {
    ErrorCode.task => TaskException(TaskError.fromCode(sub & 0xFF), sub, message, detail),
    ErrorCode.command => CommandException(sub, message, detail),
    ErrorCode.timeSync => TimeSyncException(sub, message, detail),
    ErrorCode.write => WriteException(sub, message, detail),
    ErrorCode.file => FileException(sub, message, detail),
    ErrorCode.association => AssociationException(sub, message, detail),
    ErrorCode.shutdown => ShutdownException(message, detail),
    ErrorCode.invalidHandle => InvalidHandleException(message, detail),
    ErrorCode.badConfig || ErrorCode.invalidArgument => ConfigException(code, message, detail),
    _ => NativeException(code, sub, message, detail),
  };

  @override
  String toString() => '$runtimeType: $message${detail.isEmpty ? '' : ' [$detail]'}';
}

/// Generic native failure (I/O, TLS, unsupported platform feature, ...)
final class NativeException extends Dnp3Exception {
  /// Exception for any [ErrorCode] without a dedicated subclass (e.g. io, tls, poll, panic).
  const NativeException(super.code, super.subCode, super.message, [super.detail]);
}

/// Invalid configuration or argument
final class ConfigException extends Dnp3Exception {
  /// [code] is [ErrorCode.badConfig] or [ErrorCode.invalidArgument]; the sub-code is always 0.
  const ConfigException(int code, String message, [String detail = '']) : super(code, 0, message, detail);
}

/// The object was destroyed or the handle is not valid in this process
final class InvalidHandleException extends Dnp3Exception {
  /// Exception with code [ErrorCode.invalidHandle].
  const InvalidHandleException(String message, [String detail = ''])
    : super(ErrorCode.invalidHandle, 0, message, detail);
}

/// The channel / runtime has been shut down
final class ShutdownException extends Dnp3Exception {
  /// Exception with code [ErrorCode.shutdown].
  const ShutdownException(String message, [String detail = ''])
    : super(ErrorCode.shutdown, 0, message, detail);
}

/// Errors of master tasks (mirrors `dnp3::master::TaskError`)
enum TaskError {
  /// 0: unrecognized sub-code.
  unknown,

  /// 1: too many user requests are queued.
  tooManyRequests,

  /// 2: link-layer or I/O error.
  link,

  /// 3: transport or application-layer error.
  transport,

  /// 4: the outstation set an IIN2 error bit (see [TaskException.iin2]).
  rejectedByIin2,

  /// 5: the response could not be parsed.
  malformedResponse,

  /// 6: the response contained unexpected object headers.
  unexpectedResponseHeaders,

  /// 7: a non-final response fragment did not request confirmation.
  nonFinWithoutCon,

  /// 8: a non-FIR fragment arrived while a FIR fragment was expected.
  neverReceivedFir,

  /// 9: a second FIR fragment arrived after FIR was already received.
  unexpectedFir,

  /// 10: a multi-fragment response arrived where a single FIR/FIN fragment was expected.
  multiFragmentResponse,

  /// 11: no response within the configured response timeout.
  responseTimeout,

  /// 12: insufficient buffer space to serialize the request, or its data cannot be encoded.
  writeError,

  /// 13: request data could not be encoded (e.g. a bad device attribute).
  badEncoding,

  /// 14: the association (outstation address) does not exist.
  noSuchAssociation,

  /// 15: there is no connection to the outstation.
  noConnection,

  /// 16: the master task was shut down.
  shutdown,

  /// 17: the master channel is disabled.
  disabled;

  /// Task error for the low byte of a native sub-code; out-of-range values map to [unknown].
  static TaskError fromCode(int code) => code >= 0 && code < values.length ? values[code] : TaskError.unknown;
}

/// A master task (read, command, restart, ...) failed; [error] gives the reason.
final class TaskException extends Dnp3Exception {
  /// Reason decoded from the low byte of [subCode].
  final TaskError error;

  /// Exception with code [ErrorCode.task] and the raw native [sub] code.
  const TaskException(this.error, int sub, String message, [String detail = ''])
    : super(ErrorCode.task, sub, message, detail);

  /// IIN2 byte for [TaskError.rejectedByIin2]
  int get iin2 => subCode >> 8;
}

/// Why a command response was rejected (low byte of the [CommandException] sub-code).
enum CommandResponseError {
  /// 0: unrecognized sub-code.
  unknown,

  /// 1: the outstation returned a non-success [CommandStatus] (see [CommandException.status]).
  badStatus,

  /// 2: the response has a different number of object headers than the request.
  headerCountMismatch,

  /// 3: a response header has a different type than in the request.
  headerTypeMismatch,

  /// 4: a response header has a different number of objects than in the request.
  objectCountMismatch,

  /// 5: an echoed object value differs from the request.
  objectValueMismatch,
}

/// The outstation answered a command with something other than an echo + success
final class CommandException extends Dnp3Exception {
  /// Exception with code [ErrorCode.command]; [sub] holds the reason (low byte) and status (bits 8+).
  const CommandException(int sub, String message, [String detail = ''])
    : super(ErrorCode.command, sub, message, detail);

  /// Reason decoded from the low byte of [subCode].
  CommandResponseError get error {
    final c = subCode & 0xFF;
    return c < CommandResponseError.values.length
        ? CommandResponseError.values[c]
        : CommandResponseError.unknown;
  }

  /// Status returned by the outstation when [error] is [CommandResponseError.badStatus]
  CommandStatus? get status =>
      error == CommandResponseError.badStatus ? CommandStatus.fromCode(subCode >> 8) : null;

  /// Raw status code returned by the outstation when [error] is
  /// [CommandResponseError.badStatus] (keeps codes that [CommandStatus] maps to `unknown`)
  int? get statusCode => error == CommandResponseError.badStatus ? (subCode >> 8) & 0xFF : null;
}

/// Why a time synchronization failed (low byte of the [TimeSyncException] sub-code).
enum TimeSyncError {
  /// 0: unrecognized sub-code.
  unknown,

  /// 1: the local clock went backwards during the procedure.
  clockRollback,

  /// 2: the system time could not be converted to a DNP3 (Unix-epoch) time.
  systemTimeNotUnix,

  /// 3: the outstation returned an invalid time delay, in ms (see [TimeSyncException.value]).
  badOutstationTimeDelay,

  /// 4: arithmetic overflow while computing the time.
  overflow,

  /// 5: the outstation still has IIN1.4 NEED_TIME set after the sync.
  stillNeedsTime,

  /// 6: the system time is not available.
  systemTimeNotAvailable,

  /// 7: the outstation set an IIN2 error bit (see [TimeSyncException.value]).
  iinError,
}

/// A time synchronization procedure failed; task-level failures raise [TaskException] instead.
final class TimeSyncException extends Dnp3Exception {
  /// Exception with code [ErrorCode.timeSync]; [sub] holds the reason (low byte) and a value (bits 8+).
  const TimeSyncException(int sub, String message, [String detail = ''])
    : super(ErrorCode.timeSync, sub, message, detail);

  /// Reason decoded from the low byte of [subCode].
  TimeSyncError get error {
    final c = subCode & 0xFF;
    return c < TimeSyncError.values.length ? TimeSyncError.values[c] : TimeSyncError.unknown;
  }

  /// value attached to the error (outstation delay or IIN2 byte)
  int get value => subCode >> 8;
}

/// The outstation set an IIN2 error bit in response to a WRITE / FREEZE / ...
final class WriteException extends Dnp3Exception {
  /// Exception with code [ErrorCode.write]; the sub-code is the raw [iin2] byte.
  const WriteException(int iin2, String message, [String detail = ''])
    : super(ErrorCode.write, iin2, message, detail);

  /// IIN2 byte returned by the outstation (see the IIN2 getters of [Iin]).
  int get iin2 => subCode;
}

/// Why a file transfer operation failed (low byte of the [FileException] sub-code).
enum FileError {
  /// 0: unrecognized sub-code.
  unknown,

  /// 1: the outstation returned a bad file response.
  badResponse,

  /// 2: the outstation returned a non-success file status (see [FileException.fileStatus]).
  badStatus,

  /// 3: the file handle in the response does not match the request.
  wrongHandle,

  /// 4: the outstation denied permission to access the file.
  noPermission,

  /// 5: a data block arrived with an unexpected block number.
  badBlockNum,

  /// 6: the transfer was aborted by the user.
  abortByUser,

  /// 7: the file exceeded the maximum length given by the caller.
  maxLengthExceeded,
}

/// A DNP3 file transfer failed; task-level failures raise [TaskException] instead.
final class FileException extends Dnp3Exception {
  /// Exception with code [ErrorCode.file]; [sub] holds the reason (low byte) and file status (bits 8+).
  const FileException(int sub, String message, [String detail = ''])
    : super(ErrorCode.file, sub, message, detail);

  /// Reason decoded from the low byte of [subCode].
  FileError get error {
    final c = subCode & 0xFF;
    return c < FileError.values.length ? FileError.values[c] : FileError.unknown;
  }

  /// DNP3 file status code when [error] is [FileError.badStatus]
  int get fileStatus => subCode >> 8;
}

/// Adding an association to a master channel failed.
final class AssociationException extends Dnp3Exception {
  /// Exception with code [ErrorCode.association]; sub-code 1 duplicate address, 2 wrong channel type.
  const AssociationException(int sub, String message, [String detail = ''])
    : super(ErrorCode.association, sub, message, detail);

  /// An association with the same outstation address already exists on the channel (sub-code 1).
  bool get duplicateAddress => subCode == 1;

  /// The operation needs a different channel type, stream (TCP/TLS/serial) vs UDP (sub-code 2).
  bool get wrongChannelType => subCode == 2;
}
