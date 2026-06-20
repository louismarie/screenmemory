#!/usr/bin/env python3
"""ScreenMemory UI — tiny local server bridging the web UI to the Swift CLI.

Uses the DEV binary (.build/release/ScreenMemory), never the frozen .app
(rebuilding the .app would break its TCC screen-recording grant).
Endpoints: /api/stats /api/list /api/search /api/ask — all shell out to the CLI.
"""
import json
import re
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

HERE = Path(__file__).resolve().parent
BIN = HERE.parent / ".build" / "release" / "ScreenMemory"
# The canonical dashboard is now the in-app one (the menubar app serves it on :7790, or
# `ScreenMemory serve`). This Python server is a dev convenience that serves the SAME file.
DASH = HERE.parent / "Sources" / "ScreenMemory" / "Resources" / "dashboard.html"
PORT = 7790

def cli(*args, timeout=240):
    """Run the ScreenMemory CLI and return parsed JSON from stdout."""
    out = subprocess.run([str(BIN), *args], capture_output=True, text=True, timeout=timeout)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip() or f"exit {out.returncode}")
    return json.loads(out.stdout)

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):  # quiet
        pass

    def _send(self, code, payload, ctype="application/json; charset=utf-8"):
        body = payload if isinstance(payload, bytes) else json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json_error(self, e):
        self._send(500, {"error": str(e)})

    def do_GET(self):
        url = urlparse(self.path)
        q = parse_qs(url.query)
        try:
            if url.path == "/" or url.path == "/index.html":
                self._send(200, DASH.read_bytes(), "text/html; charset=utf-8")
            elif url.path == "/api/days":
                self._send(200, cli("days", timeout=30))
            elif url.path == "/api/stats":
                raw = subprocess.run([str(BIN), "stats"], capture_output=True, text=True, timeout=30).stdout
                m = re.search(r"memories: (\d+).*paused: (\w+)", raw)
                self._send(200, {"count": int(m.group(1)), "paused": m.group(2) == "true"} if m else {"count": 0, "paused": False})
            elif url.path == "/api/list":
                limit = int(q.get("limit", ["50"])[0])
                offset = int(q.get("offset", ["0"])[0])
                self._send(200, cli("list", str(limit), str(offset), timeout=60))
            elif url.path == "/api/search":
                query = q.get("q", [""])[0]
                k = int(q.get("k", ["8"])[0])
                self._send(200, cli("search", query, str(k)))
            elif url.path == "/api/recap":
                date = q.get("date", ["yesterday"])[0]
                self._send(200, cli("recap", date, "--json", timeout=900))
            elif url.path == "/api/analytics":
                days = int(q.get("days", ["1"])[0])
                self._send(200, cli("analytics", str(days), timeout=120))
            elif url.path == "/api/focus":
                days = int(q.get("days", ["1"])[0])
                self._send(200, cli("focus", str(days), "--json", timeout=120))
            elif url.path == "/api/coach":
                day = q.get("day", ["yesterday"])[0]
                self._send(200, cli("coach", day, "--json", timeout=900))
            elif url.path == "/api/weekly":
                end = q.get("end", ["yesterday"])[0]
                args = ["weekly", "--json"] if end == "yesterday" else ["weekly", end, "--json"]
                self._send(200, cli(*args, timeout=900))
            else:
                self._send(404, {"error": "not found"})
        except Exception as e:
            self._json_error(e)

    def do_POST(self):
        url = urlparse(self.path)
        try:
            n = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(n) or b"{}")
            if url.path == "/api/ask":
                self._send(200, cli("ask", body["q"], str(body.get("k", 4))))
            else:
                self._send(404, {"error": "not found"})
        except Exception as e:
            self._json_error(e)

if __name__ == "__main__":
    if not BIN.exists():
        raise SystemExit(f"dev binary missing: {BIN}\nrun: swift build -c release")
    print(f"🧠 ScreenMemory UI → http://127.0.0.1:{PORT}")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
