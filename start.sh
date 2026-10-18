#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

if [[ -x "$ROOT_DIR/.toolchains/flutter/bin/flutter" ]]; then
  export PATH="$ROOT_DIR/.toolchains/flutter/bin:$PATH"
fi

if ! command -v flutter >/dev/null 2>&1; then
  echo "Flutter не найден. Установите Flutter или положите его в .toolchains/flutter"
  exit 1
fi

if [[ ! -d "$ROOT_DIR/linux" ]]; then
  flutter create --platforms=linux .
fi

flutter pub get
exec flutter run -d linux "$@"
