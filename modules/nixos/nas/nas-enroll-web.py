"""Enrolment web form: an account owner redeems a one-time token and sets their own passwords."""

import argparse
import hashlib
import hmac
import html
import os
import re
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs

NAME_RE = re.compile(r"^[a-z][a-z0-9-]{1,30}$")

PAGE = """<!doctype html><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>NAS enrolment</title>
<style>
body{{font-family:system-ui,sans-serif;max-width:26rem;margin:4rem auto;padding:0 1rem;
line-height:1.5;color:#1a1a1a;background:#fafafa}}
h1{{font-size:1.3rem}} label{{display:block;margin:1rem 0 .25rem;font-weight:600}}
input{{width:100%;padding:.55rem;border:1px solid #bbb;border-radius:4px;font-size:1rem}}
button{{margin-top:1.5rem;padding:.6rem 1.2rem;font-size:1rem;border:0;border-radius:4px;
background:#2a6;color:#fff;cursor:pointer}}
.msg{{padding:.75rem;border-radius:4px;margin-bottom:1rem}}
.err{{background:#fdd;border:1px solid #c88}} .ok{{background:#dfd;border:1px solid #8c8}}
small{{color:#666}}
@media(prefers-color-scheme:dark){{body{{background:#141414;color:#eee}}
input{{background:#222;color:#eee;border-color:#444}}
.err{{background:#402020;border-color:#804040}} .ok{{background:#204020;border-color:#408040}}
small{{color:#999}}}}
</style>
<h1>NAS enrolment</h1>
{message}
<form method=post>
<label for=account>Account</label>
<input id=account name=account autocomplete=username value="{account}" required>
<label for=token>Enrolment token</label>
<input id=token name=token autocomplete=one-time-code required>
<label for=pw1>New password</label>
<input id=pw1 name=pw1 type=password autocomplete=new-password required>
<label for=pw2>Repeat password</label>
<input id=pw2 name=pw2 type=password autocomplete=new-password required>
<button type=submit>Set password</button>
</form>
<p><small>Sets both the file-sharing and login password. At least {minlen} characters.
The token works once and then expires.</small></p>
"""


def render(message="", account="", minlen=12, css_class=""):
    block = f'<div class="msg {css_class}">{html.escape(message)}</div>' if message else ""
    return PAGE.format(message=block, account=html.escape(account), minlen=minlen)


class Handler(BaseHTTPRequestHandler):
    server_version = "nas-enroll"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _send(self, code, body):
        raw = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'")
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        self._send(200, render(minlen=self.server.min_length))

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length > 4096:
            self._send(413, render("Request too large.", css_class="err",
                                   minlen=self.server.min_length))
            return
        fields = parse_qs(self.rfile.read(length).decode("utf-8", "replace"))
        account = (fields.get("account") or [""])[0].strip()
        token = (fields.get("token") or [""])[0].strip()
        pw1 = (fields.get("pw1") or [""])[0]
        pw2 = (fields.get("pw2") or [""])[0]

        time.sleep(0.4)

        ok, message = self.server.enrol(account, token, pw1, pw2)
        self._send(200 if ok else 400,
                   render(message, "" if ok else account,
                          self.server.min_length, "ok" if ok else "err"))


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, addr, state_dir, min_length):
        super().__init__(addr, Handler)
        self.state_dir = Path(state_dir)
        self.min_length = min_length

    def enrol(self, account, token, pw1, pw2):
        generic = "Account, token or password was not accepted."
        if not NAME_RE.match(account or ""):
            return False, generic
        state = self.state_dir / account
        if not state.is_file():
            return False, generic
        try:
            want, expires = state.read_text().split()
        except ValueError:
            return False, generic
        if time.time() > int(expires):
            state.unlink(missing_ok=True)
            return False, "That token has expired. Ask for a new one."
        got = hashlib.sha256(token.encode()).hexdigest()
        if not hmac.compare_digest(got, want):
            return False, generic
        if pw1 != pw2:
            return False, "The two passwords do not match."
        if len(pw1) < self.min_length:
            return False, f"Password must be at least {self.min_length} characters."

        try:
            subprocess.run(["chpasswd"], input=f"{account}:{pw1}", text=True,
                           check=True, capture_output=True)
            subprocess.run(["smbpasswd", "-s", "-a", account],
                           input=f"{pw1}\n{pw1}\n", text=True,
                           check=True, capture_output=True)
        except (OSError, subprocess.CalledProcessError):
            return False, "Could not set the password. Tell Max."

        state.unlink(missing_ok=True)
        return True, "Password set. You can now connect to your share."


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8081)
    ap.add_argument("--state-dir", default="/var/lib/nas-enroll")
    ap.add_argument("--min-length", type=int, default=12)
    args = ap.parse_args()

    os.umask(0o077)
    server = Server((args.listen, args.port), args.state_dir, args.min_length)
    server.serve_forever()


if __name__ == "__main__":
    main()
