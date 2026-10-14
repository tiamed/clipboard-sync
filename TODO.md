# Clipboard Sync — Next

Push-architecture has shipped (parallel workers, FIFO payloads, default `macos_event_mode = fifo`, SSH failure logging, macOS daemon install). It is not tracked below.

## Next

- [x] Substitute `{{INSTALL_PREFIX}}` (and the FIFO / image-path tokens) before `launchctl load`. A raw plist template makes launchd exit **EX_CONFIG (78)** and the Mac daemon never starts.
- [x] Bump `softprops/action-gh-release` to **v2** so `make_latest` is honored. v1 accepts the input and ignores it, so release candidates only stayed off Latest via `prerelease: true`. Hyphenated tags stay prerelease and `make_latest: false`; stable tags are `make_latest: true`.
- [x] README daemon download example uses `v1.3.0` (or the latest stable release), not `v1.3.0-rc2`.
- [x] Post-install self-check: FIFO exists, LaunchAgent status is not EX_CONFIG, daemon process is running, plus a one-shot TEXT round-trip hint. Linux installers reject a unit that still contains `{{...}}` and confirm the binary is present.

### Optional later

- [ ] End-to-end smoke script (text push/pull against a fake Mac FIFO).
- [ ] Clearer logs when a large clipboard or image transfer fails.

## Not now

### WebSocket relay

Do not replace SSH unless we need more than two devices. A persistent relay is extra infrastructure; ControlMaster already covers the two-host case.

### Mac inbound SET FIFO

Linux writing `SET_TEXT:` into a Mac-side FIFO instead of `pbcopy` is a marginal gain once ControlMaster is warm.

### Wayland protocol client

A direct wlr-data-control / ext-data-control client is low priority unless `wl-paste --watch` is missing. Prefer the original `wl-clipboard` package.
