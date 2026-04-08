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

## Configuration Reference

| Section | Option | Default | Description |
|---------|--------|---------|-------------|
| `[remote]` | `user` | (required) | macOS username |
| `[remote]` | `host` | (required) | macOS hostname/IP |
| `[remote]` | `image_copy_path` | (required) | Path to imagecopy helper |
| `[sync]` | `min_length` | `1` | Minimum text length to sync |
| `[sync]` | `poll_interval` | `1` | Seconds between polls |
| `[sync]` | `enable_text` | `true` | Enable text sync |
| `[sync]` | `enable_image` | `true` | Enable image sync |
| `[notifications]` | `enabled` | `true` | Show desktop notifications |
| `[ssh]` | `options` | (see example) | SSH connection options |

## Usage

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

### Manual Run

```bash
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

## License

MIT
