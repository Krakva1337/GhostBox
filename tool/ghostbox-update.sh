#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 /tmp/new-GhostBox.AppImage OLD_PID" >&2
  exit 2
fi

SOURCE="$(realpath -- "$1")"
OLD_PID="$2"
APP_DIR="${HOME}/.local/opt/ghostbox"
APP_PATH="$APP_DIR/GhostBox.AppImage"
RELEASES_DIR="$APP_DIR/releases"
LAUNCHER="${HOME}/.local/bin/ghostbox"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
VENDOR_DIR="$DATA_HOME/ghostbox-appimage/vendor/bin"
ICON_DIR="$DATA_HOME/icons/hicolor/scalable/apps"
APP_RUN_SOURCE="${GHOSTBOX_APP_RUN_SOURCE:-}"
TMP_DIR="$(mktemp -d "$APP_DIR/.update.XXXXXX")"
cleanup() { rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT

[[ -f "$SOURCE" ]] || { echo "Downloaded AppImage not found: $SOURCE" >&2; exit 1; }
chmod u+x "$SOURCE"

# Keep the old application running until it has fully exited before replacing
# its extracted files. The new release is staged next to it for rollback safety.
while kill -0 "$OLD_PID" 2>/dev/null; do sleep 0.4; done

install -m 0755 "$SOURCE" "$TMP_DIR/GhostBox.AppImage"
(cd "$TMP_DIR" && ./GhostBox.AppImage --appimage-extract >/dev/null)
NEW_HASH="$(sha256sum "$TMP_DIR/GhostBox.AppImage" | cut -d ' ' -f1)"
NEW_RELEASE="$RELEASES_DIR/$NEW_HASH"
mkdir -p "$RELEASES_DIR"
if [[ ! -d "$NEW_RELEASE" ]]; then
  mv "$TMP_DIR/squashfs-root" "$NEW_RELEASE"
fi

if [[ -n "$APP_RUN_SOURCE" && -x "$APP_RUN_SOURCE" ]]; then
  install -m 0755 "$APP_RUN_SOURCE" "$NEW_RELEASE/AppRun"
elif [[ -x "$(dirname -- "$0")/../packaging/appimage/AppRun" ]]; then
  install -m 0755 "$(dirname -- "$0")/../packaging/appimage/AppRun" "$NEW_RELEASE/AppRun"
fi

# Replace executable and extracted bundle atomically after extraction succeeds.
install -m 0755 "$TMP_DIR/GhostBox.AppImage" "$APP_DIR/GhostBox.AppImage.new"
mv -f "$APP_DIR/GhostBox.AppImage.new" "$APP_PATH"
ln -sfn "$NEW_RELEASE" "$APP_DIR/AppDir.new"
mv -Tf "$APP_DIR/AppDir.new" "$APP_DIR/AppDir"

for core in sing-box xray; do
  source_core="$NEW_RELEASE/vendor/bin/$core"
  target_core="$VENDOR_DIR/$core"
  if [[ -x "$source_core" ]]; then
    had_net_admin=false
    if command -v getcap >/dev/null 2>&1 && getcap "$target_core" 2>/dev/null | grep -q 'cap_net_admin'; then
      had_net_admin=true
    fi
    install -m 0755 "$source_core" "$target_core.new"
    mv -f "$target_core.new" "$target_core"
    if "$had_net_admin" && command -v setcap >/dev/null 2>&1; then
      setcap cap_net_admin+ep "$target_core" 2>/dev/null || true
    fi
  fi
done
if [[ -f "$NEW_RELEASE/vendor/bin/BUILD-INFO.txt" ]]; then
  install -m 0644 "$NEW_RELEASE/vendor/bin/BUILD-INFO.txt" "$VENDOR_DIR/BUILD-INFO.txt"
fi
if [[ -f "$NEW_RELEASE/ghostbox.svg" ]]; then
  mkdir -p "$ICON_DIR"
  install -m 0644 "$NEW_RELEASE/ghostbox.svg" "$ICON_DIR/ghostbox.svg"
fi

# The old process has exited and AppDir now points at the verified new bundle.
# Prune previous extracted builds so they do not accumulate across updates.
for old_release in "$RELEASES_DIR"/*; do
  [[ -d "$old_release" && "$old_release" != "$NEW_RELEASE" ]] || continue
  rm -rf -- "$old_release"
done

rm -f -- "$SOURCE"
exec "$LAUNCHER" --ghostbox-updated
