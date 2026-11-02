# Clipboard Sync

Near-instant bidirectional clipboard sync between **Linux (Wayland)** and **macOS**.

## Architecture (v2 push)

```
Linux                          SSH ControlMaster                    macOS
─────                          ─────────────────                    ─────
wl-paste --watch ──► outbound worker ──► pbcopy / imagecopy
                                              ▲
wl-copy ◄── inbound worker ◄── line-buffered FIFO ◄── clipboard-sync-daemon
             (apply TEXT:/IMGFILE: payload)     (NSPasteboard → push)
```

- **Two parallel workers** — Linux→Mac and Mac→Linux never block each other.
- **Push, not poll** — Mac daemon writes `TEXT:<base64>` / `IMGFILE:/tmp/...` on a FIFO; Linux applies the payload (text has no second SSH round-trip; images scp once).
- **Persistent SSH mux** — ControlMaster keeps latency low; a failed master is retried on the next event, not disabled for the daemon's lifetime.
- **Echo-loop safe** — content hashes are claimed before the clipboard write, so `wl-paste --watch` cannot echo an inbound payload back to the Mac.
- **Fast Mac events** — 50ms `NSPasteboard` poll with App Nap guarded; the FIFO is reused across daemon restarts, and transient empty pasteboard states are retried instead of dropped.
- **Failures logged** — SSH/scp errors go to journald (not swallowed).
- **Safety-net poll** — rare fallback if a push event is missed.

## Quick Start

### 1. macOS (required for push)

```bash
curl -sSL https://tiamed.github.io/clipboard-sync/install-macos.sh | bash
```

Installs `~/scripts/imagecopy`, `~/scripts/clipboard-sync-daemon`, and a LaunchAgent.

The installer substitutes `{{INSTALL_PREFIX}}`, `{{FIFO_PATH}}`, and `{{IMAGE_PATH}}` in `macos/clipboard-sync-daemon.plist.template` before `launchctl load`. It will not load a plist that still contains `{{...}}` (that leaves launchd in **EX_CONFIG / status 78** and the daemon never starts). After load it checks that the agent is running, that the status is not 78, and that `/tmp/clipboard-sync.fifo` exists, then prints a one-shot text hint (`clipboard-sync sync-to` / `sync-from` from Linux).

### 2. Linux

```bash
curl -sSL https://tiamed.github.io/clipboard-sync/install-linux.sh | bash
nano ~/.config/clipboard-sync/config.ini   # set remote.user / remote.host
ssh-copy-id YOUR_USER@YOUR_MAC
systemctl --user enable --now clipboard-sync
```

Run the installer from the graphical session when you can. It records the live Wayland socket (often `wayland-1`). If none is visible, as with a typical SSH install, the unit leaves `WAYLAND_DISPLAY` unset.

### 3. Verify

```bash
journalctl --user -u clipboard-sync -f
# Copy text on either side — you should see → / ← lines within ~100–300ms on a LAN.
clipboard-sync sync-to    # one-shot push
clipboard-sync sync-from  # one-shot pull
```

### If it still feels slow

The link, not the clipboard tools, dominates. Measure:

```bash
# 1. Is ControlMaster actually up? A cold SSH handshake costs ~0.7-1.5s on Wi-Fi.
ssh -O check -S ~/.cache/clipboard-sync/ssh-mux/* bo@YOUR_MAC

# 2. RTT/jitter. Wired LAN is ~1-2ms; Wi-Fi is often 30-90ms with spikes.
ping -c 20 YOUR_MAC

# 3. Which path handled the event?
journalctl --user -u clipboard-sync -o short-precise | grep -E '→|←'
# [push] = FIFO, [poll] = safety net (should be rare)
```

- Put the Mac on Ethernet if possible. Linux→Mac still runs a remote `pbcopy`, and each remote process spawn plus RTT is visible on a busy Wi-Fi link.
- Keep `mux_enabled = true`. A failed master is now retried; check `ssh -O check` if journald reports `SSH multiplexing failed`.
- `poll_interval` is only the safety net. With `poll_interval = 1`, text is rechecked every 5s and images every 60s.
- If the Mac is under memory pressure (`vm.swapusage`), process spawn and AppKit calls slow down; close apps or reboot.
- Continuous screen-sharing/KVM traffic (for example Deskflow) on the same Wi-Fi adds airtime and jitter; wired Ethernet or QoS helps.

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

