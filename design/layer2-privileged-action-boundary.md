# Layer 2 (API-boundary enforcement) for issue #29 — design and honest limits

## TL;DR

The layer-2 goal from the triage was "a denylisting proxy in front of the Supervisor/Core API so destructive actions are refused at the boundary regardless of how the request is phrased." After researching the HA Supervisor security model and this container's constraints, the honest conclusion is:

- **A hard, un-bypassable boundary is not achievable from inside the add-on container.** The add-on process runs as root (uid 0, `cap dac_override`) with `SUPERVISOR_TOKEN` in its environment, and can reach the Supervisor at its raw IP `172.30.32.2`. Forcing that traffic through a local filter needs `CAP_NET_ADMIN` (iptables/nft), which the AppArmor profile deliberately withholds — and a root agent granted it could just flush the rules. So any in-container proxy is bypassable by design.
- **The only vector-proof lever is server-side: reduce the add-on's `hassio_role` / API grants.** That is enforced by the Supervisor against the add-on's token, so it holds no matter how the request is phrased. But roles are coarse prefix-tiers, not per-action ACLs, so you cannot express "allow log reads + service calls, deny only core.stop / host.reboot / watchdog-off."
- Two complementary pieces were on the table: (A) a **grant reduction** that removes a whole class of destructive endpoints server-side, and (B) a **denylisting reverse proxy** that covers the honest MCP/curl/`ha`-CLI path structurally.

> **Maintainer decision (recorded):** the add-on will **keep `hassio_role: manager`**, because host/OS/supervisor/add-on management from the terminal is a used capability. So Phase A (grant reduction) is **not** pursued, and the full destructive set stays reachable at the platform level. Layer 2 is therefore delivered as **Phase B only** — the reverse proxy, whose denylist spans the entire manager-tier destructive set — layered on top of the PreToolUse hook already shipped in #30. Neither is a sandbox; both are safety nets, consistent with the framing in #30.

## What the research established

