#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v flutter >/dev/null || { echo 'Flutter is required.' >&2; exit 1; }
command -v go >/dev/null || { echo 'Go is required to build libbox.' >&2; exit 1; }

"$project_dir/tool/build_mobile_cores.sh" android
"$project_dir/tool/build_android_xray.sh"
mkdir -p "$project_dir/android/app/libs"
install -m 0644 "$project_dir/dist/cores/android/libbox.aar" \
  "$project_dir/android/app/libs/libbox.aar"
install -m 0644 "$project_dir/dist/cores/android/libXray.aar" \
  "$project_dir/android/app/libs/libXray.aar"
cd "$project_dir"
flutter pub get
ghostbox_version="$(awk '/^version:/ {split($2,v,"+"); print v[1]}' pubspec.yaml)"
ghostbox_build="$(awk '/^version:/ {split($2,v,"+"); print v[2]}' pubspec.yaml)"
update_branch="${GHOSTBOX_UPDATE_BRANCH:-main}"
flutter build apk --release \
  --dart-define="GHOSTBOX_VERSION=$ghostbox_version" \
  --dart-define="GHOSTBOX_BUILD=$ghostbox_build" \
  --dart-define="GHOSTBOX_UPDATE_BRANCH=$update_branch"
mkdir -p "$project_dir/dist/android"

# Keep the previous APKs available locally before writing this build's output.
mkdir -p "$project_dir/old"
shopt -s nullglob
for apk in "$project_dir"/dist/android/*.apk; do
  apk_name="$(basename "$apk")"
  archived_apk="$project_dir/old/$apk_name"
  if [[ -e "$archived_apk" || -e "$archived_apk.sha256" ]]; then
    stem="${apk_name%.apk}"
    suffix=1
    while [[ -e "$project_dir/old/$stem-old$suffix.apk" || \
            -e "$project_dir/old/$stem-old$suffix.apk.sha256" ]]; do
      suffix=$((suffix + 1))
    done
    archived_apk="$project_dir/old/$stem-old$suffix.apk"
  fi
  mv -- "$apk" "$archived_apk"
  if [[ -f "$apk.sha256" ]]; then
    mv -- "$apk.sha256" "$archived_apk.sha256"
  fi
done
install -m 0644 build/app/outputs/flutter-apk/app-release.apk \
  "$project_dir/dist/android/GhostBox-Android-universal.apk"
echo "Built dist/android/GhostBox-Android-universal.apk"
