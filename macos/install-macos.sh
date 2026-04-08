#!/bin/bash
#
# install-macos.sh - Install imagecopy helper on macOS
#
# Usage: curl -sSL https://tiamed.github.io/clipboard-sync/install-macos.sh | bash
#

set -euo pipefail

REPO="tiamed/clipboard-sync"
INSTALL_DIR="${HOME}/scripts"
BINARY_NAME="imagecopy"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

get_arch() {
    case "$(uname -m)" in
        arm64)  echo "arm64" ;;
        x86_64) echo "x86_64" ;;
        *)      log_error "Unsupported architecture: $(uname -m)"; exit 1 ;;
    esac
}

get_latest_release() {
    curl -s "https://api.github.com/repos/${REPO}/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/'
}

main() {
    echo ""
    echo "=========================================="
    echo "  Clipboard Sync - macOS Helper Installer"
    echo "=========================================="
    echo ""
    
    if [[ "$(uname)" != "Darwin" ]]; then
        log_error "This script is for macOS only"
        exit 1
    fi
    
    ARCH=$(get_arch)
    log_info "Detected architecture: $ARCH"
    
    VERSION=$(get_latest_release)
    if [[ -z "$VERSION" ]]; then
        log_error "Could not determine latest release"
        exit 1
    fi
    log_info "Latest version: $VERSION"
    
    mkdir -p "$INSTALL_DIR"
    
    DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${VERSION}/imagecopy-${ARCH}"
    log_info "Downloading from: $DOWNLOAD_URL"
    
    if ! curl -fSL -o "${INSTALL_DIR}/${BINARY_NAME}" "$DOWNLOAD_URL"; then
        log_error "Download failed"
        exit 1
    fi
    
    chmod +x "${INSTALL_DIR}/${BINARY_NAME}"
    log_success "Installed to: ${INSTALL_DIR}/${BINARY_NAME}"
    
    echo ""
    log_success "Installation complete!"
    echo ""
    echo "You can now use imagecopy:"
    echo "  ~/scripts/imagecopy /path/to/image.png     # Push image to clipboard"
    echo "  ~/scripts/imagecopy -o /path/to/output.png # Save clipboard image to file"
    echo ""
}

main "$@"
