/// DNP3 master: channels, associations, polls, commands and file transfer.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'config.dart';
import 'connection_policy.dart';
import 'errors.dart';
import 'measurements.dart';
import 'native/bindings.dart';
import 'native/protocol.dart';
import 'native/runtime.dart';
import 'native/writer.dart';
import 'requests.dart';
import 'types.dart';
import 'variation.dart';

// ---------------------------------------------------------------------------------------
// shared event plumbing
// ---------------------------------------------------------------------------------------

ClientStateEvent _clientState(int code, Object? payload) {
  final ms = payload as int? ?? 0;
  final state = ClientState.values[code.clamp(0, ClientState.values.length - 1)];
  return ClientStateEvent(state, ms > 0 ? Duration(milliseconds: ms) : null);
}

PortStateEvent _portState(int code, Object? payload) {
  final ms = payload as int? ?? 0;
  final state = PortState.values[code.clamp(0, PortState.values.length - 1)];
  return PortStateEvent(state, ms > 0 ? Duration(milliseconds: ms) : null);
}

ConnectionEvent _connectionEvent(int code, Object? payload) {
  final s = payload as String? ?? '|';
  final sep = s.indexOf('|');
  final addr = s.substring(0, sep);
  final host = s.substring(sep + 1);
  return ConnectionEvent(
    ConnectionEventType.values[code.clamp(0, ConnectionEventType.values.length - 1)],
    addr.isEmpty ? null : addr,
    host.isEmpty ? null : host,
  );
}

/// Mixin for native objects that publish client / port / connection events
mixin ClientEvents {
  final _clientStates = StreamController<ClientStateEvent>.broadcast();
  final _portStates = StreamController<PortStateEvent>.broadcast();
  final _connectionEvents = StreamController<ConnectionEvent>.broadcast();

  ClientStateEvent? _lastClientState;

  ConnectionPolicy? _connectionPolicy;
  List<String> _endpoints = const [];

  /// Installs the policy that answers native connection requests for `endpoints` (internal).
  @internal
  void setConnectionPolicy(ConnectionPolicy? policy, List<String> endpoints) {
    _connectionPolicy = policy;
    _endpoints = endpoints;
  }

  /// Answer a native connection request with the installed [ConnectionPolicy]
  @internal
  void answerConnectionRequest(int token, Uint8List data) =>
      handleConnectionRequest(_connectionPolicy, _endpoints, token, data);

  /// State of the TCP/TLS client (connecting, connected, waiting, ...)
  Stream<ClientStateEvent> get clientStates => _clientStates.stream;

  /// Last known client state
  ClientStateEvent? get clientState => _lastClientState;

  /// State of the serial port
  Stream<PortStateEvent> get portStates => _portStates.stream;

  /// Detailed connection attempts / failures of TCP/TLS clients
  Stream<ConnectionEvent> get connectionEvents => _connectionEvents.stream;

  /// Returns true if the event was consumed
  @internal
  bool handleClientEvent(int kind, int b, Object? payload) {
    switch (kind) {
      case Msg.clientState:
        final e = _clientState(b, payload);
        _lastClientState = e;
        _clientStates.add(e);
        return true;
      case Msg.portState:
        _portStates.add(_portState(b, payload));
        return true;
      case Msg.connectionEvent:
        _connectionEvents.add(_connectionEvent(b, payload));
        return true;
    }
    return false;
  }

  /// Closes the client-state, port-state and connection-event streams (internal).
  @internal
  void closeClientEvents() {
    _clientStates.close();
    _portStates.close();
    _connectionEvents.close();
  }
}

// ---------------------------------------------------------------------------------------
// master channel
// ---------------------------------------------------------------------------------------

/// A communication channel of a master (TCP, TLS, serial or UDP) that can talk to one or
/// more outstations through [Association]s.
final class MasterChannel with ClientEvents {
  /// Opaque native handle; can be sent to another isolate and re-attached with [attach]
  final int handle;
  final NativeRuntime _rt;
  final bool _owned;
  final _associations = <Association>[];
  bool _destroyed = false;
  bool _released = false;

  MasterChannel._(this.handle, this._rt, this._owned) {
    if (_owned) _rt.register(handle, _onEvent, _release);
  }

  static MasterChannel _create(
    Map<String, Object?> transport,
    MasterChannelConfig config, [
    ConnectionPolicy? policy,
  ]) {
    final rt = NativeRuntime.current;
    if (policy != null) {
      transport['connectionCallback'] = true;
      transport['callbackTimeoutMs'] = policy.callbackTimeout.inMilliseconds;
    }
    final json = toJson({'channel': config.toJson(), 'transport': transport});
    final id = withNativeString(json, (p, l) => dnp3_master_create(p, l, rt.port));
    final channel = MasterChannel._(check(id), rt, true);
    channel.setConnectionPolicy(policy, (transport['endpoints'] as List?)?.cast<String>() ?? const []);
    return channel;
  }

