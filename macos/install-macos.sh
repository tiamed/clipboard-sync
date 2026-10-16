#!/bin/bash
#
# install-macos.sh - Install imagecopy + clipboard-sync-daemon on macOS
#
# Usage: curl -sSL https://tiamed.github.io/clipboard-sync/install-macos.sh | bash
#
# The LaunchAgent plist is always rendered from clipboard-sync-daemon.plist.template
# (or the embedded copy, when this script is piped to bash). Placeholders are
# substituted before launchctl load. A plist that still contains {{...}} is
# never loaded: launchd would exit EX_CONFIG (78) and the daemon would not start.

set -euo pipefail

REPO="tiamed/clipboard-sync"
INSTALL_DIR="${HOME}/scripts"
FIFO_PATH="/tmp/clipboard-sync.fifo"
IMAGE_PATH="/tmp/clipboard-sync-push.png"
PLIST_DIR="${HOME}/Library/LaunchAgents"
PLIST_PATH="${PLIST_DIR}/clipboard-sync.daemon.plist"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# Directory of this file when it is a real script. Empty when curl | bash
# feeds the script on stdin (no sibling template on disk).
resolve_script_dir() {
    local src="${BASH_SOURCE[0]:-}"
    if [[ -n "$src" && -f "$src" ]]; then
        cd "$(dirname "$src")" && pwd
    fi
}
SCRIPT_DIR="$(resolve_script_dir)"

get_arch() {
    case "$(uname -m)" in
        arm64)  echo "arm64" ;;
        x86_64) echo "x86_64" ;;
        *)      log_error "Unsupported architecture: $(uname -m)"; exit 1 ;;
    esac
}

get_latest_release() {
    curl -fsS "https://api.github.com/repos/${REPO}/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || true
}

download_or_build() {
    local name="$1"
    local arch="$2"
    local version="$3"
    local dest="$4"

    if [[ -n "$version" ]]; then
        local url="https://github.com/${REPO}/releases/download/${version}/${name}-${arch}"
        log_info "Downloading ${name} from ${url}"
        if curl -fSL -o "$dest" "$url"; then
            chmod +x "$dest"
            return 0
        fi
        log_warn "Release binary missing; building from source"
    fi

    local src_url="https://raw.githubusercontent.com/${REPO}/master/macos/${name}.swift"
    local tmp
    tmp=$(mktemp)
    curl -fSL -o "$tmp" "$src_url"
    log_info "Compiling ${name}.swift..."
    swiftc "$tmp" -o "$dest"
    chmod +x "$dest"
    rm -f "$tmp"
}

# Keep this byte-for-byte identical to clipboard-sync-daemon.plist.template
# (tests/integration/test_plist_substitution.sh enforces that). curl | bash
# has no sibling template file, so the embedded copy is the fallback.
embedded_plist_template() {
    cat << 'END_PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- Rendered by macos/install-macos.sh. Do not launchctl load this file directly.
     Tokens: INSTALL_PREFIX, FIFO_PATH, IMAGE_PATH. -->
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>clipboard-sync.daemon</string>

    <key>ProgramArguments</key>
    <array>
        <string>{{INSTALL_PREFIX}}/clipboard-sync-daemon</string>
        <string>--fifo-path</string>
        <string>{{FIFO_PATH}}</string>
        <string>--image-path</string>
        <string>{{IMAGE_PATH}}</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
        <key>Crashed</key>
        <true/>
    </dict>

    <key>ThrottleInterval</key>
    <integer>5</integer>

    <key>StandardOutPath</key>
    <string>/tmp/clipboard-sync-daemon.log</string>

    <key>StandardErrorPath</key>
    <string>/tmp/clipboard-sync-daemon.log</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
</dict>
</plist>
END_PLIST
}

load_plist_template() {
    if [[ -n "${CLIPBOARD_SYNC_PLIST_TEMPLATE:-}" ]]; then
        if [[ ! -f "$CLIPBOARD_SYNC_PLIST_TEMPLATE" ]]; then
            log_error "Plist template not found: $CLIPBOARD_SYNC_PLIST_TEMPLATE"
            return 1
        fi
        cat "$CLIPBOARD_SYNC_PLIST_TEMPLATE"
        return 0
    fi
    if [[ -n "$SCRIPT_DIR" && -f "${SCRIPT_DIR}/clipboard-sync-daemon.plist.template" ]]; then
        cat "${SCRIPT_DIR}/clipboard-sync-daemon.plist.template"
        return 0
    fi
    embedded_plist_template
}

