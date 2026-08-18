"""Per-user file browser. Runs as the account itself, so the kernel is the access control."""

import argparse
import html
import mimetypes
import os
import socket
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from socketserver import ThreadingMixIn

PAGE = """<!doctype html><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>{title}</title>
<style>
body{{font-family:system-ui,sans-serif;max-width:60rem;margin:2rem auto;padding:0 1rem;
line-height:1.6;color:#1a1a1a;background:#fafafa}}
a{{color:#06c;text-decoration:none}} a:hover{{text-decoration:underline}}
table{{width:100%;border-collapse:collapse}} td,th{{text-align:left;padding:.35rem .5rem;
border-bottom:1px solid #ddd}} th{{font-size:.85rem;color:#666;text-transform:uppercase}}
td.size{{text-align:right;white-space:nowrap;color:#666}}
nav{{margin-bottom:1rem;color:#666}}
@media(prefers-color-scheme:dark){{body{{background:#141414;color:#eee}}
td,th{{border-color:#333}} a{{color:#6af}} td.size,th,nav{{color:#999}}}}
</style>
<nav>{crumbs}</nav>
<table><tr><th>Name</th><th class=size>Size</th></tr>
{rows}
</table>
"""


def human(n):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024:
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} PB"


class Handler(BaseHTTPRequestHandler):
    server_version = "nas-web"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s\n" % (fmt % args))

    def resolve(self, path):
        root = self.server.root
        wanted = urllib.parse.unquote(path.split("?", 1)[0]).lstrip("/")
        target = (root / wanted).resolve()
        if target != root and root not in target.parents:
            return None
        return target

    def do_GET(self):
        target = self.resolve(self.path)
        if target is None:
            self.send_error(403, "Outside your files")
            return
        try:
            if target.is_dir():
                self._listing(target)
            elif target.is_file():
                self._file(target)
            else:
                self.send_error(404, "Not found")
        except PermissionError:
            self.send_error(403, "Permission denied")
        except OSError:
            self.send_error(404, "Not found")

    def _listing(self, target):
        root = self.server.root
        rel = target.relative_to(root)
        entries = []
        for child in sorted(target.iterdir(), key=lambda p: (not p.is_dir(), p.name.lower())):
            if child.name.startswith(".nashidden"):
                continue
            if (child / ".nashidden").exists():
                continue
            try:
                size = "" if child.is_dir() else human(child.stat().st_size)
            except OSError:
                continue
            href = "/" + urllib.parse.quote(str(child.relative_to(root)))
            name = html.escape(child.name) + ("/" if child.is_dir() else "")
            entries.append(f'<tr><td><a href="{href}">{name}</a></td><td class=size>{size}</td></tr>')

        crumbs = ['<a href="/">home</a>']
        walked = Path()
        for part in rel.parts:
            walked = walked / part
            crumbs.append(f'<a href="/{urllib.parse.quote(str(walked))}">{html.escape(part)}</a>')
        body = PAGE.format(
            title=html.escape(str(rel) if str(rel) != "." else "Your files"),
            crumbs=" / ".join(crumbs),
            rows="\n".join(entries) or "<tr><td colspan=2>Empty</td></tr>",
        )
        raw = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'")
        self.end_headers()
        self.wfile.write(raw)

    def _file(self, target):
        ctype = mimetypes.guess_type(target.name)[0] or "application/octet-stream"
        size = target.stat().st_size
        with target.open("rb") as fh:
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(size))
            self.send_header("Content-Disposition",
                             f'inline; filename="{urllib.parse.quote(target.name)}"')
            self.end_headers()
            while chunk := fh.read(262144):
                self.wfile.write(chunk)


class Server(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, fd, root):
        self.root = root
        HTTPServer.__init__(self, ("", 0), Handler, bind_and_activate=False)
        self.socket = socket.socket(fileno=fd)
        self.server_activate()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    args = ap.parse_args()

    root = Path(args.root).resolve()
    if not root.is_dir():
        print(f"no such home: {root}", file=sys.stderr)
        return 1

    listen_fds = int(os.environ.get("LISTEN_FDS", "0"))
    if listen_fds < 1:
        print("expected a socket-activated fd", file=sys.stderr)
        return 2

    Server(3, root).serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
