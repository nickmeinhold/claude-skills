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


NEIGHBOURS = 4  # turns of conversation revealed on each side by the expander


def find_context(pattern, flags, turn=None):
    """Locate the matching turn — the ANCHORED turn when the correction is
    turn-scoped, else the first match — and return
    (turn_index, ts, speaker, before, matched, after). `before`/`after` are
    the rest of the SAME turn around the match; surrounding turns are attached
    separately by the caller. Returns None if a turn-scoped anchor no longer
    matches (rather than a misleading match from elsewhere)."""
    f = re.I if "i" in (flags or "") else 0
    if turn is not None:
        candidates = [(turn, turns[turn])] if 0 <= turn < len(turns) else []
    else:
        candidates = list(enumerate(turns))
    for ti, t in candidates:
        m = re.search(pattern, t.get("text", ""), flags=f)
        if m:
            txt = t["text"]
            a, b = m.start(), m.end()
            return (ti, fmt_ts(t["start"]), t.get("speaker", "?"),
                    txt[:a], txt[a:b], txt[b:])
    return None


def neighbour_html(ti, direction):
    """Render up to NEIGHBOURS surrounding turns as speaker-labelled lines,
    hidden until the expander chip reveals them."""
    if direction == "before":
        idxs = range(max(0, ti - NEIGHBOURS), ti)
    else:
        idxs = range(ti + 1, min(len(turns), ti + 1 + NEIGHBOURS))
    lines = "".join(
        f'<div class="nt"><span class="ns">{escape(turns[j].get("speaker", "?"))}:</span> '
        f'{escape(turns[j]["text"])}</div>'
        for j in idxs)
    return lines


