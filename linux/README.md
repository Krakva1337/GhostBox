# Linux hotspot VPN sharing

GhostBox's Linux TUN interface can be used as the egress for IPv4 traffic
forwarded by a hotspot. The hotspot manager must already be running, and its
client-facing network interface must be known.

With GhostBox connected in TUN mode, run:

```sh
sudo "$HOME/.local/share/ghostbox-appimage/vendor/bin/ghostbox-hotspot-vpn.sh" start <hotspot-interface>
```

For example, the interface may be `wlan0` or a NetworkManager hotspot device.
Find the actual name with `ip link`; pass the interface that receives client
traffic. To stop sharing and remove GhostBox's firewall table, run:

```sh
sudo "$HOME/.local/share/ghostbox-appimage/vendor/bin/ghostbox-hotspot-vpn.sh" stop
```

For a source checkout, replace the installed path above with
`tool/linux_hotspot_vpn.sh`.

The commands require root (typically via `sudo`), `nftables`, and `sysctl`.
The start command requires the active GhostBox TUN interface `ghostbox0`. It
enables IPv4 forwarding and creates only the dedicated `inet
ghostbox_hotspot` nftables table, with forwarding and masquerading limited to
the selected hotspot interface and `ghostbox0`. It does not configure the
hotspot, DHCP, IPv6 forwarding, or unrelated firewall rules. The stop command
removes that table and restores IPv4 forwarding to `0` only if it was `0`
before start and is still `1`; otherwise it preserves the current setting.

Sharing has an explicit lifecycle: run `stop` before disconnecting the VPN or
restarting GhostBox. If the machine crashes or is powered off, Linux clears
the runtime nftables table and `/run` state on reboot.
