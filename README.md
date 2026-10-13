# Clipboard Sync

Near-instant bidirectional clipboard sync between **Linux (Wayland)** and **macOS**.

## Architecture (v2 push)

```
Linux                          SSH ControlMaster                    macOS
─────                          ─────────────────                    ─────
wl-paste --watch ──► outbound worker ──► pbcopy / imagecopy
                                              ▲
wl-copy ◄── inbound worker ◄── cat FIFO ◄── clipboard-sync-daemon
             (apply TEXT:/IMGFILE: payload)     (NSPasteboard → push)
```

- **Two parallel workers** — Linux→Mac and Mac→Linux never block each other.
- **Push, not poll** — Mac daemon writes `TEXT:<base64>` / `IMGFILE:/tmp/...` on a FIFO; Linux applies the payload (text has no second SSH round-trip; images scp once).
- **Persistent SSH mux** — ControlMaster keeps latency low.
- **Echo-loop safe** — shared content hashes + flock.
- **Failures logged** — SSH/scp errors go to journald (not swallowed).
- **Safety-net poll** — rare fallback if a push event is missed.

## Quick Start

### 1. macOS (required for push)

```bash
curl -sSL https://tiamed.github.io/clipboard-sync/install-macos.sh | bash
```

Installs `~/scripts/imagecopy`, `~/scripts/clipboard-sync-daemon`, and a LaunchAgent.

### 2. Linux

```bash
curl -sSL https://tiamed.github.io/clipboard-sync/install-linux.sh | bash
nano ~/.config/clipboard-sync/config.ini   # set remote.user / remote.host
ssh-copy-id YOUR_USER@YOUR_MAC
systemctl --user enable --now clipboard-sync
```

### 3. Verify

```bash
journalctl --user -u clipboard-sync -f
# Copy text on either side — you should see → / ← lines within ~100–300ms on a LAN.
clipboard-sync sync-to    # one-shot push
clipboard-sync sync-from  # one-shot pull
```

## Requirements

| Side | Needs |
|------|--------|
| Linux | Wayland, `wl-clipboard` (original, with `--watch`), SSH client, `notify-send`, `iconv`, `sha256sum` |
| macOS | Remote Login (SSH), `imagecopy` + `clipboard-sync-daemon` (installer provides both) |

> Prefer the original `wl-clipboard` package. `wl-clipboard-rs` lacks `--watch` and falls back to outbound polling.

## Configuration

`~/.config/clipboard-sync/config.ini`:

```ini
[remote]
user = your_mac_username
host = 192.168.1.100
image_copy_path = /Users/your_mac_username/scripts/imagecopy

[sync]
min_length = 1
poll_interval = 30
enable_text = true
enable_image = true
use_wayland_watch = true
macos_event_mode = fifo
macos_event_fifo = /tmp/clipboard-sync.fifo
macos_push_image = /tmp/clipboard-sync-push.png

[notifications]
enabled = true

[ssh]
options = -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3
mux_enabled = true
mux_persist = 600
```

### Migrating from v1 (polling)

1. Re-run the macOS installer (or build/load the daemon) so the FIFO exists.
2. Set `macos_event_mode = fifo` (default in new installs).
3. Raise `poll_interval` to `30` (it is only a safety net now).
4. `systemctl --user restart clipboard-sync`

Old `macos_event_mode = polling` still works but will feel slow.

## Commands

```bash
clipboard-sync              # daemon (systemd)
clipboard-sync sync-to      # push Linux → macOS once
clipboard-sync sync-from    # pull macOS → Linux once
clipboard-sync --help
```

Keyboard shortcuts (sway/i3/hyprland):

```
bindsym $mod+Shift+c exec clipboard-sync sync-to
bindsym $mod+Shift+v exec clipboard-sync sync-from
```

## Logs

```bash
journalctl --user -u clipboard-sync -f
# Mac daemon:
tail -f /tmp/clipboard-sync-daemon.log
DEBUG=true clipboard-sync   # foreground verbose
```

## Troubleshooting

| Symptom | Check |
|---------|--------|
| Slow or silent | `journalctl --user -u clipboard-sync -n 80` — look for SSH / FIFO errors |
| Mac → Linux never pushes | `ssh user@mac 'launchctl list \| grep clipboard-sync'`; FIFO must exist |
| `FIFO missing` in logs | Re-run macOS installer / start LaunchAgent |
| Linux → Mac slow only | Ensure `mux_enabled = true` and master stays up (`ssh -O check`) |
| No Wayland watch | Install original `wl-clipboard`; confirm `wl-paste --help \| grep watch` |
| Echo / bounce | Hashes should prevent this; restart both sides if state is stale: `rm -f ~/.local/state/clipboard-sync/*_hash` |

## Uninstall

```bash
./scripts/uninstall.sh           # keep config
./scripts/uninstall.sh --purge   # remove everything
# macOS:
launchctl unload ~/Library/LaunchAgents/clipboard-sync.daemon.plist
rm -f ~/scripts/imagecopy ~/scripts/clipboard-sync-daemon
```

## License

MIT
