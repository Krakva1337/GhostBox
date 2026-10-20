#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
libxray_version="${GHOSTBOX_LIBXRAY_VERSION:-v26.10.17}"
gomobile_version="${GHOSTBOX_LIBXRAY_GOMOBILE_VERSION:-v0.0.0-20261011034528-197770444867}"
android_ndk_version="${GHOSTBOX_ANDROID_NDK_VERSION:-28.2.13676358}"
android_sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$project_dir/.toolchains/android-sdk}}"
android_ndk="$android_sdk/ndk/$android_ndk_version"
source_dir="$project_dir/.toolchains/src/libxray-$libxray_version"

command -v go >/dev/null || { echo 'Go is required to build the Android Xray core.' >&2; exit 1; }
command -v git >/dev/null || { echo 'Git is required to fetch libXray.' >&2; exit 1; }
command -v python3 >/dev/null || { echo 'Python 3 is required to build libXray.' >&2; exit 1; }
[[ -d "$android_ndk/toolchains/llvm" ]] || {
  echo "Android NDK $android_ndk_version is required at $android_ndk." >&2
  exit 1
}

mkdir -p "$(dirname "$source_dir")" "$project_dir/dist/cores/android"
if [[ ! -d "$source_dir/.git" ]]; then
  git clone --depth 1 --branch "$libxray_version" \
    https://github.com/XTLS/libXray.git "$source_dir"
else
  git -C "$source_dir" fetch --depth 1 origin "refs/tags/$libxray_version:refs/tags/$libxray_version"
  git -C "$source_dir" checkout --detach "$libxray_version"
fi

export ANDROID_HOME="$android_sdk"
export ANDROID_SDK_ROOT="$android_sdk"
export ANDROID_NDK_HOME="$android_ndk"
export ANDROID_NDK_ROOT="$android_ndk"
export GOFLAGS="${GOFLAGS:+$GOFLAGS }-buildvcs=false"
export LIBXRAY_GOMOBILE_VERSION="$gomobile_version"
export PATH="$(go env GOPATH)/bin:$PATH"

pushd "$source_dir" >/dev/null
python3 build/main.py android
[[ -s libXray.aar ]] || { echo 'libXray Android build did not produce libXray.aar.' >&2; exit 1; }
install -m 0644 libXray.aar "$project_dir/dist/cores/android/libXray.aar"
printf 'libXray %s\nGo %s\nAndroid API: 21+\nXray XHTTP: enabled by Xray-core\n' \
  "$libxray_version" "$(go version)" > "$project_dir/dist/cores/android/XRAY-BUILD-INFO.txt"
popd >/dev/null
echo "Android libXray AAR: $project_dir/dist/cores/android/libXray.aar"
