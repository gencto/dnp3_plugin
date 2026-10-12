// Raw bindings to the native library built from `native/` (see hook/build.dart).
//
// Functions that never block and never call back into Dart are declared as leaf calls;
// leaf calls can receive `Uint8List.address` directly, which lets us hand Dart heap memory
// to native code without copying it.
//
// ignore_for_file: non_constant_identifier_names
@DefaultAsset('package:dnp3/src/native/bindings.dart')
library;

import 'dart:ffi';

// ---------------------------------------------------------------- library

@Native<Int64 Function()>(isLeaf: true)
external int dnp3_abi_version();

@Native<Pointer<Char> Function()>(isLeaf: true)
external Pointer<Char> dnp3_version();

@Native<Int64 Function(Pointer<Void>)>()
external int dnp3_init(Pointer<Void> postCObject);

@Native<Int64 Function(Uint32)>()
external int dnp3_runtime_start(int workerThreads);

@Native<Int64 Function(Uint64)>()
external int dnp3_runtime_shutdown(int timeoutMs);

@Native<Pointer<Char> Function()>(isLeaf: true)
external Pointer<Char> dnp3_last_error();

@Native<Int64 Function(Int64, Uint8, Uint8)>()
external int dnp3_logging_init(int port, int level, int withTarget);

@Native<Int64 Function(Uint8)>(isLeaf: true)
external int dnp3_logging_set_level(int level);

@Native<Int64 Function(Uint64)>(isLeaf: true)
external int dnp3_set_external_threshold(int bytes);

@Native<Int64 Function(Uint64, Int64, Pointer<Uint8>, Size)>(isLeaf: true)
external int dnp3_reply(int token, int status, Pointer<Uint8> data, int len);

@Native<Int64 Function(Uint8, Uint8)>(isLeaf: true)
external int dnp3_disable_tcp_no_delay(int client, int server);

@Native<Int64 Function(Uint8)>(isLeaf: true)
external int dnp3_debug_object_count(int kind);

@Native<Void Function(Pointer<Uint8>)>(isLeaf: true)
external void dnp3_buffer_free(Pointer<Uint8> ptr);

final Pointer<NativeFinalizerFunction> dnp3BufferFreePtr =
    Native.addressOf<NativeFunction<Void Function(Pointer<Uint8>)>>(dnp3_buffer_free).cast();

// ---------------------------------------------------------------- master

@Native<Int64 Function(Pointer<Uint8>, Size, Int64)>()
external int dnp3_master_create(Pointer<Uint8> json, int len, int events);

@Native<Int64 Function(Uint64)>()
external int dnp3_master_destroy(int id);

@Native<Int64 Function(Uint64, Uint8, Int64, Int64)>(isLeaf: true)
external int dnp3_master_enable(int id, int enable, int port, int request);

@Native<Int64 Function(Uint64, Pointer<Uint8>, Size, Int64, Int64)>(isLeaf: true)
external int dnp3_master_set_decode_level(int id, Pointer<Uint8> json, int len, int port, int request);

@Native<Int64 Function(Uint64, Int64, Int64)>(isLeaf: true)
external int dnp3_master_get_decode_level(int id, int port, int request);

@Native<Int64 Function(Uint64, Pointer<Uint8>, Size, Int64, Int64, Int64)>(isLeaf: true)
external int dnp3_master_add_association(
  int id,
  Pointer<Uint8> json,
  int len,
  int events,
  int port,
  int request,
);

@Native<Int64 Function(Uint64, Int64, Int64)>(isLeaf: true)
external int dnp3_association_remove(int id, int port, int request);

@Native<Int64 Function(Uint64, Int64)>(isLeaf: true)
external int dnp3_association_set_time_offset(int id, int offsetMs);

@Native<Int64 Function(Uint64, Pointer<Uint8>, Size, Int64, Int64)>(isLeaf: true)
external int dnp3_association_read(int id, Pointer<Uint8> req, int len, int port, int request);

