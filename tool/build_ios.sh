#!/usr/bin/env bash
# Build the host and its Packet Tunnel together. Signed mode uses the local
# Xcode account/provisioning profiles; unsigned output cannot install on iPhone.
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode="${1:-unsigned}"
[[ "$(uname -s)" == Darwin ]] || { echo 'iOS builds require macOS and Xcode.' >&2; exit 1; }
case "$mode" in unsigned|signed) ;; *) echo "Usage: $0 unsigned|signed" >&2; exit 2 ;; esac
if [[ "$mode" == signed ]]; then
  [[ -n "${GHOSTBOX_APPLE_TEAM_ID:-}" ]] || { echo 'Set GHOSTBOX_APPLE_TEAM_ID for both host and extension signing.' >&2; exit 1; }
  [[ -f "${GHOSTBOX_IOS_EXPORT_OPTIONS_PLIST:-}" ]] || { echo 'Set GHOSTBOX_IOS_EXPORT_OPTIONS_PLIST to your Xcode export options plist.' >&2; exit 1; }
fi
"$project_dir/tool/build_mobile_cores.sh" apple
cd "$project_dir"
flutter pub get
version="$(awk '/^version:/ {split($2, v, "+"); print v[1]}' pubspec.yaml)"
build_number="$(awk '/^version:/ {split($2, v, "+"); print v[2]}' pubspec.yaml)"
numeric_version="${version%%-*}"
mkdir -p dist
if [[ "$mode" == unsigned ]]; then
  flutter build ios --release --no-codesign \
    --build-name="$numeric_version" --build-number="$build_number" \
    --dart-define="GHOSTBOX_VERSION=$version" --dart-define="GHOSTBOX_BUILD=$build_number"
  app="$project_dir/build/ios/iphoneos/Runner.app"
  [[ -d "$app/PlugIns/Extension.appex" ]] || { echo 'Packet Tunnel extension missing from app bundle.' >&2; exit 1; }
  [[ -d "$app/Frameworks/Library.framework" ]] || { echo 'Packet Tunnel Library.framework dependency missing from app bundle.' >&2; exit 1; }
  output="$project_dir/dist/GhostBox-$version-iOS-unsigned.zip"
  ditto -c -k --sequesterRsrc --keepParent "$app" "$output"
  shasum -a 256 "$output" > "$output.sha256"
  ipa_staging="$(mktemp -d "${TMPDIR:-/tmp}/ghostbox-ipa.XXXXXX")"
  trap 'rm -rf "$ipa_staging"' EXIT
  mkdir -p "$ipa_staging/Payload"
  ditto "$app" "$ipa_staging/Payload/GhostBox.app"
  ipa_output="$project_dir/dist/GhostBox-$version-iOS-unsigned.ipa"
  ditto -c -k --norsrc --keepParent "$ipa_staging/Payload" "$ipa_output"
  shasum -a 256 "$ipa_output" > "$ipa_output.sha256"
  echo "Unsigned compile artifacts: $output and $ipa_output (requires Apple signing before installation)."
else
  flutter build ios --config-only --release \
    --build-name="$numeric_version" --build-number="$build_number" \
    --dart-define="GHOSTBOX_VERSION=$version" --dart-define="GHOSTBOX_BUILD=$build_number"
  archive="$project_dir/build/ios/archive/GhostBox.xcarchive"
  xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner \
    -configuration Release -destination 'generic/platform=iOS' \
    -archivePath "$archive" -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$GHOSTBOX_APPLE_TEAM_ID" archive
  app="$archive/Products/Applications/Runner.app"
  [[ -d "$app/PlugIns/Extension.appex" && -d "$app/Frameworks/Library.framework" ]] || {
    echo 'Archived app is missing Packet Tunnel dependencies.' >&2; exit 1;
  }
  codesign --verify --deep --strict "$app"
  xcodebuild -exportArchive -archivePath "$archive" \
    -exportPath "$project_dir/dist/ios" \
    -exportOptionsPlist "$GHOSTBOX_IOS_EXPORT_OPTIONS_PLIST" -allowProvisioningUpdates
  echo "Signed iOS package: $project_dir/dist/ios"
fi
