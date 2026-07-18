#!/usr/bin/env python3
"""Local review server: makes the review page's OK button actually apply.

Serves the work dir over localhost and gives repair_review.html two endpoints:

  POST /apply  {"decisions": {"<idx>": "approved"|"rejected"}}
      -> flips statuses in corrections.json, runs apply_corrections.py,
         regenerates the review page, rebuilds outputs; responds with a
         summary. The browser then reloads the (regenerated) page, which
         shows only the still-undecided proposals.
  POST /finish
      -> responds, then shuts the server down.

Stdlib only, single-threaded, binds 127.0.0.1 on a free port. Started by
run.sh --review; exits when the reviewer clicks the final OK (or on ^C).
"""
import json
import os
import subprocess
import sys
from http.server import HTTPServer, SimpleHTTPRequestHandler
from pathlib import Path

WORK = Path(os.environ["TRANSCRIBE_WORK"])
SCRIPTS = Path(__file__).parent
PY = sys.executable


def run_stage(script):
    r = subprocess.run([PY, str(SCRIPTS / script)], capture_output=True,
                       text=True, env=os.environ)
    print(r.stdout, end="", flush=True)
    if r.returncode != 0:
        print(r.stderr, end="", flush=True)
    return r.returncode == 0


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=str(WORK), **kw)

    def log_message(self, *a):
        pass  # quiet

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        payload = json.loads(self.rfile.read(n) or b"{}")
        if self.path == "/apply":
            cpath = WORK / "corrections.json"
            data = json.loads(cpath.read_text()) if cpath.exists() else {"corrections": []}
            corrections = data.get("corrections", [])
            decided = 0
            for idx, verdict in (payload.get("decisions") or {}).items():
                i = int(idx)
                if 0 <= i < len(corrections) and verdict in ("approved", "rejected") \
                        and corrections[i].get("status") == "proposed":
                    corrections[i]["status"] = verdict
                    decided += 1
            cpath.write_text(json.dumps({"corrections": corrections}, indent=1,
                                        ensure_ascii=False))
            ok = (run_stage("apply_corrections.py")
                  and run_stage("make_review.py")
                  and run_stage("build_outputs.py"))
            remaining = sum(1 for c in corrections if c.get("status") == "proposed")
            self._json(200 if ok else 500,
                       {"ok": ok, "decided": decided, "remaining": remaining})
        elif self.path == "/finish":
            self._json(200, {"ok": True})
            # shut down after the response is flushed
            import threading
            threading.Thread(target=self.server.shutdown, daemon=True).start()
        else:
            self._json(404, {"ok": False})


def main():
    server = HTTPServer(("127.0.0.1", 0), Handler)
    port = server.server_address[1]
    url = f"http://127.0.0.1:{port}/repair_review.html"
    print(f"  review server: {url}", flush=True)
    if os.environ.get("TRANSCRIBE_REVIEW_NO_OPEN") != "1":
        subprocess.run(["open", url], check=False)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    print("  review server: finished", flush=True)


if __name__ == "__main__":
    main()
