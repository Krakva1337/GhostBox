# GhostBox on iOS

The Flutter host controls a `NETunnelProviderManager`. The sing-box Apple
`Extension` target runs independently of the host in a Packet Tunnel extension.
The host embeds both `Extension.appex` and its `Library.framework` dependency.
Closing the app does not stop the tunnel; reopening reads the existing system
connection, its connected date and its profile name. Switching profiles waits
for the previous tunnel to stop before replacing its configuration.

Domain and IP/CIDR split rules run inside sing-box. Ordinary personal iPhones
do not expose arbitrary application selection for per-app VPN: Apple's per-app
mode requires a managed device. Do not present process rules as supported on
unmanaged iOS devices. See [Apple TN3134](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment).

## Build

Use a Mac with Xcode, the iOS Simulator runtime, Flutter, Go and Python 3:

```sh
./tool/build_ios.sh unsigned
```

This prepares the pinned Apple client and Libbox framework, compiles the host
and extension together and creates `dist/GhostBox-*-iOS-unsigned.zip`. It is a
compile artifact and cannot be installed on a device without signing.

For a signed archive/export, first configure Xcode with your Apple Developer
account. Register the app IDs `app.ghostbox.ghostbox` and
`app.ghostbox.ghostbox.PacketTunnel`, enabling Network Extensions / Packet
Tunnel and the shared App Group `group.app.ghostbox.ghostbox` for both. Then:

```sh
export GHOSTBOX_APPLE_TEAM_ID=YOURTEAMID
export GHOSTBOX_IOS_EXPORT_OPTIONS_PLIST=/absolute/path/to/ExportOptions.plist
./tool/build_ios.sh signed
```

Export options must match your account and distribution method. The script
passes the team to the host and extension; Xcode performs provisioning. A free
personal team does not provide the VPN capabilities needed by this app.

`tool/build_mobile_cores.sh apple` prepares `.toolchains/apple-client`, which
is the source project reference used by `Runner.xcodeproj`. Run that preparation
before opening/building the Xcode project. The pinned upstream target/product
IDs are checked before build, so upstream project changes fail explicitly.

## Dependencies and device verification

The upstream sing-box core and Apple client retain their own GPL license;
license copies and build provenance are included in `dist/cores/apple`.
Distribution of the linked app must comply with those licenses; GhostBox's
custom project license does not replace third-party terms.

The Apple backend uses sing-box. Xray-only transports or options need support
in the chosen Apple core; the iOS host cannot spawn a desktop Xray executable.

Device verification still requires a provisioned iPhone: connect, switch a
profile, close/reopen the host, disable VPN and check actual traffic routing,
DNS and reconnection. A Linux static check does not verify an iOS VPN session.