# Bash treats "&" in a ${var//pat/repl} replacement as "the matched text"
# and "\" as an escape. Escape both so a home directory can contain them
# without putting {{INSTALL_PREFIX}} back into the plist.
escape_repl() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//&/\\&}"
    printf '%s' "$s"
}

# Literal replace. Not sed, so a path that contains "|" or "/" cannot
# break the rewrite or leave the token in place.
apply_plist_placeholders() {
    local content="$1"
    local prefix fifo image
    if [[ -z "${INSTALL_DIR}" || -z "${FIFO_PATH}" || -z "${IMAGE_PATH}" ]]; then
        log_error "INSTALL_DIR, FIFO_PATH, and IMAGE_PATH must be set before rendering the plist"
        return 1
    fi
    prefix="$(escape_repl "$INSTALL_DIR")"
    fifo="$(escape_repl "$FIFO_PATH")"
    image="$(escape_repl "$IMAGE_PATH")"
    content="${content//\{\{INSTALL_PREFIX\}\}/${prefix}}"
    content="${content//\{\{FIFO_PATH\}\}/${fifo}}"
    content="${content//\{\{IMAGE_PATH\}\}/${image}}"
    printf '%s' "$content"
}

# launchctl list columns: PID Status Label
# PID is "-" when the job is not running. Status 78 is EX_CONFIG.
classify_launchctl_status() {
    local pid="$1"
    local status="$2"
    if [[ "$status" == "78" ]]; then
        printf '%s' "ex_config"
    elif [[ -z "$pid" || "$pid" == "-" ]]; then
        printf '%s' "not_running"
    else
        printf '%s' "running"
    fi
}

reject_unsubstituted() {
    local file="$1"
    local what="$2"
    if grep -q '{{' "$file"; then
        log_error "${what} still contains unsubstituted {{placeholders}}: ${file}"
        log_error "Refusing to load it. launchd would exit EX_CONFIG (78) and clipboard-sync-daemon would never start."
        return 1
    fi
    return 0
}

# Write a substituted plist to dest. Does not call launchctl.
render_plist_to() {
    local dest="$1"
    local content rendered tmp dest_dir

    content="$(load_plist_template)" || return 1
    rendered="$(apply_plist_placeholders "$content")" || return 1

    dest_dir="$(dirname "$dest")"
    mkdir -p "$dest_dir"
    tmp="$(mktemp "${dest_dir}/.clipboard-sync.plist.XXXXXX")"
    printf '%s\n' "$rendered" > "$tmp"

    if ! reject_unsubstituted "$tmp" "LaunchAgent plist"; then
        rm -f "$tmp"
        return 1
    fi
    if ! grep -F -q "<string>${INSTALL_DIR}/clipboard-sync-daemon</string>" "$tmp"; then
        log_error "Rendered plist is missing program path ${INSTALL_DIR}/clipboard-sync-daemon"
        rm -f "$tmp"
        return 1
    fi
    if ! grep -F -q "<string>${FIFO_PATH}</string>" "$tmp"; then
        log_error "Rendered plist is missing FIFO path ${FIFO_PATH}"
        rm -f "$tmp"
        return 1
    fi
    chmod 644 "$tmp"
    mv "$tmp" "$dest"
}

wait_for_fifo() {
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if [[ -p "$FIFO_PATH" ]]; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}

print_roundtrip_hint() {
    echo ""
    echo "One-shot text check (from Linux, after config.ini and SSH work):"
    echo "  clipboard-sync sync-to      # push text Linux → Mac"
    echo "  clipboard-sync sync-from    # pull text Mac → Linux"
    echo "On this Mac, a FIFO wake is: echo PING > ${FIFO_PATH}"
    echo ""
}

