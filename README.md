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
- [imagecopy](#macos-setup) helper script

## Quick Start

```bash
cd ~/projects/clipboard-sync
./scripts/install.sh
```

Edit the config file with your Mac's details:

```bash
nano ~/.config/clipboard-sync/config.ini
```

Start the service:

```bash
systemctl --user enable --now clipboard-sync
```

## Installation

### 1. Install Dependencies

**Ubuntu/Debian:**
```bash
sudo apt install wl-clipboard libnotify-bin
```

**Arch Linux:**
```bash
sudo pacman -S wl-clipboard libnotify
```

**Fedora:**
```bash
sudo dnf install wl-clipboard libnotify
```

### 2. Run Installer

```bash
./scripts/install.sh [PREFIX]
```

Default prefix is `~/.local`. Files installed:
- `~/.local/bin/clipboard-sync` - Main executable
- `~/.config/clipboard-sync/config.ini` - Configuration
- `~/.local/state/clipboard-sync/` - State files
- `~/.config/systemd/user/clipboard-sync.service` - Systemd service

### 3. Configure

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

### 4. Setup SSH Keys

Ensure passwordless SSH works to your Mac:

```bash
ssh-copy-id your_mac_username@your_mac_host
ssh your_mac_username@your_mac_host "echo OK"
```

### 5. Start Service

```bash
systemctl --user enable --now clipboard-sync
systemctl --user status clipboard-sync
```

## macOS Setup

On your Mac, install the helper scripts:

```bash
mkdir -p ~/scripts
cp macos/imagecopy.swift ~/scripts/imagecopy.swift
cp macos/notify.swift ~/scripts/notify.swift

chmod +x ~/scripts/imagecopy.swift
chmod +x ~/scripts/notify.swift

ln -sf ~/scripts/imagecopy.swift ~/scripts/imagecopy
ln -sf ~/scripts/notify.swift ~/scripts/notify
```

Or compile for faster execution:

```bash
swiftc macos/imagecopy.swift -o ~/scripts/imagecopy
swiftc macos/notify.swift -o ~/scripts/notify
chmod +x ~/scripts/imagecopy ~/scripts/notify
```

**Files:**
- `imagecopy.swift` - Copy images to/from clipboard (required for image sync)
- `notify.swift` - Desktop notifications (optional)

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
