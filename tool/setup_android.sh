#!/usr/bin/env bash
# Official Google command line tools, verified against developer.android.com/studio.
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sdk_dir="${GHOSTBOX_ANDROID_SDK:-$project_dir/.toolchains/android-sdk}"
archive="$project_dir/.toolchains/downloads/commandlinetools-linux.zip"
mkdir -p "$(dirname "$archive")" "$sdk_dir/cmdline-tools"
if [[ ! -x "$sdk_dir/cmdline-tools/latest/bin/sdkmanager" ]]; then
  curl --fail --location --retry 2 --output "$archive" https://dl.google.com/android/repository/commandlinetools-linux-15859902_latest.zip
  printf '%s  %s\n' '4e4c464f145a7512b57d088ac6c278c03c9eea610886b35a5e0804e74eedf583' "$archive" | sha256sum --check
  unzip -q "$archive" -d "$sdk_dir/cmdline-tools"
  mv "$sdk_dir/cmdline-tools/cmdline-tools" "$sdk_dir/cmdline-tools/latest"
fi
sdkmanager="$sdk_dir/cmdline-tools/latest/bin/sdkmanager"
# Review and accept Google's licenses interactively, then fetch SDK/NDK.
"$sdkmanager" --sdk_root="$sdk_dir" --licenses
"$sdkmanager" --sdk_root="$sdk_dir" 'platform-tools' 'platforms;android-36' 'build-tools;36.0.0' 'ndk;28.2.13676358' 'cmake;3.22.1'
flutter precache --android
printf '\nUse this SDK when building:\nANDROID_HOME="%s" flutter build apk --debug\n' "$sdk_dir"
