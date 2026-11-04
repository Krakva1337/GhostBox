# Discord Rich Presence

GhostBox uses local Discord IPC without a user token, OAuth login or network
service. Enable **Discord Rich Presence** in settings while the desktop Discord
client is running.

The activity contains:

```text
GhostBox
1.7.5-alpha | VPN Подключен
↓ 1.2 MB/s ↑ 120 KB/s | Сегодня: 2.4 GB
<Discord's live elapsed connection timer>
[GitHub] [Telegram]
```

The timer is driven by `timestamps.start` (Unix seconds). Its position and
appearance are controlled by Discord. An elapsed counter embedded in `details`
would be a stale snapshot, so GhostBox does not publish one. Traffic snapshots
are coalesced and sent at most once every five seconds; Discord can delay their
display. Status transitions are prioritized within the five-updates-per-twenty-
seconds presence budget. Only the newest snapshot is kept while a request is
in flight or Discord is unavailable.

Both buttons are sent with every activity. Discord intentionally hides custom
buttons when viewing your own activity; inspect the profile from another
account to check the rendered buttons. The RPC status in GhostBox settings
shows connection failures and the number of buttons echoed in Discord's
acknowledgement when that field is available. An acknowledgement confirms IPC
acceptance, not what another client's profile card renders.

## Desktop transports

| Platform | Transport | Packaging |
| --- | --- | --- |
| Windows x64 | `kernel32` named pipes `discord-ipc-0..9`, nonblocking I/O in a worker isolate | No extra DLL; `ffi` is a Dart dependency |
| Linux | Unix sockets in runtime/temp paths, including Flatpak and Snap directories | Standard AppImage |
| macOS | Unix sockets, including the session's `TMPDIR` | Existing nonsandboxed app bundle |

The protocol layer handles fragmented/coalesced frames, opaque ping/pong,
READY, command acknowledgements, bounded buffering and shutdown. Reconnection
uses exponential backoff; rejected commands have a separate cooldown. Turning
RPC off clears the activity and closes IPC. Reconnecting to Discord preserves
the VPN session's start time.

All desktop build scripts pass `GHOSTBOX_DISCORD_CLIENT_ID`. The default is the
GhostBox application ID `1566838058207412414`; override it through the environment
when invoking the build scripts or a Dart define when building directly.
Server names, VPN addresses and profile names are never included.

Windows and macOS builds require their respective host toolchains. A Linux
build and static analysis do not verify their native runtime behavior.

References: [Discord RPC](https://docs.discord.com/developers/topics/rpc),
[timestamps and buttons](https://docs.discord.com/developers/discord-social-sdk/development-guides/setting-rich-presence),
[presence update limit](https://docs.discord.com/developers/events/gateway-events#update-presence).
