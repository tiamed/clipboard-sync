#!/bin/bash
# Inbound FIFO worker must not die when remote FIFO is missing (ssh exit 2).
set -euo pipefail

TEST_HOME=$(mktemp -d)
export HOME="$TEST_HOME"
export CLIPBOARD_SYNC_STATE="$TEST_HOME/state"
export CLIPBOARD_SYNC_CONFIG="$TEST_HOME/config.ini"
mkdir -p "$CLIPBOARD_SYNC_STATE" "$TEST_HOME/bin"
trap 'rm -rf "$TEST_HOME"; kill "$WORKER_PID" 2>/dev/null || true' EXIT

# Fake ssh: first call (master check/open) succeeds; FIFO stream exits 2 with message
cat > "$TEST_HOME/bin/ssh" << 'SSH'
#!/bin/bash
# ControlMaster check / open
if [[ "$*" == *"-O check"* ]] || [[ "$*" == *"-fN"* ]] || [[ "$*" == *"-M"* ]]; then
  exit 0
fi
# Stream command: print FIFO missing and exit 2
echo "FIFO missing at /tmp/clipboard-sync.fifo — start clipboard-sync-daemon on Mac" >&2
exit 2
SSH
chmod +x "$TEST_HOME/bin/ssh"
export PATH="$TEST_HOME/bin:$PATH"

# shellcheck disable=SC1091
source "$(dirname "$0")/../../bin/clipboard-sync"

TEMP_DIR=$(mktemp -d)
REMOTE_USER=bo
REMOTE_HOST=127.0.0.1
SSH_MUX_ENABLED=false
MACOS_EVENT_FIFO=/tmp/clipboard-sync.fifo
ENABLE_TEXT=true

# Capture logs
LOGF="$TEST_HOME/log"
log_info()  { echo "INFO $*" | tee -a "$LOGF"; }
log_warn()  { echo "WARN $*" | tee -a "$LOGF"; }
log_error() { echo "ERROR $*" | tee -a "$LOGF"; }
log_debug() { :; }

run_inbound_fifo_worker &
WORKER_PID=$!
sleep 3

if ! kill -0 "$WORKER_PID" 2>/dev/null; then
  echo "FAIL: inbound worker died after FIFO-missing ssh (set -e leak)" >&2
  cat "$LOGF" >&2 || true
  exit 1
fi

kill "$WORKER_PID" 2>/dev/null || true
wait "$WORKER_PID" 2>/dev/null || true

grep -q "FIFO unavailable\|FIFO missing\|Mac FIFO" "$LOGF" || {
  echo "FAIL: expected FIFO-missing error in log" >&2
  cat "$LOGF" >&2
  exit 1
}
echo "PASS: inbound FIFO worker survives missing Mac FIFO and retries"
