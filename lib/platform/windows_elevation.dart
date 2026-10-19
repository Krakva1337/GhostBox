import 'dart:io';

class WindowsElevation {
  static const _powerShell = 'powershell.exe';

  static Future<bool> isElevated() async {
    final result = await Process.run(
      _powerShell,
      const [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        r"([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)",
      ],
      runInShell: false,
    );
    return result.exitCode == 0 && result.stdout.toString().trim() == 'True';
  }

  /// Starts a second copy with the standard Windows UAC prompt. The caller
  /// persists any one-shot action before relaunching.
  static Future<void> relaunchElevated() async {
    final executable = Platform.resolvedExecutable;
    final escaped = executable.replaceAll("'", "''");
    final script = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}ghostbox-elevate-${pid}.ps1',
    );
    await script
        .writeAsString("Start-Process -FilePath '$escaped' -Verb RunAs\n");
    try {
      final result = await Process.run(
        _powerShell,
        [
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          script.path
        ],
        runInShell: false,
      );
      if (result.exitCode != 0) {
        throw ProcessException(
          _powerShell,
          ['-File', script.path],
          result.stderr.toString().trim(),
          result.exitCode,
        );
      }
    } finally {
      if (await script.exists()) await script.delete();
    }
  }
}
