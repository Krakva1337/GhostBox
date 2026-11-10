#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="${HOME}/.local/opt/ghostbox"
APP_PATH="$APP_DIR/GhostBox.AppImage"
APP_DIR_LINK="$APP_DIR/AppDir"
RELEASES_DIR="$APP_DIR/releases"
STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
TRANSACTIONS_DIR="$STATE_HOME/ghostbox/updates"
LAUNCHER="${HOME}/.local/bin/ghostbox"
BIN_DIR="${HOME}/.local/bin"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
VENDOR_DIR="$DATA_HOME/ghostbox-appimage/vendor/bin"
ICON_DIR="$DATA_HOME/icons/hicolor/scalable/apps"
DESKTOP_DIR="$DATA_HOME/applications"

log() { printf '[ghostbox-update] %s\n' "$*" >&2; }
TXN=""
fail() {
  log "$*"
  if [[ -n "$TXN" && -d "$TXN" ]]; then
    printf '%s\n' "$*" > "$TXN/error" 2>/dev/null || true
    : > "$TXN/failed" 2>/dev/null || true
  fi
  exit 1
}

write_launcher() {
  mkdir -p "$BIN_DIR"
  local tmp="$BIN_DIR/.ghostbox.$TXN_ID"
  cat > "$tmp" <<EOF_LAUNCHER
#!/usr/bin/env bash
set -euo pipefail
APP_DIR="$APP_DIR"
UPDATER="$BIN_DIR/ghostbox-update"
if [[ "\${1:-}" != --ghostbox-updated=* && -x "\$UPDATER" ]]; then
  "\$UPDATER" --recover || true
fi
exec "\$APP_DIR/AppDir/AppRun" "\$@"
EOF_LAUNCHER
  chmod 0755 "$tmp"
  mv -f -- "$tmp" "$LAUNCHER"
}

write_transaction() {
  local dir="$1" state="$2" old_appdir="$3" old_appimage="$4" new_release="$5" new_hash="$6" version="$7" source="$8"
  mkdir -p "$dir"
  TXN_DIR="$dir" TXN_ID="$(basename -- "$dir")" TXN_STATE="$state" \
  TXN_OLD_APPDIR="$old_appdir" TXN_OLD_APPIMAGE="$old_appimage" \
  TXN_NEW_RELEASE="$new_release" TXN_NEW_HASH="$new_hash" \
  TXN_VERSION="$version" TXN_SOURCE="$source" \
  python3 - <<'PY'
import json, os, tempfile
p = os.environ['TXN_DIR'] + '/update_transaction.json'
d = {}
try:
  with open(p, encoding='utf-8') as f: d = json.load(f)
except (OSError, ValueError): pass
d.update({
  'id': os.environ['TXN_ID'], 'status': os.environ['TXN_STATE'], 'platform': 'linux',
  'oldVersion': d.get('currentVersion', d.get('oldVersion', '')),
  'targetVersion': os.environ['TXN_VERSION'] or d.get('targetVersion', d.get('newVersion', '')),
  'newVersion': os.environ['TXN_VERSION'] or d.get('newVersion', ''),
  'oldAppDir': os.environ['TXN_OLD_APPDIR'] or d.get('oldAppDir', ''),
  'oldAppImage': os.environ['TXN_OLD_APPIMAGE'] or d.get('oldAppImage', ''),
  'newRelease': os.environ['TXN_NEW_RELEASE'] or d.get('newRelease', ''),
  'sha256': os.environ['TXN_NEW_HASH'] or d.get('sha256', ''),
  'packagePath': os.environ['TXN_SOURCE'] or d.get('packagePath', ''),
  'source': os.environ['TXN_SOURCE'] or d.get('source', ''),
  'backupPath': os.environ['TXN_OLD_APPIMAGE'],
  'updatedAt': __import__('datetime').datetime.now(__import__('datetime').timezone.utc).isoformat()
})
if os.environ['TXN_STATE'] in ('FAILED', 'ROLLBACK', 'RESTORE_OLD'):
  d.setdefault('error', 'The update did not complete; the previous version was restored.')
fd, tmp = tempfile.mkstemp(prefix='.transaction.', dir=os.environ['TXN_DIR'])
with os.fdopen(fd, 'w') as f:
  json.dump(d, f, ensure_ascii=False, sort_keys=True)
  f.write('\n'); f.flush(); os.fsync(f.fileno())
os.replace(tmp, p)
fd = os.open(os.environ['TXN_DIR'], os.O_RDONLY); os.fsync(fd); os.close(fd)
PY
}

