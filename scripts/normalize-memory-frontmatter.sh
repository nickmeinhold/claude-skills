#!/usr/bin/env bash
# normalize-memory-frontmatter.sh — regularize a memory file's frontmatter to
# the canonical YAML block the /consolidate memory-writer and the self-maintaining
# tooling (write-suppression #739, eviction #740) parse with a YAML reader.
#
# Canonical target:
#   ---
#   name: <human-readable title>
#   description: <one-line retrieval cue>
#   metadata:
#     type: feedback | concept | project | reference | user
#     scope: repo | universal | meta
#   ---
#
# DESIGN — preserve-first, not generate-first (hardened 2026-06-17, issue #859):
#   This tool used to (a) reject every prefix but feedback_/concept_, (b) hardcode
#   scope:repo, and (c) LLM-regenerate name+description on every run. On an already-
#   canonical file that meant: refusing most of the corpus, CLOBBERING scope:universal
#   /meta down to repo (destroying the graduation classification — the most valuable
#   bit), and lossily rewriting curated text. All three are fixed here:
#     - TYPE comes from a prefix->type map covering the whole corpus, not a 2-entry
#       allowlist.
#     - SCOPE is READ from the existing frontmatter and only DEFAULTS to repo when
#       genuinely absent. Existing universal/meta is never downgraded. (A bulk sweep
#       still never PROMOTES — it can't invent universal/meta where none was written;
#       promotion stays the graduation pipeline's job.)
#     - name + description are PRESERVED verbatim (re-quoted YAML-safe via json.dumps).
#       The headless-Claude call fires ONLY when a field is genuinely missing/empty —
#       i.e. on the drifted/unfenced files this tool exists to repair, not on healthy
#       ones. Zero LLM calls on a clean corpus; the steady-state run is a fast no-op.
#
# Usage:
#   normalize-memory-frontmatter.sh <file>            # DRY RUN: print proposed frontmatter to stdout
#   normalize-memory-frontmatter.sh --apply <file>    # rewrite the file in place
#
# Exit 0 on success; non-zero (and no write) on any failure, so a driver can skip.
#   1 = bad args / no file / unknown prefix
#   2 = a field is missing AND the LLM fallback could not fill it
#   3 = the emitted frontmatter failed yaml.safe_load (atomic temp is discarded)
set -euo pipefail

APPLY=0
if [ "${1:-}" = "--apply" ]; then APPLY=1; shift; fi
FILE="${1:?usage: normalize-memory-frontmatter.sh [--apply] <file>}"
[ -f "$FILE" ] || { echo "ERROR: no such file: $FILE" >&2; exit 1; }

# All real work is in one Python block: bash YAML parsing is exactly the fragility
# that produced the malformed files this tool repairs. Python lenient-extracts the
# curated values, re-quotes them YAML-safe, and shells back out to `claude` ITSELF
# (only when a field is empty) so the conditional LLM call stays in one place.
APPLY="$APPLY" python3 - "$FILE" <<'PY'
import sys, os, re, json, subprocess, tempfile

FILE = sys.argv[1]
APPLY = os.environ.get("APPLY", "0") == "1"
base = os.path.basename(FILE)

# --- prefix -> canonical type (covers the whole corpus, not a 2-entry allowlist) ---
PREFIX_TYPE = {
    "feedback": "feedback", "concept": "concept", "project": "project",
    "reference": "reference", "user": "user", "session": "project",
    "plan": "project", "technical": "reference", "bug": "reference",
}
prefix = base.split("_", 1)[0] if "_" in base else base.rsplit(".", 1)[0]
TYPE = PREFIX_TYPE.get(prefix)
if TYPE is None:
    sys.stderr.write(f"ERROR: unknown prefix {prefix!r} (want one of {sorted(PREFIX_TYPE)}): {base}\n")
    sys.exit(1)

VALID_SCOPES = ("repo", "universal", "meta")
text = open(FILE, encoding="utf-8").read()


def split_frontmatter(t):
    """Return (frontmatter_text_or_None, body). Tolerates a missing closing fence."""
    if not t.startswith("---\n") and not t.startswith("---\r\n"):
        return None, t
    lines = t.split("\n")
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            return "\n".join(lines[1:i]), "\n".join(lines[i + 1:])
    return None, t  # no closing fence -> treat the whole thing as body, rebuild fm


