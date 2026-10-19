# Cross-platform build preparation

## Build artifacts

Core versions are pinned in the build scripts so desktop and mobile artifacts can
be rebuilt from the same revisions:

- Xray `v1.260327.0` and sing-box `v1.14.3` desktop CLI cores for Windows and
  macOS. The sing-box build includes QUIC and uTLS.
- sing-box `libbox` for Android (`libbox.aar` and the upstream legacy AAR) and
  Apple (`Libbox.xcframework`). The official Apple gomobile build applies
  `with_low_memory` to iOS targets while excluding macOS.
- Windows x64 and ARM64 builds are stored separately under `vendor/windows/`;
  generated core files
  and mobile libraries remain ignored build artifacts.

Run the core workflow from GitHub Actions → **Build platform cores** to produce
Windows/macOS architecture variants, Android AARs and the Apple XCFramework.
Artifacts are retained for 14 days. Locally, desktop cores can be built with Go:

```bash
./tool/build_desktop_cores.sh windows amd64
./tool/build_desktop_cores.sh windows arm64
./tool/build_desktop_cores.sh macos amd64
./tool/build_desktop_cores.sh macos arm64
```

The equivalent one-command entry points are `./tool/build_platform_cores.sh desktop`,
`./tool/build_platform_cores.sh android` or `./tool/build_platform_cores.sh apple`. On a Mac with all toolchains installed,
`./tool/build_platform_cores.sh all` builds the complete core matrix.

Windows outputs go to `vendor/windows/<arch>/bin/` and are selected by the
Windows CMake build before being copied into Flutter's release directory.
macOS outputs go
to `vendor/macos/<arch>/bin/`; after building the Flutter app, copy the matching
pair into the `.app` bundle:

```bash
flutter build macos --release
./tool/package_macos_cores.sh build/macos/Build/Products/Release/Runner.app arm64
```

The `.app` must be code-signed again after copying the nested core executables.

## Mobile core libraries

Build Android `libbox` on Linux or macOS with Go, JDK 17, Android SDK and NDK:

```bash
./tool/setup_android.sh
export JAVA_HOME=/path/to/jdk-17
export ANDROID_HOME="$PWD/.toolchains/android-sdk"
./tool/build_mobile_cores.sh android
```

The AAR files are placed in `dist/cores/android/`. Apple libraries must be built
on macOS with Xcode and the iOS Simulator runtime installed:

```bash
./tool/build_mobile_cores.sh apple
```

This produces `dist/cores/apple/Libbox.xcframework/` for iOS devices,
iOS Simulator and macOS. The iOS variant is built with upstream's
`with_low_memory` option to reduce footprint. Apple's packet tunnel memory
budget is OS/device dependent; the commonly cited ~50 MiB figure is not a
permanent guarantee. Measure the packet tunnel extension on supported devices
and keep it lean (one core runtime, no Flutter engine or UI assets in the
extension). sing-box's compile option is a starting point, not a hard memory
cap.

## Runtime status and remaining integration

These scripts prepare native core binaries/libraries and Flutter runner
projects. They do not yet make the mobile apps functional VPN clients:

- Android still needs a native `VpnService`, foreground-service lifecycle,
  permission flow, libbox platform callbacks, TUN file-descriptor handoff and a
  Flutter method-channel backend.
- iOS still needs a `PacketTunnelProvider` app-extension target, a
  `NETunnelProviderManager` setup flow, Network Extension entitlements and a
  Flutter-to-extension configuration channel. Build/sign with an Apple team.
- macOS still needs a supported VPN/TUN adapter and the required Network
  Extension or system-extension entitlements. The generated Flutter runner and
  desktop core binaries alone provide the UI and local core processes.
- Windows has a Flutter desktop build path, bundled Xray/sing-box cores and a
  per-user WinINET system-proxy adapter. TUN mode still needs its Windows
  privilege/adapter lifecycle before it can be treated as a reliable default.

The native mobile build currently prepares sing-box as the mobile engine. Do not
link independent sing-box and Xray Go libraries into the same app/extension
process: each contains a Go runtime and can conflict at link or startup. If
Xray is selected for mobile later, make it the sole Go core in that process or
run it in a separate process where the OS permits it.

## Flutter runner builds

Run platform app builds on their native hosts after `flutter pub get`:

```text
Windows: flutter build windows --release
macOS:   flutter build macos --release
iOS:     flutter build ios --no-codesign
Android: flutter build apk --release
```

Windows requires Visual Studio's Desktop development with C++ workload. Apple
targets require Xcode; iOS distribution additionally needs valid signing and
Network Extension entitlements. Android release distribution needs a private
release keystore instead of the debug key currently configured in Gradle.

On Windows, the simplest complete x64 package build is:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
./tool/build_windows.ps1
```

Install Flutter stable, Go 1.27+, and Visual Studio 2022 with the Desktop
development with C++ workload first. The script builds the pinned core binaries,
the Flutter release app and `dist/GhostBox-Windows-x64.zip`. The GitHub Actions
workflow **Build GhostBox for Windows** runs the same script and publishes a
downloadable artifact.

## References

- [Amnezia split-tunneling implementation](https://github.com/amnezia-vpn/amnezia-client/blob/dev/client/vpnConnection.cpp#L1772-L1910) resolves listed hosts to IPs and installs address routes.
- [Amnezia split-tunneling guide](https://docs.amnezia.org/documentation/instructions/vpn-split-tunneling/) notes that domain-only lists can be unreliable for large/CDN-backed sites and recommends IP/CIDR lists for predictable routing.
- [sing-box mobile library builder](https://github.com/SagerNet/sing-box/blob/v1.14.3/cmd/internal/build_libbox/main.go)
- [Xray Android/iOS TUN integration](https://github.com/XTLS/Xray-core/blob/main/proxy/tun/README.md)
- [Apple Network Extension memory discussion](https://developer.apple.com/forums/thread/73148)
- [Android SDK command line tools](https://developer.android.com/studio#command-tools)
- [Flutter platform setup](https://docs.flutter.dev/platform-integration)
