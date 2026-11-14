import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'windows_elevation.dart';

/// Native supervision applies to GhostBox's bundled core processes. Windows
/// closes their Job Object after a UI crash, removing abandoned TUNs.
class WindowsCoreLifecycle {
  static const _channel = MethodChannel('app.ghostbox.ghostbox/core_lifecycle');

  static Future<ProcessResult> _runPowerShell(
    String script, {
    required Duration timeout,
  }) async {
    final process = await Process.start(
      'powershell.exe',
      [
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        script,
      ],
      runInShell: false,
    );
    final stdout =
        process.stdout.transform<String>(systemEncoding.decoder).join();
    final stderr =
        process.stderr.transform<String>(systemEncoding.decoder).join();
    try {
      final exitCode = await process.exitCode.timeout(timeout);
      return ProcessResult(process.pid, exitCode, await stdout, await stderr);
    } on TimeoutException {
      process.kill();
      await process.exitCode.timeout(
        const Duration(seconds: 2),
        onTimeout: () => -1,
      );
      await Future.wait([stdout, stderr]);
      throw StateError(
          'PowerShell did not finish within ${timeout.inSeconds} seconds.');
    }
  }

  static Future<void> trackCore({
    required int pid,
    required String executable,
  }) async {
    if (!Platform.isWindows) return;
    final tracked = await _channel.invokeMethod<bool>('trackCore', {
      'pid': pid,
      'executable': File(executable).absolute.path,
    });
    if (tracked != true) {
      throw StateError('Windows did not confirm VPN core supervision.');
    }
  }

  /// Stop matching bundled GhostBox Xray and sing-box processes after the
  /// app's own backends have disconnected and before any new core starts.
  static Future<int> cleanupStaleCores({
    required List<String> executables,
  }) async {
    if (!Platform.isWindows) return 0;
    return await _channel.invokeMethod<int>('cleanupStaleCores', {
          'executables':
              executables.map((path) => File(path).absolute.path).toList(),
        }) ??
        0;
  }

