#!/usr/bin/env bash
# Bootstrap available platform dependencies and create a GhostBox release build.
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
target="${1:-}"
arch="$(uname -m)"
export GOCACHE="${GOCACHE:-$project_dir/.toolchains/go-build-cache}"
case "$arch" in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; esac

if [[ -z "$target" ]]; then
  echo 'Choose a build target:'
  select target in linux android windows macos ios; do
    [[ -n "${target:-}" ]] && break
    echo 'Select a number from the list.'
  done
fi

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing dependency: $1. Install it, then rerun ./tool/build.sh $target." >&2
    exit 1
  }
}

build_linux() {
  [[ "$(uname -s)" == Linux ]] || { echo 'Linux builds require a Linux host.' >&2; exit 1; }
  [[ "$arch" == amd64 || "$arch" == arm64 ]] || {
    echo "Unsupported Linux architecture: $arch (supported: amd64, arm64)." >&2
    exit 1
  }
  for command in flutter go git curl cmake ninja pkg-config; do need "$command"; done
  pkg-config --exists gtk+-3.0 || {
    echo 'GTK 3 development files are required (Void: sudo xbps-install -S gtk+3-devel).' >&2
    exit 1
  }

  "$project_dir/tool/build_desktop_cores.sh" linux "$arch"
  mkdir -p "$project_dir/vendor/bin"
  install -m 0755 "$project_dir/vendor/linux/$arch/bin/xray" "$project_dir/vendor/bin/xray"
  install -m 0755 "$project_dir/vendor/linux/$arch/bin/sing-box" "$project_dir/vendor/bin/sing-box"
  install -m 0644 "$project_dir/vendor/linux/$arch/bin/BUILD-INFO.txt" "$project_dir/vendor/bin/BUILD-INFO.txt"

  cd "$project_dir"
  flutter pub get
  local ghostbox_version
  local update_branch="${GHOSTBOX_UPDATE_BRANCH:-main}"
  ghostbox_version="$(awk '/^version:/ {split($2,v,"+"); print v[1]}' pubspec.yaml)"
  flutter build linux --release \
    --dart-define="GHOSTBOX_VERSION=$ghostbox_version" \
    --dart-define="GHOSTBOX_UPDATE_BRANCH=$update_branch"

  local appdir="$project_dir/build/appimage/GhostBox.AppDir"
  local bundle_arch=x64
  local appimage_arch=x86_64
  if [[ "$arch" == arm64 ]]; then
    bundle_arch=arm64
    appimage_arch=aarch64
  fi
  local bundle="$project_dir/build/linux/$bundle_arch/release/bundle"
  local app_binary="$bundle/GhostBox"
  local appimagetool="$project_dir/.toolchains/bin/appimagetool-$appimage_arch.AppImage"
  local runtime="$project_dir/.toolchains/bin/appimage-runtime-$appimage_arch"
  local output="$project_dir/dist/GhostBox-$(awk '/^version:/ {split($2,v,"+"); print v[1]}' pubspec.yaml)-linux-$appimage_arch.AppImage"
  if [[ ! -x "$app_binary" && -x "$bundle/ghostbox" ]]; then
    app_binary="$bundle/ghostbox"
  fi
  [[ -x "$app_binary" ]] || { echo "Flutter bundle executable not found: $bundle" >&2; exit 1; }
  rm -rf "$appdir"
  mkdir -p "$appdir/vendor/bin" "$project_dir/.toolchains/bin" "$project_dir/dist"
  cp -a "$bundle/." "$appdir/"
  if [[ "$app_binary" != "$appdir/ghostbox" ]]; then
    install -m 0755 "$app_binary" "$appdir/ghostbox"
  fi
  cp "$project_dir/packaging/appimage/AppRun" "$appdir/AppRun"
  cp "$project_dir/packaging/appimage/ghostbox.desktop" "$appdir/ghostbox.desktop"
  cp "$project_dir/assets/ghostbox_logo.svg" "$appdir/ghostbox.svg"
  cp "$project_dir/assets/ghostbox_logo.png" "$appdir/ghostbox.png"
  install -m 0755 "$project_dir/vendor/bin/xray" "$appdir/vendor/bin/xray"
  install -m 0755 "$project_dir/vendor/bin/sing-box" "$appdir/vendor/bin/sing-box"
  install -m 0644 "$project_dir/vendor/bin/BUILD-INFO.txt" "$appdir/vendor/bin/BUILD-INFO.txt"
  chmod 0755 "$appdir/AppRun"

  if [[ ! -x "$appimagetool" ]]; then
    echo 'Downloading AppImage packager…'
    curl --fail --location --retry 3 \
      "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-$appimage_arch.AppImage" \
      --output "$appimagetool"
    chmod 0755 "$appimagetool"
  fi
  local runtime_sha256 runtime_url runtime_version runtime_actual_sha256
  # Pin the runtime to an immutable release. The upstream `continuous` URL
  # is replaced in place, which invalidates previously pinned hashes.
  runtime_version=20251108
  case "$appimage_arch" in
    x86_64)
      runtime_sha256=2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d
      ;;
    aarch64)
      runtime_sha256=00cbdfcf917cc6c0ff6d3347d59e0ca1f7f45a6df1a428a0d6d8a78664d87444
      ;;
  esac
  runtime_url="https://github.com/AppImage/type2-runtime/releases/download/$runtime_version/runtime-$appimage_arch"
  runtime_actual_sha256=''
  if [[ -s "$runtime" ]]; then
    runtime_actual_sha256="$(sha256sum "$runtime" | cut -d ' ' -f1)"
  fi
  if [[ "$runtime_actual_sha256" != "$runtime_sha256" ]]; then
    echo 'Downloading AppImage runtime…'
    curl --fail --location --retry 3 "$runtime_url" --output "$runtime"
  fi
  printf '%s  %s\n' "$runtime_sha256" "$runtime" | sha256sum --check --status || {
    rm -f "$runtime"
    echo 'Downloaded AppImage runtime failed SHA-256 verification.' >&2
    exit 1
  }
  chmod 0755 "$runtime"
  echo 'Packaging AppImage…'
  ARCH="$appimage_arch" APPIMAGE_EXTRACT_AND_RUN=1 \
    "$appimagetool" --runtime-file "$runtime" "$appdir" "$output"
  chmod 0755 "$output"
  sha256sum "$output" > "$output.sha256"
  echo "Built $output"

  if [[ -t 0 ]]; then
    read -r -p 'Install GhostBox into your desktop app menu? [y/N] ' answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
      "$project_dir/tool/install_appimage.sh" "$output"
      read -r -p 'Enable TUN for the bundled cores (one-time sudo setcap)? [y/N] ' tun_answer
      if [[ "$tun_answer" =~ ^[Yy]$ ]]; then
        "$project_dir/tool/setup_tun_permissions.sh" --apply
      else
        echo 'TUN permission setup later: sudo setcap cap_net_admin+ep "$HOME/.local/share/ghostbox-appimage/vendor/bin/sing-box"'
      fi
    fi
  else
    echo 'Install later with: ./tool/install_appimage.sh '"$output"
  fi
}

