#!/usr/bin/env bash
# shellcheck shell=bash
#
# ha-guard-configure.sh - boot-time configurator for the privileged-action
# guard (issue #29). Called once from the app boot script after the Claude Code
# settings file exists. It:
#   1. Reads the guard options from /data/options.json.
#   2. Writes the policy the runtime hook reads (/root/.claude/ha-guard.json).
#   3. Wires (or, when disabled, unwires) the PreToolUse hook and a small fixed
#      fail-closed permissions.deny floor into the Claude Code settings file.
#
# All settings edits are idempotent (safe to run on every boot) and preserve
# any hooks / deny rules the user added themselves. Kept as a standalone rootfs
# script, not inline in the Dockerfile CMD, so it stays readable and lintable
# (same rationale as the .bashrc / .tmux.conf split in issue #26).

set -u

SETTINGS_FILE="${1:-/root/.claude/settings.json}"
OPTIONS_FILE="${HA_GUARD_OPTIONS:-/data/options.json}"
GUARD_FILE="${HA_GUARD_CONFIG:-/root/.claude/ha-guard.json}"
HOOK_CMD="${HA_GUARD_HOOK:-/usr/local/bin/ha-privileged-guard.sh}"
MATCHER="Bash|mcp__homeassistant__call_service_tool|mcp__homeassistant__restart_ha"

# Defaults must mirror the `options:` block in claudecode/config.yaml. They are
# repeated here so the guard is still safe if options.json is missing a key
# (for example the CI boot smoke fixtures, or a hand-edited file).
DEFAULT_DENY='["homeassistant.stop","supervisor.core_stop","supervisor.watchdog_disable","hassio.host_reboot","hassio.host_shutdown","hassio.supervisor_restart","hassio.os_update"]'
DEFAULT_CONFIRM='["homeassistant.restart"]'
# Fixed, non-configurable settings-level deny floor for the handful of shell
# commands that have no legitimate autonomous use in this app. This is
# fail-closed defense in depth: permissions.deny is enforced by Claude Code
# itself even if the PreToolUse hook is somehow bypassed. Reading logs with
# `ha core logs` / `ha core info` stays allowed - only lifecycle verbs are here.
DENY_FLOOR='["Bash(ha core stop:*)","Bash(ha host reboot:*)","Bash(ha host shutdown:*)","Bash(ha os update:*)","Bash(ha supervisor stop:*)","Bash(ha supervisor restart:*)"]'

if ! command -v jq >/dev/null 2>&1; then
  echo '[WARN] jq unavailable; privileged-action guard not configured'
  exit 0
fi

# Resolve options with defaults.
ENABLED="$(jq -r '.guard_privileged_actions // true' "$OPTIONS_FILE" 2>/dev/null || echo true)"
case "$ENABLED" in false) ENABLED=false ;; *) ENABLED=true ;; esac
# Lower-case list entries so a mixed-case config entry still matches (the hook
# lower-cases the incoming domain.service before looking it up).
DENY_JSON="$(jq -c --argjson d "$DEFAULT_DENY" '(.disallow_actions // $d) | map(ascii_downcase)' "$OPTIONS_FILE" 2>/dev/null || echo "$DEFAULT_DENY")"
CONFIRM_JSON="$(jq -c --argjson c "$DEFAULT_CONFIRM" '(.confirm_actions // $c) | map(ascii_downcase)' "$OPTIONS_FILE" 2>/dev/null || echo "$DEFAULT_CONFIRM")"

# Write the policy file the runtime hook reads.
if jq -cn --argjson e "$ENABLED" --argjson d "$DENY_JSON" --argjson c "$CONFIRM_JSON" \
     '{enabled:$e,deny:$d,confirm:$c}' > "$GUARD_FILE.tmp" 2>/dev/null; then
  mv "$GUARD_FILE.tmp" "$GUARD_FILE"
else
  rm -f "$GUARD_FILE.tmp"
  echo '[WARN] Failed to write privileged-action guard policy'
fi

# Make sure the settings file exists and is valid JSON before editing it.
mkdir -p "$(dirname "$SETTINGS_FILE")"
[ -s "$SETTINGS_FILE" ] || echo '{}' > "$SETTINGS_FILE"

TMP="$(dirname "$SETTINGS_FILE")/.settings.guard.tmp"

if [ "$ENABLED" = "true" ]; then
  # Install: drop any previous guard hook entry (idempotent across reboots),
  # add ours, and union the deny floor in. User-added hooks/denies are kept.
  if jq --arg hook "$HOOK_CMD" --arg matcher "$MATCHER" --argjson floor "$DENY_FLOOR" '
        .hooks = (.hooks // {})
        | .hooks.PreToolUse = (
            [ (.hooks.PreToolUse // [])[]
              | select( ([ .hooks[]? | .command ] | index($hook)) | not ) ]
            + [ { matcher: $matcher, hooks: [ { type: "command", command: $hook, timeout: 10 } ] } ] )
        | .permissions = (.permissions // {})
        | .permissions.deny = (((.permissions.deny // []) + $floor) | unique)
      ' "$SETTINGS_FILE" > "$TMP" 2>/dev/null && mv "$TMP" "$SETTINGS_FILE"; then
    echo "[INFO] Privileged-action guard active (deny=$(printf '%s' "$DENY_JSON" | jq 'length'), confirm=$(printf '%s' "$CONFIRM_JSON" | jq 'length'))"
  else
    rm -f "$TMP"
    echo '[WARN] Failed to install privileged-action guard into settings.json'
  fi
else
  # Disabled: remove our hook entry and the deny floor; leave everything else.
  if jq --arg hook "$HOOK_CMD" --argjson floor "$DENY_FLOOR" '
        .hooks.PreToolUse = [ (.hooks.PreToolUse // [])[]
              | select( ([ .hooks[]? | .command ] | index($hook)) | not ) ]
        | .permissions.deny = [ (.permissions.deny // [])[] | select( ($floor | index(.)) | not ) ]
      ' "$SETTINGS_FILE" > "$TMP" 2>/dev/null && mv "$TMP" "$SETTINGS_FILE"; then
    echo '[INFO] Privileged-action guard disabled (guard_privileged_actions: false)'
  else
    rm -f "$TMP"
    echo '[WARN] Failed to remove privileged-action guard from settings.json'
  fi
fi

exit 0
