#!/usr/bin/env bash
# Claude Terminal Plus overlay applier.
#
# Re-applies every "plus" change to upstream-owned files. Idempotent: safe to
# run any number of times. The upstream-sync workflow resolves any merge
# conflict in these files by taking upstream's version and re-running this
# script, so keep ALL edits to upstream-owned files in here.
#
# Usage:
#   scripts/apply-plus.sh          # ensure overlay; version becomes <upstream>.1 if not yet suffixed
#   scripts/apply-plus.sh --bump   # additionally bump the overlay suffix (overlay-only release)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$ROOT/claudecode/config.yaml"
DOCKERFILE="$ROOT/claudecode/Dockerfile"
CHANGELOG="$ROOT/claudecode/CHANGELOG.md"
README="$ROOT/README.md"
REPOYAML="$ROOT/repository.yaml"
MARKER='# --- claude-terminal-plus overlay ---'
BUMP="${1:-}"

# Portable in-place sed (macOS + GNU)
sedi() { sed -i.plusbak "$@" && rm -f "${@: -1}.plusbak"; }

changed=0

# --- config.yaml: ingress port, naming -------------------------------------
if grep -q '^ingress_port: 7681$' "$CONFIG"; then
  sedi 's/^ingress_port: 7681$/ingress_port: 7682/' "$CONFIG"
  changed=1
fi
if grep -q '^name: Claude Code$' "$CONFIG"; then
  sedi 's/^name: Claude Code$/name: Claude Code+/' "$CONFIG"
  changed=1
fi
if grep -q '^panel_title: Claude Code$' "$CONFIG"; then
  sedi 's/^panel_title: Claude Code$/panel_title: Claude Code+/' "$CONFIG"
  changed=1
fi
if grep -q '^url: https://github.com/sproft/hass-claude$' "$CONFIG"; then
  sedi 's|^url: https://github.com/sproft/hass-claude$|url: https://github.com/tanushshukla/claude-terminal-plus|' "$CONFIG"
  changed=1
fi

# --- config.yaml: version = <upstream base>.<overlay n> ---------------------
current="$(sed -n 's/^version: *"\{0,1\}\([0-9][0-9.]*\)"\{0,1\}.*/\1/p' "$CONFIG" | head -1)"
if [ -z "$current" ]; then
  echo "ERROR: could not parse version from $CONFIG" >&2
  exit 1
fi
dots="$(printf '%s' "$current" | tr -cd '.' | wc -c | tr -d ' ')"
if [ "$dots" -le 2 ]; then
  base="$current"
  n=1
else
  base="${current%.*}"
  n="${current##*.}"
  if [ "$BUMP" = "--bump" ]; then n=$((n + 1)); fi
fi
newver="$base.$n"
if [ "$newver" != "$current" ]; then
  sedi "s/^version: .*/version: \"$newver\"/" "$CONFIG"
  changed=1
fi

# --- Dockerfile: append-only overlay block ----------------------------------
if ! grep -qF "$MARKER" "$DOCKERFILE"; then
  cat >> "$DOCKERFILE" <<EOF

$MARKER
# Image upload wrapper: serves the ingress UI on 7682, proxies the terminal
# to the untouched upstream ttyd on 7681, saves pasted images to /data/images.
# Kept as an append-only block so upstream merges never conflict here.
COPY rootfs/opt/image-service /opt/image-service
RUN chmod +x /opt/image-service/entry.sh
ENTRYPOINT ["/opt/image-service/entry.sh"]
EOF
  changed=1
fi

# --- CHANGELOG: prepend overlay entry for the current version ---------------
if ! grep -qF "## [$newver]" "$CHANGELOG"; then
  tmp="$(mktemp)"
  {
    # Keep the file's H1 + intro (everything before the first release heading)
    awk '/^## \[/{exit} {print}' "$CHANGELOG"
    echo "## [$newver] - $(date -u +%Y-%m-%d)"
    echo
    echo "### Plus overlay"
    echo "- Rebased the Claude Terminal Plus overlay (image paste + voice input) on upstream $base. Overlay changes: image upload wrapper on the ingress port (paste/drag-drop/upload an image, get a \`/data/images/...\` path copied to the clipboard for Claude) and a voice-dictation modal. See upstream's $base entry below for what changed in the base release."
    echo
    # The rest of the file starting at the first release heading
    awk 'f{print} /^## \[/{if(!f){f=1; print}}' "$CHANGELOG"
  } > "$tmp"
  mv "$tmp" "$CHANGELOG"
  changed=1
fi

# --- README: plus banner section --------------------------------------------
if ! grep -q 'claude-terminal-plus overlay marker' "$README"; then
  tmp="$(mktemp)"
  {
    head -1 "$README"
    cat <<'BANNER'

<!-- claude-terminal-plus overlay marker -->
> **Claude Terminal Plus** — this is a fork of [sproft/hass-claude](https://github.com/sproft/hass-claude) that adds **image paste** (paste, drag-drop, or upload an image in the web terminal and get a file path for Claude) and **voice input**, ported from [esjavadex/claude-code-ha](https://github.com/esjavadex/claude-code-ha). It auto-syncs with upstream daily. Install URL: `https://github.com/tanushshukla/claude-terminal-plus`
BANNER
    tail -n +2 "$README"
  } > "$tmp"
  mv "$tmp" "$README"
  changed=1
fi

# --- repository.yaml ---------------------------------------------------------
if grep -q '^name: Claude Code for Home Assistant$' "$REPOYAML"; then
  sedi 's/^name: Claude Code for Home Assistant$/name: Claude Terminal Plus/' "$REPOYAML"
  changed=1
fi
if grep -q '^url: https://github.com/sproft/hass-claude$' "$REPOYAML"; then
  sedi 's|^url: https://github.com/sproft/hass-claude$|url: https://github.com/tanushshukla/claude-terminal-plus|' "$REPOYAML"
  changed=1
fi
if grep -q '^maintainer: sproft$' "$REPOYAML"; then
  sedi 's/^maintainer: sproft$/maintainer: tanushshukla/' "$REPOYAML"
  changed=1
fi

if [ "$changed" -eq 1 ]; then
  echo "apply-plus: overlay applied, version $newver"
else
  echo "apply-plus: nothing to do, version $newver"
fi