def extract_fields(fm):
    """Lenient: try YAML, then fall back to per-line regex for whatever it missed.
    Malformed-but-parseable-by-eye files are the point — never trust safe_load alone."""
    name = desc = scope = ""
    if fm is None:
        return name, desc, scope
    try:
        import yaml
        data = yaml.safe_load(fm)
    except Exception:
        data = None
    if isinstance(data, dict):
        name = str(data.get("name") or "").strip()
        desc = str(data.get("description") or "").strip()
        meta = data.get("metadata")
        if isinstance(meta, dict):
            scope = str(meta.get("scope") or "").strip()
        if not scope:
            scope = str(data.get("scope") or "").strip()  # tolerate a flat scope:
    if not (name and desc and scope):
        for line in fm.split("\n"):
            m = re.match(r"\s*name:\s*(.+)", line)
            if m and not name:
                name = m.group(1).strip().strip("\"'")
            m = re.match(r"\s*description:\s*(.+)", line)
            if m and not desc:
                desc = m.group(1).strip().strip("\"'")
            m = re.match(r"\s*scope:\s*(.+)", line)
            if m and not scope:
                scope = m.group(1).strip().strip("\"'")
    return name, desc, scope


fm, body = split_frontmatter(text)
name, desc, scope = extract_fields(fm)
body = body.lstrip("\n")  # normalize to exactly one blank line after the fence below

# scope: READ then DEFAULT. Never downgrade an existing universal/meta; only fill a
# genuine absence with repo. (A bad/typo'd scope also falls back to repo.)
if scope not in VALID_SCOPES:
    scope = "repo"

# --- mechanical name fallback (used only if both extraction AND the model fail) ----
slug = re.sub(r"\.md$", "", base.split("_", 1)[1] if "_" in base else base)
m = re.search(r"^#[ \t]+(.+)$", body, re.M)
heading = m.group(1).strip() if m else ""
if heading and heading.lower().replace(" ", "_") != slug and heading != base:
    fallback_name = heading
elif name:
    fallback_name = name
else:
    fallback_name = slug.replace("_", " ")

# --- conditional LLM fill: ONLY when a curated field is genuinely missing ----------
if not name or not desc:
    prompt = (
        "You are normalizing a memory file's frontmatter. Read the file content "
        "below and output EXACTLY two lines, nothing else, no preamble, no markdown, "
        "no code fence:\n"
        "NAME: <a short human-readable title under 60 chars. Reuse the file's existing "
        "top '# heading' if it is a real title; do NOT output the bare filename or slug. "
        "No surrounding quotes.>\n"
        "DESCRIPTION: <one sentence under 160 chars naming the SITUATION this memory is "
        "retrieved for — the trigger/cue, not a restatement of the title. No surrounding "
        "quotes.>\n\nFile content:\n" + body
    )
    try:
        raw = subprocess.run(
            ["claude", "-p", "--output-format", "text"],
            input=prompt, capture_output=True, text=True, timeout=120,
        ).stdout
    except Exception:
        raw = ""
    for line in raw.splitlines():
        m = re.match(r"NAME:\s*(.+)", line)
        if m and not name:
            cand = m.group(1).strip().strip("\"'")
            if cand and cand != slug and cand != base:
                name = cand
        m = re.match(r"DESCRIPTION:\s*(.+)", line)
        if m and not desc:
            desc = m.group(1).strip().strip("\"'")

if not name:
    name = fallback_name
if not desc:
    sys.stderr.write(f"ERROR: empty DESCRIPTION (extraction + model both failed) for {FILE}\n")
    sys.exit(2)
if not name:
    sys.stderr.write(f"ERROR: empty NAME (and no fallback) for {FILE}\n")
    sys.exit(2)

# --- emit canonical frontmatter (json.dumps => always-valid double-quoted YAML) ----
new_fm = (
    "---\n"
    f"name: {json.dumps(name, ensure_ascii=False)}\n"
    f"description: {json.dumps(desc, ensure_ascii=False)}\n"
    "metadata:\n"
    f"  type: {TYPE}\n"
    f"  scope: {scope}\n"
    "---"
)

if not APPLY:
    print(f"### {FILE}  [type={TYPE} scope={scope}]")
    print(new_fm)
    sys.exit(0)

result = new_fm + "\n\n" + body
if not result.endswith("\n"):
    result += "\n"

# Validate the result parses as YAML before replacing the original (fail-loudly gate).
try:
    import yaml
    assert result.startswith("---\n"), "no opening fence"
    parsed = yaml.safe_load(result.split("---\n", 2)[1])
    for k in ("name", "description"):
        assert parsed.get(k), f"missing/empty {k}"
    assert parsed.get("metadata", {}).get("type"), "missing metadata.type"
    assert parsed.get("metadata", {}).get("scope") in VALID_SCOPES, "bad scope"
except Exception as e:
    sys.stderr.write(f"ERROR: result frontmatter failed validation ({e}): {FILE}\n")
    sys.exit(3)

# Atomic write: temp in the same dir, then mv.
d = os.path.dirname(os.path.abspath(FILE))
fd, tmp = tempfile.mkstemp(dir=d, suffix=".tmp")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(result)
    os.replace(tmp, FILE)
except BaseException:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
print(f"normalized: {FILE}  [type={TYPE} scope={scope}]")
PY
