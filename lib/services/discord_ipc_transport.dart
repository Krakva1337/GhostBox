import 'dart:io';

import 'discord_ipc_unix.dart';
import 'discord_ipc_windows.dart';

/// A duplex byte stream. Discord framing belongs to the protocol layer.
abstract interface class DiscordIpcTransport {
  Stream<List<int>> get input;
  void add(List<int> bytes);
  Future<void> close();
}

Future<DiscordIpcTransport> connectDiscordIpc() {
  if (Platform.isWindows) return connectWindowsDiscordIpc();
  if (Platform.isLinux || Platform.isMacOS) return connectUnixDiscordIpc();
  throw UnsupportedError('Discord IPC requires Windows, Linux or macOS');
}
