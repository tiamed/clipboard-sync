# Clipboard Sync - Future Improvements

## Done in push-architecture

- [x] Parallel inbound / outbound workers (no serial blocking)
- [x] Mac FIFO events carry payload (`TEXT:` / `IMGFILE:`) applied on Linux
- [x] Default `macos_event_mode = fifo`; poll is safety net
- [x] SSH/scp failures logged instead of swallowed
- [x] macOS installer installs + loads clipboard-sync-daemon

## Next

### Optional: replace SSH payload path with WebSocket relay
- Persistent encrypted channel without SSH process overhead
- Multi-device topology
- See CrossPaste / ClipCascade

### Optional: inbound SET FIFO on Mac
- Linux writes `SET_TEXT:` into a Mac-side FIFO over SSH instead of `pbcopy`
- Marginal gain once ControlMaster is warm

### Wayland
- Direct wlr-data-control / ext-data-control client if `wl-paste --watch` unavailable
