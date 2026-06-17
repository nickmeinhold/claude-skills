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
#     type: <the filename prefix — an OPEN descriptive tag, e.g. feedback | concept |
#           project | reference | user | session | technical | …; an existing type in
#           the file is PRESERVED as-is, an absent one is DERIVED as the prefix — see DESIGN)
#     scope: repo | universal | meta
#   ---
#
# Runtime prerequisite: python3 with PyYAML (`import yaml`) for best-effort lenient
#   extraction. The apply-time validation gate is DELEGATED to the canonical schema
#   validator (scripts/validate-memory-frontmatter.sh — single source of truth,
#   issue #883), which must be present. On --apply, a rebuild that the validator
#   REJECTS exits 3 (schema-invalid); a validator that is missing or cannot run
#   exits 4 (could-not-certify). See the exit-code table below.
#
# DESIGN — preserve-first, not generate-first (hardened 2026-06-17, issue #859):
#   This tool used to (a) reject every prefix but feedback_/concept_, (b) hardcode
#   scope:repo, (c) DERIVE type from the prefix and override any existing type, and
#   (d) LLM-regenerate name+description on every run. On an already-canonical file
#   that meant: refusing most of the corpus, CLOBBERING scope:universal/meta down to
#   repo (destroying the graduation classification — the most valuable bit), CLOBBERING
#   curated types (user/session/etc.), and lossily rewriting curated text. All fixed:
#     - PREFIX is accepted via a map covering the whole corpus, not a 2-entry allowlist.
#     - TYPE is PRESERVE-FIRST: an existing non-empty metadata.type is kept verbatim
#       (the corpus has 40+ user / 27 session / 10 technical / 5 architecture files —
#       overriding from the prefix would clobber them, the identical bug class as scope).
#       Type is an OPEN descriptive tag (no tool branches on its value — SKILL.md step 1),
#       so an absent type is DERIVED as the prefix itself (user_ -> user, session_ ->
#       session), faithfully — NOT coerced into a smaller "canonical" set. The known-
#       prefix set is a typo / non-memory-file GATE only, not a type allowlist.
#     - SCOPE is READ from the existing frontmatter and only DEFAULTS to repo when
#       genuinely absent. Existing universal/meta is never downgraded. (A bulk sweep
#       still never PROMOTES — it can't invent universal/meta where none was written;
#       promotion stays the graduation pipeline's job.)
#     - name + description are PRESERVED verbatim (re-quoted YAML-safe via json.dumps).
#       The headless-Claude call fires ONLY when a field is genuinely missing/empty —
#       i.e. on the drifted/unfenced files this tool exists to repair, not on healthy
#       ones. Zero LLM calls on a clean corpus; the steady-state run is a fast no-op.
#     - The body after the closing fence is preserved BYTE-FOR-BYTE (only the
#       frontmatter block changes); an unfenced file gets one synthesized blank line.
#
# Usage:
#   normalize-memory-frontmatter.sh <file>            # DRY RUN: print proposed frontmatter to stdout
#   normalize-memory-frontmatter.sh --apply <file>    # rewrite the file in place
#
# Exit 0 on success; non-zero (and no write) on any failure, so a driver can skip.
#   1 = bad args / no file / unknown prefix
#   2 = a field is missing AND the LLM fallback could not fill it
#   3 = the rebuilt frontmatter is INVALID per the canonical schema (validator exit 1;
#       atomic temp is discarded) — a genuine schema failure
#   4 = the canonical validator could not RUN (missing, or exit 2: usage / no PyYAML);
#       the rebuild could not be certified — a toolchain failure, NOT a schema verdict
set -euo pipefail

APPLY=0
if [ "${1:-}" = "--apply" ]; then APPLY=1; shift; fi
FILE="${1:?usage: normalize-memory-frontmatter.sh [--apply] <file>}"
[ -f "$FILE" ] || { echo "ERROR: no such file: $FILE" >&2; exit 1; }

# The apply-time gate delegates to the CANONICAL schema validator (its sibling in
# this dir) rather than re-stating the schema here — one definition, no drift
# (issue #883). Resolved relative to this script so a bulk run from any cwd finds it.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export VALIDATOR="$HERE/validate-memory-frontmatter.sh"

# All real work is in one Python block: bash YAML parsing is exactly the fragility
# that produced the malformed files this tool repairs. Python lenient-extracts the
# curated values, re-quotes them YAML-safe, and shells back out to `claude` ITSELF
# (only when a field is empty) so the conditional LLM call stays in one place.
APPLY="$APPLY" python3 - "$FILE" <<'PY'
import sys, os, re, json, subprocess, tempfile

FILE = sys.argv[1]
APPLY = os.environ.get("APPLY", "0") == "1"
base = os.path.basename(FILE)