  /// TCP client connecting to `endpoints` (tried round-robin), e.g. `['127.0.0.1:20000']`
  factory MasterChannel.tcpClient({
    required MasterChannelConfig config,
    required List<String> endpoints,
    LinkErrorMode linkErrorMode = LinkErrorMode.close,
    ConnectStrategy connectStrategy = const ConnectStrategy(),
    ConnectOptions connectOptions = const ConnectOptions(),
    ConnectionPolicy? connectionPolicy,
  }) => _create(
    {
      'type': 'tcp',
      'endpoints': endpoints,
      'linkErrorMode': linkErrorMode.name,
      'connectStrategy': connectStrategy.toJson(),
      'connectOptions': connectOptions.toJson(),
    },
    config,
    connectionPolicy,
  );

  /// TLS client
  factory MasterChannel.tlsClient({
    required MasterChannelConfig config,
    required List<String> endpoints,
    required TlsConfig tls,
    LinkErrorMode linkErrorMode = LinkErrorMode.close,
    ConnectStrategy connectStrategy = const ConnectStrategy(),
    ConnectOptions connectOptions = const ConnectOptions(),
    ConnectionPolicy? connectionPolicy,
  }) => _create(
    {
      'type': 'tls',
      'endpoints': endpoints,
      'linkErrorMode': linkErrorMode.name,
      'connectStrategy': connectStrategy.toJson(),
      'connectOptions': connectOptions.toJson(),
      'tls': tls.toJson(),
    },
    config,
    connectionPolicy,
  );

  /// Serial port, e.g. `/dev/ttyUSB0` or `COM3` (not available on iOS)
  factory MasterChannel.serial({
    required MasterChannelConfig config,
    required String path,
    SerialSettings settings = const SerialSettings(),
    Duration retryDelay = const Duration(seconds: 1),
  }) => _create({
    'type': 'serial',
    'path': path,
    'settings': settings.toJson(),
    'retryDelayMs': retryDelay.inMilliseconds,
  }, config);

  /// UDP socket bound to `localEndpoint`. Use [addAssociation] with `udpDestination`.
  factory MasterChannel.udp({
    required MasterChannelConfig config,
    required String localEndpoint,
    LinkReadMode linkReadMode = LinkReadMode.datagram,
    Duration retryDelay = const Duration(seconds: 1),
  }) => _create({
    'type': 'udp',
    'localEndpoint': localEndpoint,
    'linkReadMode': linkReadMode.name,
    'retryDelayMs': retryDelay.inMilliseconds,
  }, config);

  /// Use a channel created in another isolate. No client-state events are delivered to the
  /// attached instance; all operations are available.
  factory MasterChannel.attach(int handle) => MasterChannel._(handle, NativeRuntime.current, false);

  /// Wrap a channel created natively by a [MasterServer]
  factory MasterChannel.adopt(int handle) => MasterChannel._(handle, NativeRuntime.current, true);

  void _onEvent(int kind, int a, int b, Object? payload) {
    if (kind == Msg.connectionRequest) {
      answerConnectionRequest(a, payload as Uint8List);
    } else {
      handleClientEvent(kind, b, payload);
    }
  }

  void _checkAlive() {
    if (_destroyed) throw StateError('MasterChannel has been destroyed');
  }

  /// Starts the channel: it connects / opens the port and begins running association tasks.
  ///
  /// Throws [StateError] if the channel was destroyed.
  Future<void> enable() {
    _checkAlive();
    return _rt.call((p, r) => dnp3_master_enable(handle, 1, p, r));
  }

  /// Stops the channel and closes its connection; associations and polls are kept.
  ///
  /// Throws [StateError] if the channel was destroyed.
  Future<void> disable() {
    _checkAlive();
    return _rt.call((p, r) => dnp3_master_enable(handle, 0, p, r));
  }

  /// Changes how much protocol traffic the channel logs.
  Future<void> setDecodeLevel(DecodeLevel level) {
    _checkAlive();
    final json = utf8Bytes(toJson(level.toJson()));
    return _rt.call((p, r) => dnp3_master_set_decode_level(handle, json.address, json.length, p, r));
  }

  /// Returns the channel's current protocol decode (logging) level.
  Future<DecodeLevel> getDecodeLevel() async {
    _checkAlive();
    final s = await _rt.call((p, r) => dnp3_master_get_decode_level(handle, p, r)) as String;
    return DecodeLevel.fromJson(jsonDecode(s) as Map<String, Object?>);
  }

