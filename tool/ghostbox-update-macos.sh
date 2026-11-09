#!/usr/bin/env bash
set -euo pipefail

# Elevated mode performs filesystem work only. The outer user process launches.
if [[ $# -gt 0 ]] && [[ "$1" == --swap-worker ]]; then
  [[ $# -eq 6 ]] || exit 2
  source_app="$2"
  destination="$3"
  backup="$4"
  handoff="$5"
  staged="$destination.new.$6"
  had_previous=0
  swapped=0
  rollback() {
    status=$?
    trap - EXIT
    if [[ "$swapped" -eq 1 ]]; then
      /bin/rm -rf -- "$destination"
      if [[ "$had_previous" -eq 1 ]]; then /bin/mv -- "$backup" "$destination"; fi
    elif [[ "$had_previous" -eq 1 && -d "$backup" && ! -e "$destination" ]]; then
      /bin/mv -- "$backup" "$destination"
    fi
    /bin/rm -rf -- "$staged"
    /usr/bin/touch "$handoff/restored"
    exit "$status"
  }
  trap rollback EXIT
  [[ "$destination" == /Applications/GhostBox.app && ! -e "$backup" && ! -e "$staged" ]] || exit 1
  /usr/bin/ditto "$source_app" "$staged"
  if [[ -e "$destination" ]]; then
    /bin/mv -- "$destination" "$backup"
    had_previous=1
  fi
  /bin/mv -- "$staged" "$destination"
  swapped=1
  /usr/bin/touch "$handoff/swapped"
  # First-frame acknowledgement plus user-session PID check precede cleanup.
  for ((attempt=0; attempt<300; attempt++)); do
    if [[ -f "$handoff/confirmed" ]]; then
      # Confirmation commits the new version. Backup cleanup failure must not
      # remove a successfully launched app after part of its backup was deleted.
      swapped=0
      trap - EXIT
      if [[ "$had_previous" -eq 1 ]]; then /bin/rm -rf -- "$backup" || true; fi
      /usr/bin/touch "$handoff/committed"
      exit 0
    fi
    [[ ! -f "$handoff/failed" ]] || exit 1
    /bin/sleep 0.25
  done
  exit 1
fi

if [[ $# -ne 4 ]]; then
  echo "Usage: $0 UPDATE.zip OLD_PID /Applications/GhostBox.app HANDOFF_DIR" >&2
  exit 2
fi

archive="$1"
old_pid="$2"
destination="$3"
handoff="$4"
[[ "$old_pid" =~ ^[1-9][0-9]*$ && -d "$handoff" ]] || exit 2
exec >>"$handoff/installer.log" 2>&1
backup="/Applications/.GhostBox.app.old.$old_pid"
helper="$handoff/ghostbox-update-macos.sh"
worker_pid=''
success=0
failure() {
  status=$?
  trap - EXIT
  if [[ "$success" -ne 1 ]]; then
    /bin/echo 'Установка не завершена. Предыдущая версия сохранена; см. installer.log.' > "$handoff/error"
    /usr/bin/touch "$handoff/failed"
    if [[ -n "$worker_pid" ]]; then
      if [[ -f "$handoff/swapped" && ! -f "$handoff/committed" ]]; then
        /usr/bin/pkill -TERM -u "$(/usr/bin/id -u)" -f '^/Applications/GhostBox\.app/Contents/MacOS/(GhostBox|Runner)( |$)' || true
      fi
      wait "$worker_pid" || true
      if [[ -d "$destination" && ( -f "$handoff/restored" || ! -f "$handoff/swapped" ) ]]; then
        /usr/bin/open -a "$destination" || true
      fi
    fi
  fi
  exit "$status"
}
trap failure EXIT
[[ -f "$archive" && "$destination" == /Applications/GhostBox.app ]] || exit 1
[[ ! -e "$backup" ]] || { echo 'A previous update backup needs recovery.'; exit 1; }

extracted="$handoff/extracted"
/bin/mkdir -m 0700 "$extracted"
/usr/bin/unzip -Z1 "$archive" > "$handoff/archive-entries"
if /usr/bin/awk '/^\// || /(^|\/)\.\.(\/|$)/ { bad=1 } END { exit !bad }' "$handoff/archive-entries"; then
  echo 'Unsafe archive entry path.'
  exit 1
fi
/usr/bin/ditto -x -k "$archive" "$extracted"
new_app="$(/usr/bin/find "$extracted" -type d -name '*.app' -prune -print -quit)"
[[ -n "$new_app" && ! -L "$new_app" ]] || { echo 'Update archive has no app bundle.'; exit 1; }
executable="$new_app/Contents/MacOS/GhostBox"
if [[ ! -x "$executable" ]]; then executable="$new_app/Contents/MacOS/Runner"; fi
[[ -x "$executable" && ! -L "$executable" ]] || { echo 'No executable in app bundle.'; exit 1; }
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$new_app/Contents/Info.plist")"
[[ "$bundle_id" == app.ghostbox.ghostbox ]] || { echo 'Unexpected bundle identifier.'; exit 1; }
/usr/bin/codesign --verify --deep --strict "$new_app"
arch="$(/usr/bin/uname -m)"
if [[ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || true)" == 1 ]]; then arch=arm64; fi
/usr/bin/lipo -verify_arch "$arch" "$executable"
for core in xray sing-box; do
  [[ -x "$new_app/Contents/MacOS/vendor/bin/$core" ]] || { echo "Missing bundled $core."; exit 1; }
  /usr/bin/lipo -verify_arch "$arch" "$new_app/Contents/MacOS/vendor/bin/$core"
done
[[ ! -f "$handoff/cancelled" ]] || exit 1
/usr/bin/touch "$handoff/ready"
for ((attempt=0; attempt<300; attempt++)); do
  [[ ! -f "$handoff/cancelled" ]] || exit 1
  if ! /bin/kill -0 "$old_pid" 2>/dev/null; then break; fi
  /bin/sleep 0.25
done
if /bin/kill -0 "$old_pid" 2>/dev/null; then echo 'Old application did not exit.'; exit 1; fi

run_worker() {
  trap - EXIT
  set +e
  if [[ -w /Applications ]]; then
    /bin/bash "$helper" --swap-worker "$new_app" "$destination" "$backup" "$handoff" "$old_pid"
  else
    /usr/bin/osascript - "$helper" "$new_app" "$destination" "$backup" "$handoff" "$old_pid" <<'APPLESCRIPT'
on run argv
  set commandText to "/bin/bash " & quoted form of (item 1 of argv) & " --swap-worker " & quoted form of (item 2 of argv) & " " & quoted form of (item 3 of argv) & " " & quoted form of (item 4 of argv) & " " & quoted form of (item 5 of argv) & " " & quoted form of (item 6 of argv)
  do shell script commandText with administrator privileges
end run
APPLESCRIPT
  fi
  worker_status=$?
  /bin/echo "$worker_status" > "$handoff/worker-exit"
}
run_worker &
worker_pid=$!
for ((attempt=0; attempt<600; attempt++)); do
  [[ ! -f "$handoff/swapped" ]] || break
  [[ ! -f "$handoff/worker-exit" ]] || { echo 'Bundle swap worker stopped.'; exit 1; }
  /bin/sleep 0.25
done
[[ -f "$handoff/swapped" ]] || { echo 'Bundle swap timed out.'; exit 1; }
/usr/bin/open -n -a "$destination" --args --ghostbox-updated "$handoff"
for ((attempt=0; attempt<160; attempt++)); do
  [[ ! -f "$handoff/started" ]] || break
  [[ ! -f "$handoff/worker-exit" ]] || { echo 'Startup was rolled back.'; exit 1; }
  /bin/sleep 0.25
done
[[ -f "$handoff/started" ]] || { echo 'New application did not acknowledge startup.'; exit 1; }
new_pid="$(/bin/cat "$handoff/started")"
[[ "$new_pid" =~ ^[1-9][0-9]*$ ]] || exit 1
/bin/sleep 2
/bin/kill -0 "$new_pid"
/usr/bin/touch "$handoff/confirmed"
wait "$worker_pid"
[[ "$(/bin/cat "$handoff/worker-exit")" == 0 ]] || exit 1
[[ -f "$handoff/committed" ]] || exit 1
success=1
/bin/rm -f -- "$archive"
case "$(/usr/bin/basename "$(/usr/bin/dirname "$archive")")" in
  ghostbox-download-*) /bin/rmdir -- "$(/usr/bin/dirname "$archive")" 2>/dev/null || true ;;
esac
/bin/rm -rf -- "$handoff"
trap - EXIT
