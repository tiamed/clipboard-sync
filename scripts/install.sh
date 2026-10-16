#!/bin/bash
#
# install.sh - Install clipboard-sync
#
# Usage: ./install.sh [PREFIX]
#   PREFIX - Installation prefix (default: ~/.local)
#

set -euo pipefail

# === CONFIGURATION ===
DEFAULT_PREFIX="$HOME/.local"
PREFIX="${1:-$DEFAULT_PREFIX}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# === COLORS ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# === HELPER FUNCTIONS ===
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

check_command() {
    local cmd="$1"
    local package="${2:-$1}"
    
    if ! command -v "$cmd" &> /dev/null; then
        log_error "Missing dependency: $cmd (install $package)"
        return 1
    fi
    return 0
}

# === DEPENDENCY CHECK ===
check_dependencies() {
    local missing=0
    
    log_info "Checking dependencies..."
    
    check_command "wl-paste" "wl-clipboard" || missing=$((missing + 1))
    check_command "wl-copy" "wl-clipboard" || missing=$((missing + 1))
    check_command "ssh" "openssh-client" || missing=$((missing + 1))
    check_command "scp" "openssh-client" || missing=$((missing + 1))
    check_command "notify-send" "libnotify-bin" || missing=$((missing + 1))
    check_command "iconv" "libc-bin" || missing=$((missing + 1))
    check_command "sha256sum" "coreutils" || missing=$((missing + 1))
    
    if [[ $missing -gt 0 ]]; then
        log_error "Missing $missing dependencies. Please install them first."
        return 1
    fi
    
    log_success "All dependencies satisfied"
    return 0
}

# === INSTALLATION ===
install_files() {
    log_info "Installing to $PREFIX..."
    
    # Create directories
    mkdir -p "$PREFIX/bin"
    mkdir -p "$PREFIX/lib/clipboard-sync"
    mkdir -p "$PREFIX/share/doc/clipboard-sync"
    
    # Copy binary
    cp "$SCRIPT_DIR/bin/clipboard-sync" "$PREFIX/bin/"
    chmod +x "$PREFIX/bin/clipboard-sync"
    log_success "Installed binary: $PREFIX/bin/clipboard-sync"
    
    # Copy documentation
    if [[ -f "$SCRIPT_DIR/README.md" ]]; then
        cp "$SCRIPT_DIR/README.md" "$PREFIX/share/doc/clipboard-sync/"
        log_success "Installed documentation"
    fi
}

setup_config() {
    local config_dir="$HOME/.config/clipboard-sync"
    local config_file="$config_dir/config.ini"
    
    log_info "Setting up configuration..."
    
    # Create config directory
    mkdir -p "$config_dir"
    
    # Copy config template if not exists
    if [[ ! -f "$config_file" ]]; then
        if [[ -f "$SCRIPT_DIR/config/config.ini.template" ]]; then
            cp "$SCRIPT_DIR/config/config.ini.template" "$config_file"
            log_success "Created config file: $config_file"
            log_warn "Please edit $config_file with your settings"
        else
            log_warn "Config template not found, creating default..."
            cat > "$config_file" << 'EOF'
# Clipboard Sync Configuration
# Edit this file with your settings

[remote]
user = YOUR_MAC_USERNAME
host = YOUR_MAC_HOSTNAME_OR_IP
image_copy_path = /Users/YOUR_USERNAME/scripts/imagecopy

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
EOF
            log_success "Created default config: $config_file"
            log_warn "You MUST edit $config_file before starting the service"
        fi
    else
        log_info "Config file already exists: $config_file"
    fi
    
    # Create state directory
    local state_dir="$HOME/.local/state/clipboard-sync"
    mkdir -p "$state_dir"
    log_success "Created state directory: $state_dir"
}