### Without the Mac daemon (temporary)

If you cannot compile/run `clipboard-sync-daemon` yet (e.g. Swift/SDK mismatch), keep Linux→Mac push and fall back Mac→Linux to polling:

```ini
macos_event_mode = polling
poll_interval = 1
```

Then `systemctl --user restart clipboard-sync`. FIFO mode stays recommended once the Mac daemon is running; inbound FIFO failures no longer kill the Linux service (outbound keeps working and inbound retries with backoff).

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
| Still ~0.5–1s+ per copy | Check `ssh -O check` for the mux socket, `ping` RTT to the Mac, and the "If it still feels slow" section |
| Mac copy shows up ~5s late | Daemon missed a transient pasteboard state or the FIFO stream reconnected; check `/tmp/clipboard-sync-daemon.log` for `reusing existing FIFO` / `no supported content` |
| Mac → Linux ~seconds lag, Linux → Mac fast | Update both sides: the daemon now polls at 50ms, reuses the FIFO, and retries transient empty pasteboard states; hashes are claimed before `wl-copy` to stop echo storms. |
| Mac → Linux never pushes | Mac daemon + FIFO (see below); or set `macos_event_mode = polling` |
| `FIFO missing` / inbound retries | Start LaunchAgent on Mac, or use polling until daemon builds |
| LaunchAgent status **78** (`EX_CONFIG`) | Program path is missing or the plist still contains `{{INSTALL_PREFIX}}`. Re-run `install-macos.sh`. Do not `launchctl load` the `.template` file. |
| Linux → Mac still works, inbound retries | Expected when FIFO/daemon is down — not a full service crash |
| Linux → Mac slow only | Ensure `mux_enabled = true` and master stays up (`ssh -O check`) |
| No Wayland watch | Install original `wl-clipboard`; confirm `wl-paste --help \| grep watch` |
| `Failed to connect to a Wayland server` | The unit's `WAYLAND_DISPLAY` does not match a socket in `$XDG_RUNTIME_DIR` (`wayland-1` is common). Re-run the Linux installer from the graphical session. If the unit has no `WAYLAND_DISPLAY` line, run `systemctl --user import-environment WAYLAND_DISPLAY DISPLAY && systemctl --user restart clipboard-sync`. GNOME, KDE, and uwsm start `graphical-session.target`, which this service waits for. Sway and Hyprland without that target still start it from `default.target`. |
| Echo / bounce | Hashes should prevent this; restart both sides if state is stale: `rm -f ~/.local/state/clipboard-sync/*_hash` |

### Update Mac daemon from a release tag

```bash
TAG=v1.3.0   # latest stable release; skip hyphenated prerelease tags (-rc, -alpha, -beta)
ARCH=x86_64  # or arm64
curl -L -o ~/scripts/clipboard-sync-daemon \
  https://github.com/tiamed/clipboard-sync/releases/download/$TAG/clipboard-sync-daemon-$ARCH
chmod +x ~/scripts/clipboard-sync-daemon
launchctl kickstart -k gui/$(id -u)/clipboard-sync.daemon
```

`TAG` can also be whatever the [latest stable release](https://github.com/tiamed/clipboard-sync/releases/latest) is. Re-running `install-macos.sh` is the usual path; it rewrites the LaunchAgent with a substituted program path and runs the post-install checks.

Linux script-only fixes: `install -m 755 bin/clipboard-sync ~/.local/bin/clipboard-sync && systemctl --user restart clipboard-sync` (no new Mac binary needed unless Swift changed).

### Verify Mac FIFO / daemon

On the Mac:

```bash
# LaunchAgent loaded?
launchctl list | grep clipboard-sync

# FIFO present?
ls -l /tmp/clipboard-sync.fifo

# Manual wake (Linux inbound should see a line if streaming):
echo PING > /tmp/clipboard-sync.fifo

# Daemon log:
tail -f /tmp/clipboard-sync-daemon.log
```

From Linux:

```bash
ssh USER@MAC 'ls -l /tmp/clipboard-sync.fifo; launchctl list | grep clipboard-sync'
```

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