valid_appdir_target() {
  local target="$1"
  [[ -n "$target" && "$(dirname -- "$target")" == "$RELEASES_DIR" && -d "$target" && ! -L "$target" ]]
}

backup_vendor_cores() {
  local backup_vendor="$BACKUP_DIR/vendor-bin"
  mkdir -p "$backup_vendor"
  for name in sing-box xray BUILD-INFO.txt; do
    if [[ -e "$VENDOR_DIR/$name" ]]; then
      : > "$backup_vendor/$name.existed"
      cp -a -- "$VENDOR_DIR/$name" "$backup_vendor/$name"
    fi
  done
  : > "$backup_vendor/complete"
}

restore_vendor_cores() {
  local backup_vendor="$BACKUP_DIR/vendor-bin"
  [[ -f "$backup_vendor/complete" ]] || return 0
  mkdir -p "$VENDOR_DIR"
  for name in sing-box xray BUILD-INFO.txt; do
    if [[ -e "$backup_vendor/$name.existed" ]]; then
      [[ -f "$backup_vendor/$name" ]] || continue
      cp -a -- "$backup_vendor/$name" "$VENDOR_DIR/$name.restore"
      mv -f -- "$VENDOR_DIR/$name.restore" "$VENDOR_DIR/$name"
    else
      rm -f -- "$VENDOR_DIR/$name"
    fi
  done
}

restore_transaction() {
  local txn="$1" old_appdir="$2" old_appimage="$3" stage="$4"
  local txn_id="$(basename -- "$txn")"
  local BACKUP_DIR="$APP_DIR/.update-$txn_id"
  [[ "$txn_id" =~ ^[A-Za-z0-9._-]{8,100}$ &&
      "$(dirname -- "$txn")" == "$TRANSACTIONS_DIR" ]] || fail 'Invalid recovery transaction id or directory.'
  [[ "$old_appimage" == "$BACKUP_DIR/old-GhostBox.AppImage" &&
      "$stage" == "$BACKUP_DIR/staging" ]] || fail 'Unsafe recovery backup path.'
  if [[ -n "$old_appdir" ]]; then
    valid_appdir_target "$old_appdir" || fail 'Unsafe recovery AppDir path.'
  fi
  log "Restoring transaction $(basename -- "$txn")"
  write_transaction "$txn" ROLLBACK "$old_appdir" "$old_appimage" \
    "$(cat "$txn/new-release" 2>/dev/null || true)" \
    "$(cat "$txn/new-hash" 2>/dev/null || true)" \
    "$(cat "$txn/version" 2>/dev/null || true)" ''
  if [[ -e "$old_appdir" ]]; then
    ln -sfn -- "$old_appdir" "$APP_DIR/AppDir.rollback"
    mv -Tf -- "$APP_DIR/AppDir.rollback" "$APP_DIR_LINK"
  fi
  if [[ -f "$old_appimage" ]]; then
    rm -f -- "$APP_PATH.rollback"
    mv -f -- "$APP_PATH" "$APP_PATH.rollback" 2>/dev/null || true
    mv -f -- "$old_appimage" "$APP_PATH"
    rm -f -- "$APP_PATH.rollback"
  elif [[ -f "$APP_PATH.rollback" && ! -e "$APP_PATH" ]]; then
    mv -f -- "$APP_PATH.rollback" "$APP_PATH"
  fi
  restore_vendor_cores
  : > "$txn/rolled-back"
  write_transaction "$txn" RESTORE_OLD "$old_appdir" "$old_appimage" '' '' '' ''
  rm -f -- "$txn/installing" "$txn/relaunching" "$txn/health-check"
  rm -rf -- "$(dirname -- "$stage")"
}

