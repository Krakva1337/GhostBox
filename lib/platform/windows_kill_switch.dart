import 'dart:convert';
import 'dart:io';

/// Windows Firewall based fail-closed policy for TUN/Mixed connections.
///
/// The Windows runner requires administrator elevation. These methods must be
/// called only for a resolved literal server IP and while a TUN interface is
/// configured; system-proxy mode cannot provide a system-wide kill switch.
class WindowsKillSwitch {
  static const _scriptRelativePath = 'vendor/bin/windows_killswitch.ps1';

  static Future<Map<String, dynamic>> enable({
    required String endpointIp,
    required int port,
    String tunAlias = 'ghostbox0',
  }) =>
      _invoke('Enable', endpointIp: endpointIp, port: port, tunAlias: tunAlias);

  static Future<Map<String, dynamic>> disable() => _invoke('Disable');

  static Future<Map<String, dynamic>> status() => _invoke('Status');

  static Future<Map<String, dynamic>> _invoke(
    String action, {
    String? endpointIp,
    int? port,
    String? tunAlias,
  }) async {
    if (!Platform.isWindows) {
      throw UnsupportedError(
          'Windows Kill Switch is only available on Windows.');
    }
    final executableDirectory = File(Platform.resolvedExecutable).parent;
    final script = File(
      '${executableDirectory.path}${Platform.pathSeparator}$_scriptRelativePath',
    );
    if (!await script.exists()) {
      throw FileSystemException(
        'Windows Kill Switch helper is missing. Reinstall GhostBox from the full Windows package.',
        script.path,
      );
    }
    final arguments = <String>[
      '-NoLogo',
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      script.path,
      '-Action',
      action,
    ];
    if (endpointIp != null) arguments.addAll(['-EndpointIp', endpointIp]);
    if (port != null) arguments.addAll(['-Port', '$port']);
    if (tunAlias != null) arguments.addAll(['-TunAlias', tunAlias]);

    final result = await Process.run(
      'powershell.exe',
      arguments,
      runInShell: false,
      stdoutEncoding: const SystemEncoding(),
      stderrEncoding: const SystemEncoding(),
    ).timeout(const Duration(seconds: 30));
    if (result.exitCode != 0) {
      final details = '${result.stderr}'.trim();
      throw ProcessException(
        'powershell.exe',
        arguments,
        details.isEmpty ? 'Windows Firewall operation failed.' : details,
        result.exitCode,
      );
    }
    final output = '${result.stdout}'.trim();
    final decoded = jsonDecode(output);
    if (decoded is! Map) {
      throw const FormatException(
        'Windows Kill Switch helper returned an invalid status response.',
      );
    }
    final response = Map<String, dynamic>.from(decoded);
    if (action == 'Enable' && response['active'] != true) {
      throw const FormatException(
        'Windows Firewall did not confirm that the Kill Switch is active.',
      );
    }
    if (action == 'Disable' && response['configured'] == true) {
      throw const FormatException(
        'Windows Firewall did not confirm that the saved policy was restored.',
      );
    }
    return response;
  }
}
