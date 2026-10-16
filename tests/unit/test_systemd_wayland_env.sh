#!/bin/bash
# Unit generation must follow the live Wayland socket and must not bake wayland-0.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

extract_heredoc() {
    local file="$1"
    local begin_re="$2"
    local end_line="$3"
    awk -v begin_re="$begin_re" -v end_line="$end_line" '
        $0 ~ begin_re { capturing = 1; next }
        capturing && $0 == end_line { capturing = 0; next }
        capturing { print }
    ' "$file"
}

assert_same_file() {
    local label="$1"
    local expected="$2"
    local actual="$3"
    if ! diff -u "$expected" "$actual" >/tmp/systemd-unit-diff.txt; then
        cat /tmp/systemd-unit-diff.txt >&2
        fail "$label diverged"
    fi
    pass "$label matches"
}

# Embedded curl|bash copies stay byte-for-byte with the repo sources.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

extract_heredoc "$ROOT/scripts/install-linux.sh" \
    "<< 'END_SYSTEMD_UNIT_SH'" "END_SYSTEMD_UNIT_SH" > "$tmp/embedded-unit.sh"
extract_heredoc "$ROOT/scripts/install-linux.sh" \
    "<< 'END_UNIT_TEMPLATE'" "END_UNIT_TEMPLATE" > "$tmp/embedded-template"
assert_same_file "embedded systemd-unit.sh" \
    "$ROOT/scripts/systemd-unit.sh" "$tmp/embedded-unit.sh"
assert_same_file "embedded service template" \
    "$ROOT/systemd/clipboard-sync.service.template" "$tmp/embedded-template"

if grep -nE 'WAYLAND_DISPLAY=wayland-0|DISPLAY=:0|/run/user/1000|:-wayland-0' \
    "$ROOT/scripts/systemd-unit.sh" \
    "$ROOT/systemd/clipboard-sync.service.template" \
    "$ROOT/scripts/install.sh" \
    "$ROOT/scripts/install-linux.sh" >/tmp/systemd-unit-grep.txt; then
    cat /tmp/systemd-unit-grep.txt >&2
    fail "hardcoded wayland-0, DISPLAY=:0, or uid 1000 remains in the install path"
fi
pass "install path has no hardcoded wayland-0 / :0 / uid 1000"

make_socket() {
    local path="$1"
    python3 - "$path" << 'PY'
import os, socket, sys
path = sys.argv[1]
try:
    os.unlink(path)
except FileNotFoundError:
    pass
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.bind(path)
sock.close()
PY
}

render_with() {
    local helper_mode="$1"
    local runtime="$2"
    (
        # shellcheck disable=SC1091
        source "$ROOT/scripts/install-linux.sh"
        unset WAYLAND_DISPLAY DISPLAY || true
        # shellcheck disable=SC1090
        if [[ -n "${ENV_FILE:-}" ]]; then
            # shellcheck disable=SC1090
            source "$ENV_FILE"
        fi
        export XDG_RUNTIME_DIR="$runtime"
        if [[ "$helper_mode" == "embedded" ]]; then
            export CLIPBOARD_SYNC_EMBEDDED_UNIT_HELPERS=1
        fi
        load_systemd_unit_helpers
        template="$(clipboard_sync_unit_template_text)"
        rendered="$(apply_clipboard_sync_unit_template "/opt/clipboard-sync" "$template")"
        printf '%s\n' "$rendered"
    )
}

assert_unit_common() {
    local unit="$1"
    grep -q '^After=graphical-session.target$' "$unit" || fail "missing After=graphical-session.target in $unit"
    grep -q '^PartOf=graphical-session.target$' "$unit" || fail "missing PartOf in $unit"
    grep -q '^WantedBy=graphical-session.target$' "$unit" || fail "missing WantedBy=graphical-session.target in $unit"
    grep -q '^WantedBy=default.target$' "$unit" || fail "missing WantedBy=default.target in $unit"
    if grep -q 'network.target' "$unit"; then
        fail "network.target still orders $unit"
    fi
    grep -q 'ExecStart=/opt/clipboard-sync/bin/clipboard-sync' "$unit" || fail "prefix not substituted in $unit"
    if grep -q '{{' "$unit"; then
        fail "unsubstituted placeholder in $unit"
    fi
    return 0
}

runtime="$(mktemp -d)"
make_socket "$runtime/wayland-1"
printf 'lock\n' > "$runtime/wayland-0.lock"
printf 'not a socket\n' > "$runtime/wayland-0"

