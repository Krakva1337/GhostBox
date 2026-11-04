import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'discord_ipc_transport.dart';

/// An activity was rejected by Discord while the IPC connection remains usable.
class DiscordRpcException implements Exception {
  const DiscordRpcException({required this.message, this.code});

  final int? code;
  final String message;

  @override
  String toString() =>
      'Discord RPC error${code == null ? '' : ' $code'}: $message';
}

/// One Discord IPC session, including framing, handshake and command responses.
class DiscordRpcConnection {
  DiscordRpcConnection._(this._transport);

  static const _maxPayload = 64 * 1024;
  static const _maxPending = 32;
  final DiscordIpcTransport _transport;
  final _ready = Completer<void>();
  final _pending = <String, Completer<Map<String, dynamic>?>>{};
  // Only one partial frame is retained, even when an input chunk has many frames.
  final _buffer = Uint8List(8 + _maxPayload);
  StreamSubscription<List<int>>? _subscription;
  Future<void>? _closeFuture;
  bool _closed = false;
  bool _handshakeComplete = false;
  int _buffered = 0;
  int _frameLength = 8;
  int _nonce = 0;

  bool get closed => _closed;

  static Future<DiscordRpcConnection> connect(String clientId) async {
    final id = clientId.trim();
    if (id.isEmpty) throw ArgumentError.value(clientId, 'clientId', 'is empty');
    final connection = DiscordRpcConnection._(await connectDiscordIpc());
    // Install the error listener before listening or writing: either operation
    // can fail synchronously, before the caller gets control back.
    final ready = connection._ready.future.timeout(const Duration(seconds: 5));
    unawaited(ready.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    try {
      connection._subscription = connection._transport.input.listen(
        connection._onData,
        onError: (Object error, StackTrace stack) {
          unawaited(connection._shutdown(error, stack));
        },
        onDone: () {
          unawaited(
              connection._shutdown(StateError('Discord IPC disconnected')));
        },
        cancelOnError: true,
      );
      try {
        connection._sendJson(0, {'v': 1, 'client_id': id});
      } on Object catch (error, stack) {
        unawaited(connection._shutdown(error, stack));
      }
      await ready;
      if (connection.closed) throw StateError('Discord IPC disconnected');
      return connection;
    } on Object catch (error, stack) {
      await connection._shutdown(error, stack);
      rethrow;
    }
  }

  Future<Map<String, dynamic>?> setActivity(
    Map<String, Object?>? activity,
  ) async {
    if (_closed) throw StateError('Discord IPC connection is closed');
    if (!_handshakeComplete) throw StateError('Discord IPC is not ready');
    if (_pending.length >= _maxPending) {
      throw StateError('Too many pending Discord RPC commands');
    }
    final nonce = '${pid}_${++_nonce}';
    final response = Completer<Map<String, dynamic>?>();
    final result = response.future.timeout(const Duration(seconds: 8));
    _pending[nonce] = response;
    try {
      try {
        _sendJson(1, {
          'cmd': 'SET_ACTIVITY',
          'args': {'pid': pid, 'activity': activity},
          'nonce': nonce,
        });
      } on Object catch (error, stack) {
        unawaited(_shutdown(error, stack));
      }
      return await result;
    } on TimeoutException catch (error, stack) {
      // A lost acknowledgement leaves the remote state unknown. A fresh
      // session is required before publishing the latest activity again.
      await _shutdown(error, stack);
      rethrow;
    } finally {
      _pending.remove(nonce);
    }
  }

  void _sendJson(int opcode, Map<String, Object?> value) {
    _sendFrame(opcode, utf8.encode(jsonEncode(value)));
  }

  void _sendFrame(int opcode, List<int> payload) {
    if (_closed) throw StateError('Discord IPC connection is closed');
    if (payload.length > _maxPayload) {
      throw const FormatException('Discord RPC payload exceeds 64 KiB');
    }
    final frame = Uint8List(8 + payload.length);
    final header = ByteData.sublistView(frame, 0, 8)
      ..setUint32(0, opcode, Endian.little)
      ..setUint32(4, payload.length, Endian.little);
    frame.setRange(header.lengthInBytes, frame.length, payload);
    _transport.add(frame);
  }

  void _onData(List<int> bytes) {
    if (_closed) return;
    try {
      var offset = 0;
      while (offset < bytes.length && !_closed) {
        final count = math.min(_frameLength - _buffered, bytes.length - offset);
        _buffer.setRange(_buffered, _buffered + count, bytes, offset);
        _buffered += count;
        offset += count;
        if (_buffered < _frameLength) continue;
        final header = ByteData.sublistView(_buffer, 0, 8);
        final opcode = header.getUint32(0, Endian.little);
        final payloadLength = header.getUint32(4, Endian.little);
        if (payloadLength > _maxPayload) {
          throw const FormatException('Discord RPC frame exceeds 64 KiB');
        }
        if (opcode == 2) {
          unawaited(_shutdown(StateError('Discord closed the IPC session')));
          return;
        }
        if (_frameLength == 8 && payloadLength != 0) {
          _frameLength = 8 + payloadLength;
          continue;
        }
        _handleFrame(opcode, Uint8List.sublistView(_buffer, 8, _frameLength));
        _buffered = 0;
        _frameLength = 8;
      }
    } on Object catch (error, stack) {
      unawaited(_shutdown(error, stack));
    }
  }

  void _handleFrame(int opcode, Uint8List payload) {
    if (opcode == 3) {
      _sendFrame(4, payload); // PING data is opaque; it need not contain JSON.
      return;
    }
    if (opcode == 4) return;
    if (opcode != 1) {
      throw FormatException('Unknown Discord IPC opcode $opcode');
    }
    final decoded = jsonDecode(utf8.decode(payload));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Discord RPC response is not an object');
    }
    if (decoded['evt'] == 'READY') {
      if (!_handshakeComplete) {
        _handshakeComplete = true;
        _ready.complete();
      }
      return;
    }
    if (!_handshakeComplete && decoded['evt'] == 'ERROR') {
      throw StateError(
          'Discord rejected the IPC handshake: ${decoded['data']}');
    }
    final nonce = decoded['nonce'];
    // Unsolicited events and late replies to expired requests have no owner.
    final response = nonce is String ? _pending.remove(nonce) : null;
    if (response == null) return;
    final data = decoded['data'];
    if (decoded['evt'] == 'ERROR') {
      final code = data is Map ? data['code'] : null;
      final message = data is Map ? data['message'] : null;
      response.completeError(DiscordRpcException(
        code: code is num ? code.toInt() : int.tryParse('$code'),
        message: message is String ? message : 'Activity was rejected',
      ));
    } else if (decoded['cmd'] != 'SET_ACTIVITY') {
      const error = FormatException('Unexpected Discord RPC command response');
      response.completeError(error);
      throw error;
    } else if (data == null || data is Map<String, dynamic>) {
      response.complete(data as Map<String, dynamic>?);
    } else {
      const error =
          FormatException('Discord activity response is not an object');
      response.completeError(error);
      throw error;
    }
  }

  Future<void> close() =>
      _shutdown(StateError('Discord IPC connection closed'));

  Future<void> _shutdown(Object error, [StackTrace? stack]) {
    if (_closed) return _closeFuture ?? Future<void>.value();
    _closed = true;
    if (!_ready.isCompleted) _ready.completeError(error, stack);
    for (final response in _pending.values) {
      response.completeError(error, stack);
    }
    _pending.clear();
    _buffered = 0;
    return _closeFuture = _release();
  }

  Future<void> _release() async {
    // Cleanup is best effort after the original failure has been delivered.
    // Stream callbacks intentionally do not create unobserved error futures.
    try {
      await _subscription?.cancel();
    } on Object {
      // Still close the transport if cancelling its stream failed.
    }
    try {
      await _transport.close();
    } on Object {
      // The stream already told the caller why this connection failed.
    }
  }
}
