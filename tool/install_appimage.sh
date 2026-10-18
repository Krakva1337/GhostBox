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
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
ICON_DIR="$DATA_HOME/icons/hicolor/scalable/apps"
DESKTOP_DIR="$DATA_HOME/applications"
TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$APP_DIR" "$ICON_DIR" "$DESKTOP_DIR"
install -m 0755 "$SOURCE" "$APP_PATH"

(cd "$TMP_DIR" && "$APP_PATH" --appimage-extract >/dev/null)
install -m 0644 "$TMP_DIR/squashfs-root/ghostbox.svg" "$ICON_DIR/ghostbox.svg"

cat > "$DESKTOP_DIR/ghostbox.desktop" <<EOF
[Desktop Entry]
Name=GhostBox Alpha
Comment=Linux VPN client powered by Xray and sing-box
Exec="$APP_PATH"
Icon=ghostbox
Terminal=false
Type=Application
Categories=Network;Security;
StartupWMClass=ghostbox
EOF
chmod 0644 "$DESKTOP_DIR/ghostbox.desktop"

echo "Installed GhostBox Alpha to $APP_PATH"
echo "Launch it from the application menu, then run tool/setup_tun_permissions.sh --test from the source checkout to enable TUN."