# --- known prefixes; metadata.type is the prefix itself (an OPEN descriptive tag) ----
# type is NOT a closed enum — no tool branches on its value (SKILL.md step 1); it is a
# prefix-derived descriptive tag. So type DERIVED = the prefix, faithfully (user_ -> user,
# session_ -> session), NOT coerced into a smaller set. The known-prefix set is a typo /
# non-memory-file GATE only (rejects `feedbck_`, README, etc.), not a type allowlist.
# An existing non-empty type IN the file is preserved instead of derived (preserve-first).
KNOWN_PREFIXES = {
    "feedback", "concept", "project", "reference", "user",
    "session", "plan", "next", "technical", "bug", "org", "architecture",
}
prefix = base.split("_", 1)[0] if "_" in base else base.rsplit(".", 1)[0]
if prefix not in KNOWN_PREFIXES:
    sys.stderr.write(f"ERROR: unknown prefix {prefix!r} (want one of {sorted(KNOWN_PREFIXES)}): {base}\n")
    sys.exit(1)
DERIVED_TYPE = prefix  # type = prefix; an open descriptive tag, see SKILL.md step 1

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
    Malformed-but-parseable-by-eye files are the point — never trust safe_load alone.
    Returns (name, description, scope, type) — each '' when genuinely absent."""
    name = desc = scope = ftype = ""
    if fm is None:
        return name, desc, scope, ftype
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
            ftype = str(meta.get("type") or "").strip()
        if not scope:
            scope = str(data.get("scope") or "").strip()  # tolerate a flat scope:
        if not ftype:
            ftype = str(data.get("type") or "").strip()   # tolerate a flat type:
    if not (name and desc and scope and ftype):
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
            m = re.match(r"\s*type:\s*(.+)", line)
            if m and not ftype:
                ftype = m.group(1).strip().strip("\"'")
    return name, desc, scope, ftype


fm, body = split_frontmatter(text)
had_frontmatter = fm is not None
name, desc, scope, existing_type = extract_fields(fm)

# type: PRESERVE-FIRST. An existing curated type (user/session/technical/... or any
# of the canonical 4) is kept verbatim — deriving from the prefix would clobber the
# 40+ corpus files that legitimately carry non-prefix-default types. Only DERIVE from
# the prefix (canonical allowlist) when the file has no type at all.
TYPE = existing_type if existing_type else DERIVED_TYPE

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
    except Exception as e:
        sys.stderr.write(f"WARN: headless `claude` fallback failed for {FILE}: {e}\n")
        raw = ""
    if not raw.strip():
        sys.stderr.write(f"WARN: headless `claude` returned no output for {FILE}\n")
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

# Reconstruct verbatim: when the file already had frontmatter, `body` holds everything
# after the closing fence INCLUDING its original leading blank line, so a single "\n"
# closes the fence line and the body is preserved byte-for-byte. An unfenced file had
# no separator to preserve, so synthesize exactly one blank line.
sep = "\n" if had_frontmatter else "\n\n"
result = new_fm + sep + body
if not result.endswith("\n"):
    result += "\n"

# Atomic write: temp in the same dir, validate it through the CANONICAL schema
# validator (the single source of truth — issue #883), then mv only if it passes.
# Writing the temp first lets the validator see the real on-disk bytes, and a
# failure discards the temp so the original is never replaced by an invalid file.
d = os.path.dirname(os.path.abspath(FILE))
fd, tmp = tempfile.mkstemp(dir=d, suffix=".tmp")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(result)
    validator = os.environ.get("VALIDATOR", "")
    if not validator or not os.path.exists(validator):
        # Can't CERTIFY the rebuild — distinct from "the rebuild is invalid" (exit 4,
        # not 3), so a caller can tell a broken toolchain from a real schema failure.
        sys.stderr.write(f"ERROR: canonical validator not found ({validator!r}); run install-symlinks.sh or check scripts/: {FILE}\n")
        sys.exit(4)
    proc = subprocess.run(["bash", validator, tmp], capture_output=True, text=True)
    if proc.returncode == 1:
        # Validator exit 1 == the rebuilt frontmatter genuinely violates the schema.
        sys.stderr.write(f"ERROR: rebuilt frontmatter is INVALID per canonical schema: {FILE}\n{proc.stdout}{proc.stderr}")
        sys.exit(3)
    if proc.returncode != 0:
        # Validator exit 2 (usage / missing PyYAML) or any other non-zero == the
        # validator could not RUN. That is a toolchain failure, not a schema verdict;
        # surface it as such instead of mislabelling it "invalid frontmatter".
        sys.stderr.write(f"ERROR: canonical validator could not run (exit {proc.returncode}); cannot certify {FILE}\n{proc.stdout}{proc.stderr}")
        sys.exit(4)
    os.replace(tmp, FILE)
except BaseException:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
print(f"normalized: {FILE}  [type={TYPE} scope={scope}]")
PY
