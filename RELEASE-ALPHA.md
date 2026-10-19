# GhostBox v1.0-pre-alpha

Linux x86_64 desktop preview, built with Flutter and bundled Xray-core and sing-box binaries.

## Install

Download `GhostBox-1.0.0-pre-alpha-linux-x86_64.AppImage` from the release assets and run:

```bash
chmod +x GhostBox-1.0.0-pre-alpha-linux-x86_64.AppImage
./GhostBox-1.0.0-pre-alpha-linux-x86_64.AppImage
```

Optionally add it to the desktop application menu:

```bash
./tool/install_appimage.sh ./GhostBox-1.0.0-pre-alpha-linux-x86_64.AppImage
```

Import a subscription or profile, check its connection, and choose a connection mode. TUN is the default. For Linux TUN, start GhostBox once so AppRun copies the bundled cores to the user data directory, then run:

```bash
sudo setcap cap_net_admin+ep "$HOME/.local/share/ghostbox-appimage/vendor/bin/sing-box"
```

The app will show this command with a copy button if it detects missing TUN permissions. The one-time capability setup needs administrator authentication; the VPN process itself runs as your normal user. On Void Linux, install `libcap-progs` first if `setcap` is missing: `sudo xbps-install -S libcap-progs`. The optional `./tool/setup_tun_permissions.sh --test` helper also verifies that temporary TUN interfaces are created and removed without adding system routes.

## Included

- Xray is the default core; sing-box is available in settings.
- Xray XHTTP/REALITY support and a sing-box TUN bridge for Xray TUN mode.
- TUN, local proxy, system proxy and mixed connection modes.
- Multiple URL subscriptions, link/JSON/file/clipboard import, DNS and routing controls, connection logs and recent connection history.
- Optional live core RAM usage on the main screen.

Provider-dependent information such as quota and expiry is displayed only when returned by the provider. A panel must recognize GhostBox's device headers to display OS information. The bundled sing-box build does not include every optional build tag; choose Xray for XHTTP and REALITY.

## Alpha notes

- Linux x86_64 is the only supported release target in this build.
- Keep another VPN option available while validating the servers and routes you use. Avoid running two TUN clients at the same time.
- TUN permissions need a one-time administrator action on Linux. Connections run as the logged-in user afterward.
- Windows and Android are not supported by this alpha release.
- Settings and profiles are stored locally. Do not share logs or JSON configs without removing credentials and subscription links.

## Build provenance

The AppImage is assembled from the Linux release bundle plus the pinned core binaries in `vendor/bin/`. Source build steps are in [README.md](README.md). The application does not bundle local `.env` values.
