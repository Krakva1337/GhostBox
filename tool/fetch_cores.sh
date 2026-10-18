#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$root/vendor/bin" "$root/vendor/src"
echo 'Building xray-core...'
go install github.com/xtls/xray-core/main@latest
cp "$(go env GOPATH)/bin/main" "$root/vendor/bin/xray" 2>/dev/null || true
echo 'Building sing-box...'
go install -tags with_quic github.com/sagernet/sing-box/cmd/sing-box@latest
cp "$(go env GOPATH)/bin/sing-box" "$root/vendor/bin/sing-box" 2>/dev/null || true
echo 'Done.'

