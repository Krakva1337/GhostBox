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
  if (-not $SkipCoreBuild) {
    $moduleCache = (& go env GOMODCACHE).Trim()
    $coreDirectory = Join-Path $ProjectRoot "vendor/windows/$CoreArch/bin"
    New-Item -ItemType Directory -Force -Path $coreDirectory | Out-Null

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
  # Flutter selects the Windows target architecture from the Windows runner.
  # `--target-platform` is not a supported option for `flutter build windows`.
  Invoke-Checked 'flutter' @('build', 'windows', '--release')

  $releaseDirectory = Join-Path $ProjectRoot 'build/windows/x64/runner/Release'
  $application = Join-Path $releaseDirectory 'GhostBox.exe'
  if (-not (Test-Path $application)) {
    throw "Windows build completed without expected app: $application"
  }

  $releaseCoreDirectory = Join-Path $releaseDirectory 'vendor/bin'
  New-Item -ItemType Directory -Force -Path $releaseCoreDirectory | Out-Null
  foreach ($core in @('xray.exe', 'sing-box.exe', 'BUILD-INFO.txt')) {
    $source = Join-Path $coreDirectory $core
    if (-not (Test-Path $source)) { throw "Built core artifact is missing: $source" }
    Copy-Item -Force $source (Join-Path $releaseCoreDirectory $core)
  }

  $packageDirectory = Join-Path $ProjectRoot 'dist'
  New-Item -ItemType Directory -Force -Path $packageDirectory | Out-Null
  $archive = Join-Path $packageDirectory 'GhostBox-Windows-x64.zip'
  Remove-Item -Force $archive -ErrorAction SilentlyContinue
  Compress-Archive -Path (Join-Path $releaseDirectory '*') -DestinationPath $archive
  Write-Host "Built package: $archive"

  $compiler = Get-Command 'ISCC.exe' -ErrorAction SilentlyContinue
  $compilerPath = if ($compiler) { $compiler.Source } else { $null }
  if (-not $compilerPath) {
    $defaultCompiler = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6/ISCC.exe'
    if (Test-Path $defaultCompiler) { $compilerPath = $defaultCompiler }
  }
  if ($compilerPath) {
    $version = (Select-String -Path (Join-Path $ProjectRoot 'pubspec.yaml') -Pattern '^version:\s*(\S+)' | ForEach-Object { $_.Matches[0].Groups[1].Value.Split('+')[0] })
    $installer = Join-Path $packageDirectory 'GhostBox-Setup-x64.exe'
    Invoke-Checked $compilerPath @(
      "/DAppVersion=$version",
      "/DSourceDir=$releaseDirectory",
      "/O$packageDirectory",
      "/FGhostBox-Setup-x64",
      (Join-Path $ProjectRoot 'installer/GhostBox.iss')
    )
    Write-Host "Built installer: $installer"
  } else {
    Write-Warning 'Inno Setup is unavailable; only the portable zip was built.'
  }
} finally {
  Pop-Location
}
