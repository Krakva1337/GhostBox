#!/usr/bin/env bash
# Copy the selected macOS core pair into a Flutter .app bundle.
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_bundle="${1:-}"
arch="${2:-$(uname -m)}"
case "$arch" in arm64|aarch64) arch=arm64 ;; x86_64|amd64) arch=amd64 ;; esac
core_dir="$project_dir/vendor/macos/$arch/bin"

if [[ -z "$app_bundle" || ! -d "$app_bundle/Contents/MacOS" ]]; then
  echo "Usage: $0 /path/to/GhostBox.app [arm64|amd64]" >&2
  exit 2
fi
for core in xray sing-box; do
  [[ -x "$core_dir/$core" ]] || { echo "Missing executable: $core_dir/$core" >&2; exit 1; }
done
install_dir="$app_bundle/Contents/MacOS/vendor/bin"
mkdir -p "$install_dir"
install -m 0755 "$core_dir/xray" "$install_dir/xray"
install -m 0755 "$core_dir/sing-box" "$install_dir/sing-box"
echo "Installed cores in $install_dir"
echo 'Sign the nested cores and the app bundle after copying for signed distribution.'
