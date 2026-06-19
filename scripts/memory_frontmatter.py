#!/usr/bin/env python3
"""memory_frontmatter.py — THE single definition of the memory-frontmatter schema
AND the preserve-first repair logic.

Before this module, the schema lived in validate-memory-frontmatter.sh and the
repair logic lived in normalize-memory-frontmatter.sh, and a third site that wanted
to do both (the /consolidate self-heal) re-implemented pieces inline and drifted
(issue #883, dir-id 9b3d). Now all three tools import this one module:

  - validate-memory-frontmatter.sh  -> schema_reasons() / validate_paths()
  - normalize-memory-frontmatter.sh -> compute_canonical() + apply_canonical()
  - heal-memory-dir.sh              -> both, in ONE process, in-memory (no per-file
                                       subprocess spawn on the common path)

If the prose in any SKILL.md or script header disagrees with the CODE here, the
code wins and the prose is the bug — same rule that made the validator canonical.

THE SCHEMA (enforced by schema_reasons):
  A memory file MUST open with a `---`-fenced YAML block parsing to a mapping:
    ---
    name: <non-empty string>           # human-readable title / retrieval handle
    description: <non-empty string>    # one-line retrieval cue
    metadata:
      type: <non-empty string>         # OPEN descriptive tag (usually the prefix)
      scope: repo | universal | meta   # CLOSED enum — graduation/eviction branch on it
    ---
  Rules:
    (A) top-level keys ⊆ {name, description, metadata}
    (B) metadata keys  ⊆ {type, scope}
    (C) name, description present and non-empty strings
    (D) metadata.type present and non-empty (value NOT enum-checked — open tag)
    (E) metadata.scope ∈ {repo, universal, meta}
    (F) the frontmatter parses as a YAML mapping at all
"""

import os
import re
import json
import subprocess

# ---- schema constants (the single allowlists) -------------------------------
TOP_ALLOWED = {"name", "description", "metadata"}
META_ALLOWED = {"type", "scope"}
VALID_SCOPES = ("repo", "universal", "meta")

# Known memory-file prefixes. metadata.type is the prefix itself (an OPEN descriptive
# tag — no tool branches on its value). This set is a typo / non-memory-file GATE only
# (rejects `feedbck_`, README.md, claude-md-candidates.md, etc.), NOT a type allowlist.
KNOWN_PREFIXES = {
    "feedback", "concept", "project", "reference", "user",
    "session", "plan", "next", "technical", "bug", "org", "architecture",
    "dreamscape",
}


def prefix_of(basename):
    """The filename prefix (text before the first `_`), or the stem if no `_`."""
    return basename.split("_", 1)[0] if "_" in basename else basename.rsplit(".", 1)[0]


def is_index_file(basename):
    """True for the corpus index files (MEMORY.md, MEMORY.feedback.md, …) which have
    no frontmatter by design and are out of schema scope."""
    return basename == "MEMORY.md" or basename.startswith("MEMORY.")


def is_memory_file(basename):
    """True iff this basename is a schema-gated memory file: a `.md` whose prefix is a
    known memory prefix. Index files and non-prefixed artifacts (claude-md-candidates.md,
    notes, scratch) return False — they are not memory files and must NOT be schema-gated
    (issue #936). This is the prefix filter that folds task #936 into every entry point."""
    if not basename.endswith(".md"):
        return False
    if is_index_file(basename):
        return False
    return prefix_of(basename) in KNOWN_PREFIXES


# ---- strict schema check (the validator) ------------------------------------
# The closing fence must be a line that is exactly `---` (optional trailing space), then
# a newline or EOF — NOT `---garbage`. re.S lets `.` span the YAML newlines; non-greedy
# `(.*?)` stops at the FIRST real closing fence so a body line like `---x` can't pose as it.
_FENCE_RE = re.compile(r"^---\n(.*?)\n---[ \t]*(?:\n|\Z)", re.S)


