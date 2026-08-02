#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH="${CONFIG_PATH:-claudecode/config.yaml}"
BEFORE="${GITHUB_EVENT_BEFORE:-}"
CURRENT_SHA="${GITHUB_SHA:?GITHUB_SHA is required}"
ZERO_SHA=0000000000000000000000000000000000000000

extract_version() {
    sed -n 's/^version:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}

current_version="$(extract_version < "$CONFIG_PATH")"
if [[ ! "$current_version" =~ ^[0-9]+(\.[0-9]+){2,}$ ]]; then
    echo "::error::Invalid stable version: ${current_version:-<empty>}"
    exit 1
fi

previous_version=""
if [[ -n "$BEFORE" && "$BEFORE" != "$ZERO_SHA" ]]; then
    previous_version="$(git show "${BEFORE}:${CONFIG_PATH}" 2>/dev/null | extract_version || true)"
fi

version_changed=true
if [[ -n "$previous_version" && "$previous_version" == "$current_version" ]]; then
    version_changed=false
fi

TAG="v${current_version}"
if ! remote_sha="$(git ls-remote origin "refs/tags/${TAG}" | awk 'NR == 1 { print $1 }')"; then
    echo "::error::Could not inspect remote tag ${TAG}."
    exit 1
fi

if [[ -z "$remote_sha" ]]; then
    if [[ "$version_changed" != true ]]; then
        echo "Stable version ${current_version} is unchanged and not tagged; no release action taken."
        exit 0
    fi

    git tag "$TAG" "$CURRENT_SHA"
    if git push origin "$TAG"; then
        echo "Created stable release tag ${TAG} at ${CURRENT_SHA}."
        exit 0
    fi

    # Another serialized or manually-started process may have won the race.
    # Re-read the remote and accept only the same immutable result.
    if ! remote_sha="$(git ls-remote origin "refs/tags/${TAG}" | awk 'NR == 1 { print $1 }')"; then
        echo "::error::Could not verify remote tag ${TAG} after push failure."
        exit 1
    fi
    if [[ -z "$remote_sha" ]]; then
        echo "::error::Failed to push ${TAG}; the remote tag is still absent. Check SYNC_TOKEN permissions."
        exit 1
    fi
    if ! git fetch --no-tags origin "refs/tags/${TAG}" >/dev/null; then
        echo "::error::Could not resolve remote tag ${TAG} after push failure."
        exit 1
    fi
    if ! tag_sha="$(git rev-parse "FETCH_HEAD^{commit}")"; then
        echo "::error::Could not resolve remote tag ${TAG} after push failure."
        exit 1
    fi
    if [[ "$tag_sha" == "$CURRENT_SHA" ]]; then
        echo "Stable release tag ${TAG} was created concurrently at ${CURRENT_SHA}; no-op."
        exit 0
    fi
else
    git fetch --no-tags origin "refs/tags/${TAG}:refs/tags/${TAG}" >/dev/null
    tag_sha="$(git rev-parse "${TAG}^{commit}")"
fi

if [[ "$tag_sha" == "$CURRENT_SHA" ]]; then
    echo "Stable release tag ${TAG} already points at ${CURRENT_SHA}; no-op."
    exit 0
fi

if [[ "$version_changed" != true ]]; then
    echo "Stable version ${current_version} is unchanged; existing ${TAG} is preserved."
    exit 0
fi

# The workflow serializes normal runs. This branch protects immutable release
# tags from a manual or otherwise concurrent collision.
title="Automatic stable tag collision: ${TAG}"
body="Automatic stable tagging found version ${current_version} on commit ${CURRENT_SHA}, but ${TAG} already points to ${tag_sha}. The existing tag was not moved. Bump the stable version or resolve this collision manually."

if [[ -n "${GH_TOKEN:-}" ]] && command -v gh >/dev/null 2>&1; then
    if ! existing="$(gh issue list --state open --search "in:title \"${title}\"" --json number --jq length)"; then
        echo "::warning::Could not inspect existing collision issues for ${TAG}." >&2
    elif [[ "$existing" == 0 ]]; then
        if ! gh issue create --title "$title" --body "$body"; then
            echo "::warning::Could not create collision issue for ${TAG}." >&2
        fi
    else
        echo "An open collision issue already exists for ${TAG}."
    fi
else
    echo "::warning::GH_TOKEN or gh is unavailable; no collision issue was opened."
fi

echo "::error::Refusing to move existing ${TAG} from ${tag_sha} to ${CURRENT_SHA}."
exit 1
