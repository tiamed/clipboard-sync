# systemd-unit.sh — session environment for the clipboard-sync user unit.
# Sourced by scripts/install.sh. scripts/install-linux.sh sources this file
# when it sits beside the installer, and embeds the same bytes for curl | bash.
# Do not execute directly.

if [[ "${BASH_SOURCE[0]:-}" == "$0" ]]; then
    printf 'source scripts/systemd-unit.sh; do not execute it\n' >&2
    exit 1
fi

# Always stderr. Callers capture helper stdout, and the installers' log_* helpers
# write to stdout, which would otherwise be baked into the unit.
_cs_log_warn() {
    if declare -F log_warn >/dev/null 2>&1; then
        log_warn "$@" >&2
    else
        printf '[WARN] %s\n' "$*" >&2
    fi
}

_cs_log_info() {
    if declare -F log_info >/dev/null 2>&1; then
        log_info "$@" >&2
    else
        printf '[INFO] %s\n' "$*" >&2
    fi
}

# Socket names and XDG paths we are willing to write into a unit file.
_cs_env_token_ok() {
    [[ "$1" =~ ^[A-Za-z0-9_.:/-]+$ ]]
}

_cs_runtime_dir() {
    if [[ -n "${XDG_RUNTIME_DIR:-}" ]] && _cs_env_token_ok "$XDG_RUNTIME_DIR"; then
        printf '%s\n' "$XDG_RUNTIME_DIR"
        return 0
    fi
    printf '/run/user/%s\n' "$(id -u)"
}

# 0 = a client can talk to this socket, 1 = connection refused / missing server,
# 2 = probe unavailable or inconclusive.
_cs_wayland_socket_accepts_clients() {
    local runtime="$1"
    local name="$2"
    local err rc=0

    command -v wl-paste >/dev/null 2>&1 || return 2
    command -v timeout >/dev/null 2>&1 || return 2

    err="$(XDG_RUNTIME_DIR="$runtime" WAYLAND_DISPLAY="$name" \
        timeout 2 wl-paste --list-types 2>&1 >/dev/null)" || rc=$?
    if [[ "$rc" -eq 124 ]]; then
        return 2
    fi
    if [[ "$err" == *"Failed to connect"* ]]; then
        return 1
    fi
    return 0
}

_cs_socket_mtime() {
    local runtime="$1"
    local name="$2"
    stat -c '%Y' "$runtime/$name" 2>/dev/null || printf '0'
}