def schema_reasons(text):
    """Return a list of human-readable reasons `text` violates the schema (empty == valid).

    This is THE schema — identical rules to the historical validate-memory-frontmatter.sh.
    Caller is responsible for skipping index / non-memory files (see is_memory_file)."""
    try:
        import yaml
    except ImportError:  # surfaced as a toolchain failure by the CLI wrappers
        raise

    m = _FENCE_RE.match(text)
    if not m:
        return ["no ---fenced frontmatter block"]
    try:
        fm = yaml.safe_load(m.group(1))
    except Exception as e:  # noqa: BLE001 - any YAML error is a parse failure
        return [f"UNPARSEABLE: {e}"]
    if not isinstance(fm, dict):
        return ["frontmatter is not a YAML mapping"]

    reasons = []

    extra_top = set(fm) - TOP_ALLOWED
    if extra_top:
        reasons.append(f"forbidden top-level keys {sorted(extra_top)}")

    meta = fm.get("metadata")
    if meta is None:
        reasons.append("missing metadata")
        meta = {}
    elif not isinstance(meta, dict):
        reasons.append("metadata is not a mapping")
        meta = {}
    else:
        extra_meta = set(meta) - META_ALLOWED
        if extra_meta:
            reasons.append(f"forbidden metadata keys {sorted(extra_meta)}")

    for k in ("name", "description"):
        v = fm.get(k)
        if not (isinstance(v, str) and v.strip()):
            reasons.append(f"missing/empty {k}")

    t = meta.get("type")
    if not (isinstance(t, str) and t.strip()):
        reasons.append("missing/empty metadata.type")

    s = meta.get("scope")
    if s not in VALID_SCOPES:
        reasons.append(f"metadata.scope {s!r} not in {sorted(VALID_SCOPES)}")

    return reasons


def is_valid(text):
    return not schema_reasons(text)


# ---- lenient repair extraction (the normalizer) -----------------------------
def split_frontmatter(t):
    """Return (frontmatter_text_or_None, body). Tolerates a MISSING closing fence — this
    is the lenient repair splitter, deliberately looser than the strict _FENCE_RE gate."""
    if not t.startswith("---\n") and not t.startswith("---\r\n"):
        return None, t
    lines = t.split("\n")
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            return "\n".join(lines[1:i]), "\n".join(lines[i + 1:])
    return None, t  # no closing fence -> treat whole thing as body, rebuild fm


def extract_fields(fm):
    """Lenient: try YAML, then per-line regex for whatever it missed. Malformed-but-
    parseable-by-eye files are the point — never trust safe_load alone. Returns
    (name, description, scope, type) — each '' when genuinely absent."""
    name = desc = scope = ftype = ""
    if fm is None:
        return name, desc, scope, ftype
    try:
        import yaml
        data = yaml.safe_load(fm)
    except Exception:  # noqa: BLE001
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


class RepairError(Exception):
    """Raised when a file cannot be repaired. `.code` mirrors normalize.sh exit codes:
    1 = unknown prefix, 2 = missing field the LLM fallback could not fill."""

    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def _llm_fill(body):
    """Best-effort headless-`claude` synthesis of NAME/DESCRIPTION. Returns (name, desc),
    either possibly ''. Fires ONLY when a curated field is genuinely missing."""
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
    except Exception:  # noqa: BLE001 - any failure -> empty, caller decides
        return "", ""
    name = desc = ""
    for line in raw.splitlines():
        m = re.match(r"NAME:\s*(.+)", line)
        if m and not name:
            name = m.group(1).strip().strip("\"'")
        m = re.match(r"DESCRIPTION:\s*(.+)", line)
        if m and not desc:
            desc = m.group(1).strip().strip("\"'")
    return name, desc


