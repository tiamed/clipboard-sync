# Clipboard Sync

Bidirectional clipboard synchronization between Linux (Wayland) and macOS.

## Features

- **Text sync**: Copy text on Linux → available on macOS, and vice versa
- **Image sync**: Copy images on Linux → available on macOS, and vice versa
- **Hash-based detection**: Only syncs when content changes
- **Notifications**: Optional desktop notifications on both systems
- **Systemd integration**: Runs as a user service

## Requirements

### Linux
- Wayland compositor (wl-paste, wl-copy)
- SSH client
- `notify-send` (libnotify)
- `iconv`, `sha256sum` (usually pre-installed)

### macOS
- SSH server enabled
- `pbcopy`/`pbpaste` (built-in)
- [imagecopy](#macos-setup) helper (auto-installed)

## Quick Start

### Linux

```bash
curl -sSL https://tiamed.github.io/clipboard-sync/install-linux.sh | bash
```

Then edit the config:
```bash
nano ~/.config/clipboard-sync/config.ini
```

Start the service:
```bash
systemctl --user enable --now clipboard-sync
```

### macOS

```bash
curl -sSL https://tiamed.github.io/clipboard-sync/install-macos.sh | bash
```

## Installation

### Linux

**One-liner (recommended):**
```bash
curl -sSL https://tiamed.github.io/clipboard-sync/install-linux.sh | bash
```

**Install dependencies manually:**

Ubuntu/Debian:
```bash
sudo apt install wl-clipboard libnotify-bin
```

Arch Linux:
```bash
sudo pacman -S wl-clipboard libnotify
```

Fedora:
```bash
sudo dnf install wl-clipboard libnotify
```

**Files installed:**
- `~/.local/bin/clipboard-sync` - Main executable
- `~/.config/clipboard-sync/config.ini` - Configuration
- `~/.local/state/clipboard-sync/` - State files
- `~/.config/systemd/user/clipboard-sync.service` - Systemd service

### Configuration

Edit `~/.config/clipboard-sync/config.ini`:

```ini
[remote]
user = your_mac_username
host = 192.168.1.100
image_copy_path = /Users/your_username/scripts/imagecopy

[sync]
min_length = 1
poll_interval = 1
enable_text = true
enable_image = true

[notifications]
enabled = true

[ssh]
options = -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10
```

### SSH Setup

Ensure passwordless SSH works to your Mac:

```bash
ssh-copy-id your_mac_username@your_mac_host
ssh your_mac_username@your_mac_host "echo OK"
```

### Start Service

```bash
systemctl --user enable --now clipboard-sync
systemctl --user status clipboard-sync
```

## macOS Setup

The `imagecopy` helper is required for image sync. Install it with one command:

```bash
curl -sSL https://tiamed.github.io/clipboard-sync/install-macos.sh | bash
```

This downloads a pre-compiled binary for your architecture (Intel or Apple Silicon).

**Manual installation:**

```bash
mkdir -p ~/scripts
curl -Lo ~/scripts/imagecopy https://github.com/tiamed/clipboard-sync/releases/latest/download/imagecopy-$(uname -m)
chmod +x ~/scripts/imagecopy
```

**From source:**

```bash
mkdir -p ~/scripts
swiftc macos/imagecopy.swift -o ~/scripts/imagecopy
chmod +x ~/scripts/imagecopy
```

**Usage:**
```bash
~/scripts/imagecopy /path/to/image.png     # Push image to clipboard
~/scripts/imagecopy -o /path/to/output.png # Save clipboard image to file
```

## Event-Driven Monitoring

By default the daemon tries to use native clipboard event APIs instead of
polling when it can:

- **Linux (Wayland)**: uses `wl-paste --watch` for both text and image changes.
  If your `wl-paste` does not support `--watch` (e.g. `wl-clipboard-rs`) or the
  compositor lacks the data-control protocol, the daemon automatically falls back
  to polling.
- **macOS**: install the optional `clipboard-sync-daemon` on your Mac to push
  changes to the Linux side through a FIFO or Unix domain socket instead of
  polling via SSH.

### macOS daemon (optional)

Build and install on macOS:

```bash
swiftc macos/clipboard-sync-daemon.swift -o ~/scripts/clipboard-sync-daemon
chmod +x ~/scripts/clipboard-sync-daemon
```

Load with `launchd`:

```bash
cp macos/clipboard-sync-daemon.plist.template \
   ~/Library/LaunchAgents/clipboard-sync.daemon.plist
# Edit the plist to match your install prefix, then:
launchctl load -w ~/Library/LaunchAgents/clipboard-sync.daemon.plist
```

On the Linux side, enable FIFO mode in `config.ini`:

```ini
[sync]
macos_event_mode = fifo
macos_event_fifo = /tmp/clipboard-sync.fifo
```

When the FIFO reader is active, macOS clipboard changes are pulled immediately
while the configured `poll_interval` still acts as a safety net.

## Configuration Reference

| Section | Option | Default | Description |
|---------|--------|---------|-------------|
| `[remote]` | `user` | (required) | macOS username |
| `[remote]` | `host` | (required) | macOS hostname/IP |
| `[remote]` | `image_copy_path` | (required) | Path to imagecopy helper |
| `[sync]` | `min_length` | `1` | Minimum text length to sync |
| `[sync]` | `poll_interval` | `1` | Seconds between polls (also safety-net interval for macOS polling in event mode) |
| `[sync]` | `enable_text` | `true` | Enable text sync |
| `[sync]` | `enable_image` | `true` | Enable image sync |
| `[sync]` | `use_wayland_watch` | `true` | Use `wl-paste --watch` event monitoring when available |
| `[sync]` | `macos_event_mode` | `polling` | macOS → Linux mode: `polling` or `fifo` |
| `[sync]` | `macos_event_fifo` | `/tmp/clipboard-sync.fifo` | Path to the FIFO created by the macOS daemon |
| `[sync]` | `macos_image_check_interval` | `5` | Seconds between lightweight macOS image change checks in polling mode |
| `[notifications]` | `enabled` | `true` | Show desktop notifications |
| `[ssh]` | `options` | (see example) | SSH connection options |

## Usage

### One-Shot Commands

Use these to immediately sync without waiting for the next polling cycle. Ideal for keyboard shortcuts or window manager hooks.

```bash
# Push Linux clipboard to macOS (auto-detects text or image)
clipboard-sync sync-to

# Pull macOS clipboard to Linux (tries image first, falls back to text)
clipboard-sync sync-from

# Show help
clipboard-sync --help
```

**Keyboard shortcut examples (sway/i3/hyprland):**
```
bindsym $mod+Shift+c exec clipboard-sync sync-to
bindsym $mod+Shift+v exec clipboard-sync sync-from
```

### Start/Stop Service

```bash
systemctl --user start clipboard-sync
systemctl --user stop clipboard-sync
systemctl --user restart clipboard-sync
```

### View Logs

```bash
journalctl --user -u clipboard-sync -f
```

### Continuous Daemon

```bash
# Run without arguments for continuous sync (event-driven when available)
~/.local/bin/clipboard-sync
```

## Uninstall

```bash
./scripts/uninstall.sh           # Keep config
./scripts/uninstall.sh --purge   # Remove everything
```

## Troubleshooting

### Clipboard not syncing

1. Check service status:
   ```bash
   systemctl --user status clipboard-sync
   ```

2. Check logs:
   ```bash
   journalctl --user -u clipboard-sync -n 50
   ```

3. Verify SSH connection:
   ```bash
   ssh your_mac_user@your_mac_host "pbpaste"
   ```

### Images not syncing

1. Verify `imagecopy` exists on Mac:
   ```bash
   ssh your_mac_user@your_mac_host "ls ~/scripts/imagecopy"
   ```

2. Test imagecopy manually on Mac:
   ```bash
   ssh your_mac_user@your_mac_host "~/scripts/imagecopy /tmp/test.png"
   ```

### SSH connection issues

1. Ensure SSH key is set up:
   ```bash
   ssh-copy-id your_mac_user@your_mac_host
   ```

2. Test connection:
   ```bash
   ssh -o BatchMode=yes your_mac_user@your_mac_host "echo OK"
   ```

### Wayland issues

1. Verify Wayland clipboard tools work:
   ```bash
   echo "test" | wl-copy
   wl-paste
   ```

2. Check `WAYLAND_DISPLAY` environment variable:
   ```bash
   echo $WAYLAND_DISPLAY
   ```

3. If using `wl-clipboard-rs` (doesn't support `--watch`):
   - Install the original `wl-clipboard` package for event-driven monitoring
   - Or let the daemon fall back to polling mode automatically

### Event monitoring issues

1. **"wl-paste does not support --watch"**: Install the original `wl-clipboard` package. The `wl-clipboard-rs` variant doesn't support `--watch`, so the daemon automatically falls back to polling.

2. **"Wayland watcher died, restarting..."**: Check logs for the underlying error:
   ```bash
   journalctl --user -u clipboard-sync -n 100
   ```

3. **"macOS FIFO reader failed to start"**: 
   - Verify SSH connection works: `ssh your_mac_user@your_mac_host "echo OK"`
   - Check that the macOS daemon is running: `ssh your_mac_user@your_mac_host "launchctl list | grep clipboard-sync"`
   - Verify FIFO path matches in both config.ini and the macOS daemon plist

4. **High CPU usage**: If using polling mode and CPU usage is high, increase `poll_interval` in config.ini to 2 or 3 seconds.

## License

MIT
