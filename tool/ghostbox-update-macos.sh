#!/usr/bin/env bash
set -euo pipefail

# This script is copied into a durable, user-owned handoff directory before it
# is started. It can therefore finish after GhostBox's own bundle is replaced.
# The privileged worker only swaps one validated app bundle and never launches
# an app or removes user data.

write_transaction() {
  local state="$1" detail="${2:-}"
  local temp="$handoff/update_transaction.json.tmp"
  json_escape() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    printf '%s' "$value"
  }
  {
    printf '{\n'
    printf '  "schemaVersion": 1,\n'
    printf '  "id": "%s",\n' "$(json_escape "$transaction_id")"
    printf '  "transactionId": "%s",\n' "$(json_escape "$transaction_id")"
    printf '  "platform": "macos",\n'
    printf '  "status": "%s",\n' "$(json_escape "$state")"
    printf '  "oldVersion": "%s",\n' "$(json_escape "${old_version:-}")"
    printf '  "currentVersion": "%s",\n' "$(json_escape "${old_version:-}")"
    printf '  "newVersion": "%s",\n' "$(json_escape "${new_version:-}")"
    printf '  "targetVersion": "%s",\n' "$(json_escape "${target_version:-${new_version:-}}")"
    printf '  "assetName": "%s",\n' "$(json_escape "${asset_name:-}")"
    printf '  "packagePath": "%s",\n' "$(json_escape "${archive:-}")"
    printf '  "archivePath": "%s",\n' "$(json_escape "${archive:-}")"
    printf '  "installPath": "%s",\n' "$(json_escape "${destination:-}")"
    printf '  "backupPath": "%s",\n' "$(json_escape "${backup:-}")"
    printf '  "updaterPid": "%s",\n' "$(json_escape "${updater_pid:-}")"
    printf '  "updaterStartedAt": "%s",\n' "$(json_escape "${updater_started_at:-}")"
    printf '  "sha256": "%s",\n' "$(json_escape "${archive_sha256:-}")"
    printf '  "updatedAt": "%s",\n' "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '  "detail": "%s"\n' "$(json_escape "$detail")"
    printf '}\n'
  } > "$temp"
  /bin/mv -f -- "$temp" "$handoff/update_transaction.json"
}

set_state() {
  local state="$1" detail="${2:-}"
  write_transaction "$state" "$detail"
  /usr/bin/touch "$handoff/state-$state"
}

process_state() {
  local pid="$1" executable="$2" expected_start="${3:-}" mapped current_start
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 2
  /bin/kill -0 "$pid" 2>/dev/null || return 1
  mapped="$(/usr/sbin/lsof -a -p "$pid" -d txt -Fn 2>/dev/null || true)"
  [[ -n "$mapped" ]] || return 2
  if [[ -n "$expected_start" ]]; then
    current_start="$(/bin/ps -o lstart= -p "$pid" 2>/dev/null | /usr/bin/sed 's/^ *//')"
    [[ "$current_start" == "$expected_start" ]] || return 2
  fi
  /usr/bin/awk -v expected="$executable" 'substr($0,1,1)=="n" && substr($0,2)==expected { found=1 } END { exit !found }' <<< "$mapped" && return 0
  return 2
}

is_supported_privileged_destination() {
  [[ "$1" == "/Applications/GhostBox.app" ]]
}

rollback_worker() {
  local status=$?
  /usr/bin/touch "$handoff/state-ROLLBACK"
  if [[ "${swapped:-0}" -eq 1 ]]; then
    # Do not recursively delete anything that has changed since our own swap.
    if [[ -d "$destination" && ! -L "$destination" ]]; then
      /bin/mv -- "$destination" "$handoff/failed-install.$transaction_id" 2>/dev/null || true
    fi
    if [[ "${had_previous:-0}" -eq 1 && -d "$backup" && ! -e "$destination" ]]; then
      /bin/mv -- "$backup" "$destination" || true
    fi
  elif [[ "${had_previous:-0}" -eq 1 && -d "$backup" && ! -e "$destination" ]]; then
    /bin/mv -- "$backup" "$destination" || true
  fi
  /bin/rm -rf -- "$staged" 2>/dev/null || true
  /usr/bin/touch "$handoff/restored"
  set_state RESTORE_OLD "Installation failed; the prior bundle was restored."
  exit "$status"
}