### The Supervisor security model
- Add-ons reach the Supervisor at `http://supervisor` (`172.30.32.2` on the `hassio` bridge). Core is reached *through* the Supervisor proxy at `http://supervisor/core/api/...` — add-ons never address Core directly.
- `SUPERVISOR_TOKEN` is a per-add-on bearer token; the Supervisor identifies the add-on by its token, looks up its declared `hassio_role`, and applies a path-prefix regex (`ADDONS_ROLE_ACCESS` in `supervisor/api/middleware/security.py`).
- **Roles are coarse tiers** (least → most): `default` (only `/*/info`) ⊂ `homeassistant` (adds `/core/.+`, `/homeassistant/.+`) ⊂ `backup` ⊂ `manager` (adds `/host/.+`, `/os/(?!datadisk/wipe).+`, `/supervisor/.+`, `/addons/...`) ⊂ `admin` (`.*`).
- **Two attack surfaces:**
  1. The role-gated Supervisor API (`http://supervisor/host/reboot`, `/os/update`, `/supervisor/restart`, `/core/stop`, `/core/options` watchdog, `/addons/*/stop`, …).
  2. The **role-EXEMPT** Core proxy (`/core/api/...`, `/homeassistant/api/...` are in the middleware's `NO_SECURITY_CHECK` list). Over this path, `homeassistant.stop` / `homeassistant.restart` / `hassio.host_reboot` service calls travel **untouched by `hassio_role`**, authenticated as the Supervisor to Core.

### This add-on's grants (config.yaml)
- `homeassistant_api: true` — the role-exempt Core proxy (needed: state reads + service calls).
- `hassio_api: true` + `hassio_role: manager` — the role-gated Supervisor API at the `manager` tier.
- `auth_api: true` — the HA auth/login backend. **Not used** for service calls or log reading.

### Key consequences for enforcement
- `manager` is **over-provisioned** for the add-on's documented purpose (edit config, call services, read logs). `manager` is exactly what unlocks host reboot/shutdown, OS update, supervisor restart, and control of *other* add-ons.
- Dropping to `homeassistant` role removes all of that server-side (un-bypassable), and still permits `GET /core/logs`. But `homeassistant` tier still bundles `POST /core/stop|restart|update|options`, so **core-lifecycle and watchdog-disable remain reachable at any role that also allows logs.**
- `auth_api` can be dropped with no functional loss to the stated features.

## Options considered

| Option | Vector-proof? | Coverage | Cost / downside |
|---|---|---|---|
| **A. Reduce grants** (`hassio_role manager→homeassistant`, drop `auth_api`) | **Yes** (server-side) | Removes host/OS/supervisor/cross-addon endpoints entirely | Coarse: cannot also deny core.stop/watchdog while keeping logs. May break power-user `ha host`/`ha os`/`ha supervisor`/`ha addons` CLI use. Needs real-HW test. |
| **B. Denylisting reverse proxy** owning the `supervisor` endpoint (HA_URL rewrite + `/etc/hosts` override + HTTP_PROXY) | No (raw-IP bypass) | Structurally catches MCP/curl/`ha`-CLI on the honest path, for both Supervisor endpoints and Core service calls | Needs a scoped `/etc/hosts w,` in AppArmor (re-applied each boot; Docker regenerates it); a long-lived local service; must track REST route shapes to avoid false-positives. Not a sandbox. Needs real-HW test. |
| C. HTTP_PROXY only | No | Honest clients only | Agent can `unset HTTP_PROXY` / `--noproxy`. Convention only. |
| D. Wrap `ha`/hass-mcp + hide token | No | Obvious tools only | Token cannot be hidden from a root process; curl sidesteps wrappers. |
| E. iptables REDIRECT of tcp:80 | Would close raw-IP gap | All vectors | Needs `CAP_NET_ADMIN` (deliberately withheld); a root agent could flush it. Net privilege increase for no durable gain. Rejected. |

## Recommendation

**Phase A — grant reduction: considered, DECLINED.** It would have been the only vector-proof lever (drop `auth_api`; reduce `hassio_role` `manager`→`homeassistant`, server-side removing host reboot/shutdown, OS/supervisor update+restart, and cross-add-on control). It is recorded here for completeness, but the maintainer keeps `manager` because that management capability is used from the terminal. Consequence: every destructive Supervisor endpoint stays reachable at the platform level, so Phase B's denylist must cover the whole set, and there is no un-bypassable server-side floor — the honest-path proxy and the hook are the layers.

**Phase B — reverse proxy (the layer-2 mechanism, honest-path defense-in-depth).** Because `manager` is retained, the proxy denylist spans the full destructive set: `POST /core/stop|restart|update`, `/core/options` (watchdog:false), `/host/reboot|shutdown`, `/host/services/*/stop|restart`, `/os/update`, `/supervisor/update|restart`, `/addons/*/stop|restart|uninstall`, plus the role-exempt Core service calls (`homeassistant.stop`, `hassio.host_reboot`, …). Prototype attached: `ha-supervisor-guard-proxy.py`, decision core unit-tested at 23/23. Wire it by:
- baking `HA_URL=http://127.0.0.1:PORT/core` so hass-mcp always transits it;
- pointing the `ha` CLI at it;
- adding a scoped `/etc/hosts w,` to `apparmor.txt` so boot can re-map `supervisor -> 127.0.0.1` (catches hardcoded `http://supervisor` curls);
- `HTTP_PROXY` on top as belt-and-suspenders.
It forwards allowed traffic to `172.30.32.2` and refuses the never-autonomous set by method+path (+ watchdog body). Restart stays the hook's confirm-tier (a proxy cannot run an interactive confirmation). Explicitly documented as not-a-sandbox (raw-IP bypass remains). Needs real-HW testing.

**Already shipped (#30):** the PreToolUse hook is the fine-grained, argument-aware, confirm-capable layer. It is the only one that can do the "ask for confirmation on restart" tier and see MCP arguments. The three layers compose: hook (fine-grained, soft) + proxy (honest-path structural) + grant reduction (coarse, hard).

## Honest limits (must be stated wherever this ships)
- No in-container mechanism stops a determined root agent that dials `172.30.32.2` by raw IP with the token. Only upstream Supervisor per-endpoint authorization, or grant reduction, is vector-proof.
- The token cannot be hidden from a root process.
- The proxy and the `/etc/hosts` override need an AppArmor change and must be re-applied each boot; a crashed proxy must fail closed.
- Denylist-by-path is brittle (same false-positive/negative risk as the #30 hook regex review) and must track Supervisor/Core route shapes.

## Open decisions / next steps
1. ~~Grant reduction (Phase A)~~ — **decided: keep `manager`.** Not pursued.
2. **Proxy (Phase B):** accept a scoped AppArmor `/etc/hosts w,` and a long-lived local service, and validate on a real Protection-mode install? The decision core is ready; the runtime wiring (HA_URL rewrite, hosts override, boot supervision of the proxy) and its real-HW test are the remaining work. Fail-closed behavior on proxy crash must be verified.
3. Whether to pursue an **upstream** ask to HA for per-endpoint add-on authorization, which is the only place a true hard boundary can live (roles are coarse prefix-tiers today).
