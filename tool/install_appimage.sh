#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || ! -f "$1" ]]; then
  echo "Usage: $0 /path/to/GhostBox-*.AppImage" >&2
  exit 2
fi

SOURCE="$(realpath -- "$1")"
if [[ ! -x "$SOURCE" ]]; then
  echo "Making AppImage executable..."
  chmod u+x "$SOURCE"
fi

APP_DIR="${HOME}/.local/opt/ghostbox"
APP_PATH="$APP_DIR/GhostBox.AppImage"
RELEASES_DIR="$APP_DIR/releases"
BIN_DIR="${HOME}/.local/bin"
LAUNCHER="$BIN_DIR/ghostbox"
UPDATER="$BIN_DIR/ghostbox-update"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
VENDOR_DIR="$DATA_HOME/ghostbox-appimage/vendor/bin"
ICON_DIR="$DATA_HOME/icons/hicolor/scalable/apps"
DESKTOP_DIR="$DATA_HOME/applications"
TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$APP_DIR" "$RELEASES_DIR" "$BIN_DIR" "$ICON_DIR" "$DESKTOP_DIR" "$VENDOR_DIR"
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
install -m 0755 "$project_dir/tool/ghostbox-update.sh" "$UPDATER"
install -m 0755 "$SOURCE" "$APP_PATH"

(cd "$TMP_DIR" && "$APP_PATH" --appimage-extract >/dev/null)
APPIMAGE_HASH="$(sha256sum "$APP_PATH" | cut -d ' ' -f1)"
RELEASE_DIR="$RELEASES_DIR/$APPIMAGE_HASH"
if [[ ! -x "$RELEASE_DIR/AppRun" ]]; then
  mkdir -p "$RELEASE_DIR"
  cp -a "$TMP_DIR/squashfs-root/." "$RELEASE_DIR/"
fi
# Older AppImages may contain only the Flutter "GhostBox" binary even though
# their bundled AppRun looks for the lowercase "ghostbox" name.
install -m 0755 "$project_dir/packaging/appimage/AppRun" "$RELEASE_DIR/AppRun"
ln -sfn "$RELEASE_DIR" "$APP_DIR/AppDir.new"
mv -Tf "$APP_DIR/AppDir.new" "$APP_DIR/AppDir"

install -m 0644 "$RELEASE_DIR/ghostbox.svg" "$ICON_DIR/ghostbox.svg"
for core in sing-box xray; do
  # Avoid replacing an unchanged core: that would discard a user's CAP_NET_ADMIN xattr.
  if [[ ! -f "$VENDOR_DIR/$core" ]] || ! cmp -s "$RELEASE_DIR/vendor/bin/$core" "$VENDOR_DIR/$core"; then
    install -m 0755 "$RELEASE_DIR/vendor/bin/$core" "$VENDOR_DIR/$core"
  fi
done
if [[ -f "$RELEASE_DIR/vendor/bin/BUILD-INFO.txt" ]]; then
  install -m 0644 "$RELEASE_DIR/vendor/bin/BUILD-INFO.txt" "$VENDOR_DIR/BUILD-INFO.txt"
fi

# Run the extracted AppDir directly. This avoids FUSE and AppImage runtime
# extraction quirks in Rofi and other desktop launchers.
printf '#!/usr/bin/env bash\nset -e\nexec %q "$@"\n' "$APP_DIR/AppDir/AppRun" > "$LAUNCHER"
chmod 0755 "$LAUNCHER"

cat > "$DESKTOP_DIR/ghostbox.desktop" <<EOF
[Desktop Entry]
Name=GhostBox v0.1-Alpha
Comment=Linux VPN client powered by Xray and sing-box
Exec="$LAUNCHER" %U
TryExec=$LAUNCHER
Icon=ghostbox
Terminal=false
Type=Application
Categories=Network;Security;
StartupWMClass=ghostbox
EOF
chmod 0644 "$DESKTOP_DIR/ghostbox.desktop"

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true
fi

echo "Installed GhostBox v0.1-Alpha to $APP_PATH"
echo "Rofi application mode: rofi -show drun"
echo "Rofi command mode: ghostbox"
echo "Enable TUN once with: sudo setcap cap_net_admin+ep '$VENDOR_DIR/sing-box'"