recover_transaction() {
  local directory="$1" txid="$2" user_home="$3" transaction_file status agent_file uid_value completed=0
  [[ "$txid" =~ ^[A-Fa-f0-9-]{16,64}$ && -d "$directory" ]] || exit 2
  transaction_file="$directory/update_transaction.json"
  [[ -f "$transaction_file" && ! -L "$transaction_file" ]] || exit 1
  transaction_id="$(/usr/bin/plutil -extract transactionId raw -o - "$transaction_file")"
  [[ "$transaction_id" == "$txid" ]] || exit 1
  destination="$(/usr/bin/plutil -extract installPath raw -o - "$transaction_file")"
  backup="$(/usr/bin/plutil -extract backupPath raw -o - "$transaction_file")"
  status="$(/usr/bin/plutil -extract status raw -o - "$transaction_file" 2>/dev/null || true)"
  updater_pid="$(/usr/bin/plutil -extract updaterPid raw -o - "$transaction_file" 2>/dev/null || true)"
  updater_started_at="$(/usr/bin/plutil -extract updaterStartedAt raw -o - "$transaction_file" 2>/dev/null || true)"
  if [[ "$updater_pid" =~ ^[1-9][0-9]*$ ]] && /bin/kill -0 "$updater_pid" 2>/dev/null; then
    current_start="$(/bin/ps -o lstart= -p "$updater_pid" 2>/dev/null | /usr/bin/sed 's/^ *//')"
    if [[ -n "$current_start" && "$current_start" == "$updater_started_at" ]]; then
      return 0
    fi
  fi
  updater_pid=''
  updater_started_at=''
  [[ "$destination" == */GhostBox.app && "$backup" == "$(/usr/bin/dirname -- "$destination")/.GhostBox.app.old.$txid" ]] || exit 1
  handoff="$directory"
  staged="$destination.new.$txid"
  archive="$(/usr/bin/plutil -extract archivePath raw -o - "$transaction_file" 2>/dev/null || true)"
  [[ -n "$archive" ]] || archive="$(/usr/bin/plutil -extract packagePath raw -o - "$transaction_file" 2>/dev/null || true)"
  old_version="$(/usr/bin/plutil -extract oldVersion raw -o - "$transaction_file" 2>/dev/null || true)"
  [[ -n "$old_version" ]] || old_version="$(/usr/bin/plutil -extract currentVersion raw -o - "$transaction_file" 2>/dev/null || true)"
  new_version="$(/usr/bin/plutil -extract newVersion raw -o - "$transaction_file" 2>/dev/null || true)"
  target_version="$(/usr/bin/plutil -extract targetVersion raw -o - "$transaction_file" 2>/dev/null || true)"
  asset_name="$(/usr/bin/plutil -extract assetName raw -o - "$transaction_file" 2>/dev/null || true)"
  archive_sha256="$(/usr/bin/plutil -extract sha256 raw -o - "$transaction_file" 2>/dev/null || true)"
  if [[ ! -w "$(/usr/bin/dirname -- "$destination")" ]]; then
    is_supported_privileged_destination "$destination" || {
      echo 'Administrator access is only supported for /Applications/GhostBox.app.' >&2
      exit 1
    }
    /usr/bin/osascript - "$0" "$directory" "$txid" "$user_home" <<'APPLESCRIPT'
on run argv
  set commandText to "/bin/bash " & quoted form of (item 1 of argv) & " --recover " & quoted form of (item 2 of argv) & " " & quoted form of (item 3 of argv) & " " & quoted form of (item 4 of argv)
  do shell script commandText with administrator privileges
end run
APPLESCRIPT
    return
  fi
  if [[ "$status" == COMMIT || "$status" == CLEANUP ]]; then
    /bin/rm -rf -- "$backup" "$staged" 2>/dev/null || true
    completed=1
  elif [[ -d "$backup" && ! -L "$backup" ]]; then
    /usr/bin/touch "$handoff/state-ROLLBACK"
    if [[ -e "$destination" ]]; then
      /bin/mv -- "$destination" "$handoff/failed-install.$txid"
    fi
    /bin/mv -- "$backup" "$destination"
    /usr/bin/touch "$handoff/restored"
    set_state RESTORE_OLD "Recovered the previous app after an interrupted update."
    completed=1
  elif [[ ! -e "$destination" ]]; then
    echo 'Recovery could not find either the installed app or its backup.' >&2
    exit 1
  else
    # The original app is still in place, so interruption happened before the
    # rename. Clear the stale transaction lock and allow another retry.
    if [[ -d "$staged" && ! -L "$staged" ]]; then /bin/rm -rf -- "$staged"; fi
    set_state RESTORE_OLD "The original application was intact; no bundle swap had occurred."
    completed=1
  fi
  uid_value="$(/usr/bin/stat -f '%u' "$user_home")"
  agent_file="$user_home/Library/LaunchAgents/app.ghostbox.update-recovery.$txid.plist"
  if [[ "$completed" -eq 1 ]]; then
    /bin/rm -f -- "$agent_file"
    /bin/launchctl bootout "gui/$uid_value" "$agent_file" >/dev/null 2>&1 || true
    lock_dir="$user_home/Library/Application Support/GhostBox/update.lock"
    if [[ -d "$lock_dir" && "$(/bin/cat "$lock_dir/transaction-id" 2>/dev/null || true)" == "$txid" ]]; then
      /bin/rm -rf -- "$lock_dir"
    fi
  fi
}

