#!/bin/bash
#
# install-macos.sh - Install imagecopy + clipboard-sync-daemon on macOS
#
# Usage: curl -sSL https://tiamed.github.io/clipboard-sync/install-macos.sh | bash
#

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
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

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

install_launchagent() {
    mkdir -p "$PLIST_DIR"
    if launchctl list 2>/dev/null | grep -q "clipboard-sync.daemon"; then
        launchctl unload "$PLIST_PATH" 2>/dev/null || true
    fi

    cat > "$PLIST_PATH" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>clipboard-sync.daemon</string>
    <key>ProgramArguments</key>
    <array>
        <string>${INSTALL_DIR}/clipboard-sync-daemon</string>
        <string>--fifo-path</string>
        <string>${FIFO_PATH}</string>
        <string>--image-path</string>
        <string>${IMAGE_PATH}</string>
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
PLIST

    launchctl load -w "$PLIST_PATH"
    log_success "LaunchAgent loaded: clipboard-sync.daemon"
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
    echo ""
    echo "On Linux set in ~/.config/clipboard-sync/config.ini:"
    echo "  macos_event_mode = fifo"
    echo "  macos_event_fifo = $FIFO_PATH"
    echo "  image_copy_path = ${INSTALL_DIR}/imagecopy"
    echo ""
}

main "$@"
