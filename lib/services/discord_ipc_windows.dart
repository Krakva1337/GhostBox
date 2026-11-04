import 'dart:async';
import 'dart:collection';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'discord_ipc_transport.dart';

/// Connects without loading Windows DLLs on other desktop platforms.
Future<DiscordIpcTransport> connectWindowsDiscordIpc() async {
  if (!Platform.isWindows) {
    throw UnsupportedError('Windows Discord IPC requires Windows');
  }
  final transport = _WindowsDiscordIpc();
  await transport.connect();
  return transport;
}

/// All native pipe calls run off the Flutter isolate. PIPE_NOWAIT also keeps
/// the worker responsive to close commands when Discord stops consuming data.
class _WindowsDiscordIpc implements DiscordIpcTransport {
  final _messages = ReceivePort();
  final _input = StreamController<List<int>>();
  final _ready = Completer<void>();
  final _stopped = Completer<void>();
  Isolate? _worker;
  SendPort? _commands;
  bool _closed = false;

  @override
  Stream<List<int>> get input => _input.stream;

  Future<void> connect() async {
    void reportError(Object error, [StackTrace? stackTrace]) {
      if (!_ready.isCompleted) {
        _ready.completeError(error, stackTrace);
      } else if (!_closed) {
        _input.addError(error, stackTrace);
      }
    }

    _messages.listen((message) {
      if (message is SendPort) {
        _commands = message;
        if (!_ready.isCompleted) _ready.complete();
      } else if (message is Uint8List) {
        if (!_closed) _input.add(message);
      } else if (message is String) {
        reportError(_DiscordPipeException(message));
      } else if (message is List && message.length == 2) {
        // Isolate.onError sends [error text, stack trace text].
        reportError(
          _DiscordPipeException('${message[0]}'),
          StackTrace.fromString('${message[1]}'),
        );
      } else if (message == null) {
        if (!_ready.isCompleted) {
          _ready.completeError(StateError('Discord IPC worker stopped'));
        }
        if (!_stopped.isCompleted) _stopped.complete();
        unawaited(close());
      }
    });
    try {
      // Future.wait attaches the READY error handler before yielding to the
      // worker, including when its native initialization fails immediately.
      await Future.wait<void>([
        _ready.future.timeout(const Duration(seconds: 5)),
        Isolate.spawn(
          _pipeWorker,
          _messages.sendPort,
          onExit: _messages.sendPort,
          onError: _messages.sendPort,
          errorsAreFatal: true,
        ).then((worker) {
          _worker = worker;
          if (_closed) worker.kill(priority: Isolate.immediate);
        }),
      ], eagerError: true);
    } on Object {
      await close();
      rethrow;
    }
  }

  @override
  void add(List<int> bytes) {
    if (_closed || _commands == null) {
      throw StateError('Discord IPC pipe is closed');
    }
    if (bytes.length > _maxQueuedBytes) {
      throw ArgumentError('Discord IPC write exceeds buffer limit');
    }
    _commands!.send(Uint8List.fromList(bytes));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _commands?.send(null);
    if (_worker != null && !_stopped.isCompleted) {
      try {
        await _stopped.future.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        _worker?.kill(priority: Isolate.immediate);
      }
    }
    _messages.close();
    // Do not await: a paused/unlistened stream must not prevent IPC shutdown.
    unawaited(_input.close());
  }
}

class _DiscordPipeException implements IOException {
  const _DiscordPipeException(this.message);
  final String message;

  @override
  String toString() => 'Discord IPC: $message';
}

const _maxQueuedBytes = 1024 * 1024;
const _bufferSize = 64 * 1024;

