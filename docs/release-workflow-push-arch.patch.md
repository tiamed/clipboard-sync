# Release workflow update (needs `workflow` token scope)

The PAT used for this PR lacked `workflow` scope, so `.github/workflows/release.yml` was left unchanged.
After merge (or with a token that has `workflow`), update the release job to also build and publish:

- `clipboard-sync-daemon-arm64`
- `clipboard-sync-daemon-x86_64`

alongside the existing `imagecopy-*` binaries (same `swiftc -target` matrix as imagecopy).
See the push-architecture branch history / PR description for the intended YAML.
