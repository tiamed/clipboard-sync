#!/bin/bash
# PoC: coproc + wl-paste --watch (text + image) with polling fallback.
# If your system wl-paste lacks --watch (e.g. wl-clipboard-rs), prepend the
# original wl-clipboard build to PATH before running this script.
set -euo pipefail

POLL_INTERVAL=2
WL_PASTE="${WL_PASTE:-wl-paste}"

TEXT_WATCH_PID=""
TEXT_WATCH_FD=""
IMG_WATCH_PID=""
IMG_WATCH_FD=""

log() { echo "[$(date '+%H:%M:%S')] $*" >&2; }

wl_watch_supported() {
    command -v "$WL_PASTE" >/dev/null 2>&1 || return 1
    "$WL_PASTE" --help 2>&1 | grep -q -- '--watch'
}

start_watchers() {
    if [[ -z "${WAYLAND_DISPLAY:-}" ]]; then
        log "WAYLAND_DISPLAY not set"
        return 1
    fi
    if ! wl_watch_supported; then
        log "$WL_PASTE does not support --watch"
        return 1
    fi

    # Copy PIDs to non-special variable names because bash unsets the coproc
    # PID variable once the coprocess is reaped.
    coproc _WATCH_TEXT { exec "$WL_PASTE" --type text --watch printf 'TEXT_CHANGED\n'; }
    TEXT_WATCH_PID=$_WATCH_TEXT_PID
    TEXT_WATCH_FD=${_WATCH_TEXT[0]}

    coproc _WATCH_IMG { exec "$WL_PASTE" --type image/png --watch printf 'IMG_CHANGED\n'; }
    IMG_WATCH_PID=$_WATCH_IMG_PID
    IMG_WATCH_FD=${_WATCH_IMG[0]}

    sleep 0.2
    if ! kill -0 "$TEXT_WATCH_PID" 2>/dev/null || ! kill -0 "$IMG_WATCH_PID" 2>/dev/null; then
        log "wl-paste watcher(s) failed to start"
        stop_watchers
        return 1
    fi
    log "watchers started: text=$TEXT_WATCH_PID image=$IMG_WATCH_PID"
    return 0
}

stop_watchers() {
    if [[ -n "${TEXT_WATCH_PID:-}" ]] && kill -0 "$TEXT_WATCH_PID" 2>/dev/null; then
        kill "$TEXT_WATCH_PID" 2>/dev/null || true
        wait "$TEXT_WATCH_PID" 2>/dev/null || true
    fi
    if [[ -n "${IMG_WATCH_PID:-}" ]] && kill -0 "$IMG_WATCH_PID" 2>/dev/null; then
        kill "$IMG_WATCH_PID" 2>/dev/null || true
        wait "$IMG_WATCH_PID" 2>/dev/null || true
    fi
}

handle_text_event() {
    local text
    text=$("$WL_PASTE" -t text/plain 2>/dev/null || true)
    log "Text event: ${#text} chars"
}

handle_image_event() {
    local img_type
    img_type=$("$WL_PASTE" --list-types 2>/dev/null | grep -m1 "image/" || true)
    log "Image event: type=$img_type"
}

watchdog_counter=0
run_with_watch() {
    while true; do
        local changed=false event=""

        if read -r -t 0 -u "$TEXT_WATCH_FD" _ 2>/dev/null; then
            read -r -u "$TEXT_WATCH_FD" event
            if [[ "$event" == "TEXT_CHANGED" ]]; then
                handle_text_event
                changed=true
            fi
        fi

        if read -r -t 0 -u "$IMG_WATCH_FD" _ 2>/dev/null; then
            read -r -u "$IMG_WATCH_FD" event
            if [[ "$event" == "IMG_CHANGED" ]]; then
                handle_image_event
                changed=true
            fi
        fi

        # Watchdog: check watcher health every ~5s (50 * 0.1s)
        watchdog_counter=$((watchdog_counter + 1))
        if [[ $watchdog_counter -ge 50 ]]; then
            if ! kill -0 "$TEXT_WATCH_PID" 2>/dev/null || ! kill -0 "$IMG_WATCH_PID" 2>/dev/null; then
                log "Watcher died, restarting..."
                stop_watchers
                if ! start_watchers; then
                    log "Restart failed, fallback to polling"
                    return 1
                fi
            fi
            watchdog_counter=0
        fi

        if ! $changed; then
            sleep 0.1
        fi
    done
}

run_polling() {
    while true; do
        handle_text_event
        handle_image_event
        sleep "$POLL_INTERVAL"
    done
}

trap stop_watchers EXIT INT TERM

if start_watchers; then
    run_with_watch
else
    run_polling
fi
