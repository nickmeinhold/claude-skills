#!/usr/bin/env python3
"""Render repair proposals as an interactive review page (repair_review.html).

Each proposed correction/edit is shown IN ITS TURN'S CONTEXT as a diff —
struck-out red original, green replacement — with Apply / Reject buttons per
finding, bulk buttons, and an Export that downloads a corrections.json with
your decisions applied (proposed -> approved / rejected). Decisions persist in
localStorage so the page survives reloads; nothing touches the filesystem
until you drop the exported file back into the work dir and run:

    run.sh --apply <workdir> <speakers.json>

Reads  $TRANSCRIBE_WORK/corrections.json + turns_named.json (or turns.json)
Writes $TRANSCRIBE_WORK/repair_review.html
"""
import json
import os
import re
from html import escape
from pathlib import Path

WORK = Path(os.environ["TRANSCRIBE_WORK"])
TITLE = os.environ.get("TRANSCRIBE_TITLE", "Transcript")

cpath = WORK / "corrections.json"
data = json.loads(cpath.read_text()) if cpath.exists() else {"corrections": []}
corrections = data.get("corrections", [])
proposed = [(i, c) for i, c in enumerate(corrections)
            if c.get("status") == "proposed"]

src = WORK / "turns_named.json"
if not src.exists():
    src = WORK / "turns.json"
turns = json.loads(src.read_text())


def fmt_ts(t):
    return f"{int(t//3600):02d}:{int(t%3600//60):02d}:{int(t%60):02d}"


def find_context(pattern, flags):
    """Locate the first turn matching the pattern; return (ts, speaker,
    before, matched, after) with ~120 chars of context each side."""
    f = re.I if "i" in (flags or "") else 0
    for t in turns:
        m = re.search(pattern, t.get("text", ""), flags=f)
        if m:
            txt = t["text"]
            a, b = m.start(), m.end()
            return (fmt_ts(t["start"]), t.get("speaker", "?"),
                    txt[max(0, a - 120):a], txt[a:b], txt[b:b + 120])
    return None


cards = []
for idx, c in proposed:
    ctx = find_context(c["pattern"], c.get("flags"))
    if ctx:
        ts, spk, before, matched, after = ctx
        # what the replacement renders to, with backrefs resolved
        try:
            replacement = re.sub(c["pattern"], c["replacement"], matched,
                                 flags=re.I if "i" in c.get("flags", "") else 0)
        except re.error:
            replacement = c["replacement"]
        ctx_html = (f'<span class="ctx">…{escape(before)}</span>'
                    f'<del>{escape(matched)}</del>'
                    f'<ins>{escape(replacement)}</ins>'
                    f'<span class="ctx">{escape(after)}…</span>')
    else:
        ts, spk = "—", "?"
        ctx_html = (f'<del>{escape(c["pattern"])}</del>'
                    f'<ins>{escape(c["replacement"])}</ins>'
                    f'<span class="ctx"> (pattern not found in current turns — '
                    f'may already be applied)</span>')
    scope = c.get("scope", "correction")
    cards.append(f'''
<div class="card" data-idx="{idx}">
  <div class="head">
    <span class="ts">[{escape(ts)}] {escape(spk)}</span>
    <span class="cls {'edit' if scope == 'edit' else ''}">{escape(c.get("class", "?"))}{' · edit' if scope == 'edit' else ''}</span>
    <span class="btns">
      <button class="apply" onclick="decide({idx},'approved')">Apply</button>
      <button class="reject" onclick="decide({idx},'rejected')">Reject</button>
    </span>
  </div>
  <div class="diff">{ctx_html}</div>
  <div class="note">{escape(c.get("note", ""))}</div>
</div>''')

