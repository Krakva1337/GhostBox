#!/usr/bin/env bash
set -euo pipefail

# Manually route IPv4 hotspot clients into GhostBox's fixed Linux TUN.
# The dedicated nftables table drops hotspot forwarding to every other egress
# so clients cannot silently fall back to the physical network.
readonly TABLE=ghostbox_hotspot
readonly STATE_DIR=/run/ghostbox-hotspot
readonly TUN_IF=ghostbox0

usage() {
  echo "Usage: sudo $0 start <hotspot-interface> | stop | status" >&2
  echo "Start only after GhostBox is connected in TUN mode." >&2
}

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Run this command with sudo/root." >&2
    exit 1
  fi
}

valid_interface() { [[ $1 =~ ^[a-zA-Z0-9_.:-]{1,15}$ ]]; }

restore_forwarding() {
  local previous current
  [[ -f "$STATE_DIR/forwarding.previous" ]] || return 0
  previous=$(<"$STATE_DIR/forwarding.previous")
  current=$(< /proc/sys/net/ipv4/ip_forward)
  # Restore only our known 0 -> 1 change, and only if it is still 1.
  if [[ $previous == 0 && $current == 1 ]]; then
    sysctl -q -w net.ipv4.ip_forward=0
  fi
}

stop_sharing() {
  if nft list table inet "$TABLE" >/dev/null 2>&1; then
    nft delete table inet "$TABLE"
  fi
  restore_forwarding
  rm -rf -- "$STATE_DIR"
  echo "GhostBox hotspot forwarding stopped."
}

[[ $# -ge 1 ]] || { usage; exit 2; }
need_root
command -v nft >/dev/null || { echo "nftables (nft) is required." >&2; exit 1; }
command -v sysctl >/dev/null || { echo "sysctl is required." >&2; exit 1; }

case "$1" in
  start)
    [[ $# -eq 2 ]] || { usage; exit 2; }
    hotspot_if=$2
    valid_interface "$hotspot_if" || { echo "Invalid hotspot interface name." >&2; exit 2; }
    [[ $hotspot_if != "$TUN_IF" ]] || { echo "Hotspot and TUN interfaces must differ." >&2; exit 2; }
    [[ -d "/sys/class/net/$hotspot_if" ]] || { echo "Hotspot interface $hotspot_if does not exist." >&2; exit 1; }
    [[ -d "/sys/class/net/$TUN_IF" && -e "/sys/class/net/$TUN_IF/tun_flags" ]] || {
      echo "GhostBox TUN $TUN_IF is not active. Connect GhostBox in TUN mode first." >&2
      exit 1
    }
    [[ ! -e "$STATE_DIR" ]] || { echo "Sharing is already active or needs cleanup; run stop first." >&2; exit 1; }
    if nft list table inet "$TABLE" >/dev/null 2>&1; then
      echo "Refusing to replace existing nftables table inet $TABLE." >&2
      exit 1
    fi

    install -d -m 0700 "$STATE_DIR"
    cat /proc/sys/net/ipv4/ip_forward > "$STATE_DIR/forwarding.previous"
    printf '%s\n' "$hotspot_if" > "$STATE_DIR/hotspot-interface"
    cleanup_on_error() {
      nft delete table inet "$TABLE" >/dev/null 2>&1 || true
      restore_forwarding || true
      rm -rf -- "$STATE_DIR"
    }
    trap cleanup_on_error ERR

    sysctl -q -w net.ipv4.ip_forward=1
    nft -f - <<NFT
table inet $TABLE {
  chain forward {
    type filter hook forward priority -50; policy accept;
    iifname "$hotspot_if" oifname "$TUN_IF" meta nfproto ipv4 accept
    iifname "$TUN_IF" oifname "$hotspot_if" meta nfproto ipv4 ct state established,related accept
    iifname "$hotspot_if" drop
  }
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    iifname "$hotspot_if" oifname "$TUN_IF" meta nfproto ipv4 masquerade
  }
}
NFT
    trap - ERR
    echo "Hotspot IPv4 traffic from $hotspot_if now exits through $TUN_IF."
    echo "Stop sharing before disconnecting GhostBox: sudo $0 stop"
    ;;
  stop)
    [[ $# -eq 1 ]] || { usage; exit 2; }
    stop_sharing
    ;;
  status)
    [[ $# -eq 1 ]] || { usage; exit 2; }
    if [[ -f "$STATE_DIR/hotspot-interface" ]] && nft list table inet "$TABLE" >/dev/null 2>&1; then
      echo "Active: $(<"$STATE_DIR/hotspot-interface") -> $TUN_IF (IPv4)"
    else
      echo "Inactive"
      exit 1
    fi
    ;;
  *) usage; exit 2 ;;
esac
