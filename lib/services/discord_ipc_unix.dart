import 'dart:async';
import 'dart:io';

import 'discord_ipc_transport.dart';

/// Opens Discord's local IPC endpoint on Linux or macOS.
Future<DiscordIpcTransport> connectUnixDiscordIpc() async {
  if (!Platform.isLinux && !Platform.isMacOS) {
    throw UnsupportedError('Unix Discord IPC requires Linux or macOS');
  }

  final elapsed = Stopwatch()..start();
  const budget = Duration(seconds: 5);
  const attemptTimeout = Duration(milliseconds: 350);
  Object? lastError;
  for (final directory in _socketDirectories()) {
    for (var index = 0; index < 10; index++) {
      final remaining = budget - elapsed.elapsed;
      if (remaining <= Duration.zero) {
        throw SocketException('Discord IPC connection timed out: $lastError');
      }
      try {
        final socket = await Socket.connect(
          InternetAddress('$directory/discord-ipc-$index',
              type: InternetAddressType.unix),
          0,
          timeout: remaining < attemptTimeout ? remaining : attemptTimeout,
        );
        return _UnixDiscordIpcTransport(socket);
      } on SocketException catch (error) {
        lastError = error;
      } on FileSystemException catch (error) {
        lastError = error;
      }
    }
  }
  throw SocketException('Discord IPC is unavailable: $lastError');
}

Iterable<String> _socketDirectories() sync* {
  final environment = Platform.environment;
  // Keep every environment candidate: macOS's TMPDIR must still be tried
  // when another runtime directory is defined.
  final roots = <String>{
    for (final key in ['XDG_RUNTIME_DIR', 'TMPDIR', 'TMP', 'TEMP'])
      if (environment[key]?.isNotEmpty == true) environment[key]!,
    '/tmp',
  };
  final directories = <String>{};
  for (final root in roots) {
    final base = root.endsWith('/') ? root.substring(0, root.length - 1) : root;
    if (Platform.isLinux) {
      // Flatpak exposes IPC in application-specific runtime directories;
      // Snap uses its own runtime subdirectory. Try these before the root
      // to retain preference for the currently installed Flatpak endpoint.
      directories.addAll([
        '$base/app/com.discordapp.Discord',
        '$base/app/dev.vencord.Vesktop',
        '$base/snap.discord',
        '$base/snap.discord-canary',
        '$base/snap.discord-ptb',
      ]);
    }
    directories.add(base);
  }
  yield* directories;
}

class _UnixDiscordIpcTransport implements DiscordIpcTransport {
  _UnixDiscordIpcTransport(this._socket) {
    // Sink errors are also exposed through the input stream, which the RPC
    // session consumes. Observe done separately so it cannot go unhandled.
    unawaited(
        _socket.done.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
  }

  final Socket _socket;
  bool _closed = false;

  @override
  Stream<List<int>> get input => _socket;

  @override
  void add(List<int> bytes) {
    if (_closed) throw StateError('Discord IPC transport is closed');
    _socket.add(bytes);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _socket.destroy();
  }
}
