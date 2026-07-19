#!/usr/bin/env bash
# shellcheck shell=bash
#
# ha-privileged-guard.sh - Claude Code PreToolUse hook for the Claude Code
# Home Assistant app. It enforces a privileged-action boundary (issue #29):
# some actions can take Home Assistant offline or need physical access to
# recover, so Claude must not run them autonomously.
#
# Why a hook and not just permissions.deny: Claude Code permission rules match
# an MCP tool only by NAME, not by the arguments inside the call. The dangerous
# calls here are ordinary `call_service_tool` invocations whose {domain,service}
# happens to be destructive, so a name-level deny would either block every
# service call or none. This hook reads the actual arguments and decides.
#
# Trust model: the destructive baseline (BUILTIN_DENY / BUILTIN_CONFIRM) is
# hard-coded HERE, in a script that lives on the read-only /usr/local tree
# (AppArmor: /usr/local/** is ixr). The writable policy file can only ADD to the
# baseline, never remove from it, and if that file is missing or corrupt the
# hook fails CLOSED to the baseline rather than open. So config drift, an
# accidental wipe, or an interrupted session cannot silently disable the floor.
# The one lever that disables the guard is an explicit {"enabled":false}, which
# is what the app writes when guard_privileged_actions is turned off. A fully
# adversarial agent with shell write access can still tamper with its own
# settings; this is a strong safety net against mistakes and drift, not a
# sandbox against deliberate self-sabotage.
#
# Contract (Claude Code PreToolUse hook):
#   - Full tool call arrives as JSON on stdin: {tool_name, tool_input, ...}.
#   - To let the normal permission flow proceed, exit 0 with no stdout.
#   - To block or gate, print a decision object on stdout and exit 0:
#       {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#         "permissionDecision":"deny"|"ask","permissionDecisionReason":"..."}}
#     "deny" blocks outright; "ask" forces an interactive human confirmation.
#
# Every vector (MCP call_service_tool, the restart_ha convenience tool, and
# shell commands via curl / the `ha` CLI) is reduced to canonical
# "domain.service" ids, then looked up in the effective lists.

set -u

CONFIG="${HA_GUARD_CONFIG:-/root/.claude/ha-guard.json}"

# Immutable baseline. These are always enforced while the guard is on, even if
# the policy file is gone or malformed. Keep in sync with the config.yaml
# defaults (which are shown to the user); the config lists only ever ADD to this.
BUILTIN_DENY="homeassistant.stop supervisor.core_stop supervisor.watchdog_disable hassio.host_reboot hassio.host_shutdown hassio.supervisor_restart hassio.os_update"
BUILTIN_CONFIRM="homeassistant.restart"

# jq parses the hook payload. If it is somehow unavailable we cannot read the
# arguments to make a decision, so defer (the settings-level permissions.deny
# floor still covers the worst shell commands). jq is a hard image dependency.
command -v jq >/dev/null 2>&1 || exit 0

# Resolve the master switch and any user-added entries from the policy file.
# Missing/corrupt file -> keep the baseline (fail closed). Only an explicit
# enabled:false disables the guard.
enabled=true
extra_deny='[]'
extra_confirm='[]'
if [ -r "$CONFIG" ]; then
  # Note: `.enabled // true` is WRONG here - jq's // treats a literal false as
  # "absent" and would return true, so the guard could never be switched off.
  # Only an explicit enabled:false disables; anything else stays on.
  e="$(jq -r 'if .enabled == false then "false" else "true" end' "$CONFIG" 2>/dev/null || echo true)"
  [ "$e" = "false" ] && enabled=false
  extra_deny="$(jq -c '.deny // []' "$CONFIG" 2>/dev/null || echo '[]')"
  extra_confirm="$(jq -c '.confirm // []' "$CONFIG" 2>/dev/null || echo '[]')"
fi
[ "$enabled" = "true" ] || exit 0

# Effective, deduped, lower-cased lists = baseline + user additions.
deny_all="$(jq -cn --argjson x "$extra_deny" --arg b "$BUILTIN_DENY" \
  '(($b | ascii_downcase | split(" ")) + ($x | map(ascii_downcase))) | unique' 2>/dev/null || echo '[]')"
confirm_all="$(jq -cn --argjson x "$extra_confirm" --arg b "$BUILTIN_CONFIRM" \
  '(($b | ascii_downcase | split(" ")) + ($x | map(ascii_downcase))) | unique' 2>/dev/null || echo '[]')"

input="$(cat)"
tool="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)"
[ -n "$tool" ] || exit 0

