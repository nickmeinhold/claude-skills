#!/usr/bin/env python3
"""Local review server: makes the review page's OK button actually apply.

Serves the work dir over localhost and gives repair_review.html two endpoints:

  POST /apply  {"decisions": {"<idx>": "approved"|"rejected"}}
      -> flips statuses in corrections.json, runs apply_corrections.py,
         regenerates the review page, rebuilds outputs; responds with a
         summary. On any stage failure both corrections.json and the turns file
         are rolled back to their pre-apply snapshot and the page + outputs are
         regenerated from that restored (known-good) state — the inputs are
         transactional; the derived output files are rebuilt best-effort, not
         atomically snapshotted. The page POSTs its full decision map once and
         then /finish — it does not reload mid-session.
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
# CSRF nonce: run.sh --review mints TRANSCRIBE_REVIEW_TOKEN and the served page
# echoes it as X-Review-Token on every POST. When set, mismatching/absent tokens
# are rejected — a cross-origin page can't read it or send the custom header.
REVIEW_TOKEN = os.environ.get("TRANSCRIBE_REVIEW_TOKEN", "")


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

    MAX_BODY = 4 << 20  # 4 MiB — a decisions map is tiny; refuse floods

    def do_POST(self):
        # CSRF: reject any POST lacking the shared nonce (when one is configured).
        if REVIEW_TOKEN and self.headers.get("X-Review-Token") != REVIEW_TOKEN:
            self._json(403, {"ok": False, "error": "forbidden"})
            return
        # fail closed: a malformed/oversized Content-Length or body returns an
        # error rather than crashing the single-threaded server.
        try:
            n = int(self.headers.get("Content-Length") or 0)
            if n > self.MAX_BODY:
                self._json(413, {"ok": False, "error": "body too large"})
                return
            payload = json.loads(self.rfile.read(n) or b"{}")
        except (ValueError, json.JSONDecodeError):
            self._json(400, {"ok": False, "error": "malformed request"})
            return
        if self.path == "/apply":
            cpath = WORK / "corrections.json"
            # The rollback target is the MUTATION PRODUCT, not a reader ladder:
            # apply_corrections ONLY ever writes turns_named.json (the base files
            # are immutable), so snapshot exactly that file. Record whether it
            # existed pre-apply — a failed apply that CREATED it must be rolled
            # back by REMOVING it, else "rollback" leaves corrected content behind
            # a rolled-back UI (the half-state / first-derive case).
            tpath = WORK / "turns_named.json"
            tnamed_existed = tpath.exists()
            snap_c = cpath.read_text() if cpath.exists() else None
            snap_t = tpath.read_text() if tnamed_existed else None
            data = json.loads(snap_c) if snap_c else {"corrections": []}
            corrections = (data.get("corrections", []) if isinstance(data, dict)
                           else data if isinstance(data, list) else [])
            decided = 0
            for idx, verdict in (payload.get("decisions") or {}).items():
                try:
                    i = int(idx)
                except (ValueError, TypeError):
                    continue
                if 0 <= i < len(corrections) and verdict in ("approved", "rejected") \
                        and corrections[i].get("status") == "proposed":
                    corrections[i]["status"] = verdict
                    decided += 1
            # preserve any top-level metadata (schema version, provenance) — only
            # the corrections member is rewritten; a bare-list file is wrapped.
            if isinstance(data, dict):
                data["corrections"] = corrections
                out = data
            else:
                out = {"corrections": corrections}
            cpath.write_text(json.dumps(out, indent=1, ensure_ascii=False))
            ok = (run_stage("apply_corrections.py")
                  and run_stage("make_review.py")
                  and run_stage("build_outputs.py"))
            if not ok:
                # transactional rollback: restore both files, regenerate the
                # page from the restored (all-proposed) state so the UI never
                # hides a proposal the outputs don't reflect.
                if snap_c is not None:
                    cpath.write_text(snap_c)
                # Restore the derived output to its exact pre-apply state: if it
                # existed, put the old bytes back; if it did NOT (apply created it
                # this call), delete it so the rollback is real, not cosmetic.
                if tnamed_existed:
                    tpath.write_text(snap_t)
                else:
                    tpath.unlink(missing_ok=True)
                # regenerate ALL derived artifacts from the restored inputs — the
                # review page AND the transcript outputs (build_outputs may have
                # written stale .html/.txt/.srt before failing). Rewind all rails.
                run_stage("make_review.py")
                run_stage("build_outputs.py")
                if snap_c:
                    rb = json.loads(snap_c)
                    corrections = (rb.get("corrections", []) if isinstance(rb, dict)
                                   else rb if isinstance(rb, list) else [])
                else:
                    corrections = []
            remaining = sum(1 for c in corrections if c.get("status") == "proposed")
            self._json(200 if ok else 500,
                       {"ok": ok, "decided": decided if ok else 0,
                        "remaining": remaining})
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
