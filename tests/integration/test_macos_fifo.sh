#!/bin/bash
# Unit-style tests for the macOS FIFO event reader logic.
# The actual Swift daemon cannot be built or run on Linux, so this only tests
# the bash-side availability checks and event-handler wiring.
set -euo pipefail

TEST_HOME=$(mktemp -d)
export HOME="$TEST_HOME"
trap 'rm -rf "$TEST_HOME"' EXIT

source "$(dirname "$0")/../../bin/clipboard-sync"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

pass() {
    echo "PASS: $*"
}

# Default mode is polling.
MACOS_EVENT_MODE="polling"
if macos_fifo_available; then
    fail "macos_fifo_available should be false in polling mode"
fi
pass "polling mode disables FIFO reader"

# FIFO mode requires a path.
MACOS_EVENT_MODE="fifo"
MACOS_EVENT_FIFO=""
if macos_fifo_available; then
    fail "macos_fifo_available should be false with empty FIFO path"
fi
pass "empty FIFO path disables FIFO reader"

# FIFO mode with a path is available.
MACOS_EVENT_MODE="fifo"
MACOS_EVENT_FIFO="/tmp/clipboard-sync.fifo"
if ! macos_fifo_available; then
    fail "macos_fifo_available should be true in fifo mode with a path"
fi
pass "fifo mode with path enables FIFO reader"

echo "All macOS FIFO tests passed."