# Emit newline-separated canonical action ids implied by a shell command. The
# patterns only DERIVE the id; whether it is denied/confirmed/allowed is decided
# from the lists, so this stays consistent with the MCP path. Matching arbitrary
# shell text is best-effort by nature: this catches the direct `ha` CLI, curl to
# the Supervisor API, and REST service calls, and normalizes line continuations,
# but deeper obfuscation (variable indirection, base64, an interpreter) is out
# of scope. The MCP path and the settings deny floor are the hard layers.
derive_bash_actions() {
  local cmd out="" seg d s
  # Join `\<newline>` continuations and flatten whitespace so a split command
  # cannot slip past the single-line patterns below. Done with bash parameter
  # expansion (portable, no dependence on sed multiline semantics).
  cmd="$1"
  cmd="${cmd//$'\\\n'/}"   # drop backslash-newline line continuations
  cmd="${cmd//$'\r'/ }"
  cmd="${cmd//$'\t'/ }"
  cmd="${cmd//$'\n'/ }"    # remaining newlines to spaces
  _m() { printf '%s' "$cmd" | grep -Eiq -- "$1"; }

  # REST service calls of any domain: .../services/<domain>/<service>. Derive
  # the canonical id and let the lists decide (covers homeassistant.stop,
  # hassio.host_reboot, etc. reached via the Core REST API).
  while IFS= read -r seg; do
    [ -n "$seg" ] || continue
    s="${seg##*/}"; d="${seg%/*}"; d="${d##*/}"
    [ -n "$d" ] && [ -n "$s" ] && out="$out
${d}.${s}"
  done < <(printf '%s' "$cmd" | grep -oiE 'services/[a-z_]+/[a-z_]+' | tr '[:upper:]' '[:lower:]')

  # Restart Core (ha CLI).
  _m '(^|[^[:alnum:]_])ha[[:space:]]+core[[:space:]]+restart([^[:alnum:]_]|$)' && out="$out
homeassistant.restart"
  # Stop Core (ha CLI or the Supervisor API).
  { _m '(^|[^[:alnum:]_])ha[[:space:]]+core[[:space:]]+stop([^[:alnum:]_]|$)' || _m 'supervisor/core/stop'; } && out="$out
supervisor.core_stop"
  # Disable the Supervisor watchdog. Matched only in an assignment/flag form so
  # a plain log grep that merely mentions "watchdog" is not blocked.
  { _m '[-][-]no[_-]?watchdog' \
    || _m '["'"'"']?watchdog["'"'"']?[[:space:]]*[:=][[:space:]]*(false|0|off|no|disabled?)' \
    || _m '[-][-]watchdog[[:space:]=]+(false|0|off|no)'; } && out="$out
supervisor.watchdog_disable"
  # Reboot / shut down the host (ha CLI or Supervisor API).
  { _m '(^|[^[:alnum:]_])ha[[:space:]]+host[[:space:]]+reboot([^[:alnum:]_]|$)' || _m 'supervisor/host/reboot'; } && out="$out
hassio.host_reboot"
  { _m '(^|[^[:alnum:]_])ha[[:space:]]+host[[:space:]]+shutdown([^[:alnum:]_]|$)' || _m 'supervisor/host/shutdown'; } && out="$out
hassio.host_shutdown"
  # Stop / restart / reload the Supervisor (governed as one id).
  { _m '(^|[^[:alnum:]_])ha[[:space:]]+supervisor[[:space:]]+(restart|stop|reload)([^[:alnum:]_]|$)' || _m 'supervisor/(restart|reload)'; } && out="$out
hassio.supervisor_restart"
  # OS / host update (ha CLI or Supervisor API).
  { _m '(^|[^[:alnum:]_])ha[[:space:]]+os[[:space:]]+update([^[:alnum:]_]|$)' || _m 'supervisor/os/update'; } && out="$out
hassio.os_update"

  printf '%s\n' "$out"
}

actions=""
case "$tool" in
  *restart_ha)
    actions="homeassistant.restart"
    ;;
  *call_service_tool)
    domain="$(printf '%s' "$input" | jq -r '.tool_input.domain // empty' 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    service="$(printf '%s' "$input" | jq -r '.tool_input.service // empty' 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    [ -n "$domain" ] && [ -n "$service" ] && actions="${domain}.${service}"
    ;;
  Bash)
    cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
    [ -n "$cmd" ] && actions="$(derive_bash_actions "$cmd")"
    ;;
  *)
    exit 0
    ;;
esac

# Pick the most restrictive tier across all derived ids: deny > ask > allow.
decision=""
matched=""
in_list() { printf '%s' "$1" | jq -e --arg a "$2" 'index($a)' >/dev/null 2>&1; }
while IFS= read -r a; do
  [ -n "$a" ] || continue
  a="$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')"
  if in_list "$deny_all" "$a"; then
    decision="deny"; matched="$a"; break
  elif in_list "$confirm_all" "$a"; then
    if [ "$decision" != "deny" ]; then decision="ask"; matched="$a"; fi
  fi
done <<EOF
$actions
EOF

[ -n "$decision" ] || exit 0

if [ "$decision" = "deny" ]; then
  reason="Blocked by the Home Assistant privileged-action guard: '${matched}' can take Home Assistant offline or require physical access to recover, so it is not allowed autonomously. If this is genuinely required, ask the user to perform it themselves. Prefer reloading a specific YAML domain (for example automation.reload) over stopping or rebooting. Do not try to route around this block with an alternate command."
else
  reason="The Home Assistant privileged-action guard requires human confirmation for '${matched}'. Explain to the user what you need and why, and let them approve. A full restart causes a short outage; prefer reloading a specific YAML domain if that is enough. After any state-changing call, re-read the entity to confirm it actually took effect rather than trusting the call's return."
fi

jq -cn --arg d "$decision" --arg r "$reason" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
exit 0