  /// Add an outstation to this channel.
  ///
  /// Measurements and association information are delivered to this isolate's streams
  /// (`Association.measurements`) — or, if `eventPort` is given, directly to that port in
  /// another isolate (see [MeasurementWorker]), without passing through this isolate.
  Future<Association> addAssociation(
    int address, {
    AssociationConfig config = const AssociationConfig(),
    String? udpDestination,
    bool information = false,
    SendPort? eventPort,
    int maxInFlightFragments = 0,
    Duration backpressureTimeout = const Duration(seconds: 30),
    bool manualAck = false,
  }) async {
    _checkAlive();
    final json = utf8Bytes(
      toJson({
        'address': address,
        'udpDestination': udpDestination,
        'config': config.toJson(),
        'information': information,
        'maxInFlightFragments': maxInFlightFragments,
        'backpressureTimeoutMs': backpressureTimeout.inMilliseconds,
      }),
    );
    final events = eventPort?.nativePort ?? _rt.port;
    final id =
        await _rt.call((p, r) => dnp3_master_add_association(handle, json.address, json.length, events, p, r))
            as int;
    // destroyed while the association was being added: it is gone with the channel
    _checkAlive();
    final assoc = Association._(id, address, _rt, eventPort == null, this)
      .._autoAck = maxInFlightFragments > 0 && !manualAck;
    _associations.add(assoc);
    return assoc;
  }

  /// Shut down the channel and all its associations.
  ///
  /// The native channel is shared by all isolates: destroying an [attach]ed instance shuts
  /// it down for the creating isolate as well.
  void destroy() {
    if (_destroyed) return;
    _destroyed = true;
    _release();
    dnp3_master_destroy(handle);
  }

  /// Stop delivering events to this isolate (the native channel is left untouched)
  void _release() {
    if (_released) return;
    _released = true;
    if (_owned) {
      _rt.unregister(handle);
      closeClientEvents();
    }
    for (final a in _associations) {
      a._release();
    }
    _associations.clear();
  }
}

// ---------------------------------------------------------------------------------------
// association
// ---------------------------------------------------------------------------------------

/// Type of a master task (see `AssociationEvent`)
enum TaskType {
  /// A user READ ([Association.read] / [Association.readWithHandler])
  userRead,

  /// A periodic [Poll] added with [Association.addPoll]
  periodicPoll,

  /// Integrity poll run at startup / after the outstation restarted or overflowed
  startupIntegrity,

  /// Event scan triggered automatically by the outstation's class IIN bits
  autoEventScan,

  /// SELECT/OPERATE or DIRECT_OPERATE ([Association.operate])
  command,

  /// WRITE clearing the outstation's DEVICE_RESTART IIN bit
  clearRestartBit,

  /// Automatic ENABLE_UNSOLICITED sent during startup
  enableUnsolicited,

  /// Automatic DISABLE_UNSOLICITED sent during startup
  disableUnsolicited,

  /// Time synchronization (automatic or [Association.synchronizeTime])
  timeSync,

  /// COLD_RESTART or WARM_RESTART
  restart,

  /// WRITE of analog dead bands ([Association.writeDeadBands])
  writeDeadBands,

  /// Request expecting an empty response ([Association.sendAndExpectEmptyResponse] and helpers)
  genericEmptyResponse,

  /// File or directory read
  fileRead,

  /// AUTHENTICATE_FILE ([Association.getFileAuthKey])
  fileAuth,

  /// OPEN_FILE ([Association.openFile])
  fileOpen,

  /// WRITE of a file data block ([Association.writeFileBlock])
  fileWriteBlock,

  /// CLOSE_FILE ([Association.closeFile])
  fileClose,

  /// GET_FILE_INFO ([Association.getFileInfo])
  getFileInfo,
}

/// Kind of an [AssociationEvent]
enum AssociationEventType {
  /// A task sent its request
  taskStart,

  /// A task completed successfully
  taskSuccess,

  /// A task failed; see [AssociationEvent.error]
  taskFail,

  /// An unsolicited response was received
  unsolicitedResponse,
}

/// Informational events of an association (enable with `information: true`)
final class AssociationEvent {
  /// What happened
  final AssociationEventType type;

  /// Task concerned; null for unsolicited responses
  final TaskType? taskType;

  /// Request function code (task start / success, and failures of [TaskType.genericEmptyResponse])
  final FunctionCode? functionCode;

  /// Application-layer sequence number of the request or unsolicited response
  final int sequence;

  /// Reason of a [AssociationEventType.taskFail]
  final TaskError? error;

  /// IIN2 byte returned by the outstation when [error] is [TaskError.rejectedByIin2]
  final int iin2;

  /// Unsolicited response repeated the previous one's sequence number
  final bool isDuplicate;

  /// Creates an event; instances normally come from [Association.information].
  const AssociationEvent(
    this.type, {
    this.taskType,
    this.functionCode,
    this.sequence = 0,
    this.error,
    this.iin2 = 0,
    this.isDuplicate = false,
  });

  /// Decodes a native association-info message of native `type` with packed value `v` (internal).
  static AssociationEvent decode(int type, int v) {
    final t = AssociationEventType.values[type.clamp(0, 3)];
    final task = v & 0xFF;
    final taskType = task < TaskType.values.length ? TaskType.values[task] : null;
    switch (t) {
      case AssociationEventType.taskStart || AssociationEventType.taskSuccess:
        return AssociationEvent(
          t,
          taskType: taskType,
          functionCode: FunctionCode.fromCode((v >> 8) & 0xFF),
          sequence: (v >> 16) & 0xFF,
        );
      case AssociationEventType.taskFail:
        return AssociationEvent(
          t,
          taskType: taskType,
          functionCode: taskType == TaskType.genericEmptyResponse
              ? FunctionCode.fromCode((v >> 8) & 0xFF)
              : null,
          error: TaskError.fromCode((v >> 24) & 0xFF),
          // the task error sub-code carries the IIN2 byte in its bits 8..15
          iin2: (v >> 32) & 0xFF,
        );
      case AssociationEventType.unsolicitedResponse:
        return AssociationEvent(t, isDuplicate: v & 1 != 0, sequence: (v >> 16) & 0xFF);
    }
  }

