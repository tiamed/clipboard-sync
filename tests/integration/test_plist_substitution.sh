#!/bin/bash
# LaunchAgent and systemd templates must be substituted before install.
# A raw {{INSTALL_PREFIX}} plist is what made launchd exit EX_CONFIG (78).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# shellcheck disable=SC1091
source "$ROOT/macos/install-macos.sh"

embedded="$(embedded_plist_template)"
file_tpl="$(cat "$ROOT/macos/clipboard-sync-daemon.plist.template")"
[[ "$embedded" == "$file_tpl" ]] || fail "embedded plist template drifted from clipboard-sync-daemon.plist.template"
pass "embedded template matches plist.template"

[[ "$file_tpl" == *"{{INSTALL_PREFIX}}/clipboard-sync-daemon"* ]] || fail "template should keep the INSTALL_PREFIX token"
pass "on-disk template still has the unsubstituted token"

TEST_HOME="$(mktemp -d)"
trap 'rm -rf "$TEST_HOME"' EXIT

INSTALL_DIR="$TEST_HOME/scripts"
FIFO_PATH="$TEST_HOME/clipboard-sync.fifo"
IMAGE_PATH="$TEST_HOME/clipboard-sync-push.png"
PLIST_DIR="$TEST_HOME/LaunchAgents"
PLIST_PATH="$PLIST_DIR/clipboard-sync.daemon.plist"
mkdir -p "$INSTALL_DIR"
printf '#!/bin/sh\nexit 0\n' > "$INSTALL_DIR/clipboard-sync-daemon"
chmod +x "$INSTALL_DIR/clipboard-sync-daemon"
mkfifo "$FIFO_PATH"

render_plist_to "$TEST_HOME/rendered.plist"
if grep -q '{{' "$TEST_HOME/rendered.plist"; then
    fail "rendered plist still has placeholders"
fi
grep -F -q "<string>${INSTALL_DIR}/clipboard-sync-daemon</string>" "$TEST_HOME/rendered.plist" || fail "program path missing"
grep -F -q "<string>${FIFO_PATH}</string>" "$TEST_HOME/rendered.plist" || fail "fifo path missing"
grep -F -q "<string>${IMAGE_PATH}</string>" "$TEST_HOME/rendered.plist" || fail "image path missing"
pass "render substitutes INSTALL_PREFIX, FIFO_PATH, IMAGE_PATH"

# curl | bash has no sibling template; the embedded copy must render the same way.
saved_script_dir="$SCRIPT_DIR"
SCRIPT_DIR=""
render_plist_to "$TEST_HOME/embedded-rendered.plist"
SCRIPT_DIR="$saved_script_dir"
if ! cmp -s "$TEST_HOME/rendered.plist" "$TEST_HOME/embedded-rendered.plist"; then
    fail "embedded template render differs from the on-disk template"
fi
pass "stdin/embedded render matches the on-disk template"

bad="$TEST_HOME/bad.template"
printf '%s\n{{DO_NOT_LOAD}}\n' "$file_tpl" > "$bad"
CLIPBOARD_SYNC_PLIST_TEMPLATE="$bad"
if render_plist_to "$TEST_HOME/should-not-exist.plist"; then
    fail "render should reject leftover placeholders"
fi
if [[ -f "$TEST_HOME/should-not-exist.plist" ]]; then
    fail "rejected render must not write the plist"
fi
pass "leftover placeholder is not written"

CLIPBOARD_SYNC_PLIST_TEMPLATE=""
saved_prefix="$INSTALL_DIR"
INSTALL_DIR=""
if render_plist_to "$TEST_HOME/empty.plist"; then
    fail "empty INSTALL_DIR should fail"
fi
INSTALL_DIR="$saved_prefix"
pass "empty INSTALL_DIR refused"

BIN="$TEST_HOME/bin"
mkdir -p "$BIN"
LAUNCHCTL_LOG="$TEST_HOME/launchctl.log"
export LAUNCHCTL_LOG LAUNCHCTL_LIST_LINE
LAUNCHCTL_LIST_LINE=""
cat > "$BIN/launchctl" << 'EOF'
#!/bin/bash
echo "$*" >> "$LAUNCHCTL_LOG"
if [[ "$1" == "list" ]]; then
    if [[ -n "${LAUNCHCTL_LIST_LINE:-}" ]]; then
        echo "$LAUNCHCTL_LIST_LINE"
    else
        echo "4321 0 clipboard-sync.daemon"
    fi
fi
exit 0
EOF
chmod +x "$BIN/launchctl"
export PATH="$BIN:$PATH"

: > "$LAUNCHCTL_LOG"
install_launchagent
if grep -q '{{' "$PLIST_PATH"; then
    fail "loaded plist has placeholders"
fi
grep -F -q "<string>${INSTALL_DIR}/clipboard-sync-daemon</string>" "$PLIST_PATH" || fail "installed plist path"
if ! grep -q "load -w" "$LAUNCHCTL_LOG"; then
    fail "launchctl load was not called"
fi
pass "install_launchagent loads a substituted plist"

: > "$LAUNCHCTL_LOG"
CLIPBOARD_SYNC_PLIST_TEMPLATE="$bad"
if install_launchagent; then
    fail "install_launchagent should fail when the template still has placeholders"
