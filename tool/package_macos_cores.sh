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
identity="${GHOSTBOX_CODESIGN_IDENTITY:--}"
sign_args=(--force --sign "$identity")
if [[ "$identity" != "-" ]]; then
  sign_args+=(--options runtime --timestamp)
fi
codesign "${sign_args[@]}" "$install_dir/xray"
codesign "${sign_args[@]}" "$install_dir/sing-box"
codesign "${sign_args[@]}" \
  --entitlements "$project_dir/macos/Runner/Release.entitlements" "$app_bundle"
codesign --verify --deep --strict "$app_bundle"
echo "Installed cores in $install_dir"
if [[ "$identity" == "-" ]]; then
  echo 'Ad-hoc signed for local testing; Developer ID signing and notarization are required for public distribution.'
else
  echo "Signed with: $identity. Notarize the app before public distribution."
fi