  @override
  String toString() =>
      'AssociationEvent($type, $taskType, fc: $functionCode, seq: $sequence'
      '${error != null ? ', error: $error' : ''})';
}

/// Permissions of a DNP3 file (owner / group / world × read / write / execute)
extension type const FilePermissions(int bits) {
  /// No permission
  static const FilePermissions none = FilePermissions(0);

  /// Every permission (0o777)
  static const FilePermissions all = FilePermissions(0x1FF);

  /// Execute permission for everyone else
  static const FilePermissions worldExecute = FilePermissions(0x001);

  /// Write permission for everyone else
  static const FilePermissions worldWrite = FilePermissions(0x002);

  /// Read permission for everyone else
  static const FilePermissions worldRead = FilePermissions(0x004);

  /// Execute permission for the group
  static const FilePermissions groupExecute = FilePermissions(0x008);

  /// Write permission for the group
  static const FilePermissions groupWrite = FilePermissions(0x010);

  /// Read permission for the group
  static const FilePermissions groupRead = FilePermissions(0x020);

  /// Execute permission for the owner
  static const FilePermissions ownerExecute = FilePermissions(0x040);

  /// Write permission for the owner
  static const FilePermissions ownerWrite = FilePermissions(0x080);

  /// Read permission for the owner
  static const FilePermissions ownerRead = FilePermissions(0x100);

  /// Union of both permission sets
  FilePermissions operator |(FilePermissions o) => FilePermissions(bits | o.bits);

  /// Whether every permission in `o` is granted
  bool has(FilePermissions o) => bits & o.bits == o.bits;
}

/// Type of an entry reported by the outstation (group 70 variation 7)
enum FileType {
  /// A directory
  directory,

  /// A simple file
  file,

  /// Any other type; the raw code is in [FileInfo.rawType]
  other,
}

/// Mode in which [Association.openFile] opens a file
enum FileMode {
  /// No mode (null mode code 0)
  none,

  /// Open for reading
  read,

  /// Create or truncate for writing
  write,

  /// Open for appending
  append,
}

/// Directory entry / file description returned by the outstation (group 70 variation 7)
final class FileInfo {
  /// File or directory name
  final String name;

  /// Kind of entry
  final FileType type;

  /// Raw DNP3 file type code (0 directory, 1 simple file)
  final int rawType;

  /// Size in bytes (for a directory: number of entries)
  final int size;

  /// Creation time
  final Dnp3Time created;

  /// Owner / group / world permissions
  final FilePermissions permissions;

  /// Creates a file description.
  const FileInfo(this.name, this.type, this.rawType, this.size, this.created, this.permissions);

  /// Decodes one native entry at offset `o`; returns it with the number of bytes consumed (internal).
  static (FileInfo, int) decode(ByteData d, int o) {
    final t = d.getUint8(o);
    final raw = d.getUint16(o + 2, Endian.little);
    final size = d.getUint32(o + 4, Endian.little);
    final created = d.getUint64(o + 8, Endian.little);
    final perms = d.getUint16(o + 16, Endian.little);
    final len = d.getUint32(o + 20, Endian.little);
    final name = utf8.decode(d.buffer.asUint8List(d.offsetInBytes + o + 24, len), allowMalformed: true);
    final consumed = 24 + ((len + 3) & ~3);
    return (
      FileInfo(name, FileType.values[t.clamp(0, 2)], raw, size, Dnp3Time(created), FilePermissions(perms)),
      consumed,
    );
  }

  @override
  String toString() => 'FileInfo($name, $type, $size bytes, created: $created)';
}

/// Result of [Association.openFile]
final class OpenFile {
  /// Outstation-assigned handle for [Association.writeFileBlock] and [Association.closeFile]
  final int handle;

  /// File size reported by the outstation, in bytes
  final int fileSize;

  /// Largest block size the outstation accepts, in bytes
  final int maxBlockSize;

  /// Creates an open-file result.
  const OpenFile(this.handle, this.fileSize, this.maxBlockSize);
}

/// Progress of a file read started with [Association.readFile]
final class FileReadTransfer {
  final int _id;
  final _blocks = StreamController<Uint8List>();
  final _opened = Completer<int>();
  final NativeRuntime _rt;
  final FutureOr<bool> Function(int size)? _onOpened;

  FileReadTransfer._(this._id, this._rt, [this._onOpened]) {
    _rt.register(_id, _onEvent, () => _fail(const ShutdownException('runtime closed')));
    // the failure is also reported through [blocks]; do not require awaiting [size]
    _opened.future.ignore();
  }