recover_pending() {
  [[ -d "$TRANSACTIONS_DIR" ]] || return 0
  local txn
  shopt -s nullglob
  for txn in "$TRANSACTIONS_DIR"/*; do
    [[ -d "$txn" && -f "$txn/update_transaction.json" ]] || continue
    txn_id="$(basename -- "$txn")"
    [[ "$txn_id" =~ ^[A-Za-z0-9._-]{8,100}$ && "$(dirname -- "$txn")" == "$TRANSACTIONS_DIR" ]] || fail 'Invalid recovery transaction directory.'
    if [[ ! -f "$txn/installing" && ! -f "$txn/relaunching" && ! -f "$txn/health-check" ]]; then
      status="$(python3 - "$txn/update_transaction.json" <<'PY'
import json, sys
try:
  with open(sys.argv[1], encoding='utf-8') as f: print(str(json.load(f).get('status', '')).upper())
except (OSError, ValueError): print('')
PY
      )"
      case "$status" in DOWNLOADING|VERIFYING|STAGING|STOPPING)
        stale_backup="$APP_DIR/.update-$txn_id"
        if [[ -e "$stale_backup" ]]; then
          [[ -d "$stale_backup" && ! -L "$stale_backup" ]] || fail 'Unsafe incomplete staging directory.'
          rm -rf -- "$stale_backup"
        fi
        write_transaction "$txn" FAILED '' '' '' '' '' ''
        printf '%s\n' 'Update was interrupted before the old installation changed.' > "$txn/error"
        : > "$txn/failed"
        log "Discarded incomplete staging for transaction $txn_id; the old installation is intact."
        ;;
      esac
      continue
    fi
    backup_image="$(cat "$txn/old-appimage" 2>/dev/null || printf '%s' "$txn/old-GhostBox.AppImage")"
    backup_stage="$(cat "$txn/staging-path" 2>/dev/null || printf '%s' "$txn/staging")"
    expected_backup="$APP_DIR/.update-$txn_id/old-GhostBox.AppImage"
    expected_stage="$APP_DIR/.update-$txn_id/staging"
    old_appdir="$(cat "$txn/old-appdir" 2>/dev/null || true)"
    [[ "$backup_image" == "$expected_backup" && "$backup_stage" == "$expected_stage" ]] || fail 'Unsafe recovery transaction backup paths.'
    if [[ -n "$old_appdir" ]]; then
      valid_appdir_target "$old_appdir" || fail 'Unsafe recovery AppDir path.'
    fi
    if [[ -f "$txn/confirmed" ]]; then
      : > "$txn/committed"
      write_transaction "$txn" COMMIT "$old_appdir" \
        "$backup_image" "$(cat "$txn/new-release" 2>/dev/null || true)" \
        "$(cat "$txn/new-hash" 2>/dev/null || true)" "$(cat "$txn/version" 2>/dev/null || true)" ''
      rm -rf -- "$(dirname -- "$backup_stage")"
      rm -f -- "$txn/installing" "$txn/relaunching" "$txn/health-check"
      log "Completed confirmed update $(basename -- "$txn")"
    elif [[ -f "$txn/failed" || ! -d /proc ]]; then
      restore_transaction "$txn" "$old_appdir" \
        "$backup_image" "$backup_stage"
    else
      # An unconfirmed handoff from an earlier boot is interrupted. The new app
      # may still have left a confirmation marker while the helper was stopped.
      restore_transaction "$txn" "$old_appdir" \
        "$backup_image" "$backup_stage"
    fi
  done
  shopt -u nullglob
}

if [[ "${1:-}" == --recover ]]; then
  mkdir -p "$APP_DIR" "$TRANSACTIONS_DIR"
  exec 9>"$APP_DIR/.update.lock"
  flock -n 9 || exit 0
  recover_pending
  exit 0
fi

if [[ $# -ne 4 ]]; then
  echo "Usage: $0 /path/to/GhostBox-linux-ARCH.AppImage OLD_PID TRANSACTION_ID HANDOFF_DIR" >&2
  exit 2
fi

SOURCE="$(realpath -- "$1")"
OLD_PID="$2"
[[ "$OLD_PID" =~ ^[1-9][0-9]*$ ]] || fail 'Invalid old process id.'
[[ -f "$SOURCE" && ! -L "$1" ]] || fail 'Downloaded AppImage is missing or a symlink.'
mkdir -p "$APP_DIR" "$RELEASES_DIR" "$TRANSACTIONS_DIR"
[[ ! -L "$APP_DIR" ]] || fail 'Install root must not be a symbolic link.'
exec 9>"$APP_DIR/.update.lock"
flock -n 9 || fail 'Another update is already active.'

TXN_ID="$3"
TXN="$(realpath -m -- "$4")"
EXPECTED_PARENT="$(realpath -m -- "$TRANSACTIONS_DIR")"
[[ "$TXN_ID" =~ ^[A-Za-z0-9._-]{8,100}$ && "$TXN" == "$EXPECTED_PARENT/$TXN_ID" ]] || fail 'Invalid update transaction handoff path.'
[[ -d "$TXN" && ! -L "$4" ]] || fail 'Update handoff directory is missing or unsafe.'
[[ -f "$TXN/update_transaction.json" && ! -L "$TXN/update_transaction.json" ]] || fail 'Update transaction record is missing.'

# Capture the process identity, not just a reusable numeric PID. This prevents
# waiting for an unrelated process if the original client exits and its PID is reused.
proc_stat="/proc/$OLD_PID/stat"
[[ -r "$proc_stat" ]] || fail 'GhostBox process is no longer running.'
proc_start="$(python3 - "$proc_stat" <<'PY'
import sys
s = open(sys.argv[1]).read()
tail = s[s.rfind(')') + 2:].split()
print(tail[19] if len(tail) > 19 else '')
PY
)"
proc_exe="$(readlink -f -- "/proc/$OLD_PID/exe" 2>/dev/null || true)"
[[ "$proc_exe" == "$RELEASES_DIR/"* && "$(basename -- "$proc_exe")" =~ ^(GhostBox|ghostbox)$ ]] || fail 'PID does not belong to an installed GhostBox release.'

arch="$(uname -m)"
case "$arch" in x86_64|aarch64) ;; *) fail "Unsupported Linux architecture: $arch" ;; esac
case "$(basename -- "$SOURCE")" in
  *-linux-x86_64.AppImage) [[ "$arch" == x86_64 ]] || fail 'AppImage architecture does not match this system.' ;;
  *-linux-aarch64.AppImage) [[ "$arch" == aarch64 ]] || fail 'AppImage architecture does not match this system.' ;;
  *) fail 'Update file name does not identify a supported Linux architecture.' ;;
esac

BACKUP_DIR="$APP_DIR/.update-$TXN_ID"
STAGE="$BACKUP_DIR/staging"
[[ ! -e "$BACKUP_DIR" ]] || fail 'A previous update backup needs recovery.'
mkdir -m 0700 -p "$STAGE"
old_appdir=""
if [[ -L "$APP_DIR_LINK" ]]; then old_appdir="$(readlink -f -- "$APP_DIR_LINK")"; fi
if ! valid_appdir_target "$old_appdir"; then rm -rf -- "$TXN"; fail 'Active AppDir is outside the managed releases directory.'; fi
old_appimage="$BACKUP_DIR/old-GhostBox.AppImage"
new_hash="$(sha256sum -- "$SOURCE" | awk '{print $1}')"
version="$(basename -- "$SOURCE" | sed -E 's/^GhostBox-(.*)-linux-(x86_64|aarch64)\.AppImage$/\1/')"
write_transaction "$TXN" STAGING "$old_appdir" "$old_appimage" '' "$new_hash" "$version" "$SOURCE"
printf '%s\n' "$old_appdir" > "$TXN/old-appdir"
printf '%s\n' "$old_appimage" > "$TXN/old-appimage"
printf '%s\n' "$STAGE" > "$TXN/staging-path"
printf '%s\n' "$version" > "$TXN/version"
printf '%s\n' "$new_hash" > "$TXN/new-hash"

cleanup_failure() {
  local status=$?
  trap - EXIT
  if [[ -f "$TXN/installing" || -f "$TXN/relaunching" || -f "$TXN/health-check" ]]; then
    if [[ -f "$TXN/confirmed" ]]; then
      : > "$TXN/committed"
      write_transaction "$TXN" COMMIT "$old_appdir" "$old_appimage" \
        "$(cat "$TXN/new-release" 2>/dev/null || true)" "$new_hash" "$version" "$SOURCE"
      rm -rf -- "$BACKUP_DIR"
    else
      restore_transaction "$TXN" "$old_appdir" "$old_appimage" "$STAGE"
    fi
  else
    write_transaction "$TXN" FAILED "$old_appdir" "$old_appimage" '' "$new_hash" "$version" "$SOURCE" || true
    printf '%s\n' "Update staging failed with status $status." > "$TXN/error" || true
    : > "$TXN/failed" || true
    rm -rf -- "$BACKUP_DIR"
  fi
  if [[ -x "$LAUNCHER" ]]; then
    nohup "$LAUNCHER" --ghostbox-update-recovered >/dev/null 2>&1 &
  fi
  exit "$status"
}
trap cleanup_failure EXIT

chmod u+x "$SOURCE"
cp -- "$SOURCE" "$STAGE/GhostBox.AppImage"
[[ "$(sha256sum -- "$STAGE/GhostBox.AppImage" | awk '{print $1}')" == "$new_hash" ]] || fail 'Staged AppImage SHA-256 changed.'
(cd "$STAGE" && ./GhostBox.AppImage --appimage-extract >/dev/null)
[[ -d "$STAGE/squashfs-root" && ! -L "$STAGE/squashfs-root" ]] || fail 'AppImage extraction failed.'
for required in GhostBox AppRun vendor/bin/sing-box vendor/bin/xray; do
  [[ -e "$STAGE/squashfs-root/$required" ]] || fail "AppImage is missing $required."
done
[[ -x "$STAGE/squashfs-root/vendor/bin/sing-box" && -x "$STAGE/squashfs-root/vendor/bin/xray" ]] || fail 'Bundled core executables are invalid.'
chmod 0755 "$STAGE/squashfs-root/AppRun"
new_release="$RELEASES_DIR/$new_hash"
[[ ! -e "$new_release" || -d "$new_release" ]] || fail 'Release destination is not a directory.'
if [[ ! -d "$new_release" ]]; then mv -- "$STAGE/squashfs-root" "$new_release"; fi
printf '%s\n' "$new_release" > "$TXN/new-release"
write_transaction "$TXN" VERIFYING "$old_appdir" "$old_appimage" "$new_release" "$new_hash" "$version" "$SOURCE"

# The client remains open until this marker confirms extraction and validation.
: > "$TXN/ready"
[[ ! -f "$TXN/cancelled" ]] || fail 'Update handoff was cancelled before shutdown.'

# Wait only while the exact process instance remains. Do not signal it by name
# or by PID; the app exits itself after handing control to this external helper.
for ((attempt=0; attempt<300; attempt++)); do
  if [[ ! -r "$proc_stat" ]]; then break; fi
  current_start="$(python3 - "$proc_stat" 2>/dev/null <<'PY'
import sys
s = open(sys.argv[1]).read()
tail = s[s.rfind(')') + 2:].split()
print(tail[19] if len(tail) > 19 else '')
PY
  )"
  [[ "$current_start" == "$proc_start" ]] || break
  sleep 0.2
done
if [[ -r "$proc_stat" ]] && [[ "$(python3 - "$proc_stat" 2>/dev/null <<'PY'
import sys
s = open(sys.argv[1]).read()
tail = s[s.rfind(')') + 2:].split()
print(tail[19] if len(tail) > 19 else '')
PY
)" == "$proc_start" ]]; then
  fail 'GhostBox did not exit in time.'
fi

: > "$TXN/installing"
write_transaction "$TXN" INSTALLING "$old_appdir" "$old_appimage" "$new_release" "$new_hash" "$version" "$SOURCE"
backup_vendor_cores
install -m 0755 "$STAGE/GhostBox.AppImage" "$STAGE/GhostBox.AppImage.new"
if [[ -f "$APP_PATH" ]]; then mv -- "$APP_PATH" "$old_appimage"; fi
mv -- "$STAGE/GhostBox.AppImage.new" "$APP_PATH"
ln -s -- "$new_release" "$APP_DIR/AppDir.new.$TXN_ID"
mv -Tf -- "$APP_DIR/AppDir.new.$TXN_ID" "$APP_DIR_LINK"

# Refresh user-space core copies while preserving CAP_NET_ADMIN if the previous
# copies had it. Never invoke sudo automatically.
mkdir -p "$VENDOR_DIR" "$ICON_DIR" "$DESKTOP_DIR"
for core in sing-box xray; do
  src="$new_release/vendor/bin/$core"; dst="$VENDOR_DIR/$core"
  had_net_admin=false
  if command -v getcap >/dev/null 2>&1 && getcap "$dst" 2>/dev/null | grep -q 'cap_net_admin'; then had_net_admin=true; fi
  install -m 0755 "$src" "$dst.new"
  mv -f -- "$dst.new" "$dst"
  if "$had_net_admin" && command -v setcap >/dev/null 2>&1; then
    setcap cap_net_admin+ep "$dst" 2>/dev/null || log "Could not restore CAP_NET_ADMIN on $dst; TUN may require manual permission restoration."
  elif "$had_net_admin"; then
    log "setcap is unavailable; TUN permission may need manual restoration for $dst."
  elif [[ -e "$dst" ]] && ! command -v getcap >/dev/null 2>&1; then
    log "Cannot inspect prior CAP_NET_ADMIN on $dst because getcap is unavailable."
  fi
done
[[ ! -f "$new_release/vendor/bin/BUILD-INFO.txt" ]] || install -m 0644 "$new_release/vendor/bin/BUILD-INFO.txt" "$VENDOR_DIR/BUILD-INFO.txt"
[[ ! -f "$new_release/ghostbox.svg" ]] || install -m 0644 "$new_release/ghostbox.svg" "$ICON_DIR/ghostbox.svg"
cat > "$DESKTOP_DIR/ghostbox.desktop" <<EOF2
[Desktop Entry]
Name=GhostBox Alpha
Comment=Linux VPN client powered by Xray and sing-box
Exec="$LAUNCHER" %U
TryExec=$LAUNCHER
Icon=ghostbox
Terminal=false
Type=Application
Categories=Network;Security;
MimeType=x-scheme-handler/ghostbox;
StartupWMClass=ghostbox
EOF2
chmod 0644 "$DESKTOP_DIR/ghostbox.desktop"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true
write_launcher

: > "$TXN/relaunching"
write_transaction "$TXN" RELAUNCHING "$old_appdir" "$old_appimage" "$new_release" "$new_hash" "$version" "$SOURCE"
nohup "$LAUNCHER" "--ghostbox-updated=$TXN_ID" "--ghostbox-update-handoff=$TXN" >/dev/null 2>&1 &
: > "$TXN/health-check"
write_transaction "$TXN" HEALTH_CHECK "$old_appdir" "$old_appimage" "$new_release" "$new_hash" "$version" "$SOURCE"
for ((attempt=0; attempt<240; attempt++)); do
  [[ ! -f "$TXN/failed" ]] || fail 'New GhostBox failed its startup health check.'
  [[ ! -f "$TXN/confirmed" ]] || break
  sleep 0.25
done
[[ -f "$TXN/confirmed" ]] || fail 'New GhostBox did not confirm startup in time.'
: > "$TXN/committed"
write_transaction "$TXN" COMMIT "$old_appdir" "$old_appimage" "$new_release" "$new_hash" "$version" "$SOURCE"
rm -rf -- "$BACKUP_DIR"
rm -f -- "$TXN/installing" "$TXN/relaunching" "$TXN/health-check"
write_transaction "$TXN" CLEANUP "$old_appdir" '' "$new_release" "$new_hash" "$version" "$SOURCE"
rm -f -- "$SOURCE"
trap - EXIT
log "Updated GhostBox to $version"
exit 0