# Returns 0 when the loaded agent is healthy. On EX_CONFIG, unloads the
# plist so launchd does not keep a broken job.
self_check_macos() {
    local failed=0
    local line pid status kind

    if [[ ! -f "$PLIST_PATH" ]]; then
        log_error "LaunchAgent plist was not written: $PLIST_PATH"
        return 1
    fi
    if ! reject_unsubstituted "$PLIST_PATH" "LaunchAgent plist"; then
        launchctl unload "$PLIST_PATH" 2>/dev/null || true
        return 1
    fi
    log_success "LaunchAgent plist has no unsubstituted placeholders"

    line="$(launchctl list 2>/dev/null | awk '$3 == "clipboard-sync.daemon" { print $1, $2; exit }' || true)"
    if [[ -z "$line" ]]; then
        log_error "LaunchAgent clipboard-sync.daemon is not loaded"
        failed=1
    else
        pid="${line%% *}"
        status="${line#* }"
        kind="$(classify_launchctl_status "$pid" "$status")"
        case "$kind" in
            running)
                log_success "clipboard-sync-daemon is running (pid ${pid})"
                ;;
            ex_config)
                log_error "LaunchAgent clipboard-sync.daemon exited EX_CONFIG (78)."
                log_error "The program path in ${PLIST_PATH} is missing or still unsubstituted. Unloading it."
                launchctl unload "$PLIST_PATH" 2>/dev/null || true
                failed=1
                ;;
            *)
                log_error "clipboard-sync-daemon is not running (last status ${status}). See /tmp/clipboard-sync-daemon.log"
                failed=1
                ;;
        esac
    fi

    if wait_for_fifo; then
        log_success "FIFO exists: $FIFO_PATH"
    else
        log_error "FIFO missing or not a pipe: $FIFO_PATH (daemon did not create it)"
        failed=1
    fi

    if [[ "$failed" -ne 0 ]]; then
        log_error "Post-install self-check failed"
        return 1
    fi
    print_roundtrip_hint
    log_success "Post-install self-check passed"
    return 0
}

install_launchagent() {
    local daemon="${INSTALL_DIR}/clipboard-sync-daemon"

    if [[ ! -x "$daemon" ]]; then
        log_error "Daemon binary missing or not executable: $daemon"
        log_error "Refusing to load a LaunchAgent that would exit EX_CONFIG (78)."
        return 1
    fi

    # Render aside, then install, so a failed substitution never replaces a
    # working plist and a raw template is never what launchctl loads.
    local staged
    staged="$(mktemp "${TMPDIR:-/tmp}/clipboard-sync.plist.XXXXXX")"
    if ! render_plist_to "$staged"; then
        rm -f "$staged"
        return 1
    fi

    mkdir -p "$PLIST_DIR"
    local loaded
    loaded="$(launchctl list 2>/dev/null || true)"
    if [[ "$loaded" == *"clipboard-sync.daemon"* ]]; then
        launchctl unload "$PLIST_PATH" 2>/dev/null || true
    fi
    mv "$staged" "$PLIST_PATH"
    chmod 644 "$PLIST_PATH"

    if ! reject_unsubstituted "$PLIST_PATH" "LaunchAgent plist"; then
        rm -f "$PLIST_PATH"
        return 1
    fi

    if ! launchctl load -w "$PLIST_PATH"; then
        log_error "launchctl load failed for $PLIST_PATH"
        return 1
    fi
    log_success "LaunchAgent loaded: clipboard-sync.daemon (${daemon})"

    self_check_macos
}

main() {
    echo ""
    echo "=========================================="
    echo "  Clipboard Sync - macOS Installer"
    echo "=========================================="
    echo ""

    if [[ "$(uname)" != "Darwin" ]]; then
        log_error "This script is for macOS only"
        exit 1
    fi

    ARCH=$(get_arch)
    log_info "Architecture: $ARCH"

    VERSION=$(get_latest_release)
    if [[ -z "$VERSION" ]]; then
        log_warn "No release tag found; will build from master"
    else
        log_info "Latest release: $VERSION"
    fi

    mkdir -p "$INSTALL_DIR"

    download_or_build "imagecopy" "$ARCH" "$VERSION" "${INSTALL_DIR}/imagecopy"
    log_success "Installed ${INSTALL_DIR}/imagecopy"

    download_or_build "clipboard-sync-daemon" "$ARCH" "$VERSION" "${INSTALL_DIR}/clipboard-sync-daemon"
    log_success "Installed ${INSTALL_DIR}/clipboard-sync-daemon"

    install_launchagent

    echo ""
    log_success "macOS side ready (push daemon + imagecopy)"
    echo ""
    echo "FIFO:  $FIFO_PATH"
    echo "Image: $IMAGE_PATH"
    echo "Logs:  /tmp/clipboard-sync-daemon.log"
    echo "Plist: $PLIST_PATH"
    echo ""
    echo "On Linux set in ~/.config/clipboard-sync/config.ini:"
    echo "  macos_event_mode = fifo"
    echo "  macos_event_fifo = $FIFO_PATH"
    echo "  image_copy_path = ${INSTALL_DIR}/imagecopy"
    echo ""
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