  /// Size announced by the outstation when the file was opened
  Future<int> get size => _opened.future;

  /// File content, block by block. Each block is a view into native memory adopted by
  /// the Dart heap (no copy).
  Stream<Uint8List> get blocks => _blocks.stream;

  /// Collect the whole file
  Future<Uint8List> readAll() async {
    final b = BytesBuilder(copy: false);
    await for (final x in blocks) {
      b.add(x);
    }
    return b.takeBytes();
  }

  /// Ask the master to abort the transfer at the next block
  void abort() => dnp3_file_read_abort(_id);

  Future<void> _confirmOpen(int token, Uint8List data) async {
    final size = ByteData.sublistView(data).getUint32(0, Endian.little);
    var ok = false;
    try {
      ok = await (_onOpened?.call(size) ?? true);
    } catch (_) {}
    NativeRuntime.reply(token, ok ? 1 : 0);
  }

  void _onEvent(int kind, int a, int b, Object? payload) {
    if (kind == Msg.fileOpenRequest) {
      _confirmOpen(a, payload as Uint8List);
      return;
    }
    switch (b) {
      case 0: // opened
        if (!_opened.isCompleted) _opened.complete(payload as int);
      case 1: // block
        final data = payload as Uint8List;
        final len = ByteData.sublistView(data).getUint32(4, Endian.little);
        _blocks.add(Uint8List.sublistView(data, 8, 8 + len));
      case 2: // aborted
        final s = payload as String;
        final sep = s.indexOf('|');
        _fail(decodeError(int.parse(s.substring(0, sep)), s.substring(sep + 1)));
      case 3: // completed
        if (!_opened.isCompleted) _opened.complete(0);
        _finish();
    }
  }

  void _fail(Object error) {
    if (_blocks.isClosed) return;
    if (!_opened.isCompleted) _opened.completeError(error);
    _blocks.addError(error);
    _finish();
  }

  void _finish() {
    _rt.unregister(_id);
    _blocks.close();
  }
}

/// A master's session with one outstation
final class Association {
  /// Opaque native handle; can be sent to another isolate and re-attached with [attach]
  final int handle;

  /// DNP3 address of the outstation (0 for attached instances when unknown)
  final int address;
  final NativeRuntime _rt;
  final bool _owned;
  final MasterChannel? _channel;
  final _measurements = StreamController<MeasurementFragment>.broadcast(sync: true);
  final _information = StreamController<AssociationEvent>.broadcast();
  bool _released = false;
  bool _autoAck = false;

  Association._(this.handle, this.address, this._rt, this._owned, [this._channel]) {
    if (_owned) _rt.register(handle, _onEvent, _release);
  }

  /// Use an association created in another isolate. Measurements are still delivered to
  /// the isolate that created it (or to its `eventPort`).
  factory Association.attach(int handle, {int address = 0}) =>
      Association._(handle, address, NativeRuntime.current, false);

  void _release() {
    if (_released) return;
    _released = true;
    if (_owned) {
      _rt.unregister(handle);
      _measurements.close();
      _information.close();
    }
  }

  void _onEvent(int kind, int a, int b, Object? payload) {
    switch (kind) {
      case Msg.measurements:
        if (_measurements.hasListener) {
          _measurements.add(MeasurementFragment(payload as Uint8List));
        }
        // listeners run synchronously: the fragment has been consumed
        if (_autoAck) dnp3_association_ack(handle, 1);
      case Msg.associationInfo:
        _information.add(AssociationEvent.decode(b, payload as int));
    }
  }

  /// Every response fragment / unsolicited response (polls, integrity scans, reads).
  /// Delivered synchronously from the port handler: the fragment wraps native memory
  /// adopted by the VM, nothing is copied.
  Stream<MeasurementFragment> get measurements => _measurements.stream;

  /// Task / unsolicited events (requires `information: true` when adding the association)
  Stream<AssociationEvent> get information => _information.stream;

  /// Sends a READ; completes once the response is received, its data having been
  /// delivered on [measurements]. Throws [TaskException] on failure.
  Future<void> read(ReadRequest request) {
    final req = request.toBytes();
    return _rt.call((p, r) => dnp3_association_read(handle, req.address, req.length, p, r));
  }

  /// Read and return the response directly instead of through [measurements]
  Future<List<MeasurementFragment>> readWithHandler(ReadRequest request) async {
    final req = request.toBytes();
    final data = await _rt.call(
      (p, r) => dnp3_association_read_with_handler(handle, req.address, req.length, p, r),
    );
    return MeasurementFragment.splitCollection(data as Uint8List);
  }

  /// SELECT/OPERATE (default) or DIRECT_OPERATE the commands
  Future<void> operate(CommandSet commands, {CommandMode mode = CommandMode.selectBeforeOperate}) {
    final w = ByteWriter(64);
    commands.encode(w, mode);
    final req = w.bytes;
    return _rt.call((p, r) => dnp3_association_operate(handle, req.address, req.length, p, r));
  }