cards = []
for idx, c in proposed:
    ctx = find_context(c["pattern"], c.get("flags"), c.get("turn"))
    if ctx:
        ti, ts, spk, before, matched, after = ctx
        # what the replacement renders to, with backrefs resolved
        try:
            replacement = re.sub(c["pattern"], c["replacement"], matched,
                                 flags=re.I if "i" in c.get("flags", "") else 0)
        except re.error:
            replacement = c["replacement"]
        before_nb = neighbour_html(ti, "before")
        after_nb = neighbour_html(ti, "after")
        lead = (f'<div class="far">{before_nb}</div>'
                f'<a class="more" onclick="expand(this)">⟨ show earlier ⟩</a> '
                if before_nb else '')
        tail = (f' <a class="more" onclick="expand(this)">⟨ show later ⟩</a>'
                f'<div class="far">{after_nb}</div>'
                if after_nb else '')
        ctx_html = (f'{lead}'
                    f'<span class="ctx">{escape(before)}</span>'
                    f'<del>{escape(matched)}</del>'
                    f'<ins>{escape(replacement)}</ins>'
                    f'<span class="ctx">{escape(after)}</span>'
                    f'{tail}')
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
 .toolbar{{position:sticky;top:0;background:#fff;padding:.7rem 0 .5rem;border-bottom:1px solid #ddd;margin-bottom:1.2rem;z-index:2}}
 .toolbar .row{{display:flex;gap:.6rem;align-items:center;flex-wrap:wrap}}
 .toolbar .count{{margin-left:auto;color:#555;font-size:.9rem}}
 .progress{{height:8px;background:#eee;border-radius:4px;margin-top:.55rem;overflow:hidden;display:flex}}
 .progress .fa{{background:#059669;transition:width .3s}}
 .progress .fr{{background:#dc2626;transition:width .3s}}
 .toggle{{font-size:.85rem;color:#555;display:flex;align-items:center;gap:.3rem;user-select:none}}
 button{{font:inherit;padding:.3rem .8rem;border-radius:6px;border:1px solid #ccc;background:#f6f6f6;cursor:pointer}}
 button:hover{{filter:brightness(.96)}}
 .apply{{border-color:#059669;color:#059669}} .reject{{border-color:#dc2626;color:#dc2626}}
 .export{{border-color:#2563eb;color:#2563eb;font-weight:600}}
 .card{{border:1px solid #e2e2e2;border-radius:10px;padding: .9rem 1rem;margin-bottom:1rem;transition:opacity .35s,transform .35s}}
 .card.leaving{{opacity:0;transform:translateX(2rem)}}
 body:not(.showdecided) .card.decided{{display:none}}
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
 .more{{cursor:pointer;color:#2563eb;font-weight:700;user-select:none;
        background:#eff6ff;border:1px solid #bfdbfe;border-radius:9999px;
        padding:0 .5rem;margin:0 .3rem;font-size:.8rem;white-space:nowrap;
        display:inline-block;line-height:1.4}}
 .more:hover{{background:#dbeafe}}
 .far{{display:none}}
 .far.shown{{display:block;margin:.5rem 0;padding:.5rem .7rem;background:#fafafa;
             border-left:3px solid #e2e2e2;border-radius:0 6px 6px 0}}
 .nt{{color:#777;font-size:.92rem;margin:.15rem 0}}
 .ns{{font-weight:600;color:#555}}
 .done{{background:#f0fdf4;border:1px solid #86efac;border-radius:8px;padding:.8rem 1rem;margin:1rem 0;display:none}}
 .okbtn{{border-color:#059669;background:#059669;color:#fff;font-weight:600;margin-left:.6rem}}
 .endbar{{display:flex;gap:.6rem;align-items:center;border-top:1px solid #ddd;margin-top:1.6rem;padding-top:1.1rem}}
 .endbar #endsummary{{color:#555;font-size:.9rem;margin-right:auto}}
 .finished{{display:none;text-align:center;padding:4rem 1rem;color:#333}}
 body.closed .card,body.closed .toolbar,body.closed .endbar,body.closed .done,body.closed .sub{{display:none}}
 body.closed .finished{{display:block}}
</style></head><body>
<h1>Repair review — {escape(TITLE)}</h1>
<div class="sub">{len(proposed)} proposals · click Apply / Reject per finding (saved locally as you go),
then Export to download the decided <code>corrections.json</code></div>
<div class="toolbar">
  <div class="row">
    <button class="apply" onclick="bulk('approved')">Apply all remaining</button>
    <button class="reject" onclick="bulk('rejected')">Reject all remaining</button>
    <button onclick="clearAll()">Clear decisions</button>
    <label class="toggle"><input type="checkbox" id="showdec"
      onchange="document.body.classList.toggle('showdecided', this.checked); paint()">
      show decided</label>
    <span class="count" id="count"></span>
  </div>
  <div class="progress"><div class="fa" id="pa"></div><div class="fr" id="pr"></div></div>
</div>
<div class="done" id="done">Exported. Move the download over
<code>{escape(str(cpath))}</code> then run:
<code>run.sh --apply "{escape(str(WORK))}" &lt;speakers.json&gt;</code>
<button class="okbtn" onclick="finish()">OK</button></div>
{''.join(cards)}
<div class="endbar">
  <span id="endsummary"></span>
  <button class="export" id="exportbtn" onclick="doExport()">Export corrections.json</button>
  <button class="okbtn" id="okbtn" onclick="finish()">OK</button>
</div>
<div class="finished" id="finished">
  <h2>Review finished</h2>
  <p id="finalcount"></p>
  <p id="finishedhow"></p>
</div>
<script>
// live mode (review server): OK applies + rebuilds; export is a fallback for
// a bare file:// open, so hide it when the server is here
document.addEventListener("DOMContentLoaded", () => {{
  if (location.protocol.startsWith("http")) {{
    document.getElementById("exportbtn").style.display = "none";
    document.getElementById("okbtn").textContent = "OK — apply approved & rebuild";
    document.getElementById("finishedhow").textContent =
      "Approved changes applied and transcript rebuilt. This tab can be closed.";
  }} else {{
    document.getElementById("finishedhow").textContent =
      "Decisions are saved locally. Export + run.sh --apply to apply them.";
  }}
}});
</script>
<script>
const CORR = {corr_json};
const KEY = "repair-review::{escape(str(WORK))}";
let decisions = JSON.parse(localStorage.getItem(KEY) || "{{}}");

function paint() {{
  let a = 0, r = 0, pending = 0;
  const cards = document.querySelectorAll(".card");
  cards.forEach(el => {{
    const idx = el.dataset.idx;
    el.classList.remove("approved", "rejected", "decided");
    const d = decisions[idx];
    if (d === "approved") {{ el.classList.add("approved", "decided"); a++; }}
    else if (d === "rejected") {{ el.classList.add("rejected", "decided"); r++; }}
    else pending++;
  }});
  document.getElementById("count").textContent =
    `${{a}} apply · ${{r}} reject · ${{pending}} undecided`;
  const total = cards.length || 1;
  document.getElementById("pa").style.width = (a / total * 100) + "%";
  document.getElementById("pr").style.width = (r / total * 100) + "%";
  const end = document.getElementById("endsummary");
  if (end) end.textContent = pending
    ? `${{pending}} still undecided`
    : `All ${{a + r}} decided (${{a}} apply · ${{r}} reject)` +
      (exported ? " · exported" : " · not yet exported");
}}
let exported = false;
const LIVE = location.protocol.startsWith("http");  // served by review_server.py

function endPage() {{
  document.getElementById("finalcount").textContent =
    document.getElementById("count").textContent;
  document.body.classList.add("closed");
  window.close();  // best-effort; the 'Review finished' card is the fallback
}}

async function finish() {{
  const pending = document.querySelectorAll(".card:not(.approved):not(.rejected)").length;
  if (pending && !confirm(`${{pending}} proposals are still undecided — finish anyway? (Undecided stay proposed.)`)) return;
  if (LIVE) {{
    const decided = Object.keys(decisions).length;
    try {{
      if (decided) {{
        const r = await fetch("/apply", {{method: "POST",
          headers: {{"Content-Type": "application/json"}},
          body: JSON.stringify({{decisions}})}});
        const res = await r.json();
        if (!res.ok) {{ alert("Apply failed — see the terminal running --review."); return; }}
        localStorage.removeItem(KEY);
      }}
      await fetch("/finish", {{method: "POST"}});
    }} catch (e) {{ alert("Review server unreachable: " + e); return; }}
    endPage();
  }} else {{
    const a = Object.values(decisions).filter(v => v === "approved").length;
    if (a && !exported && !confirm(`${{a}} approvals have NOT been exported — finish without exporting?`)) return;
    endPage();
  }}
}}
function decide(idx, verdict) {{
  const undoing = decisions[idx] === verdict;
  if (undoing) delete decisions[idx]; else decisions[idx] = verdict;
  localStorage.setItem(KEY, JSON.stringify(decisions));
  const el = document.querySelector(`.card[data-idx="${{idx}}"]`);
  if (!undoing && el && !document.body.classList.contains("showdecided")) {{
    // let the card slide out before it collapses from the list
    el.classList.add("leaving", verdict, "decided");
    setTimeout(() => {{ el.classList.remove("leaving"); paint(); }}, 350);
    // still update the tallies/progress immediately
    paintCounts();
  }} else paint();
}}
function paintCounts() {{
  let a = 0, r = 0, pending = 0;
  document.querySelectorAll(".card").forEach(el => {{
    const d = decisions[el.dataset.idx];
    if (d === "approved") a++; else if (d === "rejected") r++; else pending++;
  }});
  document.getElementById("count").textContent =
    `${{a}} apply · ${{r}} reject · ${{pending}} undecided`;
  const total = a + r + pending || 1;
  document.getElementById("pa").style.width = (a / total * 100) + "%";
  document.getElementById("pr").style.width = (r / total * 100) + "%";
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
function expand(el) {{
  const far = el.previousElementSibling?.classList?.contains("far")
    ? el.previousElementSibling
    : el.nextElementSibling;
  if (far) far.classList.add("shown");
  el.remove();
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
  exported = true;
  document.getElementById("done").style.display = "block";
  paint();
}}
paint();
</script>
</body></html>'''
(WORK / "repair_review.html").write_text(html)
print(f"  repair_review.html -> {len(proposed)} proposals to review", flush=True)
