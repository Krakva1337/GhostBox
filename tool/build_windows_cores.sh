#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$project_dir/tool/build_desktop_cores.sh" windows "${1:-amd64}"