  /// Send any request that expects an empty response (WRITE, FREEZE, ...)
  Future<void> sendAndExpectEmptyResponse(FunctionCode function, RequestHeaders headers) {
    final req = headers.bytes;
    return _rt.call(
      (p, r) => dnp3_association_send_and_expect_empty_response(
        handle,
        function.code,
        req.address,
        req.length,
        p,
        r,
      ),
    );
  }

  /// IMMEDIATE_FREEZE of all counters
  Future<void> freezeCounters({bool clear = false}) => sendAndExpectEmptyResponse(
    clear ? FunctionCode.freezeClear : FunctionCode.immediateFreeze,
    RequestHeaders().allObjects(_g20v0),
  );

  /// WRITE a device attribute (group 0)
  Future<void> writeAttribute(DeviceAttribute attribute) =>
      sendAndExpectEmptyResponse(FunctionCode.write, RequestHeaders().attribute(attribute));

  /// ENABLE_UNSOLICITED for the given classes
  Future<void> enableUnsolicited(EventClasses classes) =>
      sendAndExpectEmptyResponse(FunctionCode.enableUnsolicited, _classHeaders(classes));

  /// DISABLE_UNSOLICITED for the given classes
  Future<void> disableUnsolicited(EventClasses classes) =>
      sendAndExpectEmptyResponse(FunctionCode.disableUnsolicited, _classHeaders(classes));

  RequestHeaders _classHeaders(EventClasses c) {
    final h = RequestHeaders();
    if (c.class1) h.allObjects(_g60v2);
    if (c.class2) h.allObjects(_g60v3);
    if (c.class3) h.allObjects(_g60v4);
    return h;
  }

  /// WARM_RESTART; returns the restart delay reported by the outstation
  Future<Duration> warmRestart() async =>
      Duration(milliseconds: await _rt.call((p, r) => dnp3_association_restart(handle, 0, p, r)) as int);

  /// COLD_RESTART; returns the restart delay reported by the outstation
  Future<Duration> coldRestart() async =>
      Duration(milliseconds: await _rt.call((p, r) => dnp3_association_restart(handle, 1, p, r)) as int);

  /// Sets the outstation's clock from this association's [TimeSource]: LAN (RECORD_CURRENT_TIME
  /// then WRITE g50v3), non-LAN (DELAY_MEASURE then WRITE g50v1) or a direct WRITE of g50v1.
  ///
  /// Throws [TimeSyncException], or [TaskException] if the request fails.
  Future<void> synchronizeTime([TimeSyncProcedure procedure = TimeSyncProcedure.lan]) =>
      _rt.call((p, r) => dnp3_association_synchronize_time(handle, procedure.index, p, r));

  /// Offset applied to the system clock when synchronizing outstations
  void setTimeOffset(Duration offset) => setTimeSource(TimeSource.system(offset));

  /// Clock used for time synchronization (automatic and [synchronizeTime])
  void setTimeSource(TimeSource source) =>
      check(dnp3_association_set_time_source(handle, source._mode, source._value));

  /// Flow control (`maxInFlightFragments` > 0): mark `count` fragments as processed.
  /// Called automatically after the synchronous listeners unless `manualAck` was set.
  /// Returns the number of fragments still unacknowledged.
  int acknowledge([int count = 1]) => check(dnp3_association_ack(handle, count));

  /// WRITEs analog input dead bands (group 34). Throws [WriteException] if the outstation
  /// sets an IIN2 error bit, [TaskException] if the request fails.
  Future<void> writeDeadBands(List<DeadBandHeader> headers) {
    final req = DeadBandHeader.encodeAll(headers);
    return _rt.call((p, r) => dnp3_association_write_dead_bands(handle, req.address, req.length, p, r));
  }

  /// Sends a link-layer REQUEST_LINK_STATUS and completes when the outstation answers.
  /// Throws [TaskException] on failure.
  Future<void> checkLinkStatus() => _rt.call((p, r) => dnp3_association_check_link_status(handle, p, r));

  /// Periodically execute `request`. Results arrive on [measurements].
  Future<Poll> addPoll(ReadRequest request, Duration period) async {
    final req = request.toBytes();
    final id =
        await _rt.call(
              (p, r) =>
                  dnp3_association_add_poll(handle, req.address, req.length, period.inMilliseconds, p, r),
            )
            as int;
    return Poll._(id, _rt);
  }

  // ------------------------------------------------------------------ files

  /// Sends AUTHENTICATE_FILE and returns the key to pass as `authKey` to [openFile].
  /// Throws [FileException] or [TaskException].
  Future<int> getFileAuthKey(String user, String password) async {
    final u = utf8Bytes(user);
    final pw = utf8Bytes(password);
    return await _rt.call(
          (p, r) =>
              dnp3_association_get_file_auth_key(handle, u.address, u.length, pw.address, pw.length, p, r),
        )
        as int;
  }