# Substitute the unit template (prefix plus the live Wayland session) and
# refuse to install a file that still contains {{...}}. "&" in the prefix is
# escaped inside scripts/systemd-unit.sh; bash would otherwise treat it as
# the matched text.
render_systemd_unit() {
    local dest="$1"
    local template="${2:-$SCRIPT_DIR/systemd/clipboard-sync.service.template}"
    local content rendered tmp

    if [[ ! -f "$template" ]]; then
        log_error "systemd template not found: $template"
        return 1
    fi
    if [[ -z "$PREFIX" ]]; then
        log_error "PREFIX is empty; refusing to write systemd unit"
        return 1
    fi

    if ! declare -F apply_clipboard_sync_unit_template >/dev/null 2>&1; then
        # shellcheck disable=SC1091
        source "$SCRIPT_DIR/scripts/systemd-unit.sh"
    fi

    content="$(<"$template")"
    rendered="$(apply_clipboard_sync_unit_template "$PREFIX" "$content")" || return 1
    tmp="$(mktemp)"
    printf '%s\n' "$rendered" > "$tmp"

    if grep -q '{{' "$tmp"; then
        log_error "systemd unit still contains unsubstituted {{placeholders}}."
        log_error "Refusing to install $dest"
        rm -f "$tmp"
        return 1
    fi
    if ! grep -F -q "ExecStart=${PREFIX}/bin/clipboard-sync" "$tmp"; then
        log_error "systemd unit is missing ExecStart=${PREFIX}/bin/clipboard-sync"
        rm -f "$tmp"
        return 1
    fi
    mkdir -p "$(dirname "$dest")"
    mv "$tmp" "$dest"
}

install_systemd() {
    local service_name="clipboard-sync"
    local service_file="$HOME/.config/systemd/user/$service_name.service"

    log_info "Installing systemd service..."

    mkdir -p "$HOME/.config/systemd/user"

    render_systemd_unit "$service_file"
    report_clipboard_sync_wayland_choice "$(<"$service_file")"

    log_success "Created service file: $service_file"

    systemctl --user daemon-reload

    log_success "Systemd daemon reloaded"
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

    if [[ -f "$service_file" ]] && ! grep -q '{{' "$service_file"; then
        log_success "systemd unit has no unsubstituted placeholders"
    else
        log_error "systemd unit missing or still contains {{placeholders}}: $service_file"
        failed=1
    fi

    if command -v systemctl >/dev/null 2>&1; then
        if systemctl --user is-active clipboard-sync >/dev/null 2>&1; then
            log_success "clipboard-sync service is active"
        else
            log_info "clipboard-sync service is not active yet (edit config.ini, then systemctl --user enable --now clipboard-sync)"
        fi
    fi

    if [[ "$failed" -ne 0 ]]; then
        log_error "Post-install self-check failed"
        return 1
    fi
    log_success "Post-install self-check passed"
}

enable_service() {
    local service_name="clipboard-sync"
    
    log_info "Enabling systemd service..."
    
    # Check if config is valid
    if grep -q "YOUR_MAC_USERNAME\|YOUR_MAC_HOSTNAME" "$HOME/.config/clipboard-sync/config.ini" 2>/dev/null; then
        log_warn "Config file contains placeholder values!"
        log_warn "Please edit ~/.config/clipboard-sync/config.ini first"
        log_warn "Then run: systemctl --user enable --now clipboard-sync"
        return 0
    fi
    
    # Enable and start service
    systemctl --user enable "$service_name"
    
    read -p "Start clipboard-sync now? [Y/n] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        systemctl --user start "$service_name"
        log_success "Service started"
        
        # Check status
        sleep 1
        systemctl --user status "$service_name" --no-pager || true
    fi
    
    log_success "Service enabled"
}

print_summary() {
    echo ""
    echo "=========================================="
    echo -e "${GREEN}Installation complete!${NC}"
    echo "=========================================="
    echo ""
    echo "Installed to: $PREFIX"
    echo ""
    echo "Files:"
    echo "  - Binary:    $PREFIX/bin/clipboard-sync"
    echo "  - Config:    ~/.config/clipboard-sync/config.ini"
    echo "  - State:     ~/.local/state/clipboard-sync/"
    echo "  - Service:   ~/.config/systemd/user/clipboard-sync.service"
    echo ""
    echo "Next steps:"
    echo "  1. Edit ~/.config/clipboard-sync/config.ini"
    echo "  2. Ensure SSH key auth works to your Mac"
    echo "  3. Run: systemctl --user enable --now clipboard-sync"
    echo ""
    echo "To uninstall: $SCRIPT_DIR/scripts/uninstall.sh"
    echo ""
}

# === MAIN ===
main() {
    echo ""
    echo "=========================================="
    echo "  Clipboard Sync Installer"
    echo "=========================================="
    echo ""
    echo "Prefix: $PREFIX"
    echo ""
    
    # Check dependencies
    if ! check_dependencies; then
        exit 1
    fi
    
    # Install files
    install_files
    
    # Setup config
    setup_config
    
    # Install systemd service
    install_systemd
    
    # Enable service
    enable_service

    post_install_check
    
    # Print summary
    print_summary
}

if [[ "${BASH_SOURCE[0]:-}" == "$0" ]]; then
    main "$@"
fi
