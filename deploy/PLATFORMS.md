# Cross-platform build preparation

## Build artifacts

The **Build GhostBox packages** GitHub Actions workflow builds Linux AppImages
for x86_64 and ARM64 on native runners, plus a Windows x64 portable ZIP and
Inno Setup installer. Workflow artifacts are retained for 14 days. Linux ARM64
uses the `aarch64` AppImage suffix; these binaries only run on ARM64 Linux.

The manual **Build GhostBox for Apple platforms** workflow builds an Apple
Silicon macOS `.app` and an unsigned iOS app with the sing-box Packet Tunnel
extension. The macOS app uses local proxy or System Proxy mode. Installing the
iOS artifact requires matching Apple signing profiles and Network Extension
and App Group capabilities.

Core versions are pinned in the build scripts so desktop and mobile artifacts can
be rebuilt from the same revisions:

- Xray `v1.260327.0` and sing-box `v1.14.3` desktop CLI cores for Windows and
  macOS. The sing-box build includes QUIC and uTLS.
- Android `libbox` AARs are built from the pinned `Leadaxe/sing-box-lx`
  release, which enables XHTTP for VLESS/REALITY profiles. Apple uses upstream
  sing-box `Libbox.xcframework`; its gomobile build applies `with_low_memory`
  to iOS targets while excluding macOS.
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
cap. GhostBox's iOS memory control is only a 25–50 MiB soft target for the Go
runtime; it does not cap total RSS. The iOS Packet Tunnel extension runs the
sing-box service and receives configuration from the Flutter host app.
The Apple client is GPL-licensed and linked into the extension. Before
distributing iOS binaries, review the resulting source and license obligations
alongside GhostBox's project license; the bundled third-party notices are in
`dist/cores/apple`.

## Runtime status

Current platform integration:

- Android uses the system VPN permission flow, a foreground `VpnService`,
  sing-box `libbox`, platform callbacks and the Android TUN file descriptor.
  `./tool/build_android.sh` builds the AAR and a universal APK. The GitHub
  workflow produces the same APK without requiring a local Android SDK/NDK.
- Windows bundles Xray/sing-box and the per-user WinINET system proxy. TUN uses
  Wintun and requests elevation through the normal Windows UAC prompt. The
  process lifecycle manager supervises core children and cleans stale cores
  before reconnecting. The Windows workflow publishes an Inno Setup installer
  and a portable zip.
- Linux Kill Switch uses a dedicated nftables output chain for TUN/Mixed mode.
  It requires `nftables` and `pkexec`; the rule stays installed after GhostBox
  exits until explicitly disabled, and allows only loopback, `ghostbox0`, DHCP
  traffic and the selected VPN endpoint.
- macOS supports local proxy and System Proxy modes using the bundled Xray or
  sing-box process. System Proxy changes the active network service's SOCKS
  setting and requests administrator authorization; previous settings are
  saved and restored. TUN/Mixed use the elevated sing-box route process and
  require administrator authorization; this is not a Network Extension VPN.
- iOS uses the upstream sing-box `PacketTunnelProvider` extension and
  `NETunnelProviderManager` to start and stop the system VPN. The build embeds
  the extension and requests the Packet Tunnel and App Group entitlements.
  Device installation still requires matching provisioning profiles and an
  Apple Developer team with these capabilities enabled.

## Split routing behavior

All platforms use the same core routing contract for domain and IP rules:

- `example.org` matches the apex and its subdomains.
- `*.example.org` matches subdomains only.
- `full:example.org` matches exactly that hostname.
- IPv4, IPv6 and CIDR rules match destination addresses.

Rules are evaluated by Xray or sing-box inside the tunnel. The application does
not pin DNS answers into system routes: CDN addresses change and can be shared
by unrelated sites. Domain decisions use DNS answers and visible HTTP/TLS/QUIC
hostnames. Encrypted DNS and ECH can hide hostnames from the core; use IP/CIDR
rules when those destinations must be matched directly. iOS supports these
domain and address rules, while arbitrary per-app selection requires a managed
Apple device. Linux and Windows Kill Switch cannot be combined with rules that
send selected traffic directly because the current firewall policy blocks
traffic outside the tunnel.

Android and Windows builds have not yet been device/VM validated in this
workspace. Run the workflows and smoke-test VPN permission, connect/disconnect,
DNS, split routing and system recovery before distributing a release build.

Android currently uses sing-box as its native mobile engine. Do not link
independent sing-box and Xray Go libraries into the same app/extension process:
each contains a Go runtime and can conflict at link or startup. Android forces
the sing-box engine for TUN connections; Xray remains available on Linux and
Windows desktop.

## Flutter runner builds

Run platform app builds on their native hosts after `flutter pub get`:

```text
Windows: flutter build windows --release
macOS:   flutter build macos --release
iOS:     ./tool/build_ios.sh unsigned
Android: ./tool/build_android.sh
```

Windows requires Visual Studio's Desktop development with C++ workload. Apple
targets require Xcode. The macOS app is ad-hoc signed for local testing by
default; use a Developer ID certificate and notarize it before distribution.
iOS distribution needs valid signing and provisioning profiles for the Packet
Tunnel extension and shared App Group. Android release distribution needs a private
release keystore instead of the debug key currently configured in Gradle.

On Windows, build the x64 package with:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
./tool/build_windows.ps1
```

Install Flutter stable, Go 1.27+, and Visual Studio 2022 with the Desktop
development with C++ workload first. The script builds the pinned core binaries,
the Flutter release app and `dist/GhostBox-<version>-Windows-x64.zip`. When Inno Setup is
installed, it also writes `dist/GhostBox-<version>-Windows-x64-Setup.exe`. The GitHub Actions
workflow installs Inno Setup and publishes both files.

## References

- [Amnezia split-tunneling implementation](https://github.com/amnezia-vpn/amnezia-client/blob/dev/client/vpnConnection.cpp#L1772-L1910) resolves listed hosts to IPs and installs address routes.
- [Amnezia split-tunneling guide](https://docs.amnezia.org/documentation/instructions/vpn-split-tunneling/) notes that domain-only lists can be unreliable for large/CDN-backed sites and recommends IP/CIDR lists for predictable routing.
- [sing-box mobile library builder](https://github.com/SagerNet/sing-box/blob/v1.14.3/cmd/internal/build_libbox/main.go)
- [Xray Android/iOS TUN integration](https://github.com/XTLS/Xray-core/blob/main/proxy/tun/README.md)
- [Apple Network Extension memory discussion](https://developer.apple.com/forums/thread/73148)
- [Android SDK command line tools](https://developer.android.com/studio#command-tools)
- [Flutter platform setup](https://docs.flutter.dev/platform-integration)
