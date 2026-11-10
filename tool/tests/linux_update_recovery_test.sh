#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
HELPER="$ROOT/tool/ghostbox-update.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

prepare_transaction() {
  local name="$1" outcome="$2"
  local home="$TEST_ROOT/$name"
  local app="$home/.local/opt/ghostbox"
  local state="$home/.local/state/ghostbox/updates/$name"
  mkdir -p "$app/releases/old" "$app/releases/new" "$state" "$app/.update-$name/staging"
  printf 'old image' > "$app/.update-$name/old-GhostBox.AppImage"
  printf 'new image' > "$app/GhostBox.AppImage"
  ln -s "$app/releases/new" "$app/AppDir"
  printf '%s\n' "$app/releases/old" > "$state/old-appdir"
  printf '%s\n' "$app/.update-$name/old-GhostBox.AppImage" > "$state/old-appimage"
  printf '%s\n' "$app/.update-$name/staging" > "$state/staging-path"
  printf '%s\n' "$app/releases/new" > "$state/new-release"
  printf '%s\n' 'abc123' > "$state/new-hash"
  printf '%s\n' '2.1.0' > "$state/version"
  printf '{"id":"%s","platform":"linux","status":"HEALTH_CHECK","currentVersion":"2.0.0","targetVersion":"2.1.0"}\n' "$name" > "$state/update_transaction.json"
  : > "$state/installing"
  : > "$state/health-check"
  case "$outcome" in
    confirmed) : > "$state/confirmed" ;;
    failed) : > "$state/failed" ;;
    interrupted) ;;
  esac
  printf '%s\n' "$home" "$app" "$state"
}

assert_status() {
  local file="$1" expected="$2"
  python3 - "$file" "$expected" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as f: data = json.load(f)
assert data['status'] == sys.argv[2], (data['status'], sys.argv[2])
PY
}

mapfile -t success < <(prepare_transaction successful confirmed)
HOME="${success[0]}" XDG_STATE_HOME="${success[0]}/.local/state" "$HELPER" --recover
assert_status "${success[2]}/update_transaction.json" COMMIT
[[ "$(readlink -f -- "${success[1]}/AppDir")" == "${success[1]}/releases/new" ]]
[[ "$(cat "${success[1]}/GhostBox.AppImage")" == 'new image' ]]
[[ ! -e "${success[1]}/.update-successful/old-GhostBox.AppImage" ]]

mapfile -t failure < <(prepare_transaction failurecase failed)
HOME="${failure[0]}" XDG_STATE_HOME="${failure[0]}/.local/state" "$HELPER" --recover
assert_status "${failure[2]}/update_transaction.json" RESTORE_OLD
[[ "$(readlink -f -- "${failure[1]}/AppDir")" == "${failure[1]}/releases/old" ]]
[[ "$(cat "${failure[1]}/GhostBox.AppImage")" == 'old image' ]]

mapfile -t interrupted < <(prepare_transaction interrupted interrupted)
HOME="${interrupted[0]}" XDG_STATE_HOME="${interrupted[0]}/.local/state" "$HELPER" --recover
assert_status "${interrupted[2]}/update_transaction.json" RESTORE_OLD
[[ "$(readlink -f -- "${interrupted[1]}/AppDir")" == "${interrupted[1]}/releases/old" ]]
[[ "$(cat "${interrupted[1]}/GhostBox.AppImage")" == 'old image' ]]

mapfile -t staging < <(prepare_transaction stagingcase interrupted)
ln -sfn "${staging[1]}/releases/old" "${staging[1]}/AppDir"
printf 'old image' > "${staging[1]}/GhostBox.AppImage"
rm -f "${staging[1]}/.update-stagingcase/old-GhostBox.AppImage"
rm -f "${staging[2]}/installing" "${staging[2]}/health-check"
rm -f "${staging[2]}/confirmed" "${staging[2]}/failed"
sed -i 's/HEALTH_CHECK/STAGING/' "${staging[2]}/update_transaction.json"
HOME="${staging[0]}" XDG_STATE_HOME="${staging[0]}/.local/state" "$HELPER" --recover
assert_status "${staging[2]}/update_transaction.json" FAILED
[[ "$(readlink -f -- "${staging[1]}/AppDir")" == "${staging[1]}/releases/old" ]]
[[ "$(cat "${staging[1]}/GhostBox.AppImage")" == 'old image' ]]
[[ ! -e "${staging[1]}/.update-stagingcase" ]]

printf 'Linux updater recovery cases passed.\n'