fi
if grep -q "load -w" "$LAUNCHCTL_LOG"; then
    fail "launchctl load ran for an unsubstituted plist"
fi
pass "raw template is never launchctl loaded"

CLIPBOARD_SYNC_PLIST_TEMPLATE=""
cp "$ROOT/macos/clipboard-sync-daemon.plist.template" "$PLIST_PATH"
: > "$LAUNCHCTL_LOG"
if self_check_macos; then
    fail "self-check should reject a plist that still contains placeholders"
fi
if ! grep -q "unload" "$LAUNCHCTL_LOG"; then
    fail "self-check should unload a raw template"
fi
pass "self-check unloads a raw template instead of leaving it running"

LAUNCHCTL_LIST_LINE="- 78 clipboard-sync.daemon"
: > "$LAUNCHCTL_LOG"
# Restore a valid plist, then simulate launchd EX_CONFIG.
render_plist_to "$PLIST_PATH"
if install_launchagent; then
    fail "EX_CONFIG (78) should fail the self-check"
fi
if ! grep -q "unload" "$LAUNCHCTL_LOG"; then
    fail "EX_CONFIG should unload the LaunchAgent"
fi
if grep -q '{{' "$PLIST_PATH"; then
    fail "EX_CONFIG plist should still be substituted"
fi
pass "EX_CONFIG unloads and fails the self-check"

[[ "$(classify_launchctl_status 4321 0)" == "running" ]] || fail "running"
[[ "$(classify_launchctl_status - 78)" == "ex_config" ]] || fail "ex_config"
[[ "$(classify_launchctl_status - 1)" == "not_running" ]] || fail "not_running"
pass "launchctl status classification"

INSTALL_DIR="$TEST_HOME/My Scripts & stuff"
mkdir -p "$INSTALL_DIR"
FIFO_PATH="$TEST_HOME/fifo path"
IMAGE_PATH="$TEST_HOME/image.png"
printf '#!/bin/sh\nexit 0\n' > "$INSTALL_DIR/clipboard-sync-daemon"
chmod +x "$INSTALL_DIR/clipboard-sync-daemon"
render_plist_to "$TEST_HOME/spaces.plist"
grep -F -q "<string>${INSTALL_DIR}/clipboard-sync-daemon</string>" "$TEST_HOME/spaces.plist" || fail "odd prefix was not substituted"
if grep -q '{{' "$TEST_HOME/spaces.plist"; then
    fail "odd prefix render left tokens"
fi
pass "prefix with spaces and & substitutes cleanly"

# shellcheck disable=SC1091
source "$ROOT/scripts/install.sh"
PREFIX="$TEST_HOME/prefix"
unit="$TEST_HOME/clipboard-sync.service"
render_systemd_unit "$unit"
if grep -q '{{' "$unit"; then
    fail "systemd unit still has placeholders"
fi
grep -F -q "ExecStart=${PREFIX}/bin/clipboard-sync" "$unit" || fail "ExecStart path missing"
pass "systemd unit substitutes INSTALL_PREFIX"

PREFIX="$TEST_HOME/pre & fix"
render_systemd_unit "$TEST_HOME/amp.service"
grep -F -q "ExecStart=${PREFIX}/bin/clipboard-sync" "$TEST_HOME/amp.service" || fail "systemd prefix with & was corrupted"
if grep -q '{{' "$TEST_HOME/amp.service"; then
    fail "systemd prefix with & left a placeholder"
fi
pass "systemd prefix with & substitutes cleanly"

bad_unit_tpl="$TEST_HOME/bad.service.template"
printf '%s\n{{STILL_HERE}}\n' "$(cat "$ROOT/systemd/clipboard-sync.service.template")" > "$bad_unit_tpl"
if render_systemd_unit "$TEST_HOME/bad.service" "$bad_unit_tpl"; then
    fail "bad systemd template should be rejected"
fi
if [[ -f "$TEST_HOME/bad.service" ]]; then
    fail "rejected systemd unit was written"
fi
pass "systemd raw template is not installed"

saved_prefix="$PREFIX"
PREFIX=""
if render_systemd_unit "$TEST_HOME/empty.service"; then
    fail "empty PREFIX should fail"
fi
PREFIX="$saved_prefix"
pass "empty PREFIX refused"

# shellcheck disable=SC1091
source "$ROOT/scripts/install-linux.sh"
good="$TEST_HOME/good.service"
echo "ExecStart=${PREFIX}/bin/clipboard-sync" > "$good"
assert_no_placeholders "$good" "systemd unit"
[[ -f "$good" ]] || fail "good unit was removed"
badf="$TEST_HOME/bad-linux.service"
echo "ExecStart={{INSTALL_PREFIX}}/bin/clipboard-sync" > "$badf"
if assert_no_placeholders "$badf" "systemd unit"; then
    fail "linux installer should reject an unsubstituted unit"
fi
if [[ -f "$badf" ]]; then
    fail "unsubstituted linux unit should be removed"
fi
pass "linux installer rejects an unsubstituted unit"

echo "All plist/unit substitution checks passed"