void _pipeWorker(SendPort output) {
  final commands = ReceivePort();
  Timer? poll;
  _Kernel32? kernel;
  var handle = -1;
  Pointer<Uint8>? buffer;
  Pointer<Uint32>? count;
  var closed = false;
  final writes = Queue<Uint8List>();
  var queuedBytes = 0;
  var writeOffset = 0;

  void close([Object? error]) {
    if (closed) return;
    closed = true;
    poll?.cancel();
    commands.close();
    if (handle != -1) kernel!.closeHandle(handle);
    if (buffer != null) calloc.free(buffer);
    if (count != null) calloc.free(count);
    if (error != null) output.send(error.toString());
    output.send(null);
  }

  void pump() {
    if (closed) return;
    final api = kernel!;
    final data = buffer!;
    final transferred = count!;
    try {
      // Bound work per tick so commands (especially close) cannot starve.
      for (var reads = 0; reads < 4; reads++) {
        transferred.value = 0;
        final ok = api.readFile(
          handle,
          data,
          _bufferSize,
          transferred,
          nullptr,
        );
        if (ok == 0) {
          final code = api.getLastError();
          if (code == 232) break; // ERROR_NO_DATA: open, empty NOWAIT pipe.
          throw StateError('ReadFile failed ($code)');
        }
        final read = transferred.value;
        if (read == 0) break;
        output.send(Uint8List.fromList(data.asTypedList(read)));
      }
      for (var sent = 0; sent < 4 && writes.isNotEmpty; sent++) {
        final pending = writes.first;
        final remaining = pending.length - writeOffset;
        final length = remaining < _bufferSize ? remaining : _bufferSize;
        data.asTypedList(length).setRange(
              0,
              length,
              pending,
              writeOffset,
            );
        transferred.value = 0;
        final ok = api.writeFile(
          handle,
          data,
          length,
          transferred,
          nullptr,
        );
        if (ok == 0) {
          throw StateError('WriteFile failed (${api.getLastError()})');
        }
        final written = transferred.value;
        if (written == 0) break; // Discord's pipe buffer is temporarily full.
        queuedBytes -= written;
        writeOffset += written;
        if (writeOffset == pending.length) {
          writes.removeFirst();
          writeOffset = 0;
        }
      }
    } on Object catch (error) {
      close(error);
    }
  }

  try {
    kernel = _Kernel32();
    var lastError = 2;
    for (var index = 0; index < 10; index++) {
      final path = '\\\\?\\pipe\\discord-ipc-$index'.toNativeUtf16();
      try {
        handle = kernel.createFile(
          path,
          0xc0000000,
          0,
          nullptr,
          3,
          0,
          0,
        );
        if (handle != -1) break;
        lastError = kernel.getLastError();
      } finally {
        calloc.free(path);
      }
    }
    if (handle == -1) {
      throw StateError('Discord named pipe unavailable ($lastError)');
    }
    final mode = calloc<Uint32>()..value = 1; // byte mode | PIPE_NOWAIT
    try {
      if (kernel.setNamedPipeHandleState(handle, mode, nullptr, nullptr) == 0) {
        throw StateError('Cannot set pipe mode (${kernel.getLastError()})');
      }
    } finally {
      calloc.free(mode);
    }
    buffer = calloc<Uint8>(_bufferSize);
    count = calloc<Uint32>();
    commands.listen((message) {
      if (message == null) {
        close();
      } else if (message is Uint8List && message.isNotEmpty) {
        if (queuedBytes + message.length > _maxQueuedBytes) {
          close(StateError('Discord IPC write queue is full'));
          return;
        }
        writes.add(message);
        queuedBytes += message.length;
        pump();
      }
    });
    poll = Timer.periodic(const Duration(milliseconds: 25), (_) => pump());
    output.send(commands.sendPort);
  } on Object catch (error) {
    close(error);
  }
}

class _Kernel32 {
  _Kernel32() : _library = DynamicLibrary.open('kernel32.dll');
  final DynamicLibrary _library;

  late final createFile = _library.lookupFunction<
      IntPtr Function(Pointer<Utf16>, Uint32, Uint32, Pointer<Void>, Uint32,
          Uint32, IntPtr),
      int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int)>(
    'CreateFileW',
  );
  late final setNamedPipeHandleState = _library.lookupFunction<
      Int32 Function(IntPtr, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint32>),
      int Function(int, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint32>)>(
    'SetNamedPipeHandleState',
  );
  late final readFile = _library.lookupFunction<
      Int32 Function(
          IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Void>),
      int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>)>(
    'ReadFile',
  );
  late final writeFile = _library.lookupFunction<
      Int32 Function(
          IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Void>),
      int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>)>(
    'WriteFile',
  );
  late final closeHandle = _library
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
  late final getLastError = _library
      .lookupFunction<Uint32 Function(), int Function()>('GetLastError');
}