@Native<Int64 Function(Uint64, Pointer<Uint8>, Size, Int64, Int64)>(isLeaf: true)
external int dnp3_association_read_with_handler(int id, Pointer<Uint8> req, int len, int port, int request);

@Native<Int64 Function(Uint64, Pointer<Uint8>, Size, Int64, Int64)>(isLeaf: true)
external int dnp3_association_operate(int id, Pointer<Uint8> req, int len, int port, int request);

@Native<Int64 Function(Uint64, Uint8, Pointer<Uint8>, Size, Int64, Int64)>(isLeaf: true)
external int dnp3_association_send_and_expect_empty_response(
  int id,
  int function,
  Pointer<Uint8> req,
  int len,
  int port,
  int request,
);

@Native<Int64 Function(Uint64, Uint8, Int64, Int64)>(isLeaf: true)
external int dnp3_association_restart(int id, int cold, int port, int request);

@Native<Int64 Function(Uint64, Uint8, Int64, Int64)>(isLeaf: true)
external int dnp3_association_synchronize_time(int id, int procedure, int port, int request);

@Native<Int64 Function(Uint64, Pointer<Uint8>, Size, Int64, Int64)>(isLeaf: true)
external int dnp3_association_write_dead_bands(int id, Pointer<Uint8> req, int len, int port, int request);

@Native<Int64 Function(Uint64, Int64, Int64)>(isLeaf: true)
external int dnp3_association_check_link_status(int id, int port, int request);

@Native<Int64 Function(Uint64, Pointer<Uint8>, Size, Uint64, Int64, Int64)>(isLeaf: true)
external int dnp3_association_add_poll(
  int id,
  Pointer<Uint8> req,
  int len,
  int periodMs,
  int port,
  int request,
);

@Native<Int64 Function(Uint64, Int64, Int64)>(isLeaf: true)
external int dnp3_poll_demand(int id, int port, int request);

@Native<Int64 Function(Uint64, Int64, Int64)>(isLeaf: true)
external int dnp3_poll_remove(int id, int port, int request);

@Native<Int64 Function(Uint64, Pointer<Uint8>, Size, Pointer<Uint8>, Size, Int64, Int64)>(isLeaf: true)
external int dnp3_association_get_file_auth_key(
  int id,
  Pointer<Uint8> user,
  int userLen,
  Pointer<Uint8> password,
  int passwordLen,
  int port,
  int request,
);

@Native<Int64 Function(Uint64, Pointer<Uint8>, Size, Uint32, Uint16, Uint32, Uint16, Uint16, Int64, Int64)>(
  isLeaf: true,
)
external int dnp3_association_open_file(
  int id,
  Pointer<Uint8> name,
  int nameLen,
  int authKey,
  int permissions,
  int fileSize,
  int mode,
  int maxBlockSize,
  int port,
  int request,
);

@Native<Int64 Function(Uint64, Uint32, Uint32, Pointer<Uint8>, Size, Int64, Int64)>(isLeaf: true)
external int dnp3_association_write_file_block(
  int id,
  int handle,
  int block,
  Pointer<Uint8> data,
  int len,
  int port,
  int request,
);

@Native<Int64 Function(Uint64, Uint32, Int64, Int64)>(isLeaf: true)
external int dnp3_association_close_file(int id, int handle, int port, int request);

@Native<Int64 Function(Uint64, Pointer<Uint8>, Size, Int64, Int64)>(isLeaf: true)
external int dnp3_association_get_file_info(int id, Pointer<Uint8> path, int len, int port, int request);

@Native<
  Int64 Function(
    Uint64,
    Pointer<Uint8>,
    Size,
    Uint16,
    Uint64,
    Uint8,
    Pointer<Uint8>,
    Size,
    Pointer<Uint8>,
    Size,
    Int64,
    Int64,
  )
