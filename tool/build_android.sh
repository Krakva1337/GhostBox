#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v flutter >/dev/null || { echo 'Flutter is required.' >&2; exit 1; }
command -v go >/dev/null || { echo 'Go is required to build libbox.' >&2; exit 1; }

"$project_dir/tool/build_mobile_cores.sh" android
mkdir -p "$project_dir/android/app/libs"
install -m 0644 "$project_dir/dist/cores/android/libbox.aar" \
  "$project_dir/android/app/libs/libbox.aar"
cd "$project_dir"
flutter pub get
ghostbox_version="$(awk '/^version:/ {split($2,v,"+"); print v[1]}' pubspec.yaml)"
flutter build apk --release --dart-define="GHOSTBOX_VERSION=$ghostbox_version"
mkdir -p "$project_dir/dist/android"
install -m 0644 build/app/outputs/flutter-apk/app-release.apk \
  "$project_dir/dist/android/GhostBox-Android-universal.apk"
echo "Built dist/android/GhostBox-Android-universal.apk"