corr_json = json.dumps({"corrections": corrections}, ensure_ascii=False)
html = f'''<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Repair review — {escape(TITLE)}</title>
<style>
 body{{font-family:-apple-system,system-ui,sans-serif;max-width:860px;margin:0 auto;padding:2rem 1.25rem;line-height:1.55;color:#1a1a1a}}
 h1{{font-size:1.4rem;margin-bottom:.2rem}} .sub{{color:#666;font-size:.9rem;margin-bottom:1.2rem}}
 .toolbar{{position:sticky;top:0;background:#fff;padding:.7rem 0;border-bottom:1px solid #ddd;margin-bottom:1.2rem;display:flex;gap:.6rem;align-items:center;flex-wrap:wrap;z-index:2}}
 .toolbar .count{{margin-left:auto;color:#555;font-size:.9rem}}
 button{{font:inherit;padding:.3rem .8rem;border-radius:6px;border:1px solid #ccc;background:#f6f6f6;cursor:pointer}}
 button:hover{{filter:brightness(.96)}}
 .apply{{border-color:#059669;color:#059669}} .reject{{border-color:#dc2626;color:#dc2626}}
 .export{{border-color:#2563eb;color:#2563eb;font-weight:600}}
 .card{{border:1px solid #e2e2e2;border-radius:10px;padding: .9rem 1rem;margin-bottom:1rem;transition:opacity .2s}}
 .card.approved{{border-color:#059669;background:#f0fdf6}}
 .card.rejected{{border-color:#dc2626;background:#fef2f2;opacity:.6}}
 .card.approved .apply,.card.rejected .reject{{outline:2px solid currentColor}}
 /* decided cards show the OUTCOME, not the diff: Apply -> clean corrected
    text; Reject -> original text stays, proposal disappears */
 .card.approved del{{display:none}}
 .card.approved ins{{background:none;font-weight:inherit;color:inherit;padding:0}}
 .card.rejected ins{{display:none}}
 .card.rejected del{{background:none;color:inherit;text-decoration:none;padding:0}}
 .head{{display:flex;gap:.8rem;align-items:baseline;font-size:.82rem;margin-bottom:.45rem}}
 .ts{{color:#888;font-variant-numeric:tabular-nums}}
 .cls{{background:#eef2ff;color:#4338ca;border-radius:4px;padding:.05rem .5rem;font-weight:600}}
 .cls.edit{{background:#fef9c3;color:#854d0e}}
 .btns{{margin-left:auto;display:flex;gap:.4rem}}
 .diff{{font-size:1rem;margin-bottom:.4rem}}
 .ctx{{color:#777}}
 del{{background:#fee2e2;color:#b91c1c;text-decoration:line-through;padding:.06rem .15rem;border-radius:3px}}
 ins{{background:#dcfce7;color:#15803d;text-decoration:none;padding:.06rem .15rem;border-radius:3px;font-weight:600}}
 .note{{font-size:.85rem;color:#555;border-left:3px solid #e2e2e2;padding-left:.6rem}}
 .done{{background:#f0fdf4;border:1px solid #86efac;border-radius:8px;padding:.8rem 1rem;margin:1rem 0;display:none}}
</style></head><body>
<h1>Repair review — {escape(TITLE)}</h1>
<div class="sub">{len(proposed)} proposals · click Apply / Reject per finding (saved locally as you go),
then Export to download the decided <code>corrections.json</code></div>
<div class="toolbar">
  <button class="apply" onclick="bulk('approved')">Apply all remaining</button>
  <button class="reject" onclick="bulk('rejected')">Reject all remaining</button>
  <button onclick="clearAll()">Clear decisions</button>
  <button class="export" onclick="doExport()">Export corrections.json</button>
  <span class="count" id="count"></span>
</div>
<div class="done" id="done">Exported. Move the download over
<code>{escape(str(cpath))}</code> then run:
<code>run.sh --apply "{escape(str(WORK))}" &lt;speakers.json&gt;</code></div>
{''.join(cards)}
<script>
const CORR = {corr_json};
const KEY = "repair-review::{escape(str(WORK))}";
let decisions = JSON.parse(localStorage.getItem(KEY) || "{{}}");

function paint() {{
  let a = 0, r = 0, pending = 0;
  document.querySelectorAll(".card").forEach(el => {{
    const idx = el.dataset.idx;
    el.classList.remove("approved", "rejected");
    const d = decisions[idx];
    if (d === "approved") {{ el.classList.add("approved"); a++; }}
    else if (d === "rejected") {{ el.classList.add("rejected"); r++; }}
    else pending++;
  }});
  document.getElementById("count").textContent =
    `${{a}} apply · ${{r}} reject · ${{pending}} undecided`;
}}
function decide(idx, verdict) {{
  decisions[idx] = decisions[idx] === verdict ? undefined : verdict;
  if (decisions[idx] === undefined) delete decisions[idx];
  localStorage.setItem(KEY, JSON.stringify(decisions));
  paint();
}}
function bulk(verdict) {{
  document.querySelectorAll(".card").forEach(el => {{
    const idx = el.dataset.idx;
    if (!decisions[idx]) decisions[idx] = verdict;
  }});
  localStorage.setItem(KEY, JSON.stringify(decisions));
  paint();
}}
function clearAll() {{
  decisions = {{}};
  localStorage.removeItem(KEY);
  paint();
}}
function doExport() {{
  const out = JSON.parse(JSON.stringify(CORR));
  out.corrections.forEach((c, i) => {{
    if (decisions[i]) c.status = decisions[i];
  }});
  const blob = new Blob([JSON.stringify(out, null, 1)],
                        {{type: "application/json"}});
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = "corrections.json";
  a.click();
  document.getElementById("done").style.display = "block";
}}
paint();
</script>
</body></html>'''
(WORK / "repair_review.html").write_text(html)
print(f"  repair_review.html -> {len(proposed)} proposals to review", flush=True)
