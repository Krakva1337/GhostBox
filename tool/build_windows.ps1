[CmdletBinding()]
param(
  [ValidateSet('x64')]
  [string]$Architecture = 'x64',
  [switch]$SkipCoreBuild
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$CoreArch = 'amd64'
$XrayVersion = if ($env:GHOSTBOX_XRAY_VERSION) { $env:GHOSTBOX_XRAY_VERSION } else { 'v1.260327.0' }
$SingBoxVersion = if ($env:GHOSTBOX_SING_BOX_VERSION) { $env:GHOSTBOX_SING_BOX_VERSION } else { 'v1.14.3' }
$WintunUrl = 'https://www.wintun.net/builds/wintun-0.14.1.zip'
$WintunSha256 = '07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51'

function Invoke-Checked([string]$Program, [string[]]$Arguments) {
  & $Program @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$Program failed with exit code $LASTEXITCODE"
  }
}

foreach ($command in @('flutter', 'go')) {
  if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
    throw "Install $command and add it to PATH before building GhostBox."
  }
}

Push-Location $ProjectRoot
try {
  # sing-box loads Wintun dynamically when a TUN inbound starts. Bundle the
  # official signed DLL next to the core so portable ZIPs and the installer
  # work without a separate runtime download.
  $coreDirectory = Join-Path $ProjectRoot "vendor/windows/$CoreArch/bin"
  New-Item -ItemType Directory -Force -Path $coreDirectory | Out-Null
  $wintunTemp = Join-Path $env:TEMP "ghostbox-wintun-$PID"
  $wintunArchive = Join-Path $wintunTemp 'wintun.zip'
  $wintunExtract = Join-Path $wintunTemp 'extract'
  try {
    New-Item -ItemType Directory -Force -Path $wintunExtract | Out-Null
    Invoke-WebRequest -Uri $WintunUrl -OutFile $wintunArchive
    $actualHash = (Get-FileHash -Path $wintunArchive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $WintunSha256) {
      throw "Wintun archive SHA-256 mismatch: $actualHash"
    }
    Expand-Archive -Path $wintunArchive -DestinationPath $wintunExtract -Force
    $wintunDll = Get-ChildItem -Path $wintunExtract -Recurse -Filter 'wintun.dll' |
      Where-Object { $_.Directory.Name -eq $CoreArch } |
      Select-Object -First 1
    if (-not $wintunDll) { throw 'The verified Wintun archive does not contain its amd64 DLL.' }
    Copy-Item -Force $wintunDll.FullName (Join-Path $coreDirectory 'wintun.dll')
    $wintunLicense = Get-ChildItem -Path $wintunExtract -Recurse -Filter 'LICENSE.txt' |
      Select-Object -First 1
    if ($wintunLicense) {
      Copy-Item -Force $wintunLicense.FullName (Join-Path $coreDirectory 'WINTUN-LICENSE.txt')
    }
  } finally {
    Remove-Item -Recurse -Force $wintunTemp -ErrorAction SilentlyContinue
  }

  if (-not $SkipCoreBuild) {
    $moduleCache = (& go env GOMODCACHE).Trim()

    foreach ($module in @(
      @{ Path = 'github.com/xtls/xray-core'; Version = $XrayVersion; Package = './main'; Name = 'xray.exe'; Tags = $null },
      @{ Path = 'github.com/sagernet/sing-box'; Version = $SingBoxVersion; Package = './cmd/sing-box'; Name = 'sing-box.exe'; Tags = 'with_quic,with_utls' }
    )) {
      $moduleInfo = (& go mod download -json "$($module.Path)@$($module.Version)" | ConvertFrom-Json)
      if ($LASTEXITCODE -ne 0 -or -not $moduleInfo.Dir) {
        throw "Could not download $($module.Path)@$($module.Version)"
      }
      $oldGoos = $env:GOOS
      $oldGoarch = $env:GOARCH
      $oldCgo = $env:CGO_ENABLED
      try {
        $env:GOOS = 'windows'
        $env:GOARCH = 'amd64'
        $env:CGO_ENABLED = '0'
        $output = Join-Path $coreDirectory $module.Name
        $ldflags = '-s -w -buildid='
        if ($module.Path -eq 'github.com/sagernet/sing-box') {
          $ldflags += " -X github.com/sagernet/sing-box/constant.Version=$($SingBoxVersion.TrimStart('v'))"
        }
        $buildArgs = @('build', '-trimpath', '-buildvcs=false', "-ldflags=$ldflags")
        if ($module.Tags) { $buildArgs += @("-tags=$($module.Tags)") }
        $buildArgs += @('-o', $output, $module.Package)
        Push-Location $moduleInfo.Dir
        try { Invoke-Checked 'go' $buildArgs } finally { Pop-Location }
      } finally {
        $env:GOOS = $oldGoos
        $env:GOARCH = $oldGoarch
        $env:CGO_ENABLED = $oldCgo
      }
    }

    @(
      'GhostBox Windows x64 cores',
      "Xray: $XrayVersion",
      "sing-box: $SingBoxVersion",
      'sing-box tags: with_quic,with_utls'
    ) | Set-Content -Encoding utf8 (Join-Path $coreDirectory 'BUILD-INFO.txt')
  }

  Invoke-Checked 'flutter' @('pub', 'get')
  $version = (Select-String -Path (Join-Path $ProjectRoot 'pubspec.yaml') -Pattern '^version:\s*(\S+)' | ForEach-Object { $_.Matches[0].Groups[1].Value.Split('+')[0] })
  # Flutter selects the Windows target architecture from the Windows runner.
  # `--target-platform` is not a supported option for `flutter build windows`.
  $updateBranch = if ($env:GHOSTBOX_UPDATE_BRANCH) { $env:GHOSTBOX_UPDATE_BRANCH } else { 'main' }
  Invoke-Checked 'flutter' @(
    'build', 'windows', '--release',
    "--dart-define=GHOSTBOX_VERSION=$version",
    "--dart-define=GHOSTBOX_UPDATE_BRANCH=$updateBranch"
  )

  $releaseDirectory = Join-Path $ProjectRoot 'build/windows/x64/runner/Release'
  $application = Join-Path $releaseDirectory 'GhostBox.exe'
  if (-not (Test-Path $application)) {
    throw "Windows build completed without expected app: $application"
  }

  # Flutter's Windows runner dynamically links the Microsoft VC runtime.
  # Ship the redistributable app-local CRT so a clean Windows machine does not
  # fail at startup with VCRUNTIME140.dll / MSVCP140.dll missing.
  $vswhereCandidates = @(
    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'),
    (Join-Path $env:ProgramFiles 'Microsoft Visual Studio/Installer/vswhere.exe')
  ) | Where-Object { $_ -and (Test-Path $_) }
  $crtDirectories = @()
  if ($env:VCToolsRedistDir) {
    $crtDirectories += Join-Path $env:VCToolsRedistDir 'x64/Microsoft.VC143.CRT'
  }
  foreach ($vswhere in $vswhereCandidates) {
    $vsPath = (& $vswhere -latest -products '*' -property installationPath | Select-Object -First 1)
    if ($vsPath) {
      $vsPath = $vsPath.Trim()
      $crtDirectories += Get-ChildItem -Path (Join-Path $vsPath 'VC/Redist/MSVC') -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName 'x64/Microsoft.VC143.CRT' }
    }
  }
  $crtDirectory = $crtDirectories |
    Where-Object { Test-Path (Join-Path $_ 'vcruntime140.dll') } |
    Select-Object -First 1
  if (-not $crtDirectory) {
    throw 'The x64 Visual C++ app-local runtime was not found. Install the Visual C++ 14.x x64 Redistributable component in Visual Studio.'
  }
  Get-ChildItem -Path $crtDirectory -Filter '*.dll' -File |
    Copy-Item -Destination $releaseDirectory -Force
  $requiredRuntimeDlls = @('vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll')
  $missingRuntimeDlls = $requiredRuntimeDlls | Where-Object { -not (Test-Path (Join-Path $releaseDirectory $_)) }
  if ($missingRuntimeDlls) {
    throw "Visual C++ runtime bundle is incomplete; missing: $($missingRuntimeDlls -join ', ')"
  }
  Write-Host "Bundled app-local Visual C++ runtime from $crtDirectory"

  $releaseCoreDirectory = Join-Path $releaseDirectory 'vendor/bin'
  New-Item -ItemType Directory -Force -Path $releaseCoreDirectory | Out-Null
  foreach ($core in @('xray.exe', 'sing-box.exe', 'BUILD-INFO.txt', 'wintun.dll', 'WINTUN-LICENSE.txt')) {
    $source = Join-Path $coreDirectory $core
    if (-not (Test-Path $source)) {
      if ($core -eq 'WINTUN-LICENSE.txt') { continue }
      throw "Built core artifact is missing: $source"
    }
    Copy-Item -Force $source (Join-Path $releaseCoreDirectory $core)
  }

  $packageDirectory = Join-Path $ProjectRoot 'dist'
  New-Item -ItemType Directory -Force -Path $packageDirectory | Out-Null
  $archiveName = "GhostBox-$version-Windows-x64.zip"
  $archive = Join-Path $packageDirectory $archiveName
  Remove-Item -Force $archive -ErrorAction SilentlyContinue
  Compress-Archive -Path (Join-Path $releaseDirectory '*') -DestinationPath $archive
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $package = [System.IO.Compression.ZipFile]::OpenRead($archive)
  try {
    $entryNames = @($package.Entries | ForEach-Object { $_.FullName })
    foreach ($dll in $requiredRuntimeDlls) {
      if ($entryNames -notcontains $dll) { throw "Windows ZIP is missing app-local runtime DLL: $dll" }
    }
    foreach ($dll in @('flutter_windows.dll', 'vcruntime140.dll', 'msvcp140.dll')) {
      if ($entryNames -notcontains $dll) { throw "Windows ZIP is missing required runtime file: $dll" }
    }
    foreach ($core in @('vendor/bin/xray.exe', 'vendor/bin/sing-box.exe', 'vendor/bin/wintun.dll')) {
      if ($entryNames -notcontains $core) { throw "Windows ZIP is missing required core file: $core" }
    }
  } finally {
    $package.Dispose()
  }
  Write-Host "Built package: $archive"

  $compiler = Get-Command 'ISCC.exe' -ErrorAction SilentlyContinue
  $compilerPath = if ($compiler) { $compiler.Source } else { $null }
  if (-not $compilerPath) {
    $defaultCompiler = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6/ISCC.exe'
    if (Test-Path $defaultCompiler) { $compilerPath = $defaultCompiler }
  }
  if ($compilerPath) {
    $installerName = "GhostBox-$version-Windows-x64-Setup.exe"
    $installer = Join-Path $packageDirectory $installerName
    Invoke-Checked $compilerPath @(
      "/DAppVersion=$version",
      "/DSourceDir=$releaseDirectory",
      "/O$packageDirectory",
      "/FGhostBox-$version-Windows-x64-Setup",
      (Join-Path $ProjectRoot 'installer/GhostBox.iss')
    )
    Write-Host "Built installer: $installer"
  } else {
    Write-Warning 'Inno Setup is unavailable; only the portable zip was built.'
  }
} finally {
  Pop-Location
}