  /// Sends OPEN_FILE. `fileSize` and `permissions` apply when creating a file; out-of-range
  /// arguments throw [RangeError]. Throws [FileException] or [TaskException].
  Future<OpenFile> openFile(
    String name, {
    int authKey = 0,
    FilePermissions permissions = FilePermissions.none,
    int fileSize = 0,
    FileMode mode = FileMode.read,
    int maxBlockSize = 1024,
  }) async {
    RangeError.checkValueInInterval(authKey, 0, 0xFFFFFFFF, 'authKey');
    RangeError.checkValueInInterval(fileSize, 0, 0xFFFFFFFF, 'fileSize');
    RangeError.checkValueInInterval(maxBlockSize, 0, 0xFFFF, 'maxBlockSize');
    final n = utf8Bytes(name);
    final data =
        await _rt.call(
              (p, r) => dnp3_association_open_file(
                handle,
                n.address,
                n.length,
                authKey,
                permissions.bits,
                fileSize,
                mode.index,
                maxBlockSize,
                p,
                r,
              ),
            )
            as Uint8List;
    final d = ByteData.sublistView(data);
    return OpenFile(
      d.getUint32(0, Endian.little),
      d.getUint32(4, Endian.little),
      d.getUint16(8, Endian.little),
    );
  }

  /// Write one block. `blockNumber` starts at 0; set `last` on the final block.
  Future<void> writeFileBlock(int fileHandle, int blockNumber, Uint8List data, {bool last = false}) {
    RangeError.checkValueInInterval(blockNumber, 0, 0x7FFFFFFF, 'blockNumber');
    final block = blockNumber | (last ? 0x80000000 : 0);
    return _rt.call(
      (p, r) => dnp3_association_write_file_block(handle, fileHandle, block, data.address, data.length, p, r),
    );
  }

  /// Convenience: open, write all blocks, close
  Future<void> writeFile(
    String name,
    Uint8List content, {
    int authKey = 0,
    FilePermissions permissions = FilePermissions.all,
    bool append = false,
    int maxBlockSize = 1024,
  }) async {
    final file = await openFile(
      name,
      authKey: authKey,
      permissions: permissions,
      fileSize: content.length,
      mode: append ? FileMode.append : FileMode.write,
      maxBlockSize: maxBlockSize,
    );
    final size = file.maxBlockSize > 0 ? file.maxBlockSize : maxBlockSize;
    var block = 0;
    for (var o = 0; o < content.length || block == 0; o += size) {
      final end = (o + size).clamp(0, content.length);
      final last = end >= content.length;
      await writeFileBlock(file.handle, block++, Uint8List.sublistView(content, o, end), last: last);
      if (last) break;
    }
    await closeFile(file.handle);
  }

  /// Sends CLOSE_FILE for a handle returned by [openFile].
  Future<void> closeFile(int fileHandle) =>
      _rt.call((p, r) => dnp3_association_close_file(handle, fileHandle, p, r));

  /// Sends GET_FILE_INFO for `path`. Throws [FileException] or [TaskException].
  Future<FileInfo> getFileInfo(String path) async {
    final s = utf8Bytes(path);
    final data =
        await _rt.call((p, r) => dnp3_association_get_file_info(handle, s.address, s.length, p, r))
            as Uint8List;
    return FileInfo.decode(ByteData.sublistView(data), 0).$1;
  }

  /// Reads the entries of directory `path` (OPEN_FILE, READ, CLOSE_FILE); `maxSize` bounds
  /// the bytes read. Credentials are sent only when both `user` and `password` are given.
  /// Throws [FileException] or [TaskException].
  Future<List<FileInfo>> readDirectory(
    String path, {
    int maxBlockSize = 0xFFFF,
    int maxSize = 2048,
    String? user,
    String? password,
  }) async {
    final s = utf8Bytes(path);
    final u = utf8Bytes(user ?? '');
    final pw = utf8Bytes(password ?? '');
    final creds = user != null && password != null ? 1 : 0;
    final data =
        await _rt.call(
              (p, r) => dnp3_association_read_directory(
                handle,
                s.address,
                s.length,
                maxBlockSize,
                maxSize,
                creds,
                u.address,
                u.length,
                pw.address,
                pw.length,
                p,
                r,
              ),
            )
            as Uint8List;
    final d = ByteData.sublistView(data);
    final n = d.getUint32(0, Endian.little);
    var o = 4;
    return [
      for (var i = 0; i < n; i++)
        () {
          final (info, used) = FileInfo.decode(d, o);
          o += used;
          return info;
        }(),
    ];
  }

  /// Read a file from the outstation, streaming its blocks
  FileReadTransfer readFile(
    String path, {
    int maxBlockSize = 0xFFFF,
    int maxSize = 0x7FFFFFFF,
    String? user,
    String? password,
    FutureOr<bool> Function(int size)? onOpened,
    Duration openTimeout = const Duration(seconds: 2),
  }) {
    final s = utf8Bytes(path);
    final u = utf8Bytes(user ?? '');
    final pw = utf8Bytes(password ?? '');
    final creds = user != null && password != null ? 1 : 0;
    final id = check(
      dnp3_association_read_file(
        handle,
        s.address,
        s.length,
        maxBlockSize,
        maxSize,
        creds,
        u.address,
        u.length,
        pw.address,
        pw.length,
        onOpened == null ? 0 : openTimeout.inMilliseconds,
        _rt.port,
      ),
    );
    return FileReadTransfer._(id, _rt, onOpened);
  }

