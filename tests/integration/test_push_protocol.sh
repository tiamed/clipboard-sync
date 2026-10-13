#!/bin/bash
# Tests for push-architecture helpers (no Wayland / Mac required).
set -euo pipefail

TEST_HOME=$(mktemp -d)
export HOME="$TEST_HOME"
export CLIPBOARD_SYNC_STATE="$TEST_HOME/state"
export CLIPBOARD_SYNC_CONFIG="$TEST_HOME/config.ini"
mkdir -p "$CLIPBOARD_SYNC_STATE"
trap 'rm -rf "$TEST_HOME"' EXIT

# shellcheck disable=SC1091
source "$(dirname "$0")/../../bin/clipboard-sync"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

[[ "$MACOS_EVENT_MODE" == "fifo" ]] || fail "default macos_event_mode should be fifo (got $MACOS_EVENT_MODE)"
pass "default macos_event_mode=fifo"

[[ "$POLL_INTERVAL" == "30" ]] || fail "default poll_interval should be 30"
pass "default poll_interval=30"

h1=$(get_text_hash "hello")
h2=$(get_text_hash "hello")
h3=$(get_text_hash "hello ")
[[ "$h1" == "$h2" ]] || fail "identical text should hash equal"
[[ "$h1" == "$h3" ]] || fail "trailing whitespace should be ignored in text hash"
pass "text hash stable / trims trailing space"

setup
write_text_hash "abc"
[[ "$(read_text_hash)" == "abc" ]] || fail "read/write text hash"
with_lock write_text_hash "def"
[[ "$(read_text_hash)" == "def" ]] || fail "with_lock write"
pass "state + flock"

apply_text_to_linux() { printf '%s' "$1" > "$TEST_HOME/applied_text"; return 0; }
notify_linux() { :; }
ENABLE_TEXT=true
MIN_LENGTH=1
b64=$(printf 'pushed-from-mac' | base64 -w0 2>/dev/null || printf 'pushed-from-mac' | base64)
apply_macos_text_payload "$b64"
[[ -f "$TEST_HOME/applied_text" ]] || fail "text not applied"
[[ "$(cat "$TEST_HOME/applied_text")" == "pushed-from-mac" ]] || fail "wrong text applied"
[[ "$(read_text_hash)" == "$(get_text_hash 'pushed-from-mac')" ]] || fail "hash not updated after apply"
pass "TEXT payload apply"

rm -f "$TEST_HOME/applied_text"
apply_macos_text_payload "$b64"
[[ ! -f "$TEST_HOME/applied_text" ]] || fail "duplicate TEXT should be skipped"
pass "TEXT echo-loop guard"

handle_fifo_line "TEXT:$b64"
handle_fifo_line "PING"
pass "fifo line dispatch"

# Path validation (real apply_macos_imgfile; scp must not run)
if apply_macos_imgfile "/etc/passwd"; then
    fail "should reject non-/tmp path"
fi
if apply_macos_imgfile "/tmp/../etc/passwd"; then
    fail "should reject path with .."
fi
pass "IMGFILE path validation"

cat > "$CLIPBOARD_SYNC_CONFIG" << 'INI'
[remote]
user = alice
host = 10.0.0.2
image_copy_path = /Users/alice/scripts/imagecopy

[sync]
macos_event_mode = fifo
macos_event_fifo = /tmp/custom.fifo
macos_push_image = /tmp/custom.png
poll_interval = 45

[ssh]
mux_enabled = true
mux_persist = 120
INI
parse_config "$CLIPBOARD_SYNC_CONFIG"
[[ "$REMOTE_USER" == "alice" ]] || fail "parse user"
[[ "$REMOTE_HOST" == "10.0.0.2" ]] || fail "parse host"
[[ "$MACOS_EVENT_FIFO" == "/tmp/custom.fifo" ]] || fail "parse fifo"
[[ "$MACOS_PUSH_IMAGE" == "/tmp/custom.png" ]] || fail "parse push image"
[[ "$POLL_INTERVAL" == "45" ]] || fail "parse poll"
[[ "$SSH_MUX_PERSIST" == "120" ]] || fail "parse mux_persist"
pass "parse_config new keys"

echo "All push-protocol tests passed."
