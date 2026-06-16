#!/bin/bash
# Integration tests for Wayland event-driven clipboard monitoring.
# Requires a Wayland session and the original wl-clipboard (supports --watch).
set -euo pipefail

ORIG_WL_CLIPBOARD="/tmp/opencode/wl-clipboard/bin"
export PATH="$ORIG_WL_CLIPBOARD:$PATH"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"

TEST_HOME=$(mktemp -d)
export HOME="$TEST_HOME"
trap 'rm -rf "$TEST_HOME"; stop_wayland_watchers 2>/dev/null || true' EXIT

# shellcheck source=../../bin/clipboard-sync
source "$(dirname "$0")/../../bin/clipboard-sync"

mkdir -p "$HOME/.config/clipboard-sync"
cat > "$HOME/.config/clipboard-sync/config.ini" <<'EOF'
[remote]
user = testuser
host = testhost
image_copy_path = /tmp/imagecopy

[sync]
min_length = 1
poll_interval = 1
enable_text = true
enable_image = true
use_wayland_watch = true
EOF

# Stub out remote operations and notifications.
PUSHED_TEXT=""
PUSHED_IMAGE=""
push_text_to_macos() { PUSHED_TEXT="$1"; return 0; }
push_image_to_macos() {
    local src="$1"
    local dst="$TEST_HOME/pushed_image"
    cp "$src" "$dst" || return 1
    PUSHED_IMAGE="$dst"
    return 0
}
check_connection() { return 0; }
notify_linux() { :; }
notify_macos() { :; }

setup

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

pass() {
    echo "PASS: $*"
}

# Test 1: original wl-clipboard reports watch support.
if ! wayland_watch_available; then
    fail "wayland_watch_available should be true with original wl-clipboard"
fi
pass "wayland_watch_available with original wl-clipboard"

# Test 2: fallback when wl-paste lacks --watch (wl-clipboard-rs).
PATH_WITHOUT_WATCH="/usr/bin:/bin"
if PATH="$PATH_WITHOUT_WATCH" wayland_watch_available 2>/dev/null; then
    fail "wayland_watch_available should be false with wl-clipboard-rs"
fi
pass "graceful degradation when wl-paste lacks --watch"

# Test 3: start/stop watchers.
start_wayland_watchers
[[ -n "$TEXT_WATCH_PID" ]] || fail "text watcher PID not set"
[[ -n "$IMG_WATCH_PID" ]] || fail "image watcher PID not set"
kill -0 "$TEXT_WATCH_PID" || fail "text watcher not alive"
kill -0 "$IMG_WATCH_PID" || fail "image watcher not alive"
stop_wayland_watchers
if kill -0 "$TEXT_WATCH_PID" 2>/dev/null || kill -0 "$IMG_WATCH_PID" 2>/dev/null; then
    fail "watchers still alive after stop"
fi
pass "start/stop watchers"

# Test 4: text clipboard change triggers event and sync.
start_wayland_watchers
echo "hello integration test" | wl-copy
sleep 0.3

event=""
if read -r -t 2 -u "$TEXT_WATCH_FD" event; then
    [[ "$event" == "TEXT_CHANGED" ]] || fail "unexpected text event: $event"
else
    fail "no text event received"
fi

poll_linux_text
[[ "$PUSHED_TEXT" == "hello integration test" ]] || fail "pushed text mismatch: '$PUSHED_TEXT'"
pass "text change triggers sync"

# Test 5: image clipboard change triggers event and sync.
python3 - <<'PY'
from PIL import Image
import io, subprocess
img = Image.new('RGB', (10, 10), color='red')
b = io.BytesIO()
img.save(b, format='PNG')
subprocess.run(['wl-copy', '--type', 'image/png'], input=b.getvalue(), check=True)
PY
sleep 0.3

event=""
if read -r -t 2 -u "$IMG_WATCH_FD" event; then
    [[ "$event" == "IMG_CHANGED" ]] || fail "unexpected image event: $event"
else
    fail "no image event received"
fi

poll_linux_image
[[ -n "$PUSHED_IMAGE" ]] || fail "no image pushed"
[[ -s "$PUSHED_IMAGE" ]] || fail "pushed image is empty"
pass "image change triggers sync"

stop_wayland_watchers

echo "All Wayland watch integration tests passed."
