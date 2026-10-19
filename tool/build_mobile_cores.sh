#!/usr/bin/env bash
# Build official sing-box libbox artifacts for Android or Apple platforms.
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="${1:-}"
sing_box_version="${GHOSTBOX_SING_BOX_VERSION:-v1.14.3}"
gomobile_version="${GHOSTBOX_GOMOBILE_VERSION:-v0.1.13}"
source_dir="$project_dir/.toolchains/src/sing-box-$sing_box_version"
artifact_dir="$project_dir/dist/cores"

case "$target" in
  android|apple) ;;
  *) echo "Usage: $0 android|apple" >&2; exit 2 ;;
esac
command -v go >/dev/null || { echo 'Go is required.' >&2; exit 1; }
command -v git >/dev/null || { echo 'Git is required.' >&2; exit 1; }

if [[ "$target" == apple ]]; then
  [[ "$(uname -s)" == Darwin ]] || {
    echo 'Apple frameworks must be built on macOS with Xcode installed.' >&2
    exit 1
  }
  command -v xcodebuild >/dev/null || { echo 'Xcode is required.' >&2; exit 1; }
else
  [[ -n "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}" ]] || {
    echo 'Set ANDROID_HOME to an installed Android SDK (run tool/setup_android.sh first).' >&2
    exit 1
  }
fi

mkdir -p "$(dirname "$source_dir")" "$artifact_dir"
if [[ ! -d "$source_dir/.git" ]]; then
  git clone --depth 1 --branch "$sing_box_version" \
    https://github.com/SagerNet/sing-box.git "$source_dir"
else
  git -C "$source_dir" fetch --depth 1 origin "refs/tags/$sing_box_version:refs/tags/$sing_box_version"
  git -C "$source_dir" checkout --detach "$sing_box_version"
fi

go install "github.com/sagernet/gomobile/cmd/gomobile@$gomobile_version"
go install "github.com/sagernet/gomobile/cmd/gobind@$gomobile_version"
export PATH="$(go env GOPATH)/bin:$PATH"
gomobile init

pushd "$source_dir" >/dev/null
if [[ "$target" == android ]]; then
  java_version="$(java --version 2>&1 | head -n 1)"
  [[ "$java_version" == *'17'* ]] || {
    echo "sing-box v1.14.3 mobile builder requires JDK 17; detected: $java_version" >&2
    exit 1
  }
  go run ./cmd/internal/build_libbox -target android
  mkdir -p "$artifact_dir/android"
  install -m 0644 libbox.aar "$artifact_dir/android/libbox.aar"
  if [[ -f libbox-legacy.aar ]]; then
    install -m 0644 libbox-legacy.aar "$artifact_dir/android/libbox-legacy.aar"
  fi
  printf 'sing-box %s\nGo %s\nAndroid API variants: official libbox AARs\n' \
    "$sing_box_version" "$(go version)" > "$artifact_dir/android/BUILD-INFO.txt"
  echo "Android libbox AARs: $artifact_dir/android"
else
  go run ./cmd/internal/build_libbox -target apple -platform ios,iossimulator,macos
  mkdir -p "$artifact_dir/apple"
  rm -rf "$artifact_dir/apple/Libbox.xcframework"
  cp -a Libbox.xcframework "$artifact_dir/apple/Libbox.xcframework"
  printf 'sing-box %s\nGo %s\niOS low-memory build tag: with_low_memory (upstream gomobile builder)\n' \
    "$sing_box_version" "$(go version)" > "$artifact_dir/apple/BUILD-INFO.txt"
  echo "Apple Libbox.xcframework: $artifact_dir/apple/Libbox.xcframework"
fi
popd >/dev/null
