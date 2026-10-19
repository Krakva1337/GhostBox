#!/usr/bin/env bash
# One-command entry point for the pinned cross-platform core artifacts.
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="${1:-}"

build_desktop_matrix() {
  "$project_dir/tool/build_desktop_cores.sh" windows amd64
  "$project_dir/tool/build_desktop_cores.sh" windows arm64
  "$project_dir/tool/build_desktop_cores.sh" macos amd64
  "$project_dir/tool/build_desktop_cores.sh" macos arm64
}

case "$target" in
  desktop) build_desktop_matrix ;;
  android) "$project_dir/tool/build_mobile_cores.sh" android ;;
  apple) "$project_dir/tool/build_mobile_cores.sh" apple ;;
  all)
    [[ "$(uname -s)" == Darwin ]] || {
      echo 'Run "all" on macOS for Apple XCFrameworks. On Linux run desktop and android here, then apple on a Mac.' >&2
      exit 1
    }
    build_desktop_matrix
    "$project_dir/tool/build_mobile_cores.sh" android
    "$project_dir/tool/build_mobile_cores.sh" apple
    ;;
  *) echo "Usage: $0 desktop|android|apple|all" >&2; exit 2 ;;
esac
