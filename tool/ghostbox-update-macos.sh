#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 UPDATE.zip OLD_PID /path/to/GhostBox.app" >&2
  exit 2
fi

archive="$(cd -- "$(/usr/bin/dirname "$1")" && /bin/pwd)/$(/usr/bin/basename "$1")"
old_pid="$2"
destination="$(cd -- "$(/usr/bin/dirname "$3")" && /bin/pwd)/$(/usr/bin/basename "$3")"
parent="$(/usr/bin/dirname "$destination")"
temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ghostbox-update.XXXXXX")"
staged="$temporary/GhostBox.app"
backup="$parent/.GhostBox.app.old.$old_pid"
cleanup() {
  /bin/rm -rf "$temporary"
}
trap cleanup EXIT

[[ -f "$archive" ]] || { echo "Update archive not found: $archive" >&2; exit 1; }
[[ "$destination" == *.app ]] || { echo "Invalid app bundle path: $destination" >&2; exit 1; }

while /bin/kill -0 "$old_pid" 2>/dev/null; do /bin/sleep 0.4; done
/usr/bin/ditto -x -k "$archive" "$temporary"
new_app="$(/usr/bin/find "$temporary" -type d -name '*.app' -prune -print -quit)"
[[ -n "$new_app" ]] || { echo 'Update archive has no .app bundle.' >&2; exit 1; }
[[ -x "$new_app/Contents/MacOS/GhostBox" || -x "$new_app/Contents/MacOS/Runner" ]] || {
  echo 'Update archive does not contain a runnable GhostBox application.' >&2
  exit 1
}

if [[ -w "$parent" ]]; then
  /usr/bin/ditto "$new_app" "$staged"
  /bin/mv "$destination" "$backup"
  if ! /bin/mv "$staged" "$destination"; then
    /bin/mv "$backup" "$destination"
    exit 1
  fi
  /usr/bin/open -a "$destination" --args --ghostbox-updated
  /bin/sleep 3
  /bin/rm -rf "$backup"
else
  # /Applications is normally root-owned. Ask macOS for authorization only
  # for the bundle swap; extraction and integrity checks happen as the user.
  /usr/bin/osascript - "$new_app" "$destination" "$backup" <<'APPLESCRIPT'
on run argv
  set sourceApp to item 1 of argv
  set destinationApp to item 2 of argv
  set backupApp to item 3 of argv
  set stagedApp to destinationApp & ".new"
  set shellCommand to "set -e; /bin/rm -rf " & quoted form of stagedApp & "; /usr/bin/ditto " & quoted form of sourceApp & " " & quoted form of stagedApp & "; /bin/mv " & quoted form of destinationApp & " " & quoted form of backupApp & "; if ! /bin/mv " & quoted form of stagedApp & " " & quoted form of destinationApp & "; then /bin/mv " & quoted form of backupApp & " " & quoted form of destinationApp & "; exit 1; fi; /usr/bin/open -a " & quoted form of destinationApp & " --args --ghostbox-updated; /bin/sleep 3; /bin/rm -rf " & quoted form of backupApp
  do shell script shellCommand with administrator privileges
end run
APPLESCRIPT
fi

/bin/rm -f "$archive"