install_recovery_agent() {
  local agent_file="$HOME/Library/LaunchAgents/app.ghostbox.update-recovery.$transaction_id.plist"
  local uid_value
  /bin/mkdir -p "$HOME/Library/LaunchAgents"
  [[ ! -e "$agent_file" && ! -L "$agent_file" ]] || return 1
  /usr/bin/plutil -create xml1 "$agent_file"
  /usr/bin/plutil -insert Label -string "app.ghostbox.update-recovery.$transaction_id" "$agent_file"
  /usr/bin/plutil -insert ProgramArguments -array "$agent_file"
  /usr/bin/plutil -insert ProgramArguments.0 -string "$helper" "$agent_file"
  /usr/bin/plutil -insert ProgramArguments.1 -string --recover "$agent_file"
  /usr/bin/plutil -insert ProgramArguments.2 -string "$handoff" "$agent_file"
  /usr/bin/plutil -insert ProgramArguments.3 -string "$transaction_id" "$agent_file"
  /usr/bin/plutil -insert ProgramArguments.4 -string "$HOME" "$agent_file"
  /usr/bin/plutil -insert RunAtLoad -bool YES "$agent_file"
  /bin/chmod 0600 "$agent_file"
  uid_value="$(/usr/bin/id -u)"
  # Loading may execute recovery immediately, before swap; it safely exits when
  # there is no backup. The persisted plist runs again on the next login.
  /bin/launchctl bootstrap "gui/$uid_value" "$agent_file" >/dev/null 2>&1 || true
}

