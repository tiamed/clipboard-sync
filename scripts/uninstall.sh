#!/bin/bash
#
# uninstall.sh - Uninstall clipboard-sync
#
# Usage: ./uninstall.sh [--purge]
#   --purge - Also remove config and state files
#

set -euo pipefail

# === CONFIGURATION ===
DEFAULT_PREFIX="$HOME/.local"
PREFIX="${PREFIX:-$DEFAULT_PREFIX}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PURGE="${1:-}"

# === COLORS ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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
    echo -e "${RED}[ERROR]${NC} $1"
}

ask_confirm() {
    local prompt="$1"
    local default="${2:-n}"
    
    if [[ "$default" == "y" ]]; then
        read -p "$prompt [Y/n] " -n 1 -r
    else
        read -p "$prompt [y/N] " -n 1 -r
    fi
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        return 0
    fi
    return 1
}

# === UNINSTALL ===
stop_service() {
    local service_name="clipboard-sync"
    
    log_info "Stopping systemd service..."
    
    if systemctl --user is-active "$service_name" &>/dev/null; then
        systemctl --user stop "$service_name"
        log_success "Service stopped"
    else
        log_info "Service not running"
    fi
}

disable_service() {
    local service_name="clipboard-sync"
    
    log_info "Disabling systemd service..."
    
    if systemctl --user is-enabled "$service_name" &>/dev/null; then
        systemctl --user disable "$service_name"
        log_success "Service disabled"
    fi
}

remove_service_file() {
    local service_file="$HOME/.config/systemd/user/clipboard-sync.service"
    
    if [[ -f "$service_file" ]]; then
        rm -f "$service_file"
        log_success "Removed service file: $service_file"
        
        systemctl --user daemon-reload
        log_success "Systemd daemon reloaded"
    fi
}

remove_files() {
    log_info "Removing installed files..."
    
    # Remove binary
    if [[ -f "$PREFIX/bin/clipboard-sync" ]]; then
        rm -f "$PREFIX/bin/clipboard-sync"
        log_success "Removed: $PREFIX/bin/clipboard-sync"
    fi
    
    # Remove lib directory
    if [[ -d "$PREFIX/lib/clipboard-sync" ]]; then
        rm -rf "$PREFIX/lib/clipboard-sync"
        log_success "Removed: $PREFIX/lib/clipboard-sync"
    fi
    
    # Remove documentation
    if [[ -d "$PREFIX/share/doc/clipboard-sync" ]]; then
        rm -rf "$PREFIX/share/doc/clipboard-sync"
        log_success "Removed: $PREFIX/share/doc/clipboard-sync"
    fi
}

remove_config() {
    local config_dir="$HOME/.config/clipboard-sync"
    local state_dir="$HOME/.local/state/clipboard-sync"
    
    log_warn "This will remove your configuration and state files!"
    
    if ask_confirm "Remove config directory ($config_dir)?"; then
        rm -rf "$config_dir"
        log_success "Removed: $config_dir"
    fi
    
    if ask_confirm "Remove state directory ($state_dir)?"; then
        rm -rf "$state_dir"
        log_success "Removed: $state_dir"
    fi
    
    # Also remove old state files if they exist
    local old_text_hash="$HOME/.clipboard_last_text_hash"
    local old_image_hash="$HOME/.clipboard_last_image_hash"
    
    if [[ -f "$old_text_hash" ]]; then
        rm -f "$old_text_hash"
        log_success "Removed: $old_text_hash"
    fi
    
    if [[ -f "$old_image_hash" ]]; then
        rm -f "$old_image_hash"
        log_success "Removed: $old_image_hash"
    fi
}

print_summary() {
    echo ""
    echo "=========================================="
    echo -e "${GREEN}Uninstall complete!${NC}"
    echo "=========================================="
    echo ""
    echo "Removed:"
    echo "  - Binary:    $PREFIX/bin/clipboard-sync"
    echo "  - Library:   $PREFIX/lib/clipboard-sync/"
    echo "  - Service:   ~/.config/systemd/user/clipboard-sync.service"
    echo ""
    if [[ "$PURGE" == "--purge" ]]; then
        echo "Also removed:"
        echo "  - Config:    ~/.config/clipboard-sync/"
        echo "  - State:     ~/.local/state/clipboard-sync/"
    else
        echo "Preserved:"
        echo "  - Config:    ~/.config/clipboard-sync/"
        echo "  - State:     ~/.local/state/clipboard-sync/"
        echo ""
        echo "To remove config and state, run: $0 --purge"
    fi
    echo ""
}

# === MAIN ===
main() {
    echo ""
    echo "=========================================="
    echo "  Clipboard Sync Uninstaller"
    echo "=========================================="
    echo ""
    
    # Check for --purge flag
    if [[ "$PURGE" == "--purge" ]]; then
        log_warn "Purge mode: will remove config and state files"
    fi
    
    # Confirm uninstall
    if ! ask_confirm "Uninstall clipboard-sync?"; then
        log_info "Cancelled"
        exit 0
    fi
    
    # Stop and disable service
    stop_service
    disable_service
    
    # Remove service file
    remove_service_file
    
    # Remove installed files
    remove_files
    
    # Remove config if --purge or ask
    if [[ "$PURGE" == "--purge" ]]; then
        remove_config
    fi
    
    # Print summary
    print_summary
}

main "$@"
