# Release workflow

`.github/workflows/release.yml` is the workflow that runs on `v*` tags.

`softprops/action-gh-release` is **v2**. v1 accepts `make_latest` and ignores it, so a hyphenated tag only stayed off GitHub "Latest" when `prerelease: true` happened to be enough. v2 sends `make_latest` to the API.

- Hyphenated tags (`v1.3.0-rc2`, `-alpha`, `-beta`, and `workflow_dispatch` builds `v0.0.0-<sha>`) set `prerelease: true` and `make_latest: false`.
- Stable tags (`v1.3.0`) set `prerelease: false` and `make_latest: true`.

Pushing `.github/workflows/` needs a token with the `workflow` scope. If that push is rejected, leave the in-repo workflow untouched, put the intended file in `docs/release.yml.desired`, and describe it in the PR. Do not force-push.

`docs/release.yml.desired` matches the current workflow, including the v2 action.
