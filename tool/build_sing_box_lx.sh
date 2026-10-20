#!/usr/bin/env bash
# Build the experimental Leadaxe sing-box fork locally. This binary is kept out
# of vendor/bin and release packaging by design.
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
arch="${1:-$(uname -m)}"
case "$arch" in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; esac
[[ "$(uname -s)" == Linux ]] || { echo 'The experimental sing-box-lx option currently builds on Linux only.' >&2; exit 1; }
[[ "$arch" == amd64 || "$arch" == arm64 ]] || { echo "Unsupported architecture: $arch" >&2; exit 2; }
case "$(uname -m)" in
  x86_64|amd64) host_arch=amd64 ;;
  aarch64|arm64) host_arch=arm64 ;;
  *) echo 'Unsupported Linux host architecture.' >&2; exit 2 ;;
esac
[[ "$arch" == "$host_arch" ]] || { echo 'Build the experimental core for the current host architecture.' >&2; exit 2; }
for command in git go make; do
  command -v "$command" >/dev/null 2>&1 || { echo "Missing dependency: $command" >&2; exit 1; }
done

repository="${GHOSTBOX_SING_BOX_LX_REPOSITORY:-https://github.com/Leadaxe/sing-box-lx.git}"
version="${GHOSTBOX_SING_BOX_LX_VERSION:-v1.14.3-lx.21}"
source_dir="$project_dir/.toolchains/src/sing-box-lx-$version"
output_dir="$project_dir/vendor/experimental/linux/$arch"
mkdir -p "$(dirname -- "$source_dir")" "$output_dir"
if [[ ! -d "$source_dir/.git" ]]; then
  git clone --filter=blob:none --recurse-submodules --branch "$version" "$repository" "$source_dir"
else
  git -C "$source_dir" fetch --tags --force origin "$version"
  git -C "$source_dir" checkout --detach "$version"
  git -C "$source_dir" submodule update --init --recursive
fi

echo "Building experimental sing-box-lx $version for linux/$arch"
(cd "$source_dir" && make -f Makefile.lx lx-build)
binary=''
for candidate in "$source_dir/sing-box" "$source_dir/bin/sing-box" "$source_dir/build/sing-box"; do
  if [[ -x "$candidate" ]]; then binary="$candidate"; break; fi
done
if [[ -z "$binary" ]]; then
  binary="$(find "$source_dir" -maxdepth 4 -type f -name sing-box -perm -u+x -print -quit)"
fi
[[ -n "$binary" ]] || { echo 'sing-box-lx build completed but its binary was not found.' >&2; exit 1; }
install -m 0755 "$binary" "$output_dir/sing-box-lx"
{
  echo "Repository: $repository"
  echo "Version: $version"
  echo "Commit: $(git -C "$source_dir" rev-parse HEAD)"
  echo "Target: linux/$arch"
  echo 'Build: make -f Makefile.lx lx-build'
} > "$output_dir/BUILD-INFO.txt"
echo "Built experimental core: $output_dir/sing-box-lx"
