[CmdletBinding()]
param(
  [ValidateSet('installer', 'portable')][string]$Mode,
  [string]$Package,
  [int]$OldPid = 0,
  [ValidatePattern('^[a-fA-F0-9-]{16,64}$')][string]$TransactionId,
  [Parameter(Mandatory = $true)][string]$InstallRoot,
  [string]$HandoffDir,
  [ValidatePattern('^[0-9a-fA-F]{64}$')][string]$ExpectedSha256,
  [switch]$Recover
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:oldProcessStartUtcTicks = $null

function Write-Transaction([string]$Status, [string]$ErrorText = '') {
  $record.status = $Status
  $record.updatedAt = [DateTime]::UtcNow.ToString('o')
  if ($ErrorText) { $record.error = $ErrorText }
  $tmp = "$transactionFile.tmp"
  $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tmp -Encoding UTF8
  Move-Item -LiteralPath $tmp -Destination $transactionFile -Force
}
function Assert-TrustedOldProcess {
  $proc = Get-Process -Id $OldPid -ErrorAction SilentlyContinue
  if (-not $proc) { return }
  $image = [IO.Path]::GetFullPath($proc.Path)
  $root = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\') + '\'
  if (-not $image.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or
      [IO.Path]::GetFileName($image) -ne 'GhostBox.exe') {
    throw "PID $OldPid is not GhostBox.exe under the requested installation directory."
  }
  $script:oldProcessStartUtcTicks = $proc.StartTime.ToUniversalTime().Ticks
}
function Wait-OldProcess {
  $proc = Get-Process -Id $OldPid -ErrorAction SilentlyContinue
  if ($proc) {
    $image = [IO.Path]::GetFullPath($proc.Path)
    $root = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\') + '\'
    if (-not $image.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($image) -ne 'GhostBox.exe') {
      throw "PID $OldPid is not GhostBox.exe under the requested installation directory."
    }
    if ($null -ne $script:oldProcessStartUtcTicks -and
        $proc.StartTime.ToUniversalTime().Ticks -ne $script:oldProcessStartUtcTicks) {
      throw 'The original GhostBox process exited and its PID was reused.'
    }
    if (-not $proc.WaitForExit(120000)) { throw 'GhostBox did not exit within two minutes.' }
  }
}
function Wait-ForConfirmation([int]$ExpectedPid, [int]$Seconds = 120) {
  $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
  while ([DateTime]::UtcNow -lt $deadline) {
    if (Test-Path -LiteralPath (Join-Path $HandoffDir 'failed')) { throw 'The new client reported a startup failure.' }
    $startedFile = Join-Path $transactionDir 'started'
    if ((Test-Path -LiteralPath $startedFile) -and (Test-Path -LiteralPath (Join-Path $transactionDir 'confirmed'))) {
      $startedPid = 0
      if ([int]::TryParse((Get-Content -LiteralPath $startedFile -Raw).Trim(), [ref]$startedPid) -and
          $startedPid -eq $ExpectedPid) { return $true }
      throw 'Startup acknowledgement PID does not match the launched application.'
    }
    Start-Sleep -Milliseconds 300
  }
  return $false
}

$install = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
$stateRoot = Join-Path $env:LOCALAPPDATA 'GhostBox\Updater'
if ($Recover) {
  New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
  if ($HandoffDir) {
    $candidateHandoff = [IO.Path]::GetFullPath($HandoffDir)
    if (-not $candidateHandoff.StartsWith(([IO.Path]::GetFullPath($stateRoot).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) {
      throw 'HandoffDir must be inside the per-user GhostBox updater directory.'
    }
  }
  $lock = $null
  try {
    $lock = [IO.File]::Open((Join-Path $stateRoot 'update.lock'), [IO.FileMode]::OpenOrCreate,
      [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $directories = @()
    if ($HandoffDir) { $directories += [IO.Path]::GetFullPath($HandoffDir) }
    $directories += @(Get-ChildItem -LiteralPath $stateRoot -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object FullName)
    $transactionsRoot = Join-Path $stateRoot 'transactions'
    $directories += @(Get-ChildItem -LiteralPath $transactionsRoot -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object FullName)
    foreach ($directory in ($directories | Select-Object -Unique)) {
      $transactionFile = Join-Path $directory 'update_transaction.json'
      if (-not (Test-Path -LiteralPath $transactionFile -PathType Leaf)) { continue }
      try { $transaction = Get-Content -LiteralPath $transactionFile -Raw | ConvertFrom-Json } catch { continue }
      if ([IO.Path]::GetFullPath([string]$transaction.oldPath).TrimEnd('\') -ne $install) { continue }
      $id = [string]$transaction.id
      if ($id -notmatch '^[a-fA-F0-9-]{16,64}$') { continue }
      $expectedBackup = "$install.ghostbox-backup-$id"
      $expectedStaging = "$install.ghostbox-staging-$id"
      if ($transaction.status -in @('COMMIT', 'CLEANUP')) {
        if ([IO.Path]::GetFullPath([string]$transaction.backupPath) -eq $expectedBackup -and
            (Test-Path -LiteralPath $expectedBackup -PathType Container)) {
          Remove-Item -LiteralPath $expectedBackup -Recurse -Force
        }
        continue
      }
      if ([IO.Path]::GetFullPath([string]$transaction.backupPath) -ne $expectedBackup) { continue }
      if (-not (Test-Path -LiteralPath $expectedBackup -PathType Container)) {
        if ($transaction.status -notin @('CHECKING', 'VERIFYING', 'STAGING', 'STOPPING')) { continue }
        if ($transaction.stagingPath -and
            [IO.Path]::GetFullPath([string]$transaction.stagingPath) -ne $expectedStaging) { continue }
        if (Test-Path -LiteralPath $expectedStaging) {
          if (-not (Test-Path -LiteralPath $expectedStaging -PathType Container)) { throw 'Unsafe incomplete staging path.' }
          Remove-Item -LiteralPath $expectedStaging -Recurse -Force
        }
        $transaction.status = 'RESTORE_OLD'
        $transaction.error = 'Update was interrupted before the old installation changed.'
        $transaction.updatedAt = [DateTime]::UtcNow.ToString('o')
        $tmp = "$transactionFile.tmp"
        $transaction | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tmp -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $transactionFile -Force
        $old = Join-Path $install 'GhostBox.exe'
        if (Test-Path -LiteralPath $old -PathType Leaf) { Start-Process -FilePath $old -ArgumentList @('--ghostbox-update-recovered') }
        break
      }
      if ($OldPid -gt 0) {
        $running = Get-Process -Id $OldPid -ErrorAction SilentlyContinue
        if ($running) {
          $image = [IO.Path]::GetFullPath($running.Path)
          if (-not $image.StartsWith($install + '\', [StringComparison]::OrdinalIgnoreCase) -or
              [IO.Path]::GetFileName($image) -ne 'GhostBox.exe') { throw 'Recovery PID does not identify GhostBox in InstallRoot.' }
          if (-not $running.WaitForExit(120000)) { throw 'GhostBox did not exit before interrupted update recovery.' }
        }
      }
      $failedPath = "$install.ghostbox-failed-$id"
      if (Test-Path -LiteralPath $install) {
        if (Test-Path -LiteralPath $failedPath) { throw 'A prior failed bundle is present; manual recovery is required.' }
        Move-Item -LiteralPath $install -Destination $failedPath
      }
      Move-Item -LiteralPath $expectedBackup -Destination $install
      $transaction.status = 'RESTORE_OLD'
      $transaction.error = 'Recovered an interrupted Windows update before commit.'
      $transaction.updatedAt = [DateTime]::UtcNow.ToString('o')
      $tmp = "$transactionFile.tmp"
      $transaction | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tmp -Encoding UTF8
      Move-Item -LiteralPath $tmp -Destination $transactionFile -Force
      $old = Join-Path $install 'GhostBox.exe'
      if (Test-Path -LiteralPath $old -PathType Leaf) { Start-Process -FilePath $old -ArgumentList @('--ghostbox-update-recovered') }
      break
    }
    exit 0
  } finally { if ($lock) { $lock.Dispose() } }
}

$required = @('Mode', 'Package', 'TransactionId', 'HandoffDir', 'ExpectedSha256')
foreach ($name in $required) { if (-not (Get-Variable -Name $name -ValueOnly)) { throw "Missing required updater argument: -$name" } }
if ($OldPid -le 0) { throw 'OldPid must be a positive process ID.' }
$packagePath = [IO.Path]::GetFullPath($Package)
$transactionDir = [IO.Path]::GetFullPath($HandoffDir)
$resolvedStateRoot = [IO.Path]::GetFullPath($stateRoot).TrimEnd('\') + '\'
if (-not $transactionDir.StartsWith($resolvedStateRoot, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'HandoffDir must be inside the per-user GhostBox updater directory.'
}
$transactionFile = Join-Path $transactionDir 'update_transaction.json'
$lockPath = Join-Path $stateRoot 'update.lock'
New-Item -ItemType Directory -Path $transactionDir -Force | Out-Null
$lock = $null
$record = [ordered]@{
  id = $TransactionId; platform = 'windows'; mode = $Mode; status = 'CHECKING'
  oldVersion = ''; targetVersion = ''; oldPath = $install; backupPath = "$install.ghostbox-backup-$TransactionId"
  stagingPath = "$install.ghostbox-staging-$TransactionId"
  packagePath = $packagePath; sha256 = ''; startedAt = [DateTime]::UtcNow.ToString('o')
  updatedAt = [DateTime]::UtcNow.ToString('o')
}
$backup = "$install.ghostbox-backup-$TransactionId"
$staging = "$install.ghostbox-staging-$TransactionId"
$swapped = $false
$committed = $false
$healthStartPid = $null

# Request UAC only when this installation directory is not writable by the
# current token. Per-user installs run without a prompt.
$writeProbe = Join-Path $install ".ghostbox-write-probe-$TransactionId"
try {
  [IO.File]::WriteAllText($writeProbe, '')
  Remove-Item -LiteralPath $writeProbe -Force
} catch {
  $powershell = (Get-Process -Id $PID).Path
  $helperArgs = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'),
    '-Mode', $Mode, '-Package', ('"' + $packagePath + '"'), '-OldPid', "$OldPid",
    '-TransactionId', $TransactionId, '-InstallRoot', ('"' + $install + '"'),
    '-HandoffDir', ('"' + $transactionDir + '"'), '-ExpectedSha256', $ExpectedSha256
  )
  $elevated = Start-Process -FilePath $powershell -Verb RunAs -ArgumentList $helperArgs -Wait -PassThru
  exit $elevated.ExitCode
}
try {
  $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
  if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) { throw 'Update package is missing.' }
  if (-not (Test-Path -LiteralPath (Join-Path $install 'GhostBox.exe') -PathType Leaf)) { throw 'InstallRoot does not contain GhostBox.exe.' }
  Assert-TrustedOldProcess
  Write-Transaction 'CHECKING'
  $hash = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()
  $record.sha256 = $hash
  $record.backupPath = $backup
  $record.oldVersion = (Get-Item -LiteralPath (Join-Path $install 'GhostBox.exe')).VersionInfo.ProductVersion
  if ($ExpectedSha256 -and $hash -ne $ExpectedSha256.ToLowerInvariant()) { throw 'Update package SHA-256 mismatch.' }
  if (Test-Path -LiteralPath $backup) { throw 'A previous backup exists; recover it before starting another update.' }
  if (Test-Path -LiteralPath $staging) { throw 'An unfinished staging directory exists; recover it before starting another update.' }
  Write-Transaction 'VERIFYING'
  if ($Mode -eq 'installer') {
    $signature = Get-AuthenticodeSignature -LiteralPath $packagePath
    if ($signature.Status -notin @('Valid', 'NotSigned')) { throw "Installer signature status is $($signature.Status)." }
    if ($signature.Status -eq 'NotSigned') {
      Write-Warning 'The Setup package is not signed; the release SHA-256 is the available integrity check.'
    }
    $record.targetVersion = [IO.Path]::GetFileNameWithoutExtension($packagePath) -replace '^GhostBox-(.+)-Windows-x64-Setup$', '$1'
  } else {
    Add-Type -AssemblyName System.IO.Compression
    $zip = [IO.Compression.ZipFile]::OpenRead($packagePath)
    try {
      $packageEntries = @()
      foreach ($entry in $zip.Entries) {
        $entryPath = $entry.FullName.Replace('/', '\')
        if ([IO.Path]::IsPathRooted($entryPath) -or $entryPath -match '(^|\\)\.\.(\\|$)') { throw "Unsafe ZIP path: $($entry.FullName)" }
        if (-not $entry.FullName.EndsWith('/')) { $packageEntries += $entry.FullName.Replace('/', '\') }
      }
      if (-not ($zip.Entries | Where-Object { $_.FullName -eq 'GhostBox.exe' })) { throw 'ZIP does not contain a root GhostBox.exe.' }
      if (-not ($zip.Entries | Where-Object { $_.FullName -eq 'flutter_windows.dll' })) { throw 'ZIP is missing flutter_windows.dll.' }
      if (-not ($zip.Entries | Where-Object { $_.FullName -eq 'vendor/bin/xray.exe' }) -or
          -not ($zip.Entries | Where-Object { $_.FullName -eq 'vendor/bin/sing-box.exe' })) { throw 'ZIP is missing bundled VPN cores.' }
    } finally { $zip.Dispose() }
    $record.targetVersion = [IO.Path]::GetFileNameWithoutExtension($packagePath) -replace '^GhostBox-(.+)-Windows-x64$', '$1'
  }
  Write-Transaction 'STAGING'
  if ($Mode -eq 'portable') {
    New-Item -ItemType Directory -Path $staging | Out-Null
    [IO.Compression.ZipFile]::ExtractToDirectory($packagePath, $staging)
    foreach ($required in @('GhostBox.exe','flutter_windows.dll','data/app.so','vendor/bin/xray.exe','vendor/bin/sing-box.exe')) {
      if (-not (Test-Path -LiteralPath (Join-Path $staging $required) -PathType Leaf)) { throw "Staged ZIP is incomplete: $required" }
    }
  }
  Write-Transaction 'STOPPING'
  Set-Content -LiteralPath (Join-Path $transactionDir 'ready') -Value 'ready' -Encoding ascii
  if (Test-Path -LiteralPath (Join-Path $transactionDir 'cancelled')) { throw 'Update handoff was cancelled before shutdown.' }
  Wait-OldProcess
  if ($Mode -eq 'installer') {
    # A same-volume copy lets us restore a failed in-place Setup run. Unknown
    # user files remain in the backup and the Inno package no longer deletes them.
    Copy-Item -LiteralPath $install -Destination $backup -Recurse
  }
  Write-Transaction 'INSTALLING'
  if ($Mode -eq 'portable') {
    Move-Item -LiteralPath $install -Destination $backup
    try {
      foreach ($oldFile in Get-ChildItem -LiteralPath $backup -File -Recurse -Force) {
        $relative = $oldFile.FullName.Substring($backup.Length).TrimStart('\')
        if ($packageEntries -contains $relative) { continue }
        $copyPath = Join-Path $staging $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $copyPath) -Force | Out-Null
        Copy-Item -LiteralPath $oldFile.FullName -Destination $copyPath -Force
      }
      Move-Item -LiteralPath $staging -Destination $install; $swapped = $true
    }
    catch { Move-Item -LiteralPath $backup -Destination $install; throw }
  } else {
    $swapped = $true
    $swapped = $true
    $setup = Start-Process -FilePath $packagePath -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-','/CLOSEAPPLICATIONS=1',('/DIR="' + $install + '"')) -Wait -PassThru
    if ($setup.ExitCode -ne 0) { throw "Inno Setup exited with code $($setup.ExitCode)." }
    $swapped = $true
  }
  $app = Join-Path $install 'GhostBox.exe'
  if (-not (Test-Path -LiteralPath $app -PathType Leaf)) { throw 'Installed bundle is missing GhostBox.exe.' }
  Write-Transaction 'RELAUNCHING'
  Remove-Item -LiteralPath (Join-Path $transactionDir 'started') -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Join-Path $transactionDir 'confirmed') -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Join-Path $transactionDir 'failed') -Force -ErrorAction SilentlyContinue
  $newProc = Start-Process -FilePath $app -ArgumentList @(
    "--ghostbox-updated=$TransactionId",
    "--ghostbox-update-handoff=$transactionDir"
  ) -PassThru
  $script:newProcess = $newProc
  $healthStartPid = $newProc.Id
  Write-Transaction 'HEALTH_CHECK'
  if (-not (Wait-ForConfirmation -ExpectedPid $newProc.Id)) { throw 'The new client did not confirm healthy startup.' }
  Write-Transaction 'COMMIT'
  $committed = $true
  if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Recurse -Force }
  if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
  $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
  if ($packagePath.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
      (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
    Remove-Item -LiteralPath $packagePath -Force
    $packageDirectory = Split-Path -Parent $packagePath
    if ([IO.Path]::GetFileName($packageDirectory).StartsWith('ghostbox-download-', [StringComparison]::OrdinalIgnoreCase)) {
      Remove-Item -LiteralPath $packageDirectory -Recurse -Force
    }
  }
  Write-Transaction 'CLEANUP'
  exit 0
} catch {
  $message = $_.Exception.Message
  try {
    Set-Content -LiteralPath (Join-Path $transactionDir 'error') -Value $message -Encoding UTF8
    New-Item -ItemType File -Path (Join-Path $transactionDir 'failed') -Force | Out-Null
  } catch { }
  if ($committed) {
    Write-Transaction 'CLEANUP' $message
    exit 0
  }
  Write-Transaction 'FAILED' $message
  if ($swapped -and (Test-Path -LiteralPath $backup)) {
    Write-Transaction 'ROLLBACK' $message
    if ($script:newProcess) {
      $script:newProcess.CloseMainWindow() | Out-Null
      if (-not $script:newProcess.WaitForExit(5000)) { $script:newProcess.Kill() }
    }
    $failedPath = "$install.ghostbox-failed-$TransactionId"
    if (Test-Path -LiteralPath $install) { Move-Item -LiteralPath $install -Destination $failedPath }
    Move-Item -LiteralPath $backup -Destination $install
    # Preserve the failed tree so files created during the new version's
    # startup are not discarded during rollback.
    Write-Transaction 'RESTORE_OLD' $message
    $old = Join-Path $install 'GhostBox.exe'
    if (Test-Path -LiteralPath $old) { Start-Process -FilePath $old -ArgumentList @('--ghostbox-update-recovered') }
  } elseif (Test-Path -LiteralPath (Join-Path $transactionDir 'ready')) {
    $runningOld = Get-Process -Id $OldPid -ErrorAction SilentlyContinue
    $stillSameInstall = $false
    if ($runningOld) {
      try {
        $runningImage = [IO.Path]::GetFullPath($runningOld.Path)
        $stillSameInstall = $runningImage.StartsWith(($install + '\'), [StringComparison]::OrdinalIgnoreCase) -and
          [IO.Path]::GetFileName($runningImage) -eq 'GhostBox.exe'
      } catch { }
    }
    $old = Join-Path $install 'GhostBox.exe'
    if (-not $stillSameInstall -and (Test-Path -LiteralPath $old -PathType Leaf)) {
      Start-Process -FilePath $old -ArgumentList @('--ghostbox-update-recovered')
    }
  }
  if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
  exit 1
} finally {
  if ($lock) { $lock.Dispose() }
}
