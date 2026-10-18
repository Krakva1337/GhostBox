#!/usr/bin/env bash
# Build pinned official sources on Linux/macOS for the Windows x64 bundle.
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="$project_dir/vendor/windows/bin"
mkdir -p "$output_dir"
# GOBIN cannot be used with cross-compilation; resolve pinned source modules first.
go mod download github.com/xtls/xray-core@v1.260327.0
go mod download github.com/sagernet/sing-box@v1.14.3
module_cache="$(go env GOMODCACHE)"
(
  cd "$module_cache/github.com/xtls/xray-core@v1.260327.0"
  GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o "$output_dir/xray.exe" ./main
)
(
  cd "$module_cache/github.com/sagernet/sing-box@v1.14.3"
  GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -tags 'with_quic,with_utls' -trimpath -ldflags='-s -w' -o "$output_dir/sing-box.exe" ./cmd/sing-box
)
printf 'Windows x64 cores: %s\n' "$output_dir"
