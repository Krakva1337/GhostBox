#!/usr/bin/env bash
# Build official sing-box libbox artifacts for Android or Apple platforms.
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="${1:-}"
gomobile_version="${GHOSTBOX_GOMOBILE_VERSION:-v0.1.13}"
android_ndk_version="${GHOSTBOX_ANDROID_NDK_VERSION:-28.2.13676358}"
artifact_dir="$project_dir/dist/cores"

case "$target" in
  android|apple) ;;
  *) echo "Usage: $0 android|apple" >&2; exit 2 ;;
esac
if [[ "$target" == android ]]; then
  sing_box_repository="${GHOSTBOX_ANDROID_SING_BOX_REPOSITORY:-https://github.com/Leadaxe/sing-box-lx.git}"
  sing_box_version="${GHOSTBOX_ANDROID_SING_BOX_VERSION:-v1.14.3-lx.21}"
else
  sing_box_repository="${GHOSTBOX_SING_BOX_REPOSITORY:-https://github.com/SagerNet/sing-box.git}"
  sing_box_version="${GHOSTBOX_SING_BOX_VERSION:-v1.14.3}"
fi
source_dir="$project_dir/.toolchains/src/sing-box-$sing_box_version"
command -v go >/dev/null || { echo 'Go is required.' >&2; exit 1; }
command -v git >/dev/null || { echo 'Git is required.' >&2; exit 1; }

if [[ "$target" == apple ]]; then
  [[ "$(uname -s)" == Darwin ]] || {
    echo 'Apple frameworks must be built on macOS with Xcode installed.' >&2
    exit 1
  }
  command -v xcodebuild >/dev/null || { echo 'Xcode is required.' >&2; exit 1; }
else
  android_sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  [[ -n "$android_sdk" ]] || {
    echo 'Set ANDROID_HOME to an installed Android SDK (run tool/setup_android.sh first).' >&2
    exit 1
  }
  android_ndk="$android_sdk/ndk/$android_ndk_version"
  [[ -d "$android_ndk/toolchains/llvm" ]] || {
    echo "Android NDK $android_ndk_version is required at $android_ndk (set GHOSTBOX_ANDROID_NDK_VERSION to override)." >&2
    exit 1
  }
  # setup-android on GitHub runners exports its preinstalled r27 as
  # ANDROID_NDK_HOME even if sdkmanager has also installed r28. sing-box-lx's
  # Cronet archive requires r28's linker, so pin the toolchain explicitly.
  export ANDROID_HOME="$android_sdk"
  export ANDROID_SDK_ROOT="$android_sdk"
  export ANDROID_NDK_HOME="$android_ndk"
  export ANDROID_NDK_ROOT="$android_ndk"
fi

mkdir -p "$(dirname "$source_dir")" "$artifact_dir"
if [[ ! -d "$source_dir/.git" ]]; then
  git clone --depth 1 --recurse-submodules --shallow-submodules \
    --branch "$sing_box_version" "$sing_box_repository" "$source_dir"
else
  git -C "$source_dir" fetch --depth 1 origin "refs/tags/$sing_box_version:refs/tags/$sing_box_version"
  git -C "$source_dir" checkout --detach "$sing_box_version"
  git -C "$source_dir" submodule update --init --recursive --depth 1
fi

# sing-box-lx pins the exact compiler in go.version. Using a newer installed Go
# version can produce Android libbox crashes that only surface at runtime, so
# always build its AAR with the source tree's declared toolchain.
if [[ "$target" == android ]]; then
  pinned_go_version="$(tr -d '[:space:]' < "$source_dir/go.version")"
  [[ "$pinned_go_version" =~ ^go[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || {
    echo "Invalid Go toolchain pin in $source_dir/go.version: $pinned_go_version" >&2
    exit 1
  }
  export GOTOOLCHAIN="$pinned_go_version"
fi

go install "github.com/sagernet/gomobile/cmd/gomobile@$gomobile_version"
go install "github.com/sagernet/gomobile/cmd/gobind@$gomobile_version"
export PATH="$(go env GOPATH)/bin:$PATH"
gomobile init

pushd "$source_dir" >/dev/null
if [[ "$target" == android ]]; then
  java_version="$(java --version 2>&1 | head -n 1)"
  [[ "$java_version" == *'17'* ]] || {
    echo "The pinned sing-box mobile builder requires JDK 17; detected: $java_version" >&2
    exit 1
  }
  go run ./cmd/internal/build_libbox -target android
  mkdir -p "$artifact_dir/android"
  install -m 0644 libbox.aar "$artifact_dir/android/libbox.aar"
  if [[ -f libbox-legacy.aar ]]; then
    install -m 0644 libbox-legacy.aar "$artifact_dir/android/libbox-legacy.aar"
  fi
  printf 'sing-box source: %s\nGo %s\nAndroid API variants: libbox AARs\nXHTTP: enabled by pinned sing-box-lx build\n' \
    "$sing_box_version" \
    "$(go version)" > "$artifact_dir/android/BUILD-INFO.txt"
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