_cs_socket_index() {
    local n="${1#wayland-}"
    if [[ "$n" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$n"
    else
        printf '0\n'
    fi
}

# Newest socket wins. Equal mtimes prefer the higher wayland-N, so a tie
# does not collapse to wayland-0.
_cs_newest_socket() {
    local runtime="$1"
    shift
    local name mtime best="" best_mtime=-1 best_index=-1 index
    for name in "$@"; do
        mtime="$(_cs_socket_mtime "$runtime" "$name")"
        index="$(_cs_socket_index "$name")"
        if [[ "$mtime" -gt "$best_mtime" ]] || { [[ "$mtime" -eq "$best_mtime" ]] && [[ "$index" -gt "$best_index" ]]; }; then
            best="$name"
            best_mtime="$mtime"
            best_index="$index"
        fi
    done
    printf '%s\n' "$best"
}

_cs_list_wayland_sockets() {
    local runtime="$1"
    local path
    [[ -d "$runtime" ]] || return 0
    for path in "$runtime"/wayland-*; do
        [[ -S "$path" ]] || continue
        printf '%s\n' "${path##*/}"
    done
}

# Print the Wayland socket name to pin, or nothing when the unit should
# leave WAYLAND_DISPLAY unset. Never invents wayland-0.
detect_wayland_display() {
    local runtime requested found
    local -a sockets=()
    runtime="$(_cs_runtime_dir)"
    requested="${WAYLAND_DISPLAY:-}"

    if [[ -n "$requested" ]] && _cs_env_token_ok "$requested" && [[ -S "$runtime/$requested" ]]; then
        printf '%s\n' "$requested"
        return 0
    fi

    local name
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        sockets+=("$name")
    done < <(_cs_list_wayland_sockets "$runtime" | sort)

    if [[ ${#sockets[@]} -eq 1 ]]; then
        found="${sockets[0]}"
    elif [[ ${#sockets[@]} -gt 1 ]]; then
        found="$(_cs_choose_wayland_socket "$runtime" "${sockets[@]}")"
    else
        found=""
    fi

    if [[ -n "$found" ]]; then
        if [[ -n "$requested" && "$requested" != "$found" ]]; then
            _cs_log_warn "WAYLAND_DISPLAY=$requested is not a live socket under $runtime; using $found."
        fi
        printf '%s\n' "$found"
        return 0
    fi

    if [[ -n "$requested" ]] && _cs_env_token_ok "$requested"; then
        _cs_log_warn "WAYLAND_DISPLAY=$requested is set but $runtime/$requested is not a socket. The unit will pin $requested. Re-run with WAYLAND_DISPLAY empty to detect a socket or omit the variable."
        printf '%s\n' "$requested"
        return 0
    fi

    if [[ -n "$requested" ]]; then
        _cs_log_warn "Ignoring unsafe WAYLAND_DISPLAY value; the systemd unit will not set it."
    fi
    return 0
}

_cs_choose_wayland_socket() {
    local runtime="$1"
    shift
    local -a all=("$@")
    local -a candidates=()
    local name rc=0

    for name in "${all[@]}"; do
        rc=0
        _cs_wayland_socket_accepts_clients "$runtime" "$name" || rc=$?
        if [[ "$rc" -eq 1 ]]; then
            continue
        fi
        candidates+=("$name")
    done

    if [[ ${#candidates[@]} -eq 0 ]]; then
        _cs_log_warn "Wayland sockets (${all[*]}) did not accept a client; not setting WAYLAND_DISPLAY."
        return 0
    fi

    local chosen
    chosen="$(_cs_newest_socket "$runtime" "${candidates[@]}")"
    if [[ ${#all[@]} -gt 1 ]]; then
        _cs_log_warn "Multiple Wayland sockets (${all[*]}); using $chosen."
    fi
    printf '%s\n' "$chosen"
}

# Lines for the [Service] section. WAYLAND_DISPLAY and DISPLAY are included
# only when known, so an SSH install does not bake wayland-0 or :0.
clipboard_sync_environment_lines() {
    local runtime wayland display
    runtime="$(_cs_runtime_dir)"
    wayland="$(detect_wayland_display)"
    display="${DISPLAY:-}"

    printf 'Environment=XDG_RUNTIME_DIR=%s\n' "$runtime"
    if [[ -n "$wayland" ]]; then
        printf 'Environment=WAYLAND_DISPLAY=%s\n' "$wayland"
    fi
    if [[ -n "$display" ]] && _cs_env_token_ok "$display"; then
        printf 'Environment=DISPLAY=%s\n' "$display"
    elif [[ -n "$display" ]]; then
        _cs_log_warn "Ignoring unsafe DISPLAY value; the systemd unit will not set it."
    fi
}

# Bash treats "&" in ${var//pat/repl} as the matched text, and "\" starts an escape.
_cs_escape_repl() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//&/\\&}"
    printf '%s' "$s"
}

apply_clipboard_sync_unit_template() {
    local prefix="$1"
    local template_text="$2"
    local env_lines rendered escaped_prefix escaped_env
    env_lines="$(clipboard_sync_environment_lines)"
    escaped_prefix="$(_cs_escape_repl "$prefix")"
    escaped_env="$(_cs_escape_repl "$env_lines")"
    rendered="${template_text//\{\{INSTALL_PREFIX\}\}/${escaped_prefix}}"
    rendered="${rendered//\{\{ENVIRONMENT_LINES\}\}/${escaped_env}}"
    if [[ "$rendered" == *'{{'* ]]; then
        _cs_log_warn "systemd unit still contains unsubstituted placeholders"
        return 1
    fi
    printf '%s\n' "$rendered"
}

report_clipboard_sync_wayland_choice() {
    local unit_text="$1"
    local name=""
    if [[ "$unit_text" == *"Environment=WAYLAND_DISPLAY="* ]]; then
        name="${unit_text#*Environment=WAYLAND_DISPLAY=}"
        name="${name%%$'\n'*}"
        _cs_log_info "systemd unit WAYLAND_DISPLAY=$name"
        return 0
    fi
    _cs_log_warn "No live Wayland socket detected. The unit does not set WAYLAND_DISPLAY."
    _cs_log_warn "From the graphical session, re-run the installer, or import the session and restart:"
    _cs_log_warn "  systemctl --user import-environment WAYLAND_DISPLAY DISPLAY && systemctl --user restart clipboard-sync"
}
