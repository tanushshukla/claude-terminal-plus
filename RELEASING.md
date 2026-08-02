# Releasing

Stable releases are driven by the version in `claudecode/config.yaml`.

## Automatic flow

1. The daily or manually dispatched `upstream-sync.yml` workflow merges
   `sproft/hass-claude`, reapplies `scripts/apply-plus.sh`, and updates the
   overlay version and changelog.
2. A push to `main` that changes `claudecode/config.yaml` starts
   `auto-tag-stable.yml`.
3. If the version value changed and `v<version>` does not exist, the workflow
   creates that immutable tag using `SYNC_TOKEN`.
4. The tag starts `release.yml`, which validates the tag against the config and
   `main`, extracts that version's changelog section, and creates the GitHub
   Release.

This repository's Home Assistant app remains source-built; release automation
does not publish a GHCR image or change the app's installation model.

## Overlay-only release

For a fork-only change, bump the overlay suffix before committing:

```bash
bash scripts/apply-plus.sh --bump
git add -A
git commit -m "fix: describe the change"
git push origin main
```

The config version change starts the same automatic tag and release flow. Do
not create or move a stable tag manually.

## Repository secret

Both `upstream-sync.yml` and `auto-tag-stable.yml` use the repository secret
`SYNC_TOKEN`. It must be a fine-grained personal access token allowed to write
repository contents and workflows. A tag created with the default
`GITHUB_TOKEN` does not start another workflow, so the automatic release chain
depends on this secret.

## Collision behavior

Release tags are never force-moved. A rerun is a no-op when the existing tag
already points to the current commit. If a changed version collides with a tag
on another commit, the workflow preserves the tag, opens a deduplicated issue,
and fails so the version can be bumped or the collision resolved deliberately.
