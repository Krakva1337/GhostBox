#!/usr/bin/env bash
set -euo pipefail

DEST_DIR="${GHOSTBOX_BIN_DIR:-$HOME/GhostBoxBin}"
DOWNLOAD_DIR="${GHOSTBOX_DOWNLOADS_DIR:-$HOME/Downloads}"

usage() {
  cat >&2 <<'EOF'
Usage: tool/import_github_builds.sh

Scans ~/Downloads for files named GhostBox* that are ZIP/TAR archives,
extracts them into ~/GhostBoxBin, recursively unpacks nested build archives,
then removes each matching source archive only after successful extraction.
Other downloads are left untouched.
Set GHOSTBOX_BIN_DIR to choose another output directory.
Set GHOSTBOX_DOWNLOADS_DIR to use another downloads directory.
EOF
}

if [[ $# -ne 0 ]]; then
  usage >&2
  exit 2
fi

if [[ ! -d "$DOWNLOAD_DIR" ]]; then
  echo "Downloads directory not found: $DOWNLOAD_DIR" >&2
  exit 1
fi

mkdir -p -- "$DEST_DIR"
DEST_DIR="$(cd -- "$DEST_DIR" && pwd)"

is_archive() {
  local lower
  lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *.zip|*.tar|*.tar.gz|*.tgz|*.tar.xz|*.txz|*.tar.bz2|*.tbz2) return 0 ;;
    *) return 1 ;;
  esac
}

unpack_archive() {
  local archive="$1" target="$2" lower
  lower="$(printf '%s' "$archive" | tr '[:upper:]' '[:lower:]')"
  mkdir -p -- "$target"
  case "$lower" in
    *.zip) command -v unzip >/dev/null || { echo 'unzip is required.' >&2; return 1; }; unzip -q "$archive" -d "$target" ;;
    *.tar.gz|*.tgz) tar -xzf "$archive" -C "$target" ;;
    *.tar.xz|*.txz) tar -xJf "$archive" -C "$target" ;;
    *.tar.bz2|*.tbz2) tar -xjf "$archive" -C "$target" ;;
    *.tar) tar -xf "$archive" -C "$target" ;;
    *) return 2 ;;
  esac
}

unique_target() {
  local base="$1" candidate="$1" suffix=2
  while [[ -e "$candidate" ]]; do
    candidate="${base}-$suffix"
    ((suffix+=1))
  done
  printf '%s\n' "$candidate"
}

unpack_nested_archives() {
  local root="$1" archive candidate rel stem target
  while :; do
    archive=''
    while IFS= read -r -d '' candidate; do
      if is_archive "$candidate"; then
        archive="$candidate"
        break
      fi
    done < <(find "$root" -type f -print0)
    [[ -n "$archive" ]] || break
    rel="${archive#"$root"/}"
    stem="${archive##*/}"
    stem="${stem%.tar.gz}"
    stem="${stem%.tar.xz}"
    stem="${stem%.tar.bz2}"
    stem="${stem%.tgz}"
    stem="${stem%.txz}"
    stem="${stem%.tbz2}"
    stem="${stem%.tar}"
    stem="${stem%.zip}"
    target="$(unique_target "$(dirname -- "$archive")/$stem")"
    unpack_archive "$archive" "$target"
    [[ -n "$(find "$target" -mindepth 1 -print -quit)" ]] || {
      echo "Archive extracted no files: $rel" >&2
      return 1
    }
    rm -f -- "$archive"
    echo "Extracted nested archive: $rel"
  done
}

found=0
shopt -s nullglob
for source in "$DOWNLOAD_DIR"/GhostBox*; do
  [[ -f "$source" ]] || continue
  is_archive "$source" || continue
  found=1
  name="$(basename -- "$source")"
  base="$name"
  base="${base%.tar.gz}"
  base="${base%.tar.xz}"
  base="${base%.tar.bz2}"
  base="${base%.tgz}"
  base="${base%.txz}"
  base="${base%.tbz2}"
  base="${base%.tar}"
  base="${base%.zip}"
  final="$(unique_target "$DEST_DIR/$base")"
  staging="$(mktemp -d "$DEST_DIR/.ghostbox-import.XXXXXX")"
  if ! unpack_archive "$source" "$staging"; then
    rm -rf -- "$staging"
    echo "Could not extract archive: $source" >&2
    exit 1
  fi
  if [[ -z "$(find "$staging" -mindepth 1 -print -quit)" ]]; then
    rm -rf -- "$staging"
    echo "Archive contains no files: $source" >&2
    exit 1
  fi
  if ! unpack_nested_archives "$staging"; then
    rm -rf -- "$staging"
    echo "Could not extract a nested archive from: $source" >&2
    exit 1
  fi
  mv -- "$staging" "$final"
  rm -f -- "$source"
  echo "Imported and removed archive: $source -> $final"
done

if [[ "$found" -eq 0 ]]; then
  echo "No GhostBox archives found in: $DOWNLOAD_DIR"
fi

echo "Builds are in: $DEST_DIR"
