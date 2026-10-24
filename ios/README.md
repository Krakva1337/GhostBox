# GhostBox on iOS

The Flutter host controls a `NETunnelProviderManager`. The selected core runs
independently of the host in a Packet Tunnel extension.
The host embeds both `Extension.appex` and its `Library.framework` dependency.
Closing the app does not stop the tunnel; reopening reads the existing system
connection, its connected date and its profile name. Switching profiles waits
for the previous tunnel to stop before replacing its configuration.

Domain and IP/CIDR split rules run inside sing-box. Ordinary personal iPhones
do not expose arbitrary application selection for per-app VPN: Apple's per-app
mode requires a managed device. Do not present process rules as supported on
unmanaged iOS devices. See [Apple TN3134](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment).

## Build

Use a Mac with Xcode, Flutter, Go and Python 3. An iOS Simulator runtime is
only needed for simulator testing:

```sh
./tool/build_ios.sh unsigned
```

This prepares the pinned Apple client and Libbox framework, compiles the host
and extension together, and creates both
`dist/GhostBox-*-iOS-unsigned.zip` and `dist/GhostBox-*-iOS-unsigned.ipa`.
The IPA contains `Payload/GhostBox.app`, but it is unsigned and cannot be
installed on a device until you sign it with an Apple team and provisioning
profiles.

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
personal team does not provide the VPN capabilities needed by this app. If
`saveToPreferences` reports `permission denied`, the signed app or extension
profile is missing Network Extension or App Group authorization; re-signing
with a free personal team cannot grant those entitlements. See Apple's
[Network Extensions entitlement reference](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.networkextension).

`tool/build_mobile_cores.sh apple` prepares `.toolchains/apple-client`, which
is the source project reference used by `Runner.xcodeproj`. Run that preparation
before opening/building the Xcode project. The pinned upstream target/product
IDs are checked before build, so upstream project changes fail explicitly.

## Dependencies and device verification

The upstream sing-box core and Apple client retain their own GPL license;
license copies and build provenance are included in `dist/cores/apple`.
Distribution of the linked app must comply with those licenses; GhostBox's
custom project license does not replace third-party terms.

The Apple `Libbox.framework` contains sing-box-lx and Xray in one Go runtime.
sing-box-lx is built with `with_xhttp`; Xray uses the NetworkExtension utun
descriptor directly. The host can select either core for VLESS/VMess XHTTP
profiles. Xray's TUN inbound does not support ICMP packets.

Device verification still requires a provisioned iPhone: connect, switch a
profile, close/reopen the host, disable VPN and check actual traffic routing,
DNS and reconnection. A Linux static check does not verify an iOS VPN session.