>(isLeaf: true)
external int dnp3_association_read_directory(
  int id,
  Pointer<Uint8> path,
  int pathLen,
  int maxBlockSize,
  int maxFileSize,
  int hasCredentials,
  Pointer<Uint8> user,
  int userLen,
  Pointer<Uint8> password,
  int passwordLen,
  int port,
  int request,
);

@Native<
  Int64 Function(
    Uint64,
    Pointer<Uint8>,
    Size,
    Uint16,
    Uint64,
    Uint8,
    Pointer<Uint8>,
    Size,
    Pointer<Uint8>,
    Size,
    Int64,
  )
>(isLeaf: true)
external int dnp3_association_read_file(
  int id,
  Pointer<Uint8> path,
  int pathLen,
  int maxBlockSize,
  int maxFileSize,
  int hasCredentials,
  Pointer<Uint8> user,
  int userLen,
  Pointer<Uint8> password,
  int passwordLen,
  int events,
);

@Native<Int64 Function(Uint64)>(isLeaf: true)
external int dnp3_file_read_abort(int id);

@Native<Int64 Function(Pointer<Uint8>, Size, Int64, Int64, Int64)>()
external int dnp3_master_server_create(Pointer<Uint8> json, int len, int events, int port, int request);

@Native<Int64 Function(Uint64)>()
external int dnp3_master_server_destroy(int id);

// ---------------------------------------------------------------- outstation

@Native<Int64 Function(Pointer<Uint8>, Size, Int64)>()
external int dnp3_outstation_create(Pointer<Uint8> json, int len, int events);

@Native<Int64 Function(Uint64)>()
external int dnp3_outstation_destroy(int id);

@Native<Int64 Function(Uint64, Uint8, Int64, Int64)>(isLeaf: true)
external int dnp3_outstation_enable(int id, int enable, int port, int request);

@Native<Int64 Function(Uint64, Pointer<Uint8>, Size, Int64, Int64)>(isLeaf: true)
external int dnp3_outstation_set_decode_level(int id, Pointer<Uint8> json, int len, int port, int request);

@Native<Int64 Function(Uint64, Uint8)>(isLeaf: true)
external int dnp3_outstation_set_application_iin(int id, int bits);

@Native<Int64 Function(Uint64, Uint16)>(isLeaf: true)
external int dnp3_outstation_set_processing_delay(int id, int ms);

@Native<Int64 Function(Uint64, Pointer<Uint8>, Size, Pointer<Uint8>, Size)>(isLeaf: true)
external int dnp3_outstation_transaction(int id, Pointer<Uint8> ops, int len, Pointer<Uint8> out, int outLen);

@Native<Int64 Function(Uint64, Uint8, Uint16, Pointer<Uint8>, Size)>(isLeaf: true)
external int dnp3_outstation_get(int id, int pointType, int index, Pointer<Uint8> out, int cap);

@Native<Pointer<Uint8> Function(Uint64, Uint8, Uint16, Uint16, Pointer<Size>)>(isLeaf: true)
external Pointer<Uint8> dnp3_outstation_get_range(
  int id,
  int pointType,
  int start,
  int stop,
  Pointer<Size> outLen,
);

@Native<Int64 Function(Pointer<Uint8>, Size)>()
external int dnp3_outstation_server_create(Pointer<Uint8> json, int len);

@Native<Int64 Function(Uint64, Pointer<Uint8>, Size, Int64)>()
external int dnp3_outstation_server_add_outstation(int id, Pointer<Uint8> json, int len, int events);

@Native<Int64 Function(Uint64, Int64, Int64)>(isLeaf: true)
external int dnp3_outstation_server_bind(int id, int port, int request);

@Native<Int64 Function(Uint64)>()
external int dnp3_outstation_server_destroy(int id);

// ---------------------------------------------------------------- benchmarks

@Native<Int64 Function(Int64, Uint32, Uint32, Int64)>()
external int dnp3_bench_emit(int port, int fragments, int points, int request);
