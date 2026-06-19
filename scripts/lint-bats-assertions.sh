#!/usr/bin/env bash
# lint-bats-assertions.sh — fail CI if a .bats file contains a bare conditional
# assertion that bats would silently swallow.
#
# THE FOOTGUN (see tests/helpers.bash for the full writeup):
#   bats runs test bodies under `set -eET`, but the `[[ ... ]]` keyword and
#   `!`-inverted commands are EXEMPT from errexit. A false one that isn't the
#   body's last command is silently swallowed, so the test passes green while
#   its assertion is a lie.
#
# THE INVARIANT THIS ENFORCES:
#   A `[`, `[[`, or `!` command used as a STANDALONE assertion must carry an
#   `||` guard (the convention is `|| fail "msg"`; `|| return` / `|| skip` also
#   satisfy it). "Standalone" = the command segment has no `&&` or `||` of its
#   own. A segment that already chains with `&&`/`||` is deliberate control flow
#   (a teardown `[ -d x ] && rm`, a `[ a ] || printf` loop guard) — the author
#   supplied an alternative branch, so the swallow can't bite. Those are NOT
#   flagged.
#
# KNOWN LIMITATION (documented, not a bug):
#   A compound `[[ a ]] && [[ b ]]` used as an assertion is treated as control
#   flow (it has `&&`) and is NOT flagged, even though the trailing `[[ b ]]`
#   would be swallowed. Convention: write compound assertions as separate
#   `|| fail` lines. There are zero such lines in this repo today.
#
# Usage: lint-bats-assertions.sh [FILE_OR_DIR ...]   (defaults to ./tests)
set -euo pipefail

# Collect target .bats files.
targets=()
if [[ $# -eq 0 ]]; then
  set -- tests
fi
for arg in "$@"; do
  if [[ -d "$arg" ]]; then
    while IFS= read -r f; do targets+=("$f"); done < <(find "$arg" -name '*.bats' | sort)
  elif [[ -f "$arg" ]]; then
    targets+=("$arg")
  fi
done

if [[ ${#targets[@]} -eq 0 ]]; then
  echo "lint-bats-assertions: no .bats files found in: $*" >&2
  exit 0
fi

# The scanner. Reads one .bats file on stdin, prints "LINENO<TAB>SOURCE" for
# each violating line. All the awkward parsing lives here:
#   - heredoc bodies are skipped (JSON/YAML fixtures can begin with `[`)
#   - `\`-continuations are joined into one logical line
#   - trailing comments are stripped (outside quotes) before the `||` check
#   - the logical line is split on `;` into segments; each segment is judged
scan_awk='
function mask(s,    i, c, q1, q2, out) {
  # Return s with the CONTENTS of all quoted spans replaced by X, preserving
  # length and the quote chars themselves. This neutralizes shell metacharacters
  # (; # && ||) that live INSIDE strings/globs, so the structural analysis below
  # only ever sees real operators. e.g.  [[ "$x" == *";"* ]] || fail
  #                              mask ->  [[ "XX" == *"X"* ]] || fail
  q1 = 0; q2 = 0; out = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == "\x27" && !q2)      { q1 = !q1; out = out c }
    else if (c == "\"" && !q1)   { q2 = !q2; out = out c }
    else if (q1 || q2)           { out = out "X" }
    else                         { out = out c }
  }
  return out
}
function strip_comment(s,    i) {
  # On an already-masked line, the first `#` preceded by whitespace is a real
  # comment (in-quote `#` is now X). Truncate there.
  for (i = 1; i <= length(s); i++) {
    if (substr(s, i, 1) == "#" && (i == 1 || substr(s, i-1, 1) ~ /[ \t]/)) {
      return substr(s, 1, i - 1)
    }
  }
  return s
}
function is_bare_assertion(seg,    t) {
  # seg already has no surrounding whitespace. A bare assertion starts with
  # the test token and contains no && or || of its own.
  if (seg ~ /(&&|\|\|)/) return 0
  # leading token must be [ , [[ , or ! followed by whitespace or end
  if (seg ~ /^\[\[?([ \t]|$)/) return 1
  if (seg ~ /^![ \t]/) return 1
  return 0
}
BEGIN { in_heredoc = 0; delim = ""; pending = "" }
{
  raw = $0

  # Inside a heredoc body: copy through, watch for the terminator.
  if (in_heredoc) {
    line = raw
    sub(/^[ \t]*/, "", line)   # <<- allows tab-indented terminator
    if (line == delim) in_heredoc = 0
    next
  }

  # Join backslash continuations into one logical line.
  if (pending != "") { raw = pending " " raw; pending = "" }
  if (raw ~ /\\[ \t]*$/) { sub(/\\[ \t]*$/, "", raw); pending = raw; next }

  logical = raw
  lineno = NR

  # Does this logical line OPEN a heredoc? Capture the delimiter; the body
  # starts on the NEXT line, so we still lint THIS line normally.
  if (match(logical, /<<-?[ \t]*["\x27]?[A-Za-z_][A-Za-z0-9_]*["\x27]?/)) {
    d = substr(logical, RSTART, RLENGTH)
    sub(/^<<-?[ \t]*["\x27]?/, "", d)
    sub(/["\x27]?$/, "", d)
    delim = d
    in_heredoc = 1
  }

  code = strip_comment(mask(logical))

  # Split the code on ; into segments; judge each. (code is masked, so any ;
  # inside a quoted glob is gone and never splits an assertion from its guard.)
  n = split(code, segs, ";")
  for (k = 1; k <= n; k++) {
    seg = segs[k]
    gsub(/^[ \t]+|[ \t]+$/, "", seg)
    if (seg == "") continue
    if (is_bare_assertion(seg)) {
      printf "%d\t%s\n", lineno, logical
      break
    }
  }
}
'

violations=0
for f in "${targets[@]}"; do
  while IFS=$'\t' read -r lineno src; do
    printf '%s:%s: bare assertion (needs `|| fail`):%s\n' "$f" "$lineno" "$src" >&2
    violations=$((violations + 1))
  done < <(awk "$scan_awk" "$f")
done

if [[ $violations -gt 0 ]]; then
  echo "" >&2
  echo "lint-bats-assertions: $violations bare assertion(s) found." >&2
  echo "bats swallows a false \`[[ ]]\`/\`!\` that isn't the last command." >&2
  echo "Guard each with \`|| fail \"msg\"\` (see tests/helpers.bash)." >&2
  exit 1
fi
echo "lint-bats-assertions: ${#targets[@]} file(s) clean."
