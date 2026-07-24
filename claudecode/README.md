# Claude Code for Home Assistant

Run [Claude Code](https://docs.anthropic.com/en/docs/claude-code), Anthropic's AI-powered coding assistant, directly in your Home Assistant sidebar with full access to your configuration.

## Quick Start

```bash
claude "List all my automations"
claude "Turn off all lights in the living room"
claude "Create an automation to turn on lights at sunset"
claude "Why isn't my motion sensor automation working?"
```

## Requirements

- Home Assistant OS or Supervised installation
- [Anthropic account](https://console.anthropic.com/) (authentication handled in terminal)

## Features

- **Web Terminal**: Access Claude Code through a browser-based terminal
- **Config Access**: Read and write Home Assistant configuration files
- **hass-mcp Integration**: Direct control of HA entities and services
- **Session Persistence**: Optional tmux integration to preserve sessions across page refreshes
- **Customizable Theme**: Choose between dark and light terminal themes
- **Multi-Architecture**: Supports amd64, aarch64, armv7, armhf, and i386
- **Secure Authentication**: Claude Code handles its own authentication securely

## Setup

### 1. Install the App

1. Add the repository to Home Assistant
2. Install the "Claude Code" app
3. Start the app
4. Open the Web UI from the sidebar

### 2. Authenticate with Claude Code

On first launch, Claude Code will prompt you to authenticate:

1. Open the terminal from the HA sidebar
2. Type `claude` to start
3. Follow the authentication prompts
4. Your credentials are stored securely by Claude Code

**Note**: The app does NOT require you to enter API keys in the configuration. Claude Code handles authentication itself, storing credentials securely in its own configuration directory. This is more secure than storing keys in Home Assistant's app config.

## Using Claude Code

### Basic Usage

Once authenticated, Claude Code is ready to help with:

- Editing Home Assistant YAML configurations
- Creating automations and scripts
- Debugging configuration issues
- Writing custom integrations

### Home Assistant Integration

With hass-mcp enabled, Claude can:

- Query entity states: "What's the temperature in the living room?"
- Control devices: "Turn off all lights in the bedroom"
- List services: "What services are available for climate control?"
- Debug automations: "Why didn't my morning routine trigger?"

### Example Commands

```bash
# Start interactive session
claude

# One-off commands
claude "Add a new automation that turns on the porch light at sunset"
claude "Check my configuration.yaml for errors"
claude "List all unavailable entities"

# Continue previous conversation
claude --continue
```

### Keyboard Shortcuts

| Shortcut | Command |
|----------|---------|
| `c` | `claude` |
| `cc` | `claude --continue` |
| `ha-config` | Navigate to config directory |
| `ha-logs` | View Home Assistant logs |

## Configuration Options

| Option | Description | Default |
|--------|-------------|---------|
| `enable_mcp` | Enable HA integration | true |
| `terminal_font_size` | Font size (10-24) | 14 |
| `terminal_theme` | dark or light | dark |
| `working_directory` | Start directory | /homeassistant |
| `session_persistence` | Use tmux for persistent sessions | false |
| `auto_continue` | Run `claude --continue` automatically on terminal start (requires `session_persistence`) | false |
| `auto_update_claude` | Auto-update Claude Code on startup (runs in background, with timeout) | false |
| `guard_privileged_actions` | Enforce the privileged-action guard that blocks/asks before destructive HA actions | true |
| `disallow_actions` | Actions Claude may never run autonomously (`domain.service` ids) | see below |
| `confirm_actions` | Actions that require human confirmation first (`domain.service` ids) | `homeassistant.restart` |

> **Note:** `session_persistence`, `auto_continue`, and `auto_update_claude` all default to `false` to keep startup fast and prevent OOM kills on small VMs (e.g. Proxmox HAOS with limited RAM). Turn them on if you want long-running sessions across reconnects, automatic resume after a restart, or always-latest Claude Code. `guard_privileged_actions` defaults to **`true`** (secure by default).

### Privileged-action guard (`guard_privileged_actions`)

Claude Code in this app has read/write access to your config and can call Home Assistant services. A few actions can take HA offline or need physical access to recover, and an AI assistant can start a multi-step sequence (for example: disable the Supervisor watchdog, then stop Core) without any guarantee it will finish it if its session context is lost mid-way. This guard enforces that boundary in the app instead of relying on the assistant's memory or instructions (issue [#29](https://github.com/sproft/hass-claude/issues/29)).

It is enforced by a Claude Code `PreToolUse` hook, so it covers every path Claude can take: the `call_service_tool` / `restart_ha` MCP tools **and** shell commands (`curl` to the Supervisor or Core REST API, the `ha` CLI). The shell matching is host-agnostic (it catches the `supervisor` hostname, the raw Supervisor IP, and the deprecated `/homeassistant/*` alias endpoints equally) and follows the `ha` CLI's command aliases (`ha ha`, `ha ho`, `ha su`, `ha hassos`). Two tiers:

- **Blocked** (`disallow_actions`): refused outright. Baseline: `homeassistant.stop`, `supervisor.core_stop`, `supervisor.watchdog_disable`, `hassio.host_reboot`, `hassio.host_shutdown`, `hassio.supervisor_restart`, `hassio.os_update`.
- **Confirm first** (`confirm_actions`): allowed only after you approve the prompt in the terminal. Baseline: `homeassistant.restart`. A full restart causes a short outage, so it is never triggered autonomously, but reloading a specific YAML domain (`automation.reload` and similar) stays free.

Actions are matched as `domain.service` identifiers. Everything not in either list is unaffected, so normal entity control (`light.turn_on`, `climate.set_temperature`, and so on) and read-only queries work as before. Reading logs with `ha core logs` is **not** blocked; only lifecycle verbs like `ha core stop` and `ha host reboot` are, and a command that merely mentions such a verb as text (an `echo`, a `grep` pattern, a file you are writing) is not flagged. (`ha supervisor stop` and `restart` are governed together as one id, `hassio.supervisor_restart`; the harmless `ha supervisor reload` is not matched.)

**What the two lists do.** They are the effective block/confirm sets shown to you, and the baseline above is also hard-coded in the hook, which lives on the container's read-only path. Your entries in `disallow_actions` / `confirm_actions` **add** to that baseline; if the policy file is ever wiped or corrupted the hook falls back to the baseline rather than allowing everything. Removing a baseline item from a list does not re-enable it. To permit a baseline action, turn the guard off with `guard_privileged_actions: false`.

**Scope and limits.** This is a strong safety net against mistakes, config drift, and interrupted sequences, not a sandbox against a deliberately adversarial assistant: the settings and policy files live in a writable config directory, and shell obfuscation (variable indirection, an interpreter, base64, or wrapping the command in `sh -c "..."`) can evade the text matching of the shell path. The reliable layers are the MCP path (which sees structured `{domain, service}` arguments) and, as a fail-closed backstop for a few clearly-destructive shell verbs (`ha core stop`, `ha host reboot`/`shutdown`, `ha os update`, `ha supervisor restart`, and their CLI aliases), a fixed `permissions.deny` floor that Claude Code enforces even if the hook never runs. That floor is shell-only, and because its rules are literal command-prefix matches it does not back up the MCP `call_service_tool` path or a `curl` to the API, so those rely on the hook (`jq`, a hard image dependency, is required for it).

The guard does not surface anything to your Home Assistant UI; a human-facing banner or abortable-countdown pattern (like the one in issue #29) is complementary and left to you to build. And the second failure mode in issue #29 (a service call that returns success but silently does nothing, such as an orphaned automation entity) cannot be caught by a pre-action hook, so the app instead instructs the assistant, via the injected `CLAUDE.md`, to re-read state after any state-changing call. That part is guidance the assistant is told to follow, not a platform-enforced guarantee like the block/confirm tiers.

Set `guard_privileged_actions: false` to turn the whole guard off. This is a safety net, not a substitute for reviewing what your assistant is doing.

### Auto-resume after a restart (`auto_continue`)

By default, when `session_persistence` is on the terminal opens a bare shell and you type `c` or `cc` to start Claude. Set `auto_continue: true` to have the terminal run `claude --continue` automatically as soon as the session is created, so the app comes back to a live Claude session after a Home Assistant restart with no manual step.

- It only applies when `session_persistence: true`. Without tmux the terminal opens a plain login shell and `auto_continue` is ignored.
- `claude --continue` starts a fresh session if there is no previous one, so enabling it is safe even on a first launch.
- Reconnecting to an already-running session (for example a browser refresh while the app is up) reattaches to the existing Claude rather than starting a second one.
- Because the window runs Claude directly, exiting Claude (Ctrl-D or `/exit`) closes the window. Leave `auto_continue: false` if you would rather land in a shell.

## File Locations

| Path | Description | Access |
|------|-------------|--------|
| `/homeassistant` | HA configuration directory | read-write |
| `/share` | Shared folder | read-write |
| `/media` | Media folder | read-write |
| `/ssl` | SSL certificates | read-only |
| `/backup` | Backups | read-only |

## Session Persistence

When `session_persistence` is enabled, the app uses tmux to maintain your terminal session. This means:

- Your session survives browser refreshes
- You can disconnect and reconnect without losing context
- Claude Code conversations are preserved

### tmux Commands

If you're new to tmux:

| Key | Action |
|-----|--------|
| `Ctrl+b d` | Detach from session (keeps it running) |
| `Ctrl+b [` | Enter scroll/copy mode (use arrow keys) |
| Mouse wheel | Scroll up/down (auto-enters copy mode) |
| `q` | Exit scroll/copy mode |

### Copy and Paste in tmux

Since tmux captures mouse events, copy/paste works differently:

| Action | How to do it |
|--------|--------------|
| **Copy** | Hold `Ctrl+Shift` while selecting text with mouse |
| **Paste** | `Shift+Insert` or middle-click |
| **Alternative paste** | `Ctrl+Shift+V` (browser dependent) |

**Note**: Regular right-click paste and simple mouse selection won't work because tmux intercepts these events for scrolling.

#### Authenticating Claude Code (first launch)

The authentication URL can be long and may wrap across multiple lines. To handle this:

1. **Zoom out** your browser (`Ctrl + -` or `Cmd + -`) until the URL fits on a single line
2. **Click the link** — it should open in a new tab
3. Complete authentication in the browser and **copy the auth code**
4. Click back on the terminal and **paste** with `Shift+Insert` or `Ctrl+Shift+V`

If clicking the link doesn't work, hold `Ctrl+Shift` while selecting the URL with your mouse to copy it, then paste it into your browser's address bar.

### Scrolling and Session Persistence Trade-offs

**With tmux (`session_persistence: true`):**
- ✅ Session survives browser refresh/disconnect
- ✅ Can detach and reattach to running sessions
- ✅ Long-running Claude tasks continue in background
- ✅ Mouse wheel scrolling works (enters copy mode automatically)
- ✅ 5,000 line scrollback buffer
- ⚠️ Use middle-click or Shift+Insert to paste (right-click paste may not work)

**Without tmux (`session_persistence: false`, default):**
- ✅ Native browser scrolling
- ✅ Simpler terminal behavior
- ✅ Standard copy/paste behavior — easier OAuth auth code paste
- ❌ Session lost on browser refresh
- ❌ Session lost if app restarts

**Recommendation:**
- Default `session_persistence: false` is best for first-time setup — copy/paste during the OAuth flow is far less fiddly without tmux.
- Switch to `session_persistence: true` once you're authenticated and want long-running sessions to survive disconnects.

## Security

### Authentication
- **No API keys in app config**: Claude Code handles authentication itself
- Credentials are stored securely in Claude Code's own directory (`~/.claude/`)
- This is more secure than storing keys in Home Assistant's configuration

### Container Security
- The Supervisor token is automatically managed and not exposed
- File access is limited to mapped directories
- The app runs in an isolated container

## Troubleshooting

### Authentication issues

Claude Code manages its own authentication. If you have issues:
1. Type `claude` to start the authentication flow
2. Follow the prompts to log in or enter your API key
3. Credentials are saved automatically for future sessions

**Can't copy the URL or paste the auth code?** The terminal uses tmux, which changes how copy/paste works. See [Copy and Paste in tmux](#copy-and-paste-in-tmux) for instructions.

### hass-mcp not working

1. Verify `enable_mcp` is true in configuration
2. Check the app logs for connection errors
3. Restart the app after configuration changes

### Terminal not loading

1. Check that the app is running (green indicator)
2. Try refreshing the page
3. Check browser console for errors
4. Review the app logs for ttyd errors

### Session not persisting

1. Ensure `session_persistence` is set to `true` (default is `false` in 1.2.64+)
2. The session is named "claude" — it will auto-attach on reconnect

### Configuration changes not applying

After changing configuration:
1. Save the configuration
2. Restart the app completely

### App is killed on startup ("Killed" in logs)

Reported on Proxmox HAOS and other small-VM setups. The container starts, ttyd comes up, but `claude` or `npm` get killed by the OOM killer mid-boot.

Mitigations applied in this fork (1.2.64+):
- `auto_update_claude` defaults to **false** so npm doesn't run a global install on every restart
- When auto-update is enabled, it runs in the background with a 90s timeout and a 512 MB Node heap cap (`NODE_OPTIONS=--max-old-space-size=512`)
- tmux scrollback reduced from 20,000 → 5,000 lines
- Healthcheck `start-period` raised to 120s so Supervisor doesn't restart the app while it's still booting

If you still see kills:
1. Increase the VM's RAM (2 GB+ recommended)
2. Keep `auto_update_claude: false` and update manually with `npm install -g @anthropic-ai/claude-code@latest`
3. Set `session_persistence: false`

### `npm update` never picks up new Claude Code versions

Earlier versions used `npm update -g`, which is buggy for global packages and often left users stuck on the originally-installed version. This fork now uses `npm install -g @anthropic-ai/claude-code@latest` (when `auto_update_claude: true`), which always pulls the latest published release.

You can also update manually from the terminal:

```bash
npm install -g @anthropic-ai/claude-code@latest
```

### Authentication: "400 error" or can't paste the auth code

The OAuth code is long. Common causes:
- The terminal has wrapped the auth URL across lines and you copied a partial code. Zoom out (`Ctrl+-`) until the URL fits on one line.
- tmux is intercepting the paste. Use `Shift+Insert` (or middle-click) — `Ctrl+V` does not work in the terminal.
- The code expired. Re-run `claude` to get a fresh URL.

## Support

- [GitHub Issues](https://github.com/sproft/hass-claude/issues)
- [Home Assistant Community](https://community.home-assistant.io/)
