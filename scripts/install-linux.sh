#!/bin/bash
#
# install-linux.sh - Install clipboard-sync on Linux
#
# Usage: curl -sSL https://tiamed.github.io/clipboard-sync/install-linux.sh | bash
#

set -euo pipefail

REPO="tiamed/clipboard-sync"
PREFIX="${PREFIX:-$HOME/.local}"
CONFIG_DIR="$HOME/.config/clipboard-sync"
STATE_DIR="$HOME/.local/state/clipboard-sync"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

assert_no_placeholders() {
    local file="$1"
    local what="$2"
    if [[ ! -f "$file" ]]; then
        log_error "${what} was not written: $file"
        return 1
    fi
    if grep -q '{{' "$file"; then
        log_error "${what} still contains unsubstituted {{placeholders}}: $file"
        log_error "Refusing to continue."
        rm -f "$file"
        return 1
    fi
}

post_install_check() {
    local service_file="$HOME/.config/systemd/user/clipboard-sync.service"
    local failed=0

    if [[ -x "$PREFIX/bin/clipboard-sync" ]]; then
        log_success "Binary present: $PREFIX/bin/clipboard-sync"
    else
        log_error "Binary missing or not executable: $PREFIX/bin/clipboard-sync"
        failed=1
    fi

    if assert_no_placeholders "$service_file" "systemd unit"; then
        log_success "systemd unit has no unsubstituted placeholders"
    else
        failed=1
    fi

    if command -v systemctl >/dev/null 2>&1; then
        if systemctl --user is-active clipboard-sync >/dev/null 2>&1; then
            log_success "clipboard-sync service is active"
        else
            log_info "Service not started yet. Edit config.ini, then: systemctl --user enable --now clipboard-sync"
        fi
    fi

    if [[ "$failed" -ne 0 ]]; then
        log_error "Post-install self-check failed"
        return 1
    fi

    echo ""
    echo "One-shot text check (after the Mac daemon is running and SSH works):"
    echo "  clipboard-sync sync-to"
    echo "  clipboard-sync sync-from"
    echo ""
    log_success "Post-install self-check passed"
}

check_dependencies() {
    local missing=0
    
    log_info "Checking dependencies..."
    
    for cmd in wl-paste wl-copy ssh scp notify-send iconv sha256sum; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "Missing: $cmd"
            missing=$((missing + 1))
        fi
    done
    
    if [[ $missing -gt 0 ]]; then
        log_error "Missing $missing dependencies"
        log_info "Install with: sudo apt install wl-clipboard libnotify-bin"
        exit 1
    fi
    
    log_success "All dependencies satisfied"
}

get_latest_release() {
    curl -s "https://api.github.com/repos/${REPO}/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/'
}

download_files() {
    local version="$1"
    
    log_info "Downloading clipboard-sync $version..."
    
    mkdir -p "$PREFIX/bin"
    mkdir -p "$PREFIX/share/doc/clipboard-sync"
    
    local base_url="https://raw.githubusercontent.com/${REPO}/${version}"
    
    curl -fSL "${base_url}/bin/clipboard-sync" -o "$PREFIX/bin/clipboard-sync"
    chmod +x "$PREFIX/bin/clipboard-sync"
    log_success "Installed: $PREFIX/bin/clipboard-sync"
    
    curl -fSL "${base_url}/README.md" -o "$PREFIX/share/doc/clipboard-sync/README.md" 2>/dev/null || true
}

setup_config() {
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$STATE_DIR"
    
    if [[ ! -f "$CONFIG_DIR/config.ini" ]]; then
        log_info "Creating config file..."
        cat > "$CONFIG_DIR/config.ini" << 'EOF'
# Clipboard Sync Configuration
# Edit with your macOS settings

[remote]
user = YOUR_MAC_USERNAME
host = YOUR_MAC_HOSTNAME_OR_IP
image_copy_path = /Users/YOUR_MAC_USERNAME/scripts/imagecopy

[sync]
min_length = 1
# Safety-net interval; primary path is push (fifo + Wayland watch)
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
EOF
        log_warn "Please edit $CONFIG_DIR/config.ini with your settings"
    else
        log_info "Config already exists: $CONFIG_DIR/config.ini"
    fi
}

install_systemd() {
    local service_dir="$HOME/.config/systemd/user"
    local service_file="$service_dir/clipboard-sync.service"
    
    mkdir -p "$service_dir"
    
    # Detect current display and Wayland environment
    local display="${DISPLAY:-:0}"
    local wayland_display="${WAYLAND_DISPLAY:-wayland-0}"
    local xdg_runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    
    cat > "$service_file" << EOF
[Unit]
Description=Clipboard sync between Linux and macOS
After=network.target

[Service]
Type=simple
ExecStart=$PREFIX/bin/clipboard-sync
Restart=on-failure
RestartSec=10
Environment=DISPLAY=$display
Environment=WAYLAND_DISPLAY=$wayland_display
Environment=XDG_RUNTIME_DIR=$xdg_runtime_dir

[Install]
WantedBy=default.target
EOF
    
    if ! assert_no_placeholders "$service_file" "systemd unit"; then
        return 1
    fi

    log_success "Installed systemd service"
    
    systemctl --user daemon-reload
}

print_summary() {
    echo ""
    echo "=========================================="
    echo -e "${GREEN}Installation complete!${NC}"
    echo "=========================================="
    echo ""
    echo "Installed to: $PREFIX"
    echo ""
    echo "Next steps:"
    echo "  1. Edit $CONFIG_DIR/config.ini (remote.user / remote.host)"
    echo "  2. Ensure SSH key auth works to your Mac"
    echo "  3. On Mac: curl -sSL https://tiamed.github.io/clipboard-sync/install-macos.sh | bash"
    echo "  4. Run: systemctl --user enable --now clipboard-sync"
    echo ""
    echo "View logs:"
    echo "  journalctl --user -u clipboard-sync -f"
    echo ""
}

main() {
    echo ""
    echo "=========================================="
    echo "  Clipboard Sync - Linux Installer"
    echo "=========================================="
    echo ""
    
    check_dependencies
    
    VERSION=$(get_latest_release)
    if [[ -z "$VERSION" ]]; then
        log_warn "Could not get latest release, using 'main'"
        VERSION="main"
    fi
    log_info "Version: $VERSION"
    
    download_files "$VERSION"
    setup_config
    install_systemd
    post_install_check
    print_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