build_android() {
  for command in flutter go git java; do need "$command"; done
  if [[ -z "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}" ]]; then
    "$project_dir/tool/setup_android.sh"
    export ANDROID_HOME="${GHOSTBOX_ANDROID_SDK:-$project_dir/.toolchains/android-sdk}"
    export ANDROID_SDK_ROOT="$ANDROID_HOME"
  fi
  "$project_dir/tool/build_android.sh"
}

case "$target" in
  linux)
    need flutter; need go; need git
    build_linux
    ;;
  android)
    [[ "$(uname -s)" == Linux || "$(uname -s)" == Darwin ]] || { echo 'Android builds require Linux or macOS.' >&2; exit 1; }
    build_android
    ;;
  windows)
    [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* || "${OS:-}" == Windows_NT ]] || {
      echo 'Flutter Windows builds require Windows. Run: pwsh -ExecutionPolicy Bypass -File tool/build_windows.ps1' >&2
      echo 'Or run the “Build GhostBox for Windows” GitHub Actions workflow.' >&2
      exit 1
    }
    exec pwsh -ExecutionPolicy Bypass -File "$project_dir/tool/build_windows.ps1"
    ;;
  macos)
    [[ "$(uname -s)" == Darwin ]] || { echo 'macOS app builds require macOS and Xcode.' >&2; exit 1; }
    for command in flutter go git xcodebuild; do need "$command"; done
    "$project_dir/tool/build_desktop_cores.sh" macos "$arch"
    cd "$project_dir"
    flutter pub get
    flutter build macos --release
    app_dir="$project_dir/build/macos/Build/Products/Release/GhostBox.app"
    if [[ ! -d "$app_dir" ]]; then
      app_dir="$project_dir/build/macos/Build/Products/Release/Runner.app"
    fi
    "$project_dir/tool/package_macos_cores.sh" "$app_dir" "$arch"
    ;;
  ios)
    [[ "$(uname -s)" == Darwin ]] || { echo 'iOS builds require macOS and Xcode.' >&2; exit 1; }
    for command in flutter go git xcodebuild; do need "$command"; done
    "$project_dir/tool/build_mobile_cores.sh" apple
    cd "$project_dir"
    flutter pub get
    flutter build ios --no-codesign
    echo 'Built unsigned iOS app. Network Extension setup and Apple signing are still required for VPN distribution.'
    ;;
  *) echo 'Usage: ./tool/build.sh [linux|android|windows|macos|ios]' >&2; exit 2 ;;
esac
