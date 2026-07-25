#!/usr/bin/env python3
"""Unit tests for the classify() decision core of ha-supervisor-guard-proxy.py.

Run: python3 docs/prototypes/test_guard_proxy.py
No network or Supervisor required. Reference-only; the proxy is not wired into
the image (see docs/layer2-privileged-action-boundary.md)."""
import importlib.util
import os
import sys

_here = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "guard", os.path.join(_here, "ha-supervisor-guard-proxy.py")
)
guard = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(guard)

CASES = [
    # Supervisor destructive endpoints -> deny
    ("POST", "/core/stop", None, "deny"),
    ("POST", "/core/restart", None, "deny"),
    ("POST", "/core/update", None, "deny"),
    ("POST", "/host/reboot", None, "deny"),
    ("POST", "/host/shutdown", None, "deny"),
    ("POST", "/host/services/systemd-resolved/stop", None, "deny"),
    ("POST", "/os/update", None, "deny"),
    ("POST", "/supervisor/restart", None, "deny"),
    ("POST", "/supervisor/update", None, "deny"),
    ("POST", "/addons/core_mosquitto/uninstall", None, "deny"),
    # Watchdog-disable body -> deny
    ("POST", "/core/options", '{"watchdog": false}', "deny"),
    ("POST", "/homeassistant/options", '{"watchdog":false}', "deny"),
    # Destructive Core service calls over the role-exempt proxy -> deny
    ("POST", "/core/api/services/homeassistant/stop", None, "deny"),
    ("POST", "/core/api/services/hassio/host_reboot", None, "deny"),
    ("POST", "/homeassistant/api/services/hassio/os_update", None, "deny"),
    # Must NOT be blocked
    ("GET", "/core/logs", None, "allow"),
    ("GET", "/supervisor/logs", None, "allow"),
    ("GET", "/core/api/states", None, "allow"),
    ("POST", "/core/api/services/light/turn_on", None, "allow"),
    ("POST", "/core/api/services/automation/reload", None, "allow"),
    ("POST", "/core/api/services/homeassistant/reload_config_entry", None, "allow"),
    ("POST", "/core/options", '{"watchdog": true}', "allow"),   # enabling watchdog is fine
    ("POST", "/core/api/services/homeassistant/restart", None, "allow"),  # confirm-tier: the hook handles this
    ("GET", "/core/api/services/homeassistant/stop", None, "allow"),      # a GET is not an invocation
]


def main():
    passed = failed = 0
    for method, path, body, expected in CASES:
        decision, reason = guard.classify(method, path, body)
        ok = decision == expected
        status = "PASS" if ok else "FAIL"
        extra = "" if ok else f"  ::got {decision}: {reason}"
        print(f"{status} [{expected:5}] {method:5} {path}{extra}")
        passed += ok
        failed += not ok
    print(f"\nRESULT pass={passed} fail={failed}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
