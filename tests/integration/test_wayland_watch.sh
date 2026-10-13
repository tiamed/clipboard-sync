#!/bin/bash
# Optional Wayland smoke test. Skips when no compositor / wl-paste --watch.
set -euo pipefail

TEST_HOME=$(mktemp -d)
export HOME="$TEST_HOME"
export CLIPBOARD_SYNC_STATE="$TEST_HOME/state"
mkdir -p "$CLIPBOARD_SYNC_STATE"
trap 'rm -rf "$TEST_HOME"' EXIT

# shellcheck disable=SC1091
source "$(dirname "$0")/../../bin/clipboard-sync"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
skip() { echo "SKIP: $*"; exit 0; }

USE_WAYLAND_WATCH=true
if [[ -z "${WAYLAND_DISPLAY:-}" ]]; then
    skip "WAYLAND_DISPLAY not set"
fi
if ! command -v wl-paste >/dev/null 2>&1; then
    skip "wl-paste not installed"
fi
if ! wl_paste_watch_supported; then
    skip "wl-paste lacks --watch"
fi

if ! wayland_watch_available; then
    fail "wayland_watch_available should be true in this environment"
fi
pass "wayland_watch_available"

# Outbound handlers with stubbed SSH push
setup
PUSHED_TEXT=""
push_text_to_macos() { PUSHED_TEXT="$1"; return 0; }
ensure_ssh_master() { return 0; }
notify_macos() { :; }
ENABLE_TEXT=true
MIN_LENGTH=1

echo "hello push arch" | timeout 2 wl-copy -t text/plain
sleep 0.2
handle_linux_text_change
[[ "$PUSHED_TEXT" == "hello push arch" ]] || fail "expected push, got '$PUSHED_TEXT'"
pass "handle_linux_text_change pushes new text"

# Duplicate should not push again
PUSHED_TEXT=""
handle_linux_text_change
[[ -z "$PUSHED_TEXT" ]] || fail "duplicate should not push"
pass "outbound echo-loop guard"

echo "All Wayland watch smoke tests passed."
