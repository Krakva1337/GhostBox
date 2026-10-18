#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${1:---test}"
SETCAP="$(command -v setcap || true)"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
if [[ -n "${GHOSTBOX_VENDOR_DIR:-}" && -d "$GHOSTBOX_VENDOR_DIR/bin" ]]; then
  CORE_DIR="$GHOSTBOX_VENDOR_DIR/bin"
elif [[ -d "$DATA_HOME/ghostbox-appimage/vendor/bin" ]]; then
  CORE_DIR="$DATA_HOME/ghostbox-appimage/vendor/bin"
else
  CORE_DIR="$ROOT_DIR/vendor/bin"
fi
CORES=("$CORE_DIR/sing-box" "$CORE_DIR/xray")

run_privileged() {
  if [[ "$EUID" -eq 0 ]]; then
    "$@"
  elif [[ -t 0 ]]; then
    sudo "$@"
  elif command -v pkexec >/dev/null; then
    pkexec "$@"
  else
    sudo "$@"
  fi
}

for core in "${CORES[@]}"; do
  [[ -f "$core" ]] || { echo "Core binary not found: $core" >&2; exit 1; }
done
if ! command -v setcap >/dev/null || ! command -v getcap >/dev/null; then
  echo "Install setcap/getcap first (Debian/Ubuntu: sudo apt install libcap2-bin)." >&2
  exit 1
fi

case "$ACTION" in
  --remove)
    for core in "${CORES[@]}"; do
      run_privileged "$SETCAP" -r "$core"
      echo "Removed file capabilities from $core"
    done
    exit 0
    ;;
  --apply|--test)
    for core in "${CORES[@]}"; do
      run_privileged "$SETCAP" cap_net_admin+ep "$core"
      getcap "$core"
    done
    ;;
  *)
    echo "Usage: $0 [--apply|--test|--remove]" >&2
    exit 2
    ;;
esac

if [[ "$ACTION" != "--test" ]]; then
  echo "TUN capability is installed for sing-box and Xray. Re-run with --test to smoke-test both."
  exit 0
fi

if [[ ! -c /dev/net/tun ]]; then
  echo "Capability installed, but /dev/net/tun is not available in this runtime."
  echo "TUN smoke test skipped; enable the kernel TUN device and run this script again."
  exit 3
fi

CONFIG="$(mktemp --suffix=.json ghostbox-tun-check.XXXXXX)"
LOG="${CONFIG%.json}.log"
PID=""
cleanup() {
  if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
    kill -TERM "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -f "$CONFIG" "$LOG"
}
trap cleanup EXIT

smoke_test() {
  local name="$1" core="$2" iface="$3"
  if [[ "$name" == "sing-box" ]]; then
    cat > "$CONFIG" <<JSON
{"log":{"level":"error"},"inbounds":[{"type":"tun","tag":"tun-check","interface_name":"$iface","address":["172.31.255.1/30"],"auto_route":false}],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}
JSON
    "$core" check -c "$CONFIG"
  else
    cat > "$CONFIG" <<JSON
{"log":{"loglevel":"error"},"inbounds":[{"tag":"tun-check","protocol":"tun","settings":{"name":"$iface","mtu":1500,"gateway":["172.31.255.1/30"]}}],"outbounds":[{"tag":"direct","protocol":"freedom"}]}
JSON
    "$core" run -test -c "$CONFIG"
  fi
  "$core" run -c "$CONFIG" >"$LOG" 2>&1 &
  PID=$!
  for _ in $(seq 1 40); do
    [[ -e "/sys/class/net/$iface" ]] && break
    kill -0 "$PID" 2>/dev/null || break
    sleep 0.1
  done
  if [[ ! -e "/sys/class/net/$iface" ]]; then
    echo "$name did not create its temporary TUN interface. Output:" >&2
    cat "$LOG" >&2
    return 1
  fi
  kill -TERM "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
  PID=""
  if [[ -e "/sys/class/net/$iface" ]]; then
    echo "$name did not remove its temporary TUN interface." >&2
    return 1
  fi
  echo "$name TUN smoke test passed (no system routes changed)."
}

smoke_test sing-box "${CORES[0]}" gbox-cap-sb0
smoke_test Xray "${CORES[1]}" gbox-cap-xr0