if [[ "${1:-}" == --recover ]]; then
  [[ $# -eq 4 ]] || exit 2
  recover_transaction "$2" "$3" "$4"
  exit 0
fi

if [[ "${1:-}" == --swap-worker ]]; then
  [[ $# -eq 11 ]] || exit 2
  source_app="$2"
  destination="$3"
  backup="$4"
  handoff="$5"
  transaction_id="$6"
  expected_team="$7"
  old_version="$8"
  new_version="$9"
  archive="${10}"
  archive_sha256="${11}"
  updater_pid="$(/usr/bin/plutil -extract updaterPid raw -o - "$handoff/update_transaction.json" 2>/dev/null || true)"
  updater_started_at="$(/usr/bin/plutil -extract updaterStartedAt raw -o - "$handoff/update_transaction.json" 2>/dev/null || true)"
  staged="$destination.new.$transaction_id"
  had_previous=0
  swapped=0
  [[ -d "$handoff" && "$transaction_id" =~ ^[A-Fa-f0-9-]{16,64}$ ]] || exit 2
  [[ "$destination" == */GhostBox.app && ! -L "$destination" ]] || exit 1
  [[ ! -e "$backup" && ! -e "$staged" ]] || exit 1
  trap rollback_worker EXIT
  /usr/bin/ditto "$source_app" "$staged"
  /usr/bin/codesign --verify --deep --strict "$staged"
  if [[ -n "$expected_team" ]]; then
    new_team="$(/usr/bin/codesign -dv --verbose=4 "$staged" 2>&1 | /usr/bin/awk -F= '/^TeamIdentifier=/ {print $2; exit}')"
    [[ -n "$new_team" && "$new_team" == "$expected_team" ]] || {
      echo 'The update signing team does not match the installed application.' >&2
      exit 1
    }
  fi
  if [[ -e "$destination" ]]; then
    /bin/mv -- "$destination" "$backup"
    had_previous=1
  fi
  /bin/mv -- "$staged" "$destination"
  swapped=1
  set_state RELAUNCHING
  /usr/bin/touch "$handoff/swapped"
  set_state HEALTH_CHECK
  for ((attempt=0; attempt<480; attempt++)); do
    if [[ -f "$handoff/confirmed" ]]; then
      # Commit only after the new Flutter client acknowledges readiness.
      set_state COMMIT
      swapped=0
      trap - EXIT
      if [[ "$had_previous" -eq 1 ]]; then
        /bin/rm -rf -- "$backup" || echo 'Backup cleanup deferred.' >&2
      fi
      /usr/bin/touch "$handoff/committed"
      set_state CLEANUP
      exit 0
    fi
    [[ ! -f "$handoff/failed" ]] || exit 1
    /bin/sleep 0.25
  done
  echo 'New GhostBox did not confirm startup.' >&2
  exit 1
fi

usage() { echo "Usage: $0 UPDATE.zip OLD_PID /path/to/GhostBox.app HANDOFF_DIR [TRANSACTION_ID]" >&2; }
if [[ $# -lt 4 || $# -gt 5 ]]; then usage; exit 2; fi

archive="$1"
old_pid="$2"
destination="$3"
handoff="$4"
[[ "$old_pid" =~ ^[1-9][0-9]*$ && -f "$archive" && -d "$handoff" ]] || exit 2
transaction_id="${5:-$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')}"
[[ "$transaction_id" =~ ^[a-f0-9-]{36}$ ]] || exit 1
transaction_file="$handoff/update_transaction.json"
asset_name=''
target_version=''
if [[ -f "$transaction_file" ]]; then
  saved_id="$(/usr/bin/plutil -extract id raw -o - "$transaction_file" 2>/dev/null || true)"
  [[ -n "$saved_id" ]] || saved_id="$(/usr/bin/plutil -extract transactionId raw -o - "$transaction_file" 2>/dev/null || true)"
  [[ -z "$saved_id" || "$saved_id" == "$transaction_id" ]] || {
    echo 'Transaction ID does not match the persistent update record.'; exit 1;
  }
  asset_name="$(/usr/bin/plutil -extract assetName raw -o - "$transaction_file" 2>/dev/null || true)"
  target_version="$(/usr/bin/plutil -extract targetVersion raw -o - "$transaction_file" 2>/dev/null || true)"
fi
destination_parent="$(cd -- "$(/usr/bin/dirname -- "$destination")" && /bin/pwd -P)"
destination="$destination_parent/$(/usr/bin/basename -- "$destination")"
[[ "$destination" == */GhostBox.app && ! -L "$destination" ]] || {
  echo 'GhostBox.app path is invalid or is a symbolic link.' >&2; exit 1;
}
case "$destination" in
  /Volumes/*)
    echo 'GhostBox cannot update from a read-only DMG. Copy it to Applications first.' > "$handoff/error"
    /usr/bin/touch "$handoff/failed"
    exit 1
    ;;
esac
lock_dir="$HOME/Library/Application Support/GhostBox/update.lock"
/bin/mkdir -p "$(/usr/bin/dirname -- "$lock_dir")"
if ! /bin/mkdir "$lock_dir" 2>/dev/null; then
  echo 'Another update is active or interrupted recovery is required.' > "$handoff/error"
  /usr/bin/touch "$handoff/failed"
  exit 1
fi
printf '%s\n' "$transaction_id" > "$lock_dir/transaction-id"
lock_owned=1
exec >>"$handoff/installer.log" 2>&1
backup="${destination_parent}/.GhostBox.app.old.${transaction_id}"
helper="$handoff/ghostbox-update-macos.sh"
staged="${destination}.new.${transaction_id}"
old_version=''
new_version=''
archive_sha256=''
expected_team=''
worker_pid=''
success=0
updater_pid="$$"
updater_started_at="$(/bin/ps -o lstart= -p "$$" | /usr/bin/sed 's/^ *//')"

failure() {
  local status=$?
  trap - EXIT
  if [[ "$success" -ne 1 ]]; then
    echo 'Update failed. Recovery details are in update_transaction.json and installer.log.' > "$handoff/error"
    /usr/bin/touch "$handoff/failed"
    set_state FAILED "Updater exited with status $status."
    if [[ -n "$worker_pid" ]]; then wait "$worker_pid" || true; fi
    if [[ -d "$destination" && ( -f "$handoff/restored" || ! -f "$handoff/swapped" ) ]]; then
      /usr/bin/open -a "$destination" || true
    fi
    if [[ -f "$handoff/restored" ]]; then
      set_state RESTORE_OLD "The previous application was restored."
    fi
    if [[ "${lock_owned:-0}" -eq 1 && "$(/bin/cat "$lock_dir/transaction-id" 2>/dev/null || true)" == "$transaction_id" ]]; then
      /bin/rm -rf -- "$lock_dir"
    fi
  fi
  exit "$status"
}
trap failure EXIT

set_state CHECKING
install_recovery_agent

[[ -x "$destination/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$destination/Contents/Info.plist" 2>/dev/null)" ]] || {
  echo 'The running GhostBox app bundle is incomplete.'; exit 1;
}
[[ ! -e "$backup" && ! -e "$staged" ]] || { echo 'A prior update needs recovery before retrying.'; exit 1; }
current_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist")"
[[ "$current_id" == app.ghostbox.ghostbox ]] || { echo 'Unexpected installed bundle identifier.'; exit 1; }
old_executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$destination/Contents/Info.plist")"
old_executable="$destination/Contents/MacOS/$old_executable_name"
old_process_start="$(/bin/ps -o lstart= -p "$old_pid" 2>/dev/null | /usr/bin/sed 's/^ *//')"
[[ -n "$old_process_start" ]] || { echo 'Could not establish the original GhostBox process identity.'; exit 1; }
old_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$destination/Contents/Info.plist" 2>/dev/null || true)"
if /usr/bin/codesign -dv --verbose=4 "$destination" >/dev/null 2>&1; then
  expected_team="$(/usr/bin/codesign -dv --verbose=4 "$destination" 2>&1 | /usr/bin/awk -F= '/^TeamIdentifier=/ {print $2; exit}')"
fi

set_state VERIFYING
archive_sha256="$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')"
[[ "$archive_sha256" =~ ^[a-f0-9]{64}$ ]] || { echo 'Could not compute archive SHA-256.'; exit 1; }
extracted="$handoff/extracted"
/bin/mkdir -m 0700 "$extracted"
/usr/bin/unzip -Z1 "$archive" > "$handoff/archive-entries"
if /usr/bin/awk '/^\// || /(^|\/)\.\.(\/|$)/ { bad=1 } END { exit !bad }' "$handoff/archive-entries"; then
  echo 'Unsafe archive entry path.'; exit 1
fi
/usr/bin/ditto -x -k "$archive" "$extracted"
new_app="$(/usr/bin/find "$extracted" -type d -name '*.app' -prune -print -quit)"
[[ -n "$new_app" && ! -L "$new_app" ]] || { echo 'Update archive has no app bundle.'; exit 1; }
new_executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$new_app/Contents/Info.plist")"
executable="$new_app/Contents/MacOS/$new_executable_name"
[[ -x "$executable" && ! -L "$executable" ]] || { echo 'No executable in app bundle.'; exit 1; }
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$new_app/Contents/Info.plist")"
[[ "$bundle_id" == "$current_id" ]] || { echo 'Unexpected update bundle identifier.'; exit 1; }
new_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$new_app/Contents/Info.plist")"
if [[ -n "$target_version" && "$target_version" != "$new_version" ]]; then
  echo "Staged app version $new_version does not match requested $target_version."; exit 1
fi
/usr/bin/codesign --verify --deep --strict "$new_app"
if [[ -n "$expected_team" ]]; then
  new_team="$(/usr/bin/codesign -dv --verbose=4 "$new_app" 2>&1 | /usr/bin/awk -F= '/^TeamIdentifier=/ {print $2; exit}')"
  [[ -n "$new_team" && "$new_team" == "$expected_team" ]] || { echo 'Update signing team does not match.'; exit 1; }
fi
if [[ -n "$expected_team" ]]; then
  /usr/sbin/spctl --assess --type execute --verbose=2 "$new_app"
fi
arch=x86_64
if [[ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || true)" == 1 ]]; then arch=arm64; fi
/usr/bin/lipo -verify_arch "$arch" "$executable"
for core in xray sing-box; do
  core_path="$new_app/Contents/MacOS/vendor/bin/$core"
  [[ -x "$core_path" && ! -L "$core_path" ]] || { echo "Missing bundled $core."; exit 1; }
  /usr/bin/lipo -verify_arch "$arch" "$core_path"
done
write_transaction VERIFYING
set_state STAGING

# The Dart updater copied this independent helper into the durable transaction
# directory before starting it. Keep the helper and transaction directory
# outside the app bundle so replacing the bundle cannot remove the updater.
[[ "$0" == "$helper" && -f "$helper" ]] || { echo 'Independent update helper is missing.'; exit 1; }
/bin/chmod 0700 "$helper"
/usr/bin/touch "$handoff/ready"
set_state STOPPING
for ((attempt=0; attempt<240; attempt++)); do
  process_state "$old_pid" "$old_executable" "$old_process_start" || {
    process_result=$?
    [[ "$process_result" -eq 1 ]] && break
    echo 'The supplied PID no longer identifies this GhostBox process.'
    exit 1
  }
  /bin/sleep 0.25
done
if process_state "$old_pid" "$old_executable" "$old_process_start"; then
  echo 'Old GhostBox did not exit.'; exit 1
else
  process_result=$?
  [[ "$process_result" -eq 1 ]] || { echo 'Could not safely verify the old process state.'; exit 1; }
fi

run_worker() {
  trap - EXIT
  set +e
  if [[ -w "$destination_parent" ]]; then
    /bin/bash "$helper" --swap-worker "$new_app" "$destination" "$backup" "$handoff" "$transaction_id" "$expected_team" "$old_version" "$new_version" "$archive" "$archive_sha256"
  else
    is_supported_privileged_destination "$destination" || {
      echo 'Administrator access is only supported for /Applications/GhostBox.app.' >&2
      return 1
    }
    /usr/bin/osascript - "$helper" "$new_app" "$destination" "$backup" "$handoff" "$transaction_id" "$expected_team" "$old_version" "$new_version" "$archive" "$archive_sha256" <<'APPLESCRIPT'
on run argv
  set commandText to "/bin/bash " & quoted form of (item 1 of argv) & " --swap-worker " & quoted form of (item 2 of argv) & " " & quoted form of (item 3 of argv) & " " & quoted form of (item 4 of argv) & " " & quoted form of (item 5 of argv) & " " & quoted form of (item 6 of argv) & " " & quoted form of (item 7 of argv) & " " & quoted form of (item 8 of argv) & " " & quoted form of (item 9 of argv) & " " & quoted form of (item 10 of argv) & " " & quoted form of (item 11 of argv)
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
  [[ -f "$handoff/swapped" ]] && break
  [[ ! -f "$handoff/worker-exit" ]] || { echo 'Bundle swap worker stopped.'; exit 1; }
  /bin/sleep 0.25
done
[[ -f "$handoff/swapped" ]] || { echo 'Bundle swap timed out.'; exit 1; }
set_state RELAUNCHING
/usr/bin/open -n -a "$destination" --args "--ghostbox-updated=$transaction_id" "--ghostbox-update-handoff=$handoff"
for ((attempt=0; attempt<240; attempt++)); do
  [[ -f "$handoff/started" ]] && break
  [[ ! -f "$handoff/failed" ]] || { echo 'New GhostBox health check failed.'; exit 1; }
  [[ ! -f "$handoff/worker-exit" ]] || { echo 'Startup was rolled back.'; exit 1; }
  /bin/sleep 0.25
done
[[ -f "$handoff/started" ]] || { echo 'New application did not acknowledge startup.'; exit 1; }
new_pid="$(/bin/cat "$handoff/started")"
new_process_start="$(/bin/ps -o lstart= -p "$new_pid" 2>/dev/null | /usr/bin/sed 's/^ *//')"
[[ -n "$new_process_start" ]] || { echo 'Could not establish the new GhostBox process identity.'; exit 1; }
new_executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$destination/Contents/Info.plist")"
new_executable="$destination/Contents/MacOS/$new_executable_name"
process_state "$new_pid" "$new_executable" "$new_process_start" || { echo 'Startup PID does not belong to the new app.'; exit 1; }
# The Dart health check writes confirmed only after first frame, prefs and app
# services are initialized. Wait for the worker to commit or restore the bundle.
for ((attempt=0; attempt<20; attempt++)); do
  [[ -f "$handoff/committed" ]] && break
  [[ -f "$handoff/restored" ]] && { echo 'New version was rolled back.'; exit 1; }
  /bin/sleep 0.25
done
[[ -f "$handoff/committed" ]] || { echo 'Update commit was not acknowledged.'; exit 1; }
wait "$worker_pid"
[[ "$(/bin/cat "$handoff/worker-exit")" == 0 ]] || exit 1
success=1
set_state CLEANUP
/bin/rm -f -- "$archive"
/bin/rm -rf -- "$extracted"
/usr/bin/touch "$handoff/cleanup-complete"
agent_file="$HOME/Library/LaunchAgents/app.ghostbox.update-recovery.$transaction_id.plist"
/bin/launchctl bootout "gui/$(/usr/bin/id -u)" "$agent_file" >/dev/null 2>&1 || true
/bin/rm -f -- "$agent_file"
if [[ "$(/bin/cat "$lock_dir/transaction-id" 2>/dev/null || true)" == "$transaction_id" ]]; then
  /bin/rm -rf -- "$lock_dir"
fi
trap - EXIT
