# Android and Windows build preparation

## Prepared in this workspace

- Official Flutter Android and Windows runner projects.
- Android release manifest includes network access for subscriptions and server checks.
- Flutter Android debug/profile/release engine artifacts have been downloaded.
- Official Google command line tools are in `.toolchains/android-sdk/cmdline-tools/latest`.
  The archive is SHA-256 verified against Google's published checksum.
- Windows x64 Xray 26.3.27 and sing-box 1.14.3 executables were compiled from official
  Go module sources into `vendor/windows/bin/`. sing-box includes QUIC and uTLS.
- Windows CMake packages cores into `vendor/bin` beside the application. The Dart
  backend resolves cores from the app bundle and uses `.exe` on Windows.

Local SDK downloads and generated binaries are ignored by source control. They
are not part of the Flutter asset bundle; neither are `.env` or server secrets.

## Android (Linux host)

Java 17+ and Flutter are required. Java 21 is available on this machine.
Complete SDK setup with:

```bash
./tool/setup_android.sh
ANDROID_HOME="$PWD/.toolchains/android-sdk" flutter build apk --debug
```

The script asks Google's SDK manager to show its license terms and installs API
36, Build Tools 36, NDK 28.2.13676358, CMake 3.22.1 and platform-tools. These SDK/NDK
packages are not yet installed; only the command line tools and Flutter engine
artifacts are downloaded. SDK versions match the installed Flutter 3.47.7.

The Android runner currently builds the client UI. It is **not an Android VPN**:
the existing backend launches desktop subprocesses. A working Android tunnel
requires a native VpnService, foreground-service lifecycle, core library JNI/AAR
bindings and TUN file descriptor integration. Linux executables must not be
copied into Android assets. Android background behavior and permissions need
real-device testing once that native adapter exists. Generated release signing
uses the development debug key; configure a private release keystore before
publishing.

## Windows

Build the pinned native cores from Linux/macOS with Go:

```bash
./tool/build_windows_cores.sh
```

On a Windows host, install Flutter and Visual Studio with the **Desktop
development with C++** workload and Windows SDK. Copy `vendor/windows/bin/` from
the prepared workspace, then run in PowerShell:

```powershell
flutter pub get
flutter doctor -v
flutter build windows --release
```

Distribute the entire `build/windows/x64/runner/Release` directory, including
`vendor/bin`, Flutter DLLs and `data`. Native Windows Flutter builds cannot run
on this Linux host. The Windows core executables are built, but have not been
executed on Windows. The current core adapter exposes a local proxy, with no
Windows TUN or automatic system proxy installation.

## Sources

- https://developer.android.com/studio#command-tools
- https://docs.flutter.dev/platform-integration/android/setup
- https://docs.flutter.dev/platform-integration/windows/setup
- https://github.com/XTLS/Xray-core
- https://github.com/SagerNet/sing-box
