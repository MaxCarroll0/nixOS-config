"""Maps the Tailscale identity header to an account and proxies to that account's worker."""

import argparse
import http.client
import os
import re
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

NAME_RE = re.compile(r"^[a-z][a-z0-9-]{1,30}$")
IDENTITY_HEADER = "Tailscale-User-Login"
HOP_BY_HOP = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailers", "transfer-encoding", "upgrade",
}


def load_map(path):
    mapping = {}
    try:
        for line in Path(path).read_text().splitlines():
            parts = line.split()
            if len(parts) == 2 and NAME_RE.match(parts[1]):
                mapping[parts[0].lower()] = parts[1]
    except OSError:
        pass
    return mapping


class UnixConnection(http.client.HTTPConnection):
    def __init__(self, path, timeout=60):
        super().__init__("localhost", timeout=timeout)
        self.unix_path = path

    def connect(self):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(self.timeout)
        sock.connect(self.unix_path)
        self.sock = sock


class Handler(BaseHTTPRequestHandler):
    server_version = "nas-dispatch"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s\n" % (fmt % args))

    def _deny(self, code, message):
        raw = message.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        login = self.headers.get(IDENTITY_HEADER, "").strip().lower()
        if not login:
            self._deny(401, "No Tailscale identity. Reach this through the tailnet.\n")
            return

        account = self.server.lookup(login)
        if account is None:
            self._deny(403, f"{login} has no NAS account.\n")
            return

        sock_path = os.path.join(self.server.socket_dir, f"{account}.sock")
        try:
            conn = UnixConnection(sock_path)
            headers = {
                k: v for k, v in self.headers.items()
                if k.lower() not in HOP_BY_HOP and not k.lower().startswith("tailscale-")
            }
            headers["Host"] = "worker"
            conn.request("GET", self.path, headers=headers)
            upstream = conn.getresponse()
        except OSError as exc:
            self._deny(502, f"Your file service is not available: {exc}\n")
            return

        self.send_response(upstream.status)
        for key, value in upstream.getheaders():
            if key.lower() in HOP_BY_HOP:
                continue
            self.send_header(key, value)
        self.end_headers()
        while chunk := upstream.read(262144):
            self.wfile.write(chunk)
        conn.close()


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, addr, map_path, socket_dir):
        super().__init__(addr, Handler)
        self.map_path = map_path
        self.socket_dir = socket_dir
        self.identity = {}
        self.map_mtime = None
        self.lookup("")

    def lookup(self, login):
        """Reload when the map file changes, so a new account works without a restart."""
        try:
            mtime = os.stat(self.map_path).st_mtime
        except OSError:
            mtime = None
        if mtime != self.map_mtime:
            self.identity = load_map(self.map_path)
            self.map_mtime = mtime
        return self.identity.get(login)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8082)
    ap.add_argument("--identity-map", default="/etc/nas/identity-map")
    ap.add_argument("--socket-dir", default="/run/nas-web")
    args = ap.parse_args()

    Server((args.listen, args.port), args.identity_map, args.socket_dir).serve_forever()


if __name__ == "__main__":
    main()
