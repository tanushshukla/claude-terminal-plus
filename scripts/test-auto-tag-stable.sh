#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-terminal-auto-tag.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

TAG_WORKFLOW="$ROOT/.github/workflows/auto-tag-stable.yml"
RELEASE_WORKFLOW="$ROOT/.github/workflows/release.yml"
SCRIPT="$ROOT/scripts/auto-tag-stable.sh"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    local pattern="$1" file="$2"
    grep -Eq "$pattern" "$file" || fail "expected $file to contain: $pattern"
}

test -x "$SCRIPT" || fail "tag helper is missing or not executable: $SCRIPT"
test -f "$TAG_WORKFLOW" || fail "automatic tag workflow is missing"
test -f "$RELEASE_WORKFLOW" || fail "release workflow is missing"

REMOTE="$WORK/remote.git"
REPO="$WORK/repo"
git init --bare "$REMOTE" >/dev/null
git init "$REPO" >/dev/null
git -C "$REPO" config user.name test
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" remote add origin "$REMOTE"
mkdir -p "$REPO/claudecode"

write_version() {
    printf '%s\n' '---' "version: \"$1\"" > "$REPO/claudecode/config.yaml"
}

commit_version() {
    local version="$1" message="$2"
    write_version "$version"
    git -C "$REPO" add claudecode/config.yaml
    git -C "$REPO" commit -m "$message" >/dev/null
    git -C "$REPO" push origin HEAD:main >/dev/null
}

run_tag_script() {
    local sha="$1" before="$2"
    (
        cd "$REPO"
        GITHUB_SHA="$sha" \
            GITHUB_EVENT_BEFORE="$before" \
            bash "$SCRIPT"
    )
}

remote_tag_sha() {
    git -C "$REPO" ls-remote origin "refs/tags/$1" | awk 'NR == 1 { print $1 }'
}

remote_tag_inventory() {
    git -C "$REPO" ls-remote --tags origin | sort
}

zero_sha=0000000000000000000000000000000000000000

# The first version on a newly created branch is eligible for a release.
commit_version 1.2.3.1 'test: initial stable version'
first_sha="$(git -C "$REPO" rev-parse HEAD)"
run_tag_script "$first_sha" "$zero_sha"
test "$(remote_tag_sha v1.2.3.1)" = "$first_sha" \
    || fail "initial version did not create v1.2.3.1"
first_inventory="$(remote_tag_inventory)"

# A rerun accepts the existing same-commit tag and creates nothing else.
run_tag_script "$first_sha" "$zero_sha"
test "$(remote_tag_inventory)" = "$first_inventory" \
    || fail "rerun changed the remote tag inventory"

# An unchanged version is a no-op even if the helper is invoked directly.
printf 'unrelated\n' > "$REPO/README.test"
git -C "$REPO" add README.test
git -C "$REPO" commit -m 'test: unrelated change' >/dev/null
git -C "$REPO" push origin HEAD:main >/dev/null
unchanged_sha="$(git -C "$REPO" rev-parse HEAD)"
run_tag_script "$unchanged_sha" "$first_sha"
test "$(remote_tag_sha v1.2.3.1)" = "$first_sha" \
    || fail "unchanged version moved the existing tag"
test "$(remote_tag_inventory)" = "$first_inventory" \
    || fail "unchanged version created an extra tag"

# Both three- and four-component numeric versions are valid.
commit_version 1.2.4 'test: three-component stable version'
three_part_sha="$(git -C "$REPO" rev-parse HEAD)"
run_tag_script "$three_part_sha" "$unchanged_sha"
test "$(remote_tag_sha v1.2.4)" = "$three_part_sha" \
    || fail "three-component version did not create its tag"

commit_version 1.2.4.1 'test: four-component stable version'
four_part_sha="$(git -C "$REPO" rev-parse HEAD)"
run_tag_script "$four_part_sha" "$three_part_sha"
test "$(remote_tag_sha v1.2.4.1)" = "$four_part_sha" \
    || fail "four-component version did not create its tag"

# A changed version can never move an existing release tag.
git -C "$REPO" tag v1.2.5 "$four_part_sha"
git -C "$REPO" push origin v1.2.5 >/dev/null
commit_version 1.2.5 'test: collide with existing tag'
collision_sha="$(git -C "$REPO" rev-parse HEAD)"
if run_tag_script "$collision_sha" "$four_part_sha"; then
    fail "tag collision unexpectedly succeeded"
fi
test "$(remote_tag_sha v1.2.5)" = "$four_part_sha" \
    || fail "collision moved the existing tag"

# Invalid versions fail before a tag is created.
commit_version invalid 'test: invalid stable version'
invalid_sha="$(git -C "$REPO" rev-parse HEAD)"
if run_tag_script "$invalid_sha" "$collision_sha"; then
    fail "invalid version unexpectedly succeeded"
fi
test -z "$(remote_tag_sha vinvalid)" || fail "invalid version created a tag"

# Workflow contracts: a config change creates a tag using SYNC_TOKEN, then the
# tag consumer validates source/version and creates a GitHub Release.
assert_contains 'branches:' "$TAG_WORKFLOW"
assert_contains '^[[:space:]]*- main$' "$TAG_WORKFLOW"
assert_contains 'claudecode/config\.yaml' "$TAG_WORKFLOW"
assert_contains 'secrets\.SYNC_TOKEN' "$TAG_WORKFLOW"
assert_contains 'issues:[[:space:]]*write' "$TAG_WORKFLOW"
assert_contains 'cancel-in-progress:[[:space:]]*false' "$TAG_WORKFLOW"
assert_contains 'scripts/auto-tag-stable\.sh' "$TAG_WORKFLOW"

assert_contains "tags:" "$RELEASE_WORKFLOW"
assert_contains "'v\*'" "$RELEASE_WORKFLOW"
assert_contains 'contents:[[:space:]]*write' "$RELEASE_WORKFLOW"
assert_contains 'claudecode/config\.yaml' "$RELEASE_WORKFLOW"
assert_contains 'merge-base --is-ancestor' "$RELEASE_WORKFLOW"
assert_contains 'softprops/action-gh-release@v3' "$RELEASE_WORKFLOW"

if grep -Eq 'git push[^[:cntrl:]]*(--force|--force-with-lease|[[:space:]]-f([[:space:]]|$))' "$SCRIPT"; then
    fail "tag helper contains a force push"
fi

printf 'automatic stable tagging and release tests passed\n'
