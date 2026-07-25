#!/usr/bin/env python3
"""ha-supervisor-guard-proxy.py  (PROTOTYPE / reference implementation)

A denylisting reverse proxy that sits in front of the Home Assistant Supervisor
(http://supervisor -> 172.30.32.2) for the Claude Code add-on, refusing the
destructive actions from issue #29 by method+path (and watchdog-disable by body)
before they reach the Supervisor, while forwarding everything else untouched.

SCOPE / HONESTY: this catches the *honest* egress path only -- traffic that
resolves the `supervisor` name or is pointed here via HA_URL / HTTP_PROXY. It is
NOT a sandbox: the add-on runs as root with SUPERVISOR_TOKEN in its env and can
dial 172.30.32.2 by raw IP, which no in-container proxy can stop without
NET_ADMIN (deliberately withheld). The only vector-proof control is reducing the
add-on's hassio_role/grants server-side. Treat this as defense-in-depth for the
same threat model as the PreToolUse hook: mistakes, drift, interrupted
sequences -- not a determined adversary.

This module is written so the decision logic (classify) is pure and unit-testable
with no network or Supervisor present.
"""
from __future__ import annotations
import json
import re

# Supervisor REST endpoints that are refused outright. Matched on METHOD + PATH,
# after stripping a leading /core|/homeassistant proxy prefix is NOT done here:
# these are the Supervisor's own endpoints (http://supervisor/<path>).
_DENY_PATH = [
    (r"POST",  r"^/core/stop/?$"),
    (r"POST",  r"^/core/restart/?$"),
    (r"POST",  r"^/core/update/?$"),
    (r"POST",  r"^/host/reboot/?$"),
    (r"POST",  r"^/host/shutdown/?$"),
    (r"POST",  r"^/host/services/[^/]+/(stop|restart)/?$"),
    (r"POST",  r"^/os/update/?$"),
    (r"POST",  r"^/os/datadisk/wipe/?$"),
    (r"POST",  r"^/supervisor/update/?$"),
    (r"POST",  r"^/supervisor/restart/?$"),
    (r"POST",  r"^/addons/[^/]+/(stop|restart|uninstall)/?$"),
]

# Core service calls that ride the role-exempt proxy (http://supervisor/core/api
# or /homeassistant/api). Canonical domain.service ids, mirrors the PreToolUse
# hook so the two layers agree.
_DENY_SERVICE = {
    "homeassistant.stop",
    "hassio.host_reboot",
    "hassio.host_shutdown",
    "hassio.supervisor_restart",
    "hassio.os_update",
    "hassio.host_update",
}
# Confirmed-tier (restart) is intentionally NOT hard-denied here: a proxy cannot
# run an interactive human confirmation, and blocking restart outright would
# remove a legitimate capability. Restart stays gated by the PreToolUse hook,
# which can prompt. The proxy only enforces the never-autonomous set.

_SERVICE_PATH = re.compile(r"/(?:core|homeassistant)/api/services/([a-z_]+)/([a-z_]+)", re.I)
_OPTIONS_PATH = re.compile(r"^/(?:core|homeassistant)/options/?$", re.I)


def classify(method: str, path: str, body: bytes | str | None) -> tuple[str, str]:
    """Return ('deny', reason) or ('allow', '') for a request bound for Supervisor.

    Pure function: no I/O. `path` is the request path (no scheme/host)."""
    method = (method or "").upper()
    path = path or "/"
    # Normalize a possible query string off the path for matching.
    raw_path = path.split("?", 1)[0]

    # 1) Supervisor destructive endpoints by method+path.
    for m, pat in _DENY_PATH:
        if method == m and re.match(pat, raw_path):
            return "deny", f"Supervisor endpoint {method} {raw_path} is blocked (issue #29 privileged-action guard)."

    # 2) Watchdog-disable: POST /core/options (or /homeassistant/options) with watchdog:false.
    if method == "POST" and _OPTIONS_PATH.match(raw_path):
        if _body_disables_watchdog(body):
            return "deny", "Disabling the Supervisor watchdog is blocked (removes HA auto-recovery)."

    # 3) Core service calls over the role-exempt proxy -> canonical domain.service.
    if method == "POST":
        m = _SERVICE_PATH.search(raw_path)
        if m:
            action = f"{m.group(1).lower()}.{m.group(2).lower()}"
            if action in _DENY_SERVICE:
                return "deny", f"Service call {action} is blocked (issue #29 privileged-action guard)."

    return "allow", ""


def _body_disables_watchdog(body) -> bool:
    if body is None:
        return False
    if isinstance(body, bytes):
        try:
            body = body.decode("utf-8", "replace")
        except Exception:
            return False
    # Try structured first, then a permissive text fallback.
    try:
        obj = json.loads(body)
        if isinstance(obj, dict) and obj.get("watchdog") is False:
            return True
    except Exception:
        pass
    return bool(re.search(r'"watchdog"\s*:\s*false', body, re.I))


# --- Thin runtime wrapper (illustrative; not exercised by the unit test) -------
def _serve(listen_host="127.0.0.1", listen_port=8723, upstream="http://172.30.32.2"):  # pragma: no cover
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    import urllib.request

    class Handler(BaseHTTPRequestHandler):
        def _proxy(self):
            length = int(self.headers.get("Content-Length", 0) or 0)
            body = self.rfile.read(length) if length else None
            decision, reason = classify(self.command, self.path, body)
            if decision == "deny":
                payload = json.dumps({"result": "error", "message": reason}).encode()
                self.send_response(403)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                return
            # Forward upstream, preserving method/headers/body (incl. the token).
            req = urllib.request.Request(upstream + self.path, data=body, method=self.command)
            for k, v in self.headers.items():
                if k.lower() not in ("host", "content-length"):
                    req.add_header(k, v)
            try:
                with urllib.request.urlopen(req) as resp:
                    data = resp.read()
                    self.send_response(resp.status)
                    for k, v in resp.headers.items():
                        if k.lower() not in ("transfer-encoding", "content-length", "connection"):
                            self.send_header(k, v)
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
            except Exception as exc:  # fail-closed: if upstream errs, do not silently allow
                msg = json.dumps({"result": "error", "message": f"guard proxy upstream error: {exc}"}).encode()
                self.send_response(502)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(msg)))
                self.end_headers()
                self.wfile.write(msg)

        do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = _proxy

        def log_message(self, *a):
            pass

    ThreadingHTTPServer((listen_host, listen_port), Handler).serve_forever()


if __name__ == "__main__":  # pragma: no cover
    _serve()