  /// Removes only GhostBox's `ghostbox0` Wintun adapter and waits until
  /// Windows no longer reports it. Call after stopping the previous core and
  /// before starting a new sing-box TUN instance.
  static Future<bool> cleanupGhostBoxTunAdapter() async {
    if (!Platform.isWindows) return false;

    // Get-NetAdapter can omit a half-removed/phantom device even though the
    // Wintun driver still reserves its adapter name. Recover those devices by
    // joining the PnP instance to Windows' network-connection registry entry;
    // only a Wintun device whose registered connection name is exactly
    // `ghostbox0` is considered GhostBox-owned.
    const discoveryScript = r'''
function Get-GhostBoxTunAdapters {
  $aliasName = 'ghostbox0'
  $networkClass = '{4D36E972-E325-11CE-BFC1-08002BE10318}'
  $devices = @{}

  foreach ($adapter in @(Get-NetAdapter -Name $aliasName -IncludeHidden -ErrorAction SilentlyContinue)) {
    if ($adapter.Name -ne $aliasName -or $adapter.InterfaceDescription -notmatch '(Wintun|^sing-tun Tunnel(?: #\d+)?$)') {
      throw "Интерфейс $aliasName найден, но не опознан как GhostBox Wintun; адаптер оставлен без изменений."
    }
    $instanceId = [string]$adapter.PnPDeviceID
    if ([string]::IsNullOrWhiteSpace($instanceId)) {
      throw "Не удалось безопасно определить PnP-устройство адаптера $aliasName."
    }
    $devices[$instanceId] = [pscustomobject]@{ InstanceId = $instanceId; Description = [string]$adapter.InterfaceDescription }
  }

  if ((Get-Command Get-PnpDevice -ErrorAction SilentlyContinue) -and
      (Get-Command Get-PnpDeviceProperty -ErrorAction SilentlyContinue)) {
    foreach ($device in @(Get-PnpDevice -Class Net -ErrorAction SilentlyContinue)) {
      $instanceId = [string]$device.InstanceId
      if ([string]::IsNullOrWhiteSpace($instanceId)) { continue }

      # DEVPKEY_NetCfgInstanceId is not exposed by every Windows/PnP provider.
      # The device's DEVPKEY_Device_Driver points at its class-driver registry
      # key, where NetCfgInstanceId is stored for network devices.
      $netCfgIds = @()
      $netCfgProperty = Get-PnpDeviceProperty -InstanceId $instanceId `
        -KeyName 'DEVPKEY_NetCfgInstanceId' -ErrorAction SilentlyContinue
      if ($null -ne $netCfgProperty -and $null -ne $netCfgProperty.Data) {
        try { $netCfgIds += ([Guid]$netCfgProperty.Data).ToString('B') }
        catch { }
      }

      # Always try the driver-key path too. Some providers omit the direct
      # network-config property, and stale devnodes can expose a stale value.
      $driverProperty = Get-PnpDeviceProperty -InstanceId $instanceId `
        -KeyName 'DEVPKEY_Device_Driver' -ErrorAction SilentlyContinue
      $driverSubkey = [string]$driverProperty.Data
      $driverInfo = $null
      $driverSubkey = $driverSubkey -replace `
        '^(?:SYSTEM\\CurrentControlSet\\Control\\Class\\|\\Registry\\Machine\\System\\CurrentControlSet\\Control\\Class\\)', ''
      if ($driverSubkey -match `
          '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}\\\d+$') {
        $driverKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$driverSubkey"
        $driverInfo = Get-ItemProperty -LiteralPath $driverKey `
          -ErrorAction SilentlyContinue
        if ($null -ne $driverInfo -and
            -not [string]::IsNullOrWhiteSpace([string]$driverInfo.NetCfgInstanceId)) {
          try { $netCfgIds += ([Guid]$driverInfo.NetCfgInstanceId).ToString('B') }
          catch { }
        }
      }

      $ownsGhostBoxAlias = $false
      foreach ($netCfgId in ($netCfgIds | Select-Object -Unique)) {
        $connectionKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Network\$networkClass\$netCfgId\Connection"
        $connection = Get-ItemProperty -LiteralPath $connectionKey -Name Name -ErrorAction SilentlyContinue
        if ([string]$connection.Name -eq $aliasName) {
          $ownsGhostBoxAlias = $true
          break
        }
      }
      if (-not $ownsGhostBoxAlias) { continue }
      $description = [string]$device.FriendlyName
      if ($description -notmatch '(Wintun|^sing-tun Tunnel(?: #\d+)?$)' -and $null -ne $driverInfo) {
        $description = [string]$driverInfo.DriverDesc
      }
      if ($description -notmatch '(Wintun|^sing-tun Tunnel(?: #\d+)?$)') {
        throw "Интерфейс $aliasName найден в PnP, но не опознан как Wintun; устройство оставлено без изменений."
      }
      $devices[$instanceId] = [pscustomobject]@{ InstanceId = $instanceId; Description = $description }
    }
  }

  return @($devices.Values)
}
''';
    const detectScript = '$discoveryScript\n'
        r'''
$ErrorActionPreference = 'Stop'
$adapters = @(Get-GhostBoxTunAdapters)
if ($adapters.Count -eq 0) { Write-Output 'ABSENT'; exit 0 }
Write-Output 'PRESENT'
''';
    final detection = await _runPowerShell(
      detectScript,
      timeout: const Duration(seconds: 8),
    );
    if (detection.exitCode != 0) {
      final detail = detection.stderr.toString().trim().isNotEmpty
          ? detection.stderr.toString().trim()
          : detection.stdout.toString().trim();
      throw StateError(
        'Не удалось проверить GhostBox TUN-адаптер ghostbox0.'
        '${detail.isEmpty ? '' : ' $detail'}',
      );
    }
    final detectionOutput = detection.stdout.toString();
    if (detectionOutput.contains('ABSENT')) return false;
    if (!detectionOutput.contains('PRESENT')) {
      throw StateError(
        'Windows не подтвердила состояние GhostBox TUN-адаптера ghostbox0.',
      );
    }

    if (!await WindowsElevation.isElevated()) {
      throw StateError(
        'Для очистки TUN-адаптера ghostbox0 нужны права администратора. '
        'Перезапустите GhostBox от имени администратора и повторите подключение.',
      );
    }

    const script = '$discoveryScript\n'
        r'''
$ErrorActionPreference = 'Stop'
$aliasName = 'ghostbox0'
$adapters = @(Get-GhostBoxTunAdapters)
if ($adapters.Count -eq 0) { Write-Output 'ABSENT'; exit 0 }

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class GhostBoxDeviceRemoval {
  [StructLayout(LayoutKind.Sequential)]
  public struct DeviceInfoData {
    public UInt32 Size;
    public Guid ClassGuid;
    public UInt32 DevInst;
    public IntPtr Reserved;
  }
  [DllImport("setupapi.dll", EntryPoint = "SetupDiCreateDeviceInfoList", ExactSpelling = true, SetLastError = true)]
  public static extern IntPtr SetupDiCreateDeviceInfoList(IntPtr classGuid, IntPtr hwndParent);
  [DllImport("setupapi.dll", EntryPoint = "SetupDiOpenDeviceInfoW", ExactSpelling = true, CharSet = CharSet.Unicode, SetLastError = true)]
  public static extern bool SetupDiOpenDeviceInfo(IntPtr set, string instanceId, IntPtr hwndParent, UInt32 flags, ref DeviceInfoData data);
  [DllImport("newdev.dll", EntryPoint = "DiUninstallDevice", ExactSpelling = true, SetLastError = true)]
  public static extern bool DiUninstallDevice(IntPtr hwndParent, IntPtr set, ref DeviceInfoData data, UInt32 flags, out bool needReboot);
  [DllImport("setupapi.dll", EntryPoint = "SetupDiDestroyDeviceInfoList", ExactSpelling = true, SetLastError = true)]
  public static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
}
'@

foreach ($adapter in $adapters) {
  $instanceId = [string]$adapter.InstanceId
  if ([string]::IsNullOrWhiteSpace($instanceId)) {
    throw "Не удалось безопасно определить PnP-устройство адаптера $aliasName."
  }
  $set = [GhostBoxDeviceRemoval]::SetupDiCreateDeviceInfoList([IntPtr]::Zero, [IntPtr]::Zero)
  if ($set -eq [IntPtr]::new(-1)) { throw "SetupAPI не создала список устройств ($([Runtime.InteropServices.Marshal]::GetLastWin32Error()))." }
  try {
    $device = New-Object -TypeName 'GhostBoxDeviceRemoval+DeviceInfoData'
    $device.Size = [Runtime.InteropServices.Marshal]::SizeOf($device)
    if (-not [GhostBoxDeviceRemoval]::SetupDiOpenDeviceInfo($set, $instanceId, [IntPtr]::Zero, 0, [ref]$device)) {
      throw "SetupAPI не открыла GhostBox-устройство $instanceId ($([Runtime.InteropServices.Marshal]::GetLastWin32Error()))."
    }
    $needReboot = $false
    if (-not [GhostBoxDeviceRemoval]::DiUninstallDevice([IntPtr]::Zero, $set, [ref]$device, 0, [ref]$needReboot)) {
      throw "Windows не удалила GhostBox Wintun $instanceId ($([Runtime.InteropServices.Marshal]::GetLastWin32Error()))."
    }
    if ($needReboot) { throw 'Windows требует перезагрузку для удаления GhostBox Wintun; новое подключение отменено.' }
  } finally {
    [void][GhostBoxDeviceRemoval]::SetupDiDestroyDeviceInfoList($set)
  }
}

$deadline = [DateTime]::UtcNow.AddSeconds(12)
do {
  $remaining = @(Get-GhostBoxTunAdapters)
  if ($remaining.Count -eq 0) { Write-Output 'REMOVED'; exit 0 }
  Start-Sleep -Milliseconds 250
} while ([DateTime]::UtcNow -lt $deadline)
throw "Windows не подтвердила удаление адаптера $aliasName за 12 секунд."
''';

    final result = await _runPowerShell(
      script,
      timeout: const Duration(seconds: 20),
    );
    if (result.exitCode != 0) {
      final detail = result.stderr.toString().trim().isNotEmpty
          ? result.stderr.toString().trim()
          : result.stdout.toString().trim();
      throw StateError(
        'Не удалось очистить GhostBox TUN-адаптер ghostbox0. '
        'Новое подключение остановлено.${detail.isEmpty ? '' : ' $detail'}',
      );
    }
    return result.stdout.toString().contains('REMOVED');
  }
}
