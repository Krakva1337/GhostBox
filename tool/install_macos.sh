#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 /path/to/GhostBox.app|GhostBox-*.zip" >&2
}

if [[ $# -ne 1 || ! -e "$1" ]]; then
  usage
  exit 2
fi

source_path="$(cd -- "$(dirname -- "$1")" && pwd)/$(basename -- "$1")"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/ghostbox-macos-install.XXXXXX")"
new_path="/Applications/.GhostBox.app.new.$$"
backup_path="/Applications/.GhostBox.app.old.$$"
installed=0
cleanup() {
  rm -rf -- "$work_dir"
  if [[ -d "$new_path" ]]; then sudo rm -rf -- "$new_path"; fi
  if [[ "$installed" -eq 0 && -d "$backup_path" && ! -e /Applications/GhostBox.app ]]; then
    sudo mv -- "$backup_path" /Applications/GhostBox.app
  fi
}
trap cleanup EXIT

if [[ -d "$source_path" && "$source_path" == *.app ]]; then
  app_path="$source_path"
elif [[ -f "$source_path" && "$source_path" == *.zip ]]; then
  /usr/bin/ditto -x -k "$source_path" "$work_dir"
  app_path="$(find "$work_dir" -type d -name '*.app' -prune -print -quit)"
  if [[ -z "$app_path" ]]; then
    echo "No .app bundle was found in the archive." >&2
    exit 1
  fi
else
  echo "Pass a GhostBox.app bundle or its .zip archive." >&2
  usage
  exit 2
fi

if [[ ! -x "$app_path/Contents/MacOS/GhostBox" && ! -x "$app_path/Contents/MacOS/Runner" ]]; then
  echo "The selected bundle does not look like a GhostBox macOS app: $app_path" >&2
  exit 1
fi

# Reject an incomplete or modified bundle before requesting administrator access.
/usr/bin/codesign --verify --deep --strict "$app_path"
for core in sing-box xray; do
  [[ -x "$app_path/Contents/MacOS/vendor/bin/$core" ]] || {
    echo "Bundled $core is missing; install a complete macOS release archive." >&2
    exit 1
  }
  /usr/bin/lipo -verify_arch "$(uname -m)" "$app_path/Contents/MacOS/vendor/bin/$core" || {
    echo "The bundled $core does not support this Mac ($(uname -m))." >&2
    exit 1
  }
done

echo "Installing GhostBox to /Applications/GhostBox.app (macOS will request administrator access)."
sudo -v
sudo /usr/bin/ditto "$app_path" "$new_path"
if [[ -e /Applications/GhostBox.app ]]; then
  sudo mv -- /Applications/GhostBox.app "$backup_path"
fi
sudo mv -- "$new_path" /Applications/GhostBox.app
installed=1
if [[ -e "$backup_path" ]]; then sudo rm -rf -- "$backup_path"; fi
open /Applications/GhostBox.app
echo "Installed and opened /Applications/GhostBox.app"
