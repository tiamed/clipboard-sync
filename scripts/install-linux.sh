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

# curl | bash has no sibling files. The blocks below are byte-for-byte copies of
# scripts/systemd-unit.sh and systemd/clipboard-sync.service.template.
# tests/unit/test_systemd_wayland_env.sh fails if they diverge.
load_systemd_unit_helpers() {
    if [[ "${CLIPBOARD_SYNC_EMBEDDED_UNIT_HELPERS:-}" != "1" ]]; then
        local src="${BASH_SOURCE[0]:-}"
        local lib=""
        local src_dir=""
        if [[ -n "$src" && -f "$src" ]]; then
            src_dir="${src%/*}"
            if [[ "$src_dir" == "$src" ]]; then
                src_dir="."
            fi
            lib="${src_dir}/systemd-unit.sh"
        fi
        if [[ -n "$lib" && -f "$lib" ]]; then
            # shellcheck disable=SC1090
            source "$lib"
            return 0
        fi
    fi
    _define_systemd_unit_helpers_fallback
}

_define_systemd_unit_helpers_fallback() {
    # BEGIN scripts/systemd-unit.sh
    source /dev/stdin << 'END_SYSTEMD_UNIT_SH'
# systemd-unit.sh — session environment for the clipboard-sync user unit.
# Sourced by scripts/install.sh. scripts/install-linux.sh sources this file
# when it sits beside the installer, and embeds the same bytes for curl | bash.
# Do not execute directly.

if [[ "${BASH_SOURCE[0]:-}" == "$0" ]]; then
    printf 'source scripts/systemd-unit.sh; do not execute it\n' >&2
    exit 1
fi

# Always stderr. Callers capture helper stdout, and the installers' log_* helpers
# write to stdout, which would otherwise be baked into the unit.
_cs_log_warn() {
    if declare -F log_warn >/dev/null 2>&1; then
        log_warn "$@" >&2
    else
        printf '[WARN] %s\n' "$*" >&2
    fi
}

_cs_log_info() {
    if declare -F log_info >/dev/null 2>&1; then
        log_info "$@" >&2
    else
        printf '[INFO] %s\n' "$*" >&2
    fi
}

# Socket names and XDG paths we are willing to write into a unit file.
_cs_env_token_ok() {
    [[ "$1" =~ ^[A-Za-z0-9_.:/-]+$ ]]
}

_cs_runtime_dir() {
    if [[ -n "${XDG_RUNTIME_DIR:-}" ]] && _cs_env_token_ok "$XDG_RUNTIME_DIR"; then
        printf '%s\n' "$XDG_RUNTIME_DIR"
        return 0
    fi
    printf '/run/user/%s\n' "$(id -u)"
}

# 0 = a client can talk to this socket, 1 = connection refused / missing server,
# 2 = probe unavailable or inconclusive.
_cs_wayland_socket_accepts_clients() {
    local runtime="$1"
    local name="$2"
    local err rc=0

    command -v wl-paste >/dev/null 2>&1 || return 2
    command -v timeout >/dev/null 2>&1 || return 2

    err="$(XDG_RUNTIME_DIR="$runtime" WAYLAND_DISPLAY="$name" \
        timeout 2 wl-paste --list-types 2>&1 >/dev/null)" || rc=$?
    if [[ "$rc" -eq 124 ]]; then
        return 2
    fi
    if [[ "$err" == *"Failed to connect"* ]]; then
        return 1
    fi
    return 0
}

_cs_socket_mtime() {
    local runtime="$1"
    local name="$2"
    stat -c '%Y' "$runtime/$name" 2>/dev/null || printf '0'
}

_cs_socket_index() {
    local n="${1#wayland-}"
    if [[ "$n" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$n"
    else
        printf '0\n'
    fi
}

# Newest socket wins. Equal mtimes prefer the higher wayland-N, so a tie
# does not collapse to wayland-0.
_cs_newest_socket() {
    local runtime="$1"
    shift
    local name mtime best="" best_mtime=-1 best_index=-1 index
    for name in "$@"; do
        mtime="$(_cs_socket_mtime "$runtime" "$name")"
        index="$(_cs_socket_index "$name")"
        if [[ "$mtime" -gt "$best_mtime" ]] || { [[ "$mtime" -eq "$best_mtime" ]] && [[ "$index" -gt "$best_index" ]]; }; then
            best="$name"
            best_mtime="$mtime"
            best_index="$index"
        fi
    done
    printf '%s\n' "$best"
}

_cs_list_wayland_sockets() {
    local runtime="$1"
    local path
    [[ -d "$runtime" ]] || return 0
    for path in "$runtime"/wayland-*; do
        [[ -S "$path" ]] || continue
        printf '%s\n' "${path##*/}"
    done
}

# Print the Wayland socket name to pin, or nothing when the unit should
# leave WAYLAND_DISPLAY unset. Never invents wayland-0.
detect_wayland_display() {
    local runtime requested found
    local -a sockets=()
    runtime="$(_cs_runtime_dir)"
    requested="${WAYLAND_DISPLAY:-}"

    if [[ -n "$requested" ]] && _cs_env_token_ok "$requested" && [[ -S "$runtime/$requested" ]]; then
        printf '%s\n' "$requested"
        return 0
    fi

    local name
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        sockets+=("$name")
    done < <(_cs_list_wayland_sockets "$runtime" | sort)

    if [[ ${#sockets[@]} -eq 1 ]]; then
        found="${sockets[0]}"
    elif [[ ${#sockets[@]} -gt 1 ]]; then
        found="$(_cs_choose_wayland_socket "$runtime" "${sockets[@]}")"
    else
        found=""
    fi

    if [[ -n "$found" ]]; then
        if [[ -n "$requested" && "$requested" != "$found" ]]; then
            _cs_log_warn "WAYLAND_DISPLAY=$requested is not a live socket under $runtime; using $found."
        fi
        printf '%s\n' "$found"
        return 0
    fi

    if [[ -n "$requested" ]] && _cs_env_token_ok "$requested"; then
        _cs_log_warn "WAYLAND_DISPLAY=$requested is set but $runtime/$requested is not a socket. The unit will pin $requested. Re-run with WAYLAND_DISPLAY empty to detect a socket or omit the variable."
        printf '%s\n' "$requested"
        return 0
    fi

    if [[ -n "$requested" ]]; then
        _cs_log_warn "Ignoring unsafe WAYLAND_DISPLAY value; the systemd unit will not set it."
    fi
    return 0
}

_cs_choose_wayland_socket() {
    local runtime="$1"
    shift
    local -a all=("$@")
    local -a candidates=()
    local name rc=0

    for name in "${all[@]}"; do
        rc=0
        _cs_wayland_socket_accepts_clients "$runtime" "$name" || rc=$?
        if [[ "$rc" -eq 1 ]]; then
            continue
        fi
        candidates+=("$name")
    done

    if [[ ${#candidates[@]} -eq 0 ]]; then
        _cs_log_warn "Wayland sockets (${all[*]}) did not accept a client; not setting WAYLAND_DISPLAY."
        return 0
    fi

    local chosen
    chosen="$(_cs_newest_socket "$runtime" "${candidates[@]}")"
    if [[ ${#all[@]} -gt 1 ]]; then
        _cs_log_warn "Multiple Wayland sockets (${all[*]}); using $chosen."
    fi
    printf '%s\n' "$chosen"
}

# Lines for the [Service] section. WAYLAND_DISPLAY and DISPLAY are included
# only when known, so an SSH install does not bake wayland-0 or :0.
clipboard_sync_environment_lines() {
    local runtime wayland display
    runtime="$(_cs_runtime_dir)"
    wayland="$(detect_wayland_display)"
    display="${DISPLAY:-}"

    printf 'Environment=XDG_RUNTIME_DIR=%s\n' "$runtime"
    if [[ -n "$wayland" ]]; then
        printf 'Environment=WAYLAND_DISPLAY=%s\n' "$wayland"
    fi
    if [[ -n "$display" ]] && _cs_env_token_ok "$display"; then
        printf 'Environment=DISPLAY=%s\n' "$display"
    elif [[ -n "$display" ]]; then
        _cs_log_warn "Ignoring unsafe DISPLAY value; the systemd unit will not set it."
    fi
}

# Bash treats "&" in ${var//pat/repl} as the matched text, and "\" starts an escape.
_cs_escape_repl() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//&/\\&}"
    printf '%s' "$s"
}

apply_clipboard_sync_unit_template() {
    local prefix="$1"
    local template_text="$2"
    local env_lines rendered escaped_prefix escaped_env
    env_lines="$(clipboard_sync_environment_lines)"
    escaped_prefix="$(_cs_escape_repl "$prefix")"
    escaped_env="$(_cs_escape_repl "$env_lines")"
    rendered="${template_text//\{\{INSTALL_PREFIX\}\}/${escaped_prefix}}"
    rendered="${rendered//\{\{ENVIRONMENT_LINES\}\}/${escaped_env}}"
    if [[ "$rendered" == *'{{'* ]]; then
        _cs_log_warn "systemd unit still contains unsubstituted placeholders"
        return 1
    fi
    printf '%s\n' "$rendered"
}

report_clipboard_sync_wayland_choice() {
    local unit_text="$1"
    local name=""
    if [[ "$unit_text" == *"Environment=WAYLAND_DISPLAY="* ]]; then
        name="${unit_text#*Environment=WAYLAND_DISPLAY=}"
        name="${name%%$'\n'*}"
        _cs_log_info "systemd unit WAYLAND_DISPLAY=$name"
        return 0
    fi
    _cs_log_warn "No live Wayland socket detected. The unit does not set WAYLAND_DISPLAY."
    _cs_log_warn "From the graphical session, re-run the installer, or import the session and restart:"
    _cs_log_warn "  systemctl --user import-environment WAYLAND_DISPLAY DISPLAY && systemctl --user restart clipboard-sync"
}
END_SYSTEMD_UNIT_SH
    # END scripts/systemd-unit.sh
}

clipboard_sync_unit_template_text() {
    # BEGIN systemd/clipboard-sync.service.template
    cat << 'END_UNIT_TEMPLATE'
[Unit]
Description=Clipboard sync between Linux and macOS
# graphical-session.target is started by GNOME, KDE, and uwsm once the
# compositor is up. After= orders this service behind that target when the
# desktop pulls it in. It is not required: WantedBy=default.target still
# starts the service for Sway/Hyprland setups that never activate
# graphical-session.target, and for a headless enable.
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=simple
ExecStart={{INSTALL_PREFIX}}/bin/clipboard-sync
Restart=on-failure
RestartSec=10
# Session environment is substituted at install. WAYLAND_DISPLAY is written
# only when a live socket (or an explicit WAYLAND_DISPLAY) is known.
# XDG_RUNTIME_DIR uses the installing user, not a fixed uid.
{{ENVIRONMENT_LINES}}

[Install]
WantedBy=graphical-session.target
WantedBy=default.target
END_UNIT_TEMPLATE
    # END systemd/clipboard-sync.service.template
}

install_systemd() {
    local service_dir="$HOME/.config/systemd/user"
    local service_file="$service_dir/clipboard-sync.service"
    local template_text rendered

    mkdir -p "$service_dir"

    load_systemd_unit_helpers

    template_text="$(clipboard_sync_unit_template_text)"
    rendered="$(apply_clipboard_sync_unit_template "$PREFIX" "$template_text")" || return 1
    printf '%s\n' "$rendered" > "$service_file"
    report_clipboard_sync_wayland_choice "$rendered"

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

# Executed directly, including `curl | bash` (no BASH_SOURCE). Skip when sourced.
if [[ "${BASH_SOURCE[0]:-}" == "$0" || -z "${BASH_SOURCE[0]:-}" ]]; then
    main "$@"
fi
