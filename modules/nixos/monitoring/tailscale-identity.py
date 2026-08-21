#!/usr/bin/env python3
"""nginx auth_request responder resolving a tailnet peer address to its Tailscale login."""

import json
import os
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TAILSCALE = os.environ.get("TAILSCALE_BIN", "tailscale")
LISTEN_PORT = int(os.environ.get("IDENTITY_PORT", "8082"))
ADMIN_LOGINS = {s for s in os.environ.get("ADMIN_LOGINS", "").split(",") if s}
DEFAULT_ROLE = os.environ.get("DEFAULT_ROLE", "Viewer")
CACHE_TTL = float(os.environ.get("CACHE_TTL", "60"))

_cache: dict[str, tuple[float, tuple[str, str, str] | None]] = {}
_lock = threading.Lock()


def whois(addr):
    try:
        out = subprocess.run(
            [TAILSCALE, "whois", "--json", addr],
            capture_output=True,
            timeout=5,
            check=True,
        ).stdout
        profile = json.loads(out).get("UserProfile") or {}
    except (subprocess.SubprocessError, json.JSONDecodeError, OSError):
        return None

    login = profile.get("LoginName")
    if not login:
        return None
    role = "Admin" if login in ADMIN_LOGINS else DEFAULT_ROLE
    return login, profile.get("DisplayName") or login, role


def lookup(addr):
    now = time.monotonic()
    with _lock:
        hit = _cache.get(addr)
        if hit and now - hit[0] < CACHE_TTL:
            return hit[1]
    identity = whois(addr)
    with _lock:
        _cache[addr] = (now, identity)
    return identity


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        addr = self.headers.get("X-Real-IP", "")
        identity = lookup(addr) if addr else None
        if identity is None:
            self.send_response(403)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        login, name, role = identity
        self.send_response(200)
        self.send_header("X-Webauth-User", login)
        self.send_header("X-Webauth-Name", name)
        self.send_header("X-Webauth-Role", role)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, fmt, *args):
        sys.stderr.write("tailscale-identity: " + (fmt % args) + "\n")


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", LISTEN_PORT), Handler).serve_forever()