for mode in sibling embedded; do
    render_with "$mode" "$runtime" > "$tmp/unit-$mode"
    assert_unit_common "$tmp/unit-$mode"
    grep -q "^Environment=WAYLAND_DISPLAY=wayland-1$" "$tmp/unit-$mode" \
        || fail "$mode unit did not select wayland-1"
    grep -q "^Environment=XDG_RUNTIME_DIR=$runtime$" "$tmp/unit-$mode" \
        || fail "$mode unit runtime dir mismatch"
    if grep -q '^Environment=DISPLAY=' "$tmp/unit-$mode"; then
        fail "$mode unit baked DISPLAY from an empty session"
    fi
    if grep -q 'wayland-0' "$tmp/unit-$mode"; then
        fail "$mode unit mentions wayland-0"
    fi
    pass "$mode install selects wayland-1 and skips lock files"
done
diff -u "$tmp/unit-sibling" "$tmp/unit-embedded" >/tmp/systemd-unit-mode-diff.txt \
    || { cat /tmp/systemd-unit-mode-diff.txt >&2; fail "sibling and embedded renders differ"; }
pass "sibling and embedded renders match"

# Explicit session value wins when that socket exists, even if another is newer.
make_socket "$runtime/wayland-0"
touch -d '2020-01-01 00:00:00' "$runtime/wayland-0"
touch -d '2024-01-01 00:00:00' "$runtime/wayland-1"
cat > "$tmp/env" << EOF
WAYLAND_DISPLAY=wayland-0
DISPLAY=:1
EOF
(
    source "$ROOT/scripts/install-linux.sh"
    # shellcheck disable=SC1090
    source "$tmp/env"
    export XDG_RUNTIME_DIR="$runtime"
    load_systemd_unit_helpers
    detect_wayland_display
) > "$tmp/explicit-name"
[[ "$(cat "$tmp/explicit-name")" == "wayland-0" ]] || fail "explicit live WAYLAND_DISPLAY was ignored: $(cat "$tmp/explicit-name")"
pass "explicit live WAYLAND_DISPLAY is kept"

# Stale WAYLAND_DISPLAY is ignored when a different socket is actually present.
rm -f "$runtime/wayland-0"
printf 'WAYLAND_DISPLAY=wayland-0\n' > "$tmp/env"
(
    source "$ROOT/scripts/install-linux.sh"
    # shellcheck disable=SC1090
    source "$tmp/env"
    export XDG_RUNTIME_DIR="$runtime"
    load_systemd_unit_helpers
    detect_wayland_display
) > "$tmp/stale-name"
[[ "$(cat "$tmp/stale-name")" == "wayland-1" ]] || fail "stale WAYLAND_DISPLAY was pinned: $(cat "$tmp/stale-name")"
pass "missing WAYLAND_DISPLAY falls through to the live socket"

# No socket and no variable: omit WAYLAND_DISPLAY. Do not invent wayland-0.
empty="$(mktemp -d)"
(
    source "$ROOT/scripts/install-linux.sh"
    unset WAYLAND_DISPLAY DISPLAY
    export XDG_RUNTIME_DIR="$empty"
    load_systemd_unit_helpers
    clipboard_sync_environment_lines
) > "$tmp/empty-env"
if grep -q '^Environment=WAYLAND_DISPLAY=' "$tmp/empty-env"; then
    fail "empty session still set WAYLAND_DISPLAY: $(cat "$tmp/empty-env")"
fi
grep -q "^Environment=XDG_RUNTIME_DIR=$empty$" "$tmp/empty-env" || fail "runtime dir missing when display is unknown"
if grep -q '^Environment=DISPLAY=' "$tmp/empty-env"; then
    fail "empty session set DISPLAY"
fi
pass "unset session omits WAYLAND_DISPLAY and DISPLAY"

# Explicit name with no socket yet (SSH before the compositor): keep it.
(
    source "$ROOT/scripts/install-linux.sh"
    export WAYLAND_DISPLAY=wayland-1
    unset DISPLAY
    export XDG_RUNTIME_DIR="$empty"
    load_systemd_unit_helpers
    detect_wayland_display
) > "$tmp/pinned-name"
[[ "$(cat "$tmp/pinned-name")" == "wayland-1" ]] || fail "explicit WAYLAND_DISPLAY dropped when compositor is down"
pass "explicit WAYLAND_DISPLAY is kept when no socket exists yet"

# Several sockets: wl-paste chooses the one that accepts a client, not the newest dead socket.
make_socket "$runtime/wayland-0"
touch -d '2024-06-01 00:00:00' "$runtime/wayland-0"
touch -d '2020-01-01 00:00:00' "$runtime/wayland-1"
toolpath="$(mktemp -d)"
ln -s "$(command -v stat)" "$toolpath/stat"
ln -s "$(command -v sort)" "$toolpath/sort"
ln -s "$(command -v timeout)" "$toolpath/timeout"
fakebin="$(mktemp -d)"
cat > "$fakebin/wl-paste" << 'EOF'
#!/bin/bash
if [[ "${WAYLAND_DISPLAY:-}" == "wayland-0" ]]; then
    echo "Failed to connect to a Wayland server: No such file or directory" >&2
    exit 1