def compute_canonical(file_path, text=None, allow_llm=True):
    """Compute the canonical form of a memory file, preserve-first. Returns the FULL new
    file text (frontmatter + body). Pure except for the conditional headless-`claude` call
    when a curated field is missing (gated by allow_llm). Raises RepairError on unknown
    prefix or an unfillable missing field.

    Preserve-first guarantees (issue #859):
      - existing non-empty metadata.type kept verbatim; absent -> derived as the prefix
      - existing scope kept; absent or invalid -> defaults to repo (NEVER downgrades
        universal/meta — only fills a genuine absence)
      - name + description preserved verbatim; LLM fill ONLY when genuinely missing
      - body preserved byte-for-byte (an unfenced file gets one synthesized blank line)"""
    base = os.path.basename(file_path)
    if text is None:
        text = open(file_path, encoding="utf-8").read()

    prefix = prefix_of(base)
    if prefix not in KNOWN_PREFIXES:
        raise RepairError(1, f"unknown prefix {prefix!r} (want one of {sorted(KNOWN_PREFIXES)}): {base}")
    derived_type = prefix

    fm, body = split_frontmatter(text)
    had_frontmatter = fm is not None
    name, desc, scope, existing_type = extract_fields(fm)

    ftype = existing_type if existing_type else derived_type
    if scope not in VALID_SCOPES:
        scope = "repo"

    # mechanical name fallback (used only if both extraction AND the model fail)
    slug = re.sub(r"\.md$", "", base.split("_", 1)[1] if "_" in base else base)
    m = re.search(r"^#[ \t]+(.+)$", body, re.M)
    heading = m.group(1).strip() if m else ""
    if heading and heading.lower().replace(" ", "_") != slug and heading != base:
        fallback_name = heading
    elif name:
        fallback_name = name
    else:
        fallback_name = slug.replace("_", " ")

    if (not name or not desc) and allow_llm:
        fill_name, fill_desc = _llm_fill(body)
        if fill_name and not name and fill_name != slug and fill_name != base:
            name = fill_name
        if fill_desc and not desc:
            desc = fill_desc

    if not name:
        name = fallback_name
    if not desc:
        raise RepairError(2, f"empty DESCRIPTION (extraction + model both failed) for {file_path}")
    if not name:
        raise RepairError(2, f"empty NAME (and no fallback) for {file_path}")

    new_fm = (
        "---\n"
        f"name: {json.dumps(name, ensure_ascii=False)}\n"
        f"description: {json.dumps(desc, ensure_ascii=False)}\n"
        "metadata:\n"
        f"  type: {ftype}\n"
        f"  scope: {scope}\n"
        "---"
    )

    # Reconstruct verbatim: a previously-fenced file's `body` already holds its original
    # leading blank line, so a single "\n" closes the fence and the body is byte-for-byte.
    # An unfenced file had no separator to preserve, so synthesize exactly one blank line.
    sep = "\n" if had_frontmatter else "\n\n"
    result = new_fm + sep + body
    if not result.endswith("\n"):
        result += "\n"
    return result


def apply_canonical(file_path, allow_llm=True, skip_if_valid=True):
    """Repair `file_path` in place. Atomic temp+replace, and the rebuilt text is certified
    against the SAME schema_reasons before replacing — a rebuild that would be invalid is
    discarded (RepairError code 3), original untouched. Returns 'clean' (no write) or
    'normalized' (rewritten).

    skip_if_valid=True  (heal's path): an already-valid file is left untouched (no mtime
                        churn, no spurious rewrite). Heal pre-filters to known prefixes so
                        an unknown prefix never reaches here.
    skip_if_valid=False (normalize's path): ALWAYS rebuild, which runs the prefix gate even
                        on a valid file — so `normalize --apply` on an unknown-prefix file
                        raises RepairError(1) and writes nothing, its documented contract."""
    import tempfile

    text = open(file_path, encoding="utf-8").read()
    if skip_if_valid and is_valid(text):
        return "clean"

    result = compute_canonical(file_path, text=text, allow_llm=allow_llm)
    reasons = schema_reasons(result)
    if reasons:  # in-process certification — no subprocess spawn, same single source
        raise RepairError(3, f"rebuilt frontmatter is INVALID per canonical schema: {file_path}: {'; '.join(reasons)}")

    d = os.path.dirname(os.path.abspath(file_path))
    fd, tmp = tempfile.mkstemp(dir=d, suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(result)
        os.replace(tmp, file_path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    return "normalized"