  /// Remove the association from its channel
  Future<void> remove() async {
    _release();
    _channel?._associations.remove(this);
    await _rt.call((p, r) => dnp3_association_remove(handle, p, r));
  }
}

const _g20v0 = Variation.group20Var0;
const _g60v2 = Variation.group60Var2;
const _g60v3 = Variation.group60Var3;
const _g60v4 = Variation.group60Var4;

/// A periodic poll
final class Poll {
  /// Opaque native handle; can be sent to another isolate and re-attached with [attach]
  final int handle;
  final NativeRuntime _rt;
  Poll._(this.handle, this._rt);

  /// Uses a poll created in another isolate.
  factory Poll.attach(int handle) => Poll._(handle, NativeRuntime.current);

  /// Execute the poll now
  Future<void> demand() => _rt.call((p, r) => dnp3_poll_demand(handle, p, r));

  /// Removes the poll from its association; the handle becomes invalid.
  Future<void> remove() => _rt.call((p, r) => dnp3_poll_remove(handle, p, r));
}

// ---------------------------------------------------------------------------------------
// worker isolates
// ---------------------------------------------------------------------------------------

/// Decode a raw association event received on a port given as `eventPort` to
/// [MasterChannel.addAssociation]. Returns a [MeasurementFragment], an [AssociationEvent]
/// or null.
Object? decodeAssociationMessage(Object? message) {
  final m = message as List<Object?>;
  return switch (m[0]) {
    Msg.measurements => MeasurementFragment(m[3] as Uint8List),
    Msg.associationInfo => AssociationEvent.decode(m[2] as int, m[3] as int),
    _ => null,
  };
}

/// A dedicated isolate that receives measurement fragments directly from native code.
///
/// The fragments never touch the isolate that created the association, so heavy
/// processing does not block the UI isolate in Flutter apps.
///
/// ```dart
/// void onFragment(MeasurementFragment f) { ... } // top-level or static
/// final worker = await MeasurementWorker.spawn(onFragment);
/// final assoc = await channel.addAssociation(10, eventPort: worker.port);
/// ```
final class MeasurementWorker {
  /// The worker isolate
  final Isolate isolate;

  /// Pass this as `eventPort` to [MasterChannel.addAssociation]
  final SendPort port;

  MeasurementWorker._(this.isolate, this.port);

  /// Spawns the worker. `onFragment` and `onEvent` run in the worker isolate (use top-level
  /// or static functions); each fragment is acknowledged for flow control after `onFragment`.
  static Future<MeasurementWorker> spawn(
    void Function(MeasurementFragment fragment) onFragment, {
    void Function(AssociationEvent event)? onEvent,
    String debugName = 'dnp3-measurements',
  }) async {
    final ready = ReceivePort();
    try {
      final isolate = await Isolate.spawn(_workerMain, (
        ready.sendPort,
        onFragment,
        onEvent,
      ), debugName: debugName);
      final port = await ready.first as SendPort;
      return MeasurementWorker._(isolate, port);
    } finally {
      ready.close();
    }
  }

  static void _workerMain(
    (SendPort, void Function(MeasurementFragment), void Function(AssociationEvent)?) args,
  ) {
    final (ready, onFragment, onEvent) = args;
    final rx = RawReceivePort();
    rx.handler = (Object? message) {
      if (message == null) {
        rx.close();
        return;
      }
      final decoded = decodeAssociationMessage(message);
      if (decoded is MeasurementFragment) {
        try {
          onFragment(decoded);
        } finally {
          // flow control: acknowledge in the worker (no-op without `maxInFlightFragments`),
          // also when the handler throws, so the master is never left waiting
          dnp3_association_ack((message as List)[1] as int, 1);
        }
      } else if (decoded is AssociationEvent) {
        onEvent?.call(decoded);
      }
    };
    ready.send(rx.sendPort);
  }

  /// Stop the worker
  void close() {
    port.send(null);
  }
}

/// Clock used by an association to synchronize the outstation's time
final class TimeSource {
  final int _mode;
  final int _value;
  const TimeSource._(this._mode, this._value);

  /// System clock shifted by `offset`
  TimeSource.system([Duration offset = Duration.zero]) : this._(0, offset.inMilliseconds);

  /// No valid time: synchronization fails with [TimeSyncError.systemTimeNotAvailable]
  const TimeSource.unavailable() : this._(1, 0);

  /// Externally provided time (GPS, NTP client, ...). It keeps running on the monotonic
  /// clock until replaced, so it only needs to be refreshed occasionally.
  TimeSource.manual(Dnp3Time now) : this._(2, now.millis);
}