fi
printf 'text/plain\n'
exit 0
EOF
chmod +x "$fakebin/wl-paste"
(
    source "$ROOT/scripts/install-linux.sh"
    unset WAYLAND_DISPLAY DISPLAY
    export XDG_RUNTIME_DIR="$runtime"
    export PATH="$fakebin:$toolpath"
    hash -r
    load_systemd_unit_helpers
    detect_wayland_display
) > "$tmp/probed-name"
[[ "$(cat "$tmp/probed-name")" == "wayland-1" ]] || fail "probe kept a dead newer socket: $(cat "$tmp/probed-name")"
pass "probe prefers the socket wl-paste can use"

# No wl-paste: equal mtimes prefer the higher wayland-N.
touch -d '2024-01-01 00:00:00' "$runtime/wayland-0" "$runtime/wayland-1"
(
    source "$ROOT/scripts/install-linux.sh"
    unset WAYLAND_DISPLAY DISPLAY
    export XDG_RUNTIME_DIR="$runtime"
    export PATH="$toolpath"
    hash -r
    load_systemd_unit_helpers
    detect_wayland_display
) > "$tmp/tie-name"
[[ "$(cat "$tmp/tie-name")" == "wayland-1" ]] || fail "mtime tie did not prefer wayland-1: $(cat "$tmp/tie-name")"
pass "equal mtimes prefer the higher wayland-N"

# Both installers write the same unit. Use a single live socket so the
# assertion does not depend on whichever compositor this machine has.
one_socket="$(mktemp -d)"
make_socket "$one_socket/wayland-1"
printf 'lock\n' > "$one_socket/wayland-0.lock"
mockbin="$(mktemp -d)"
cat > "$mockbin/systemctl" << 'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$mockbin/systemctl"
home_a="$(mktemp -d)"
home_b="$(mktemp -d)"
(
    export HOME="$home_a"
    export PATH="$mockbin:$PATH"
    export XDG_RUNTIME_DIR="$one_socket"
    unset WAYLAND_DISPLAY
    export DISPLAY=:2
    # shellcheck disable=SC1091
    source "$ROOT/scripts/install.sh"
    PREFIX="/opt/clipboard-sync"
    install_systemd
)
(
    export HOME="$home_b"
    export PATH="$mockbin:$PATH"
    export XDG_RUNTIME_DIR="$one_socket"
    unset WAYLAND_DISPLAY
    export DISPLAY=:2
    # shellcheck disable=SC1091
    source "$ROOT/scripts/install-linux.sh"
    PREFIX="/opt/clipboard-sync"
    install_systemd
)
diff -u "$home_a/.config/systemd/user/clipboard-sync.service" \
    "$home_b/.config/systemd/user/clipboard-sync.service" \
    >/tmp/systemd-installer-diff.txt \
    || { cat /tmp/systemd-installer-diff.txt >&2; fail "install.sh and install-linux.sh units differ"; }
grep -q '^Environment=WAYLAND_DISPLAY=wayland-1$' \
    "$home_a/.config/systemd/user/clipboard-sync.service" \
    || fail "install.sh unit missed wayland-1"
grep -q '^Environment=DISPLAY=:2$' \
    "$home_a/.config/systemd/user/clipboard-sync.service" \
    || fail "install.sh unit missed DISPLAY"
pass "install.sh and install-linux.sh write the same unit"

# Sourcing must not start an install. Executing the real guard — including
# curl | bash, where BASH_SOURCE is unset — must call main.
sourced_out="$(bash -c "source '$ROOT/scripts/install-linux.sh'; printf 'SOURCED_ONLY\n'")"
[[ "$sourced_out" == "SOURCED_ONLY" ]] || fail "sourcing install-linux.sh ran main: $sourced_out"
python3 - "$ROOT/scripts/install-linux.sh" "$tmp/piped-install.sh" << 'PY'
import pathlib, sys
src, dest = sys.argv[1:]
text = pathlib.Path(src).read_text()
old = 'main() {\n    echo ""\n'
new = 'main() {\n    echo PIPED_MAIN_RAN\n    return 0\n    echo ""\n'
if old not in text:
    raise SystemExit("main() preamble not found")
pathlib.Path(dest).write_text(text.replace(old, new, 1))
PY
chmod +x "$tmp/piped-install.sh"
direct_out="$("$tmp/piped-install.sh")"
[[ "$direct_out" == "PIPED_MAIN_RAN" ]] || fail "direct installer skipped main: $direct_out"
piped_out="$(cat "$tmp/piped-install.sh" | bash)"
[[ "$piped_out" == "PIPED_MAIN_RAN" ]] || fail "piped installer skipped main: $piped_out"
pass "installer main runs when piped to bash and not when sourced"

echo "ALL PASS"
