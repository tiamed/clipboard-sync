# Clipboard Sync - Future Improvements

## Priority 1: Event-Driven Clipboard Monitoring (Eliminate Polling)

### Option A: Implement watch mode in wl-clipboard-rs
- **Status**: Not currently supported
- **Effort**: Medium
- **Impact**: Eliminates CPU usage when idle, instant response to changes
- **Reference**: [wl-clipboard-rs repo](https://github.com/YaLTeR/wl-clipboard-rs)

### Option B: Implement wlr-data-control event loop directly
- **Status**: Protocol available, requires implementation
- **Effort**: High
- **Impact**: Native event-driven clipboard control
- **Protocol**: [wlr-data-control-unstable-v1](https://github.com/bugaevc/wl-clipboard/blob/master/src/protocol/wlr-data-control-unstable-v1.xml)
- **Compositor Support**: Sway, Hyprland, KWin, Mutter (varies)
- **Note**: Would need to use wayland-client crate directly

---

## Priority 2: WebSocket Transport Layer

### Replace SSH with persistent WebSocket connection
- **Status**: Research complete
- **Effort**: High
- **Impact**: Real-time bidirectional push, lower overhead
- **Architecture**:
  ```
  Linux Wayland (watch) → WebSocket (persistent) → macOS NSPasteboard monitor
  ```

### Reference Implementations
- **CrossPaste**: WebSocket-based sync with HTTP fallback
  - Repo: https://github.com/CrossPaste/crosspaste-desktop
  - Key commit: WebSocket protocol implementation
  
- **ClipCascade**: Self-hosted WebSocket relay with P2P option
  - Repo: https://github.com/Sathvik-Rao/ClipCascade
  - Docker deployment available

### Benefits
- Push-based updates (no polling)
- Lower per-message overhead
- End-to-end encryption possible
- Multi-device topology support

---

## Priority 3: macOS Event-Driven Monitoring

### NSPasteboard change notifications
- **Current**: Polling via `pbpaste`
- **Improvement**: Use NSPasteboard change count monitoring
- **Reference**: `NSPasteboard.changeCount` property

### Implementation approach
```swift
// Monitor pasteboard changes in Swift
NotificationCenter.default.addObserver(
    forName: NSPasteboard.didChangeContentsNotification,
    object: NSPasteboard.general,
    queue: nil
) { notification in
    // Push change to Linux via WebSocket/SSH
}
```

---

## Completed

- [x] SSH Multiplexing (ControlMaster) — 20-100x latency improvement
  - Added `mux_enabled` and `mux_persist` config options
  - Master connection persists for configurable duration (default 5 min)
  - Socket stored in `~/.cache/clipboard-sync/ssh-mux/`
  - Automatic fallback to direct connection if multiplexing fails

---

## Research Sources

### SSH Optimization
- SSH config docs: https://man7.org/linux/man-pages/man5/ssh_config.5.html
- Multiplexing benchmarks: 200-600ms → 10-50ms per connection

### Wayland Protocols
- wlr-data-control: https://github.com/bugaevc/wl-clipboard/blob/master/src/protocol/wlr-data-control-unstable-v1.xml
- ext-data-control-v1: https://wayland.app/protocols/ext-data-control-v1
- wl-clipboard watch mode: https://github.com/bugaevc/wl-clipboard

### WebSocket Sync Projects
- CrossPaste: https://github.com/CrossPaste/crosspaste-desktop
- ClipCascade: https://github.com/Sathvik-Rao/ClipCascade
- ClipHop: https://github.com/theopedapolu/ClipHop

### Event-Driven Examples
- Clipman (Python): https://github.com/MohammedEl-sayedAhmed/clipman
