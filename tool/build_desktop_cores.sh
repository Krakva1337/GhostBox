#!/usr/bin/env bash
# Build pinned Xray and sing-box CLI cores for Windows or macOS.
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="${1:-}"
arch="${2:-amd64}"
xray_version="${GHOSTBOX_XRAY_VERSION:-v1.260327.0}"
sing_box_version="${GHOSTBOX_SING_BOX_VERSION:-v1.14.3}"

case "$target" in
  windows) goos=windows; extension=.exe; output_dir="$project_dir/vendor/windows/$arch/bin" ;;
  macos) goos=darwin; extension=; output_dir="$project_dir/vendor/macos/$arch/bin" ;;
  *) echo "Usage: $0 windows|macos [amd64|arm64]" >&2; exit 2 ;;
esac
case "$arch" in amd64|arm64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 2 ;; esac
command -v go >/dev/null || { echo 'Go is required.' >&2; exit 1; }

go mod download "github.com/xtls/xray-core@$xray_version"
go mod download "github.com/sagernet/sing-box@$sing_box_version"
module_cache="$(go env GOMODCACHE)"
xray_source="$module_cache/github.com/xtls/xray-core@$xray_version"
sing_box_source="$module_cache/github.com/sagernet/sing-box@$sing_box_version"
mkdir -p "$output_dir"

echo "Building Xray $xray_version for $goos/$arch"
(cd "$xray_source" && GOOS="$goos" GOARCH="$arch" CGO_ENABLED=0 \
  go build -trimpath -buildvcs=false -ldflags='-s -w -buildid=' \
  -o "$output_dir/xray$extension" ./main)

echo "Building sing-box $sing_box_version for $goos/$arch"
(cd "$sing_box_source" && GOOS="$goos" GOARCH="$arch" CGO_ENABLED=0 \
  go build -tags='with_quic,with_utls' -trimpath -buildvcs=false \
  -ldflags='-s -w -buildid=' -o "$output_dir/sing-box$extension" ./cmd/sing-box)

cat > "$output_dir/BUILD-INFO.txt" <<EOF
GhostBox desktop cores
Xray: $xray_version
sing-box: $sing_box_version
Target: $goos/$arch
sing-box tags: with_quic,with_utls
EOF
echo "Built cores: $output_dir"
