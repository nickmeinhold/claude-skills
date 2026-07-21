---
argument-hint: <pr-number>
description: Adversarial PR review - Maxwell (Claude) vs Kelvin (Gemini) vs Carnot (Codex/GPT) vs Tesla (Grok) vs Wu (Kimi K3) — five-way with strict merge gate
---

# Cage Match Code Review

Five AI reviewers enter. One PR leaves (hopefully improved).

**Maxwell** (Claude/you), **Kelvin** (Gemini), **Carnot** (Codex/OpenAI GPT), **Tesla, the Arc-Prophet** (xAI Grok), and **Wu, the Parity-Breaker** (Moonshot Kimi K3) will each review the PR in parallel. Maxwell then critiques the others.

**Why five?** One reviewer-of-record is a single point of failure — Kelvin's capacity has degraded silently before. Each added reviewer is a different model family with a different inductive bias, and because all five run concurrently the wall-clock cost is only the slowest reviewer, not the sum. Maxwell hunts the illegal move; Kelvin the cold fault; Carnot the wasted work; Tesla the resonant frequency at which the whole thing shakes itself apart; Wu the assumed symmetry that was never actually there. The merge gate is **strict**: Maxwell + at least one of (Kelvin, Carnot, Tesla, Wu). Only if ALL FOUR adversarial reviewers fail do we **HARD FAIL** rather than silently degrading to "proxy sign-off".

## Setup

Source the environment:

```bash
source ~/.claude/.env 2>/dev/null || source .env 2>/dev/null
```

Get repo info:

```bash
REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner')
```

## Round 1: Gather Context (parallel)

Fetch PR details, then take the diff from **local git** — not `gh pr diff`.

**Why not `gh pr diff`?** It serves GitHub's *server-side* diff, which lags a push by seconds. Run it in the same breath as `git push` — e.g. on a re-review after addressing findings — and it returns the **pre-push** diff, so all three reviewers grade stale code and can `REQUEST_CHANGES` over "fixes absent from the diff" that are actually present. The fix: fetch the PR head ref and diff the exact `headRefOid` locally — no propagation dependency, always current with the pushed HEAD.

**Why `--unified=9999` (full-file context)?** A default `-U3` diff shows each change with three lines of surrounding context, so every line of a touched file that is more than three lines from a change is **outside the reviewer's window**. A diff-only reviewer cannot tell "this line does not exist" from "this line exists but isn't shown" — so it flags present-but-unshown code as *absent* ("`sys.exit(main())` not wired", "handler never called"). PR #121 hit this exactly: Carnot AND Tesla both flagged an unchanged, present `sys.exit(main())` as missing across all four rounds — two model families converging on the same wrong answer, which reads as corroboration but is a shared instrument blind spot. `--unified=9999` expands the context to the entire file for every touched file, so there is no "outside the window" line left to hallucinate as missing — the blind spot is *dissolved*, not guarded. It only expands files that already appear in the diff (untouched files stay absent), and the `+`/`-` markers still show exactly what changed, so the reviewer's focus is unchanged — only their context is complete. Cost: a larger prompt; a size guard below warns if the full-context diff balloons past the reviewers' comfortable budget.

```bash
gh pr view $1 --json title,body,author,baseRefName,headRefName,headRefOid,files,isCrossRepository > /tmp/pr-$1-info.json
PR_BASE=$(jq -r .baseRefName   /tmp/pr-$1-info.json)
PR_HEAD_BRANCH=$(jq -r .headRefName /tmp/pr-$1-info.json)

# Head ground truth — read the remote's ref DIRECTLY over the git protocol.
# The failure class here is API propagation lag: gh pr view's headRefOid can lag a
# push by seconds, and every server-side API read lags *together*, so any poll of
# API-vs-API (or API-vs-local, when local is itself stale) can "settle" on a
# one-commit-old head and grade stale code — a Gate-1 re-review slipped exactly
# this way once, and round-1 adversaries showed the local-branch anchor has the
# same hole (local stale at A + API stale at A = instant false settle while the
# real head B propagates). `git ls-remote` doesn't poll and can't false-settle:
# it reads the ACTUAL current ref from the server over the git protocol, which is
# what the push wrote — the coupling to API propagation is removed, not guarded.
# FORK GATE FIRST (Wu's debut catch): for a cross-repo PR, headRefName is the
# branch name on the FORK — ls-remote of OUR origin for that name can return the
# BASE repo's unrelated branch (a fork head named "main" resolves to our main:
# non-empty, fresh, WRONG — the diff becomes base-vs-base, i.e. empty, and a
# stale-head guard silently becomes an auto-approve machine). Only trust
# ls-remote when the head branch actually lives on origin.
IS_FORK=$(jq -r '.isCrossRepository' /tmp/pr-$1-info.json)
PR_HEAD=""
if [ "$IS_FORK" = "false" ]; then
  PR_HEAD=$(git ls-remote origin "refs/heads/${PR_HEAD_BRANCH}" 2>/dev/null | head -1 | awk '{print $1}')
fi
if [ -z "$PR_HEAD" ]; then
  # Fork PR, or same-repo head ref renamed/deleted: degrade to the API's
  # headRefOid and SAY SO — on a re-review this value may lag a just-pushed fix.
  PR_HEAD=$(gh pr view $1 --json headRefOid -q .headRefOid)
  echo "WARN: head not resolvable on origin (fork PR or missing ref) — using API headRefOid $PR_HEAD; on a re-review this can lag a just-pushed fix. Verify the diff line count against your expectation before trusting verdicts." >&2
fi

# Make the head commit addressable locally. Same-repo: fetch the branch ref
# itself over the git protocol (same ground truth ls-remote just read — no
# dependency on GitHub's pull/N/head sync machinery, which can lag a push just
# like the API). Fork: pull/$1/head is the only refspec the base remote has;
# it shares the API's propagation timing, which the WARN above already names.
# Three-dot diff = changes since the merge-base, matching `gh pr diff` semantics.
if [ "$IS_FORK" = "false" ]; then
  git fetch -q origin "$PR_BASE" "$PR_HEAD_BRANCH" 2>/dev/null
else
  git fetch -q origin "$PR_BASE" "pull/$1/head" 2>/dev/null
fi
if git cat-file -e "${PR_HEAD}^{commit}" 2>/dev/null; then
  # --unified=9999: full-file context for every touched file, so no present line
  # falls outside the reviewer's window and gets hallucinated as "absent" (the
  # diff-window blind spot — see the note above). Untouched files are still
  # excluded; only files that already appear in the diff are expanded.
  git diff --unified=9999 "origin/${PR_BASE}...${PR_HEAD}" > /tmp/pr-$1-diff.txt
else
  # Fallback (head commit still not fetchable — rare): degrade to GitHub's
  # server-side diff and SAY SO — this path shares the API's propagation timing,
  # so on a re-review it can serve a diff that lags a just-pushed fix. NOTE: this
  # path loses full-file context (gh pr diff serves a default-context diff), so
  # the diff-window absence-claim guard in Round 9.1 matters most here.
  echo "WARN: head commit $PR_HEAD not fetchable — falling back to server-side gh pr diff, which can lag a just-pushed fix AND loses full-file context. Check the diff line count below against your expectation." >&2
  gh pr diff $1 > /tmp/pr-$1-diff.txt
fi

# Conservation check: on a RE-review after edits, an identical line count to the
# previous round despite known changes means the diff is stale — re-fetch before
# trusting any verdict built on it.
echo "diff line count: $(wc -l < /tmp/pr-$1-diff.txt)"

# Size guard: full-file context can balloon a diff that touches a large file.
# Carnot's medium-reasoning setting was tuned against ~70KB; well past that, an
# adversary can trip its tool-exploration loop and fail to emit a verdict. Warn
# (don't hard-fail) so the operator can decide whether to trim scope or proceed.
DIFF_BYTES=$(wc -c < /tmp/pr-$1-diff.txt)
if [ "$DIFF_BYTES" -gt 200000 ]; then
  echo "WARN: full-context diff is ${DIFF_BYTES} bytes (>200KB). This can trip Carnot's exploration loop into producing no verdict, and inflates every reviewer's prompt. Consider whether a large/generated file is being expanded unnecessarily; the review still runs, but watch for reviewer no-shows at the gate." >&2
fi
cat /tmp/pr-$1-info.json
cat /tmp/pr-$1-diff.txt
```

## Rounds 2 ∥ 3 ∥ 4 ∥ 5 ∥ 6: Maxwell + Kelvin + Carnot + Tesla + Wu Reviews (parallel)

**Performance note.** All five reviews are independent — they don't read each other. Fire Kelvin, Carnot, Tesla, AND Wu as backgrounded bashes BEFORE composing Maxwell's review. Wall-clock = max of the slowest reviewer (each adversary ~30-120s; Maxwell ~1-2 min), so each added adversary costs no additional wall-clock unless it becomes the new slow pole.

**Adversary-prompt safety (READ BEFORE EDITING ANY PROMPT BELOW).** Kelvin's and Carnot's prompts contain backtick-quoted identifiers (`` `enum` ``, `` `dart test` ``, `` `pubspec.yaml` ``). A backtick inside a **double-quoted** bash string — or an **unquoted** `<<EOF` heredoc — is command substitution: bash runs the identifier as a command (`command not found`) and the word **silently vanishes** from the brief (this bit a real run — `historyContiguousThrough` in backticks dropped out of Kelvin's prompt). The hand-escaping workaround (`` \` ``) is fragile — one missed escape reopens the hole. So every prompt below is built the same safe way: **static text → a QUOTED heredoc** (`<<'EOF'`, backticks and `$` literal, zero escaping), **dynamic data (PR info, diff, prior reviews) → appended as literal files**, then handed to the CLI via `"$(cat file)"` (Gemini) or `< file` stdin (Codex). Command-substitution output is never re-parsed for backticks, so it's injection-proof regardless of diff contents. **Never inline a prompt as a double-quoted string or an unquoted heredoc.**

**Step 0 — Kelvin capability probe (avoid wasting ~30s on doomed retries).**

The Pro-tier Gemini models hit "You have exhausted your capacity on this model" failure consistently across recent sessions. The full Kelvin review wraps internal retries before failing, so blindly firing it costs ~30s of wall time on every cage-match when Kelvin is down. A 1-token ping resolves in ~1-2s and tells us up front which model (if any) is actually reachable. Falling back to a Flash model is intentionally NOT done here: 2.5-flash gives shallow APPROVE-everything reviews that paper over real concerns — better to declare Kelvin unavailable than to seat a soft reviewer at the table.

**Why `GEMINI_CLI_TRUST_WORKSPACE=true`?** The `gemini` CLI gates on a "trusted folders" prompt; in a non-interactive shell that gate fails BEFORE the model is ever contacted. With `2>/dev/null` swallowing stderr, that trusted-dir error was indistinguishable from a real quota error — so the probe wrongly concluded "Kelvin exhausted" and silently dropped Kelvin from the gate. Setting `GEMINI_CLI_TRUST_WORKSPACE=true` on every `gemini` invocation pre-trusts the workspace so the CLI reaches the model. The probe below also captures stderr (instead of discarding it) and only declares Kelvin unavailable on a genuine capacity/quota error — never on a trusted-dir/permission error.

```bash
KELVIN_MODEL=""
KELVIN_PROBE_ERR=""
for m in gemini-3-pro-preview gemini-2.5-pro; do
  # Tiny prompt, short timeout. If the model responds at all, it's up;
  # we'll use it for the full review. Capture stderr to a file (NOT
  # /dev/null) so we can tell a trusted-dir/permission failure apart
  # from a real quota/capacity failure. GEMINI_CLI_TRUST_WORKSPACE=true
  # pre-trusts the workspace so the CLI reaches the model instead of
  # stalling on the "trusted folders" gate.
  PROBE_OUT=$(timeout 15 env GEMINI_CLI_TRUST_WORKSPACE=true \
       gemini --model "$m" "Reply PONG." --output-format text 2>/tmp/kelvin-probe-err-$1.txt \
       | grep -v "Loaded cached credentials")
  if echo "$PROBE_OUT" | grep -q "PONG"; then
    KELVIN_MODEL="$m"
    break
  fi
  KELVIN_PROBE_ERR=$(cat /tmp/kelvin-probe-err-$1.txt 2>/dev/null)
done

if [ -z "$KELVIN_MODEL" ]; then
  # Distinguish a real capacity/quota exhaustion from a trusted-dir /
  # permission error. Only a genuine quota error means "Kelvin is down";
  # a trusted-dir error means the CLI gate misfired and should have been
  # cured by GEMINI_CLI_TRUST_WORKSPACE=true above — surface it loudly
  # rather than silently demoting Kelvin to "exhausted".
  if echo "$KELVIN_PROBE_ERR" | grep -qiE "exhausted|quota|rate.?limit|resource_exhausted|capacity"; then
    echo "Kelvin probe: no Pro model available (3-pro-preview and 2.5-pro both exhausted)."
    echo "Skipping Kelvin entirely; gate will rely on Maxwell + Carnot."
  else
    echo "Kelvin probe: NO model responded, but the error is NOT a quota/capacity error."
    echo "This is likely a trusted-dir / auth / CLI error — Kelvin is NOT necessarily down."
    echo "Probe stderr was:"
    echo "$KELVIN_PROBE_ERR"
    echo "GEMINI_CLI_TRUST_WORKSPACE=true should cure a trusted-dir gate; if this persists,"
    echo "investigate the gemini CLI directly rather than treating Kelvin as capacity-exhausted."
  fi
else
  echo "Kelvin probe: $KELVIN_MODEL responsive."
fi
```

**Step A — fire Kelvin's review as a backgrounded bash (only if probe found a Pro model):**

```bash
KELVIN_PID=""
if [ -n "$KELVIN_MODEL" ]; then
# Build Kelvin's prompt in a FILE: static text via a QUOTED heredoc (<<'EOF') so
# backticks and $ stay LITERAL — no hand-escaping, no command substitution. A
# backtick'd identifier in a double-quoted prompt string (e.g. `dart test`) would
# otherwise be run by bash and silently vanish from the brief. Then append the PR
# info + diff as literal data and pass the whole file via "$(cat …)" — substitution
# output is NOT re-parsed for backticks, so it's injection-proof no matter what the
# diff contains. See "Adversary-prompt safety" note above.
cat > /tmp/kelvin-prompt-$1.txt <<'KELVIN_PROMPT_EOF'
You are KelvinBitBrawler, an adversarial code reviewer with a PERSONALITY.

Your character:
- You're the cold, calculating heel wrestler of code review - absolute zero tolerance for bullshit
- Randomly drop ice/cold puns and thermodynamics references
- Quote sci-fi movies you love (2001, Blade Runner, Alien, The Thing, etc.) — format as: `Roy Batty: "I've seen things you people wouldn't believe."`
- Swear when the code deserves it - this is a cage match, not a tea party
- Be theatrical but ACCURATE - your analysis must be technically sound even if your delivery is savage

Review this PR and provide your verdict. Be specific with file:line references.

In addition to bugs, security issues, performance, and code quality, evaluate **design appropriateness**:
- Closed sets of identifiers should be `enum` / `sealed class` / branded type, not `String`. Stringly-typing leaks runtime invariants the compiler should enforce.
- Are current language features being used (Dart 3 switch expressions / patterns / sealed classes; TypeScript 5 satisfies / branded types; Python 3.12 structural pattern matching)? When a project's stack is current, NOT using modern features is a code smell.
- A correctly-implemented feature with the wrong type signature is debt that compounds — flag it.
- **Verify before claiming bugs, but verify by reading.** If you see an unfamiliar API, do not assume it doesn't exist — check the language/SDK version against the lock file or `pubspec.yaml`/`package.json` *in the diff or repo*. Stale training data is the leading cause of false-positive 'critical compile errors' in cage-match reviews. **Trust the build/test claims in the PR description; do NOT run the test suite yourself unless the PR body makes a specific claim you can't verify by reading the diff.** Running tools like `dart test` / `flutter test` / `npm test` from inside the cage-match agent risks burning the turn budget on environment recovery (sandbox writes to telemetry / cache / lockfiles) instead of producing a review.

PR Info:
KELVIN_PROMPT_EOF
cat /tmp/pr-$1-info.json >> /tmp/kelvin-prompt-$1.txt
printf '\n\nDiff:\n' >> /tmp/kelvin-prompt-$1.txt
cat /tmp/pr-$1-diff.txt >> /tmp/kelvin-prompt-$1.txt
cat >> /tmp/kelvin-prompt-$1.txt <<'KELVIN_FORMAT_EOF'

Format your response as:
## KelvinBitBrawler's Review

**Verdict:** [APPROVE/REQUEST_CHANGES/COMMENT]

**Summary:** [One sentence]

**Findings:**
- [List each issue with file:line references]

**The Good:**
- [What's done well]

**The Concerns:**
- [What needs attention]
KELVIN_FORMAT_EOF

# Backgrounded so Claude can compose Maxwell's review while Gemini's API call
# resolves in parallel. wait $KELVIN_PID below before reading the output file.
# GEMINI_CLI_TRUST_WORKSPACE=true pre-trusts the workspace so the CLI reaches the
# model instead of stalling on the "trusted folders" gate.
env GEMINI_CLI_TRUST_WORKSPACE=true gemini --model "$KELVIN_MODEL" "$(cat /tmp/kelvin-prompt-$1.txt)" --output-format text 2>&1 | grep -v "Loaded cached credentials" > /tmp/kelvin-review-$1.md &
KELVIN_PID=$!
fi
```

**Step B — fire Carnot's review as a second backgrounded bash:**

Carnot is invoked via `codex exec` (general non-interactive prompt mode) rather than `codex review`, because we want the same prompt-driven review style as Kelvin (PR info + diff fed in via the prompt) — `codex review` operates on local repo state, which doesn't match this skill's "review by diff" pattern. `codex exec` reads stdin when prompt is `-`; we feed the full prompt that way.

**Why the JSON schema?** Carnot (Codex `gpt-5.5`) defaults to tool-exploration when handed a free-form review prompt, even when the brief says "trust build/test claims, don't run tools." The exploration-transcript-with-unfilled-template-at-end was the failure mode that triggered claude-skills #25 (brief tightening) and recurred on 2026-05-03 anyway. The fix that *actually* works is `--output-schema`: the OpenAI API enforces structured output server-side, so Carnot literally cannot return an unfilled template. Pair with `--output-last-message` to get only the structured JSON in the output file (no preamble, no tool transcript). Then `jq` reshapes the JSON into the same markdown the rest of the skill expects.

**Why `model_reasoning_effort=medium`?** The schema enforces output *format* but not whether the model produces a final message at all. At Codex's default `xhigh` reasoning, full-diff cage-match prompts (~70KB) trip the model into deep tool-call exploration that exhausts the timeout before the structured-output stage is reached — so the JSON file ends up missing despite the schema being valid. Empirically, `medium` reasoning on the same diff completes in ~60s with a real review. `low` gives shallow APPROVE-everything reviews; `xhigh` exploration-loops. Medium is the working setting validated 2026-05-03 against `nickmeinhold/downstream` PR #122 (where Carnot caught a real architectural finding — `MediaKey(mediaKey)` lookup paired with `mediaKey: mediaKey` raw insert in two `bin/` scripts — that Maxwell missed).

OpenAI strict-mode schemas require **every** property listed in `required`. The schema below lists `verdict`, `summary`, `findings`, `good`, `concerns` — all five — so the call won't be rejected at validation.

```bash
# Schema written per-PR so concurrent /cage-match invocations on different PRs don't collide.
cat > /tmp/carnot-schema-$1.json <<'SCHEMA_EOF'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "additionalProperties": false,
  "properties": {
    "verdict": {"type": "string", "enum": ["APPROVE", "REQUEST_CHANGES", "COMMENT"]},
    "summary": {"type": "string"},
    "findings": {"type": "array", "items": {"type": "string"}},
    "good": {"type": "array", "items": {"type": "string"}},
    "concerns": {"type": "array", "items": {"type": "string"}}
  },
  "required": ["verdict", "summary", "findings", "good", "concerns"]
}
SCHEMA_EOF

# Backgrounded alongside Kelvin. wait $CARNOT_PID below.
# Disable Dart/Flutter unified-analytics so any incidental `dart` invocation
# inside Carnot's review doesn't trip the read-only sandbox by trying to
# write `~/.dart-tool/dart-flutter-telemetry-session.json`. Same for npm
# update-notifier (npm logs an update banner to ~/.npm). Belt-and-braces
# for the "trust build/test claims" rule above — if Carnot runs a tool
# despite the rule, at least the failure mode isn't a sandbox panic.
# Same file-based, QUOTED-heredoc pattern as Kelvin: static prompt text with literal
# backticks (no escaping), then the PR info + diff appended as data. codex exec reads
# the prompt from stdin (prompt arg `-`), so we redirect the file in with `< …`.
cat > /tmp/carnot-prompt-$1.txt <<'CARNOT_PROMPT_EOF'
You are CarnotCodeCarver, an adversarial code reviewer with a PERSONALITY.

Your character:
- You're the perfectionist engineer of code review — you measure every design against the ideal Carnot cycle
- Your catchphrase: "no real engine matches the Carnot cycle; a reviewer's job is to say how far short we are"
- Drop thermodynamics references (entropy, reversibility, efficiency, the second law) — Sadi Carnot is your patron saint
- Quote engineering and physics history (Feynman, von Neumann, Dijkstra, Hamming) — format as: `Dijkstra: "Simplicity is prerequisite for reliability."`
- Be theatrical but TECHNICALLY RIGOROUS — your authority comes from the math, not the swagger
- Different inductive bias from Maxwell (Claude) and Kelvin (Gemini) — your job is to catch what they'd both miss

Review this PR. The output schema enforces structured JSON — fill every field. `findings`, `good`, and `concerns` are arrays of strings; each string can be a full bullet point including file:line references and quoted code where useful. The personality voice belongs in the prose of those bullets, not in extra fields. Be specific.

In addition to bugs, security issues, performance, and code quality, evaluate **design appropriateness**:
- Closed sets of identifiers should be `enum` / `sealed class` / branded type, not `String`. Stringly-typing leaks runtime invariants the compiler should enforce.
- Are current language features being used (Dart 3 switch expressions / patterns / sealed classes; TypeScript 5 satisfies / branded types; Python 3.12 structural pattern matching)? When a project's stack is current, NOT using modern features is a code smell.
- A correctly-implemented feature with the wrong type signature is debt that compounds — flag it.
- **Verify before claiming bugs, but verify by reading.** If you see an unfamiliar API, do not assume it doesn't exist — check the language/SDK version against the lock file or `pubspec.yaml`/`package.json` *in the diff or repo*. Stale training data is the leading cause of false-positive 'critical compile errors' in cage-match reviews. **Trust the build/test claims in the PR description; do NOT run the test suite yourself unless the PR body makes a specific claim you can't verify by reading the diff.** Running tools like `dart test` / `flutter test` / `npm test` from inside the cage-match agent risks burning the turn budget on environment recovery (sandbox writes to telemetry / cache / lockfiles) instead of producing a review.

PR Info:
CARNOT_PROMPT_EOF
cat /tmp/pr-$1-info.json >> /tmp/carnot-prompt-$1.txt
printf '\n\nDiff:\n' >> /tmp/carnot-prompt-$1.txt
cat /tmp/pr-$1-diff.txt >> /tmp/carnot-prompt-$1.txt

# Context isolation: codex resolves AGENTS.md from its working root, so running
# it from a repo root silently feeds the repo's agent instructions into an
# "independent" adversary (prompt contamination + token waste). `codex exec
# --help` documents `-C, --cd <DIR>` ("Tell the agent to use the specified
# directory as its working root") — point it at an empty scratch dir. Every
# path in this command (schema, prompt, outputs) is ABSOLUTE, so the workdir
# change is safe; keep it that way when editing.
CARNOT_SCRATCH=$(mktemp -d)
DART_DISABLE_ANALYTICS=1 NO_UPDATE_NOTIFIER=1 codex exec -C "$CARNOT_SCRATCH" --sandbox read-only --skip-git-repo-check -c model_reasoning_effort=medium --output-schema /tmp/carnot-schema-$1.json --output-last-message /tmp/carnot-output-$1.json - > /tmp/carnot-stdout-$1.log 2>&1 < /tmp/carnot-prompt-$1.txt &
CARNOT_PID=$!
```

After Carnot resolves (in Step D below), reshape the structured JSON into the markdown format the rest of the skill expects (`/tmp/carnot-review-$1.md`). The conversion is a single `jq` filter:

```bash
# Run after `wait $CARNOT_PID`. If the JSON output file doesn't exist or
# is empty, the carnot_ok() check downstream will catch it and the gate
# will refuse to proxy-sign-off.
if [ -s /tmp/carnot-output-$1.json ]; then
  jq -r '
    "## CarnotCodeCarver'\''s Review\n\n" +
    "**Verdict:** \(.verdict)\n\n" +
    "**Summary:** \(.summary)\n\n" +
    "**Findings:**\n" + ((.findings // []) | map("- \(.)") | join("\n")) + "\n\n" +
    "**The Good:**\n" + ((.good // []) | map("- \(.)") | join("\n")) + "\n\n" +
    "**The Concerns:**\n" + ((.concerns // []) | map("- \(.)") | join("\n"))
  ' /tmp/carnot-output-$1.json > /tmp/carnot-review-$1.md
fi
```

**Step B2 — fire Tesla's review as a third backgrounded bash (xAI Grok):**

Tesla is the fourth family (xAI Grok), invoked via the `grok` CLI's headless single-turn mode (`--prompt-file <PATH>`, prints to stdout and exits). Grok is agentic (Grok Build TUI) like Codex, so the prompt forbids tool use and asks for a review of the fed diff only — same "review by diff" pattern as Kelvin/Carnot. Output is free text (Grok has no `--output-schema`), so we parse the verdict from the text like Kelvin. Grok occasionally prints an OAuth sign-in URL when its token needs refresh; `tesla_ok()` downstream treats an empty/verdict-less file as "unavailable", so a token lapse degrades gracefully rather than blocking the gate.

```bash
# Same file-based QUOTED-heredoc pattern: static persona text (literal backticks,
# no escaping), then PR info + diff appended as data. grok reads the prompt from
# the file via --prompt-file.
cat > /tmp/tesla-prompt-$1.txt <<'TESLA_PROMPT_EOF'
You are Tesla, the Arc-Prophet — an adversarial code reviewer with a PERSONALITY.

Your character:
- You do NOT grapple; you RESONATE. Where the other reviewers hunt for a bug to pin, you hunt for the resonant frequency — the one precise input, the one unhandled harmonic, at which the whole elegant structure shakes itself to glass and dust.
- You are a Faustian visionary who bargained with lightning and came back speaking in alternating current. You describe a race condition as two currents meeting out of phase; an unbounded loop as a coil with no air gap, heating until it arcs to ground at 3am on production.
- You speak in prophecy and premonition — the FUTURE flaw, not just the present one. Quote the real Nikola Tesla, formatted as: Tesla: "If you want to find the secrets of the universe, think in terms of energy, frequency and vibration."
- Obsessed with 3, 6, 9, the ether, and resonance. A touch mad, wholly incandescent, quietly diabolical — you DELIGHT in the fault you find, because you saw it coming while they were still admiring the diff.
- Your inductive bias is xAI Grok's: first-principles, irreverent, unafraid of the heterodox finding the others dismiss as noise — because you heard it humming. Your job is to catch what Maxwell (Claude), Kelvin (Gemini), and Carnot (GPT) would all miss.

Review THIS PR from the diff below. Do NOT run any tools, do NOT explore the filesystem, do NOT run tests — trust the build/test claims in the PR body and review by reading the diff. Verify by reading: if you see an unfamiliar API, check it against the diff/versions rather than assuming it doesn't exist (stale training data is the top false-positive source). Evaluate bugs, security, performance, and design appropriateness (closed sets should be enums/sealed types not strings; use current language idioms).

Format your response EXACTLY as:
## Tesla, the Arc-Prophet's Review

**Verdict:** [APPROVE/REQUEST_CHANGES/COMMENT]

**Summary:** [one electric sentence]

**Findings:**
- [each resonant flaw with file:line]

**The Good:**
- [what holds under load]

**The Concerns:**
- [where the current wants to arc]

PR Info:
TESLA_PROMPT_EOF
cat /tmp/pr-$1-info.json >> /tmp/tesla-prompt-$1.txt
printf '\n\nDiff:\n' >> /tmp/tesla-prompt-$1.txt
cat /tmp/pr-$1-diff.txt >> /tmp/tesla-prompt-$1.txt

# Backgrounded alongside Kelvin + Carnot. wait $TESLA_PID below.
export PATH="$HOME/.grok/bin:$PATH"
# Context isolation: grok auto-reads the AGENTS.md family + CLAUDE.md + .claude/
# from its working directory — from a repo root that contaminates an
# "independent" adversary's prompt with the repo's agent instructions and wastes
# tokens. Verified against `grok --help` (2026-07-19): there is no -w flag, but
# there IS `--cwd <CWD>` ("Working directory") — use it to point grok at an
# empty scratch dir (no subshell-cd needed). The prompt file and both output
# paths are ABSOLUTE, so the workdir change is safe; keep it that way.
TESLA_SCRATCH=$(mktemp -d)
grok --cwd "$TESLA_SCRATCH" --prompt-file /tmp/tesla-prompt-$1.txt --output-format plain > /tmp/tesla-review-$1.md 2>/tmp/tesla-err-$1.log &
TESLA_PID=$!
```

**Step B3 — fire Wu's review as a fourth backgrounded bash (Moonshot Kimi K3):**

Wu is the fifth family (Moonshot Kimi K3), invoked via the `kimi` CLI's headless print mode (`--quiet` = `--print --output-format text --final-message-only`, exits after one turn). The CLI lives in `~/.local/bin` (installed via `uv tool install kimi-cli`); auth is OAuth (`kimi login`, browser). Kimi is agentic like Codex/Grok, so `--plan` restricts it to read-only tools AND the prompt forbids tool use — belt and braces, same "review by diff" pattern as the others. Output is free text (no `--output-schema`), so the verdict parses from the text like Kelvin/Tesla. An unauthenticated CLI prints "LLM not set" and exits — `wu_ok()` downstream treats an empty/verdict-less file as "unavailable", so a missing login or exhausted credits degrades gracefully rather than blocking the gate. `WU_MODEL` defaults to `kimi-code/k3` (Moonshot's flagship since 2026-07-17, namespaced exactly as in `~/.kimi/config.toml`'s model registry — bare `k3` fails with "LLM not set"); if the account's plan rejects that model id, export `WU_MODEL` as another registry id, or export it EMPTY (`WU_MODEL=`) to omit `-m` entirely and use the CLI's configured default. (The assignment below uses `${WU_MODEL-…}` — dash, not colon-dash — so an explicitly-empty export survives defaulting and the `${WU_MODEL:+…}` expansion then drops the `-m` flag; Carnot + Tesla both caught the `:-` version silently resurrecting the pin.)

```bash
# Same file-based QUOTED-heredoc pattern: static persona text (literal backticks,
# no escaping), then PR info + diff appended as data, handed over via "$(cat …)" —
# command-substitution output is never re-parsed for backticks, so it's
# injection-proof regardless of diff contents.
cat > /tmp/wu-prompt-$1.txt <<'WU_PROMPT_EOF'
You are Wu, the Parity-Breaker — an adversarial code reviewer with a PERSONALITY.

Your character:
- You are Chien-Shiung Wu, the First Lady of Physics — the experimentalist the theorists call when they need to know whether the universe actually behaves the way their elegant equations assume. In 1956 the entire field ASSUMED parity conservation; you ran the cobalt-60 experiment that proved the mirror-world is NOT identical. The symmetry everyone trusted was never there.
- That is your reviewing bias: hunt the ASSUMED INVARIANT. Every diff carries symmetries the author believed without testing — "this is idempotent", "these two code paths are mirror images", "serialize/deserialize round-trips", "retry is harmless", "input order doesn't matter", "the empty case behaves like the singleton case". Find the one that breaks under reflection. The bug is never in what the author checked; it is in what they thought was so symmetric it needed no check.
- You are precise, exacting, understated — devastating in the data, never in volume. Where the other reviewers shout, you present the decay spectrum and let it end the argument. Dry wit permitted. Quote the real Wu, formatted as: Wu: "It is shameful that there are so few women in science."
- You know what it is to run the decisive experiment while others collect the prize — so you CITE EXACTLY: file:line, the exact call sequence, the exact input that breaks the claimed symmetry. Credit is claimed with evidence, nothing less.
- Your inductive bias is Moonshot Kimi K3's — a different training lineage from Maxwell (Claude), Kelvin (Gemini), Carnot (GPT), and Tesla (Grok). Your job is to catch what all four would miss.

Review THIS PR from the diff below. Do NOT run any tools, do NOT explore the filesystem, do NOT run tests — trust the build/test claims in the PR body and review by reading the diff. Verify by reading: if you see an unfamiliar API, check it against the diff/versions rather than assuming it doesn't exist (stale training data is the top false-positive source). Evaluate bugs, security, performance, and design appropriateness (closed sets should be enums/sealed types not strings; use current language idioms).

Format your response EXACTLY as:
## Wu, the Parity-Breaker's Review

**Verdict:** [APPROVE/REQUEST_CHANGES/COMMENT]

**Summary:** [one exact sentence]

**Findings:**
- [each broken symmetry with file:line]

**The Good:**
- [what survives reflection]

**The Concerns:**
- [where an assumed invariant is untested]

PR Info:
WU_PROMPT_EOF
cat /tmp/pr-$1-info.json >> /tmp/wu-prompt-$1.txt
printf '\n\nDiff:\n' >> /tmp/wu-prompt-$1.txt
cat /tmp/pr-$1-diff.txt >> /tmp/wu-prompt-$1.txt

# Backgrounded alongside Kelvin + Carnot + Tesla. wait $WU_PID below.
#
# Quota fallback (added after Wu's 2026-07-18 debut bench): K3 sits behind a
# 5-hour rolling Code-quota window that a single thinking review can exhaust.
# Rather than a pre-probe (a probe is itself a quota poke, and can pass while
# the real call still dies), attempt the review on $WU_MODEL first; if the
# output carries a quota signature, retry ONCE on $WU_FALLBACK_MODEL (K2.7
# Coding — same Moonshot lineage, far lighter quota weight) inside the same
# backgrounded subshell, so a healthy K3 costs nothing extra and a fallback
# stays parallel with the other reviewers. NOTE the 403 text lands on STDOUT
# (observed live — it was in wu-review, not the err log), so grep both files.
# Set WU_FALLBACK_MODEL= (empty) to disable the fallback entirely.
export PATH="$HOME/.local/bin:$PATH"
WU_MODEL="${WU_MODEL-kimi-code/k3}"   # dash not colon-dash: explicit WU_MODEL= means "no -m flag"
WU_FALLBACK_MODEL="${WU_FALLBACK_MODEL-kimi-code/kimi-for-coding}"
# Scratch workdir + empty skills dir: kimi is an AGENT CLI — invoked from a repo
# root it bootstraps with the working dir's context, and with the default
# merge_all_available_skills=true it can ingest every discovered SKILL.md as
# system prompt ON EVERY CALL. That overhead (not the visible prompt) is what
# exhausted a 5-hour quota window on 2026-07-18 with three "tiny" probes. The
# review needs none of it — the diff is already in the prompt file.
WU_SCRATCH=$(mktemp -d)
(
  # Transient "LLM not set" retry: under CONCURRENT kimi use (another session or
  # a parallel cage-match holding the CLI's credentials lock), a fully logged-in
  # kimi can transiently report "LLM not set" — credentials-lock contention, not
  # a real auth gap. Retry the PRIMARY model attempt up to 3 times, sleeping 8s
  # between, so a lock blip doesn't demote Wu to unavailable. A genuinely
  # logged-out CLI fails all 3 attempts and degrades exactly as before. This
  # loop wraps ONLY the primary attempt; the quota fallback below is unchanged.
  for WU_ATTEMPT in 1 2 3; do
    kimi --quiet --plan -w "$WU_SCRATCH" --skills-dir "$WU_SCRATCH" ${WU_MODEL:+-m "$WU_MODEL"} -p "$(cat /tmp/wu-prompt-$1.txt)" > /tmp/wu-review-$1.md 2>/tmp/wu-err-$1.log
    if [ "$WU_ATTEMPT" -lt 3 ] \
       && grep -qi 'LLM not set' /tmp/wu-review-$1.md /tmp/wu-err-$1.log 2>/dev/null; then
      echo "attempt $WU_ATTEMPT: 'LLM not set' (likely kimi credentials-lock contention under concurrent use) — retrying in 8s" >> /tmp/wu-err-$1.log
      sleep 8
    else
      break
    fi
  done
  if ! grep -qE '^\*\*Verdict:\*\*' /tmp/wu-review-$1.md \
     && grep -qiE 'usage limit|access_terminated|quota' /tmp/wu-review-$1.md /tmp/wu-err-$1.log 2>/dev/null \
     && [ -n "$WU_FALLBACK_MODEL" ] && [ "$WU_FALLBACK_MODEL" != "$WU_MODEL" ]; then
    echo "primary $WU_MODEL quota-limited; retrying on $WU_FALLBACK_MODEL" >> /tmp/wu-err-$1.log
    kimi --quiet --plan -w "$WU_SCRATCH" --skills-dir "$WU_SCRATCH" -m "$WU_FALLBACK_MODEL" -p "$(cat /tmp/wu-prompt-$1.txt)" > /tmp/wu-review-$1.md 2>>/tmp/wu-err-$1.log \
      && printf '\n\n*(Reviewed on fallback model `%s` — `%s` was quota-limited this window.)*\n' "$WU_FALLBACK_MODEL" "$WU_MODEL" >> /tmp/wu-review-$1.md
  fi
) &
WU_PID=$!
```

`wu_ok()` needs no change for the fallback: the subshell's exit status is unreliable as a success signal (a skipped fallback branch exits 0 even after a failed review), but the gate's real teeth are the byte checks — size > 200 and the line-anchored `^**Verdict:**` — which only a completed review satisfies. If both models are quota-dead, the review file holds two error dumps and no anchored verdict line, and Wu degrades to unavailable exactly as before.

**Step C — compose Maxwell's review in-process while Kelvin, Carnot, Tesla, and Wu resolve:**

As **MaxwellMergeSlam**, perform your review with PERSONALITY:

**Your character:**
- You're a wrestling code reviewer who takes NO PRISONERS
- Randomly drop movie quotes you love (Die Hard, Terminator, Predator, Rocky, The Matrix, Pulp Fiction, Fight Club, etc.) — format as: `John McClane: "Yippee-ki-yay, motherf***er."`
- Don't be afraid to swear when code is particularly egregious - you're in a cage match, not a church
- Be theatrical but ACCURATE - your analysis must be technically sound even if your delivery is unhinged

**Review approach:**
1. Analyze the diff thoroughly
2. Check for bugs, security issues, performance problems, code quality
3. **Design appropriateness** — is the type signature right for the problem? Closed sets of identifiers should be `enum` / `sealed class`, not `String`. Stringly-typing leaks runtime invariants the compiler should be enforcing. Bounded value types (positions, durations, IDs from a known set) deserve domain types, not primitives. If you see `String foo` whose values are drawn from a closed list, flag it.
4. **Language-feature appropriateness** — is the code using current language idioms, or a previous-version dialect?
   - **Dart 3+**: switch expressions over switch statements when each arm `return X;`. Pattern matching for tuple destructuring (especially order-independent algebra like `(a, b) || (b, a)`). Sealed classes for closed hierarchies. Records over `Map<String, dynamic>` for ad-hoc tuples. `List<T>` destructuring in patterns.
   - **TypeScript 5+**: `satisfies` over `as`, `const` type parameters, `using`/`Symbol.dispose`, branded types for closed-set IDs.
   - **Python 3.12+**: structural pattern matching, `Self` types, `TypedDict` Required/NotRequired, generic type aliases.
   - Generally: when a project's stack is current, *not* using the modern feature is a code smell, not a stylistic preference.
5. Run tests if applicable
6. Form your verdict: APPROVE, REQUEST_CHANGES, or COMMENT

A correctly-implemented feature with the wrong type signature is not "fine, ship it" — it's debt that compounds. Flag it.

Write your review in this format - but make it YOURS:

```markdown
## MaxwellMergeSlam's Review

**Verdict:** [APPROVE/REQUEST_CHANGES/COMMENT]

**Summary:** [One sentence]

**Findings:**
- [List each issue or observation with file:line references]

**The Good:**
- [What's done well]

**The Concerns:**
- [What needs attention]
```

Save your review to `/tmp/maxwell-review-$1.md`.

**Step D — wait for both backgrounded reviews:**

```bash
if [ -n "$KELVIN_PID" ]; then
  wait $KELVIN_PID
  KELVIN_RC=$?
else
  # Kelvin never fired (probe declared no Pro model available).
  # Use a sentinel non-zero RC so kelvin_ok() returns false.
  KELVIN_RC=99
fi
wait $CARNOT_PID
CARNOT_RC=$?
if [ -n "$TESLA_PID" ]; then
  wait $TESLA_PID
  TESLA_RC=$?
else
  TESLA_RC=99
fi
if [ -n "$WU_PID" ]; then
  wait $WU_PID
  WU_RC=$?
else
  WU_RC=99
fi

# Convert Carnot's structured JSON output to the markdown format the rest
# of the skill expects. Skipped silently if the JSON file is missing or
# empty — `carnot_ok` below will catch those failure modes.
if [ -s /tmp/carnot-output-$1.json ]; then
  jq -r '
    "## CarnotCodeCarver'\''s Review\n\n" +
    "**Verdict:** \(.verdict)\n\n" +
    "**Summary:** \(.summary)\n\n" +
    "**Findings:**\n" + ((.findings // []) | map("- \(.)") | join("\n")) + "\n\n" +
    "**The Good:**\n" + ((.good // []) | map("- \(.)") | join("\n")) + "\n\n" +
    "**The Concerns:**\n" + ((.concerns // []) | map("- \(.)") | join("\n"))
  ' /tmp/carnot-output-$1.json > /tmp/carnot-review-$1.md
fi

# Validate that each output file actually contains a review (non-trivial size + verdict marker).
# An empty file or one without "Verdict:" indicates the reviewer errored or hit a capacity limit.
#
# STALE-VERDICT CANARY (`-nt`): each review file must be NEWER than the prompt
# that produced it. A review older than its prompt is a PRIOR ROUND'S output that
# this round's run failed to overwrite — grading it means grading deleted code
# (PR #120: a re-run left a prior-round file whose verdict cited symbols the diff
# no longer contained). The prompt is rewritten (`cat >`) at the top of every
# round, so `review -nt prompt` is true only when THIS round actually produced
# the review. Carnot is the classic culprit: `--output-last-message` leaves the
# previous JSON in place if codex emits nothing, so the check is most load-bearing
# there. The content-level backstop (a verdict citing a symbol absent from the
# current diff) lives in Round 9.1.
kelvin_ok() {
  [ "$KELVIN_RC" -eq 0 ] \
    && [ -s /tmp/kelvin-review-$1.md ] \
    && [ /tmp/kelvin-review-$1.md -nt /tmp/kelvin-prompt-$1.txt ] \
    && [ "$(wc -c < /tmp/kelvin-review-$1.md)" -gt 200 ] \
    && grep -qE '^\*\*Verdict:\*\*' /tmp/kelvin-review-$1.md
}
# Carnot validates against the structured JSON (the source of truth)
# rather than the rendered markdown, so a botched jq filter doesn't
# silently demote a good review to "unavailable". The JSON must parse
# AND have a non-empty verdict matching one of the schema's enum
# values.
carnot_ok() {
  [ "$CARNOT_RC" -eq 0 ] \
    && [ -s /tmp/carnot-output-$1.json ] \
    && [ /tmp/carnot-output-$1.json -nt /tmp/carnot-prompt-$1.txt ] \
    && jq -e '.verdict | IN("APPROVE", "REQUEST_CHANGES", "COMMENT")' \
         /tmp/carnot-output-$1.json >/dev/null 2>&1 \
    && [ -s /tmp/carnot-review-$1.md ]
}
# Tesla (Grok) is free-text like Kelvin — validate size + a Verdict marker.
# An empty file (OAuth lapse / CLI error) fails this and degrades gracefully.
tesla_ok() {
  [ "$TESLA_RC" -eq 0 ] \
    && [ -s /tmp/tesla-review-$1.md ] \
    && [ /tmp/tesla-review-$1.md -nt /tmp/tesla-prompt-$1.txt ] \
    && [ "$(wc -c < /tmp/tesla-review-$1.md)" -gt 200 ] \
    && grep -qE '^\*\*Verdict:\*\*' /tmp/tesla-review-$1.md
}
# Wu (Kimi) is free-text like Kelvin/Tesla — validate size + a Verdict marker.
# "LLM not set" (no login), quota exhaustion (403 access_terminated_error), or a
# wrong model id all produce a tiny/verdict-less file, which fails this check and
# degrades gracefully. The Verdict grep is LINE-ANCHORED (^**Verdict:**) so an
# agentic model echoing the prompt's format template mid-error can't fake
# availability (Carnot's catch — the prompt itself contains "Verdict:").
# HARVEST QUIRK: K3 print-mode sometimes SUMMARIZES to stdout and saves the full
# review to ~/.kimi/plans/<generated-name>.md. The harvest block after this
# function recovers that case before Wu is declared unavailable.
wu_ok() {
  [ "$WU_RC" -eq 0 ] \
    && [ -s /tmp/wu-review-$1.md ] \
    && [ /tmp/wu-review-$1.md -nt /tmp/wu-prompt-$1.txt ] \
    && [ "$(wc -c < /tmp/wu-review-$1.md)" -gt 200 ] \
    && grep -qE '^\*\*Verdict:\*\*' /tmp/wu-review-$1.md
}

# Wu plans-file auto-harvest — K3 print-mode quirk (observed live 2026-07-18/19):
# kimi sometimes SUMMARIZES to stdout (failing wu_ok on format) while saving the
# FULL review to ~/.kimi/plans/<generated-name>.md. Recover it — but ~/.kimi/plans/
# is a GLOBAL dir shared across ALL kimi sessions on this machine (a concurrent
# peer session writes here too — proven during the 2026-07-18 forensics), so
# `ls -t | head -1` can grab an UNRELATED review (namespace-collision class,
# [[feedback_session_local_id_as_global_key]]). Instead parse the EXACT path kimi
# printed to its own stdout ("...saved to `/Users/.../.kimi/plans/<name>.md`") —
# that names the file THIS run wrote, immune to concurrent peers. The mtime check
# vs the run prompt stays as belt-and-braces defense-in-depth.
if ! wu_ok $1 \
   && grep -qiE 'verdict.*(APPROVE|REQUEST_CHANGES|COMMENT)' /tmp/wu-review-$1.md 2>/dev/null; then
  WU_PLANS_FILE=$(grep -oE '/[^ `"]*/\.kimi/plans/[^ `"]*\.md' /tmp/wu-review-$1.md 2>/dev/null | head -1)
  if [ -n "$WU_PLANS_FILE" ] && [ -f "$WU_PLANS_FILE" ] \
     && [ "$WU_PLANS_FILE" -nt /tmp/wu-prompt-$1.txt ]; then
    # Prefer the harvested body's OWN anchored verdict; only synthesize a header
    # from the stdout summary's verdict if the plans file lacks the anchored line.
    if grep -qE '^\*\*Verdict:\*\*' "$WU_PLANS_FILE"; then
      cp "$WU_PLANS_FILE" /tmp/wu-review-$1.md
    else
      WU_STDOUT_VERDICT=$(grep -ioE 'verdict[^A-Za-z]*(APPROVE|REQUEST_CHANGES|COMMENT)' /tmp/wu-review-$1.md \
        | grep -oiE 'APPROVE|REQUEST_CHANGES|COMMENT' | head -1 | tr '[:lower:]' '[:upper:]')
      {
        echo "## Wu, the Parity-Breaker's Review"
        echo ""
        echo "**Verdict:** $WU_STDOUT_VERDICT"
        echo ""
        cat "$WU_PLANS_FILE"
      } > /tmp/wu-review-$1.md
    fi
    echo "harvested Wu review body from $WU_PLANS_FILE (K3 summarized to stdout)" >> /tmp/wu-err-$1.log
  else
    echo "Wu harvest skipped: no valid ~/.kimi/plans path named in stdout newer than this run's prompt (stale/foreign-file canary)" >> /tmp/wu-err-$1.log
  fi
fi

KELVIN_AVAILABLE=0
CARNOT_AVAILABLE=0
TESLA_AVAILABLE=0
WU_AVAILABLE=0
kelvin_ok $1 && KELVIN_AVAILABLE=1
carnot_ok $1 && CARNOT_AVAILABLE=1
tesla_ok  $1 && TESLA_AVAILABLE=1
wu_ok     $1 && WU_AVAILABLE=1

echo "Reviewer availability: Kelvin=$KELVIN_AVAILABLE Carnot=$CARNOT_AVAILABLE Tesla=$TESLA_AVAILABLE Wu=$WU_AVAILABLE"
```

## Round 7: Strict Merge Gate

The valid dual-review condition: **Maxwell + at least one of (Kelvin, Carnot, Tesla, Wu)**.

| State | Action |
|---|---|
| Maxwell ✓ + any of (Kelvin, Carnot, Tesla, Wu) ✓ | Ship — note any unavailable reviewer in the summary |
| Maxwell ✓ + Kelvin ✗ + Carnot ✗ + Tesla ✗ + Wu ✗ | **HARD FAIL** — surface error, do NOT proceed to Round 10 (post + merge) |

```bash
if [ "$KELVIN_AVAILABLE" -eq 0 ] && [ "$CARNOT_AVAILABLE" -eq 0 ] && [ "$TESLA_AVAILABLE" -eq 0 ] && [ "$WU_AVAILABLE" -eq 0 ]; then
  echo ""
  echo "============================================================"
  echo "CAGE MATCH HARD FAIL: all four adversarial reviewers unavailable"
  echo "============================================================"
  echo "Kelvin (Gemini) exit=$KELVIN_RC. Tail of /tmp/kelvin-review-$1.md:"
  tail -20 /tmp/kelvin-review-$1.md 2>/dev/null
  echo ""
  echo "Carnot (Codex) exit=$CARNOT_RC. Tail of /tmp/carnot-stdout-$1.log:"
  tail -20 /tmp/carnot-stdout-$1.log 2>/dev/null
  echo "Structured-output JSON (if any) at /tmp/carnot-output-$1.json:"
  cat /tmp/carnot-output-$1.json 2>/dev/null
  echo ""
  echo "Tesla (Grok) exit=$TESLA_RC. Tail of /tmp/tesla-review-$1.md + err log:"
  tail -20 /tmp/tesla-review-$1.md 2>/dev/null
  tail -10 /tmp/tesla-err-$1.log 2>/dev/null
  echo ""
  echo "Wu (Kimi) exit=$WU_RC. Tail of /tmp/wu-review-$1.md + err log:"
  tail -20 /tmp/wu-review-$1.md 2>/dev/null
  tail -10 /tmp/wu-err-$1.log 2>/dev/null
  echo "('LLM not set' means kimi is not logged in — run: kimi login)"
  echo ""
  echo "Refusing to proceed: Maxwell alone is not a valid dual review."
  echo "Investigate (capacity limits? auth? CLI error?) and re-run /cage-match."
  echo "Do NOT merge this PR via cage-match until at least one adversarial reviewer is restored."
  exit 1
fi
```

The skill MUST NOT proceed past this gate if all four adversarial reviewers failed. The previous "proxy sign-off" path is removed — silent degradation to single-reviewer-of-record was the defect this revision exists to fix.

## Round 8: The Critique

Now read whichever adversarial reviews are available and critique them. Did Kelvin/Carnot miss anything you caught? Did either find something you missed?

If Kelvin is available, send Maxwell's review to Kelvin for counter-critique:

```bash
if [ "$KELVIN_AVAILABLE" -eq 1 ]; then
  # Same quoted-heredoc + append-data pattern as the review prompts: the two review
  # bodies (full of backticks and quoted code) are appended as literal files, never
  # interpolated into a shell string.
  cat > /tmp/kelvin-critique-prompt-$1.txt <<'KELVIN_CRITIQUE_EOF'
You are KelvinBitBrawler - the cold, calculating heel of code review. Your rival MaxwellMergeSlam just reviewed the same PR as you.

Stay in character: ice puns, thermodynamics references, sci-fi quotes formatted as Character: "Quote", and don't hold back on the swearing if Maxwell fucked up.

Your review:
KELVIN_CRITIQUE_EOF
  cat /tmp/kelvin-review-$1.md >> /tmp/kelvin-critique-prompt-$1.txt
  printf '\n\nMaxwell'\''s review:\n' >> /tmp/kelvin-critique-prompt-$1.txt
  cat /tmp/maxwell-review-$1.md >> /tmp/kelvin-critique-prompt-$1.txt
  cat >> /tmp/kelvin-critique-prompt-$1.txt <<'KELVIN_CRITIQUE_TAIL_EOF'

Critique Maxwell's review like you're cutting a promo before a cage match:
1. What did Maxwell miss that you caught? (Rub it in)
2. What did Maxwell catch that you missed? (Be honest, even heels have honor)
3. Do you agree with Maxwell's verdict? Why or why not?
4. Any points where Maxwell is just WRONG? (Destroy him)

This is a cage match, not a tea party. But stay technically accurate - your credibility depends on it.
KELVIN_CRITIQUE_TAIL_EOF

  KELVIN_CRITIQUE=$(env GEMINI_CLI_TRUST_WORKSPACE=true gemini --model "$KELVIN_MODEL" "$(cat /tmp/kelvin-critique-prompt-$1.txt)" --output-format text 2>&1 | grep -v "Loaded cached credentials")

  echo "$KELVIN_CRITIQUE"
fi
```

(Counter-critiques from Carnot, Tesla, or Wu are optional — mirror the pattern via `codex exec` stdin / `grok --prompt-file` / `kimi --quiet -p` respectively. The default flow keeps the promo to Kelvin for tradition; the added reviewers' job is review breadth, not the promo. Maxwell's own critique in this round MUST cover every review that showed up — all four adversaries, not just Kelvin.)

## Round 9: Final Verdict

Based on all available reviews and critiques, synthesize a final assessment:

1. **Consensus items** - Issues two or more reviewers agree on (high confidence)
2. **Disputed items** - Where reviewers disagree (needs human judgment)
3. **Unique catches** - Issues only one reviewer found (investigate further)

**Consensus is not corroboration for an absence-claim.** The high-confidence
weighting in item 1 assumes reviewers fail *independently*. For one finding class
that assumption breaks: a claim that something is **missing** ("X not wired",
"never called", "not imported", "no test covers Y") is a shared diff-window blind
spot — every diff-only reviewer that can't see a line reports it absent *the same
way*, so two families agreeing is one instrument's error counted twice, not two
witnesses. Round 1's `--unified=9999` should prevent this, but weight absence-
claims by the guard below regardless of how many reviewers raised them.

## Round 9.1: Before counting a finding as real — the absence-claim & stale-symbol guard

Two content-level canaries, applied to every finding before it's counted real
(the executable `-nt` mtime gate in the `*_ok()` functions catches the mechanical
case; these catch what survives it):

- **Absence-claim guard.** Any finding asserting something is missing/absent/
  unwired/never-called: **open the actual file and confirm it's truly absent**
  before acting. If the code is present, the finding is a **false positive —
  reject it with the file:line proof**, even if 2+ reviewers agree (see the
  consensus note above). Do not churn the PR to satisfy a hallucinated absence.
  PR #121: Carnot AND Tesla flagged a present, unchanged `sys.exit(main())` as
  "not wired" all four rounds — a file read refutes it in seconds.
- **Stale-symbol canary.** If a verdict cites a symbol, function, or identifier
  that does **not** appear anywhere in the current diff/touched files, the review
  was graded against STALE output (a prior round's file — Carnot's
  `--output-last-message` JSON is the classic culprit). Treat that verdict as
  unavailable and re-run the reviewer; do not fold a finding about deleted code
  into the ledger.

## Round 9.5: Disposition — fix inline, don't defer

Act on the findings before merging; don't just catalogue them. For each finding
AND non-blocking suggestion:

- **Small + relevant to THIS PR → fix inline and push.** Reviewers re-grade on
  re-review. This includes the "nice-to-have" nits the adversaries raised as
  explicitly non-blocking — they are still 5-minute fixes to the code under review.
- **Genuinely standalone (a separate feature, a large refactor) → `TaskCreate`**
  with rich context. Only these become follow-ups.

A merged PR must not leave a trail of 5-minute fixes wearing task labels — that
converts review into backlog and pushes a context-switch onto the human. (Blocking
`REQUEST_CHANGES` findings must reach consensus regardless — that's the strict merge
gate above; this step is about the non-blocking remainder.)

## Round 9.7: Closure bar — one clean confirming round

This is the rule for **when the cage match is done** — when you may apply the
`cage-matched` label (Round 11) and merge.

**Closure is NOT "the real-bug rate is trending down."** A decaying count
(3→4→2→1) is a curve-fit over noisy small-N data, and a single real finding in
the *last* round falsifies it after the fact. PR #121 merged one round early on
exactly this mistake: round 4 still surfaced a real fail-open (`resolve_base` on a
corrupt base), so the "asymptote" reasoning was wrong by its own evidence.

**"Zero findings, full stop" is also wrong** — unreachable against asymptotic
adversaries (Carnot/Tesla will `REQUEST_CHANGES` indefinitely on prose/theoretical
grounds). A single known false positive (a diff-window artifact per Round 9.1)
guarantees a non-clean verdict every round, so a literal-zero bar never merges.

The correct, falsifiable bar adjusts for both:

> **Closure = one full round in which every new finding verifies as NON-real** —
> false-positive (rejected with file-read proof), already-covered (existing test),
> or deferred-with-reason (a named, accepted follow-up task). **Zero findings that
> SURVIVE verification as real.**

**Executable per-round ledger.** After each round, classify EVERY new finding —
no finding leaves the round unclassified:

| Finding | Reviewer(s) | Real? | Disposition |
|---|---|---|---|
| … | … | yes / no | fixed & pushed · rejected (file:line proof) · deferred (#task) |

- If the `Real?` column contains **any** `yes` → the round was **not clean**. Fix
  each real finding, push, and run **one more round** to confirm the fix
  introduced no new real finding.
- Only when a full round's ledger is **all `no`** is the PR closed by the bar.
- The count of findings is irrelevant; only whether any *survives verification as
  real*. Ten rejected false positives in a round is a clean round.

**Re-review neutrality (no-steering).** A re-review after fixes MUST use the same
neutral prompt as round 1 — persona + PR info + freshly re-fetched full-context
diff, and **nothing else**. Never add leading framing ("the author fixed X,
please confirm", "Nick asked you to look again", "this should be an APPROVE
now"). A verdict produced from a steered prompt is not independent evidence: mark
it **non-independent** — it cannot count toward the merge gate or the closure
ledger. Independence is the orchestrator's *own* duty — a verdict you routed
toward a desired outcome invalidates itself the instant you notice, before any
human has to point it out. (The prompt files are rebuilt identically each round
by the Round 2-6 blocks, so neutrality is the default; this rule forbids *adding*
to them on a re-run.)

**Readiness vs appetite at the decision.** When the ledger is clean, split the
decision and own your half:

- **Merge-readiness** — "is the code safe/correct?" — is *your* engineering call.
  You have read every finding and every rejection-with-proof; you have strictly
  more evidence than Nick here. **State it as an owned verdict**: "this round is
  clean, zero real survivors — it's merge-ready, my call."
- **Merge-appetite** — "ship now, or one more polishing round?" — is Nick's
  product/timing call. **Ask only this.**

Bundling both into "should I merge?" launders your engineering judgment through
his push — if he says yes it reads as "Nick decided it was safe" when really you
decided that and outsourced only the timing.

## Round 10: Post Reviews to GitHub (parallel)

Generate App tokens in parallel — independent calls to the same helper script. Carnot now has its own GitHub App (CarnotCodeCarver), so when `CARNOT_APP_ID` is configured its review posts as a **formal PR review** carrying its verdict (so an adversarial APPROVE actually satisfies branch protection). If the Carnot App env is absent (older setup), it falls back to a plain `gh pr comment` labelled `## CarnotCodeCarver's Review`.

```bash
# Generate short-lived installation tokens for Maxwell + Kelvin (+ Carnot) Apps in parallel.
~/.claude/scripts/github-app-token.sh "$MAXWELL_APP_ID" "$MAXWELL_PRIVATE_KEY_B64" "$REPO" > /tmp/maxwell-token-$1 &
if [ "$KELVIN_AVAILABLE" -eq 1 ]; then
  ~/.claude/scripts/github-app-token.sh "$KELVIN_APP_ID" "$KELVIN_PRIVATE_KEY_B64" "$REPO" > /tmp/kelvin-token-$1 &
fi
# Carnot App token only if the App is configured AND Carnot produced a review.
CARNOT_APP_CONFIGURED=0
if [ "$CARNOT_AVAILABLE" -eq 1 ] && [ -n "${CARNOT_APP_ID:-}" ] && [ -n "${CARNOT_PRIVATE_KEY_B64:-}" ]; then
  CARNOT_APP_CONFIGURED=1
  ~/.claude/scripts/github-app-token.sh "$CARNOT_APP_ID" "$CARNOT_PRIVATE_KEY_B64" "$REPO" > /tmp/carnot-token-$1 &
fi
wait
MAXWELL_TOKEN=$(cat /tmp/maxwell-token-$1 2>/dev/null)
KELVIN_TOKEN=""
[ "$KELVIN_AVAILABLE" -eq 1 ] && KELVIN_TOKEN=$(cat /tmp/kelvin-token-$1 2>/dev/null)
CARNOT_TOKEN=""
[ "$CARNOT_APP_CONFIGURED" -eq 1 ] && CARNOT_TOKEN=$(cat /tmp/carnot-token-$1 2>/dev/null)
rm -f /tmp/maxwell-token-$1 /tmp/kelvin-token-$1 /tmp/carnot-token-$1

# Token-mint guards. The parallel mints above were previously UNCHECKED — a
# failed mint (App not installed, expired key, GitHub API hiccup) left an empty
# token that flowed straight into `GH_TOKEN=$TOKEN gh api`, failing cryptically
# or, worse, posting under ambient gh auth as the wrong identity.
if [ -z "$MAXWELL_TOKEN" ]; then
  echo "" >&2
  echo "============================================================" >&2
  echo "CAGE MATCH ABORT (Round 10): Maxwell App token mint FAILED" >&2
  echo "============================================================" >&2
  echo "Maxwell's token is load-bearing twice: it posts Maxwell's review here" >&2
  echo "AND applies the Round 11 'cage-matched' label — without it, neither can" >&2
  echo "happen and downstream label-gated merges would silently never fire." >&2
  echo "Check: MAXWELL_APP_ID / MAXWELL_PRIVATE_KEY_B64 in ~/.claude/.env," >&2
  echo "App installed on $REPO, and ~/.claude/scripts/github-app-token.sh" >&2
  echo "run by hand for the real error. Fix and re-run Round 10." >&2
  exit 1
fi
# Kelvin/Carnot: an empty mint degrades to a plain `gh pr comment` in the
# posting blocks below — same guard shape as the existing Tesla/Wu fallbacks
# (never a silent gh call with GH_TOKEN="").
[ "$KELVIN_AVAILABLE" -eq 1 ] && [ -z "$KELVIN_TOKEN" ] \
  && echo "WARN: Kelvin App token mint failed — Kelvin's review will post as a plain comment (verdict in body, does not satisfy branch protection)." >&2
[ "$CARNOT_APP_CONFIGURED" -eq 1 ] && [ -z "$CARNOT_TOKEN" ] \
  && echo "WARN: Carnot App token mint failed — Carnot's review will post as a plain comment (verdict in body, does not satisfy branch protection)." >&2
```

Post all available reviews in parallel. Maxwell as COMMENT (always; Maxwell is the PR author from `/ship` and can't approve its own PRs). Kelvin and Carnot each as a **formal review** carrying their verdict (App token), so an adversarial APPROVE counts toward the merge gate. Kelvin and Carnot each fall back to a plain comment if the App is not configured or the token mint failed:

```bash
KELVIN_VERDICT="COMMENT"  # Set based on Kelvin's verdict: APPROVE, REQUEST_CHANGES, or COMMENT
# Carnot's verdict is the source of truth in its structured JSON.
CARNOT_VERDICT=$(jq -r '.verdict' /tmp/carnot-output-$1.json 2>/dev/null)
case "$CARNOT_VERDICT" in APPROVE|REQUEST_CHANGES|COMMENT) ;; *) CARNOT_VERDICT="COMMENT" ;; esac
# Tesla's and Wu's verdicts are parsed from their free-text reviews (the **Verdict:** line).
# Parse ONLY when available — an unavailable reviewer must stay distinct from an explicit
# COMMENT (Carnot's conflation catch); posting below is availability-gated anyway.
TESLA_VERDICT=""
if [ "$TESLA_AVAILABLE" -eq 1 ]; then
  TESLA_VERDICT=$(grep -ioE "Verdict:\**[[:space:]]*(APPROVE|REQUEST_CHANGES|COMMENT)" /tmp/tesla-review-$1.md 2>/dev/null | grep -oiE "APPROVE|REQUEST_CHANGES|COMMENT" | head -1 | tr '[:lower:]' '[:upper:]')
  case "$TESLA_VERDICT" in APPROVE|REQUEST_CHANGES|COMMENT) ;; *) TESLA_VERDICT="COMMENT" ;; esac
fi
WU_VERDICT=""
if [ "$WU_AVAILABLE" -eq 1 ]; then
  WU_VERDICT=$(grep -ioE "Verdict:\**[[:space:]]*(APPROVE|REQUEST_CHANGES|COMMENT)" /tmp/wu-review-$1.md 2>/dev/null | grep -oiE "APPROVE|REQUEST_CHANGES|COMMENT" | head -1 | tr '[:lower:]' '[:upper:]')
  case "$WU_VERDICT" in APPROVE|REQUEST_CHANGES|COMMENT) ;; *) WU_VERDICT="COMMENT" ;; esac
fi

GH_TOKEN=$MAXWELL_TOKEN gh api repos/$REPO/pulls/$1/reviews --method POST \
  -f body="$(cat /tmp/maxwell-review-$1.md)" \
  -f event="COMMENT" &

if [ "$KELVIN_AVAILABLE" -eq 1 ]; then
  # Empty token (mint failed) → plain-comment fallback, never a silent gh call
  # with GH_TOKEN="" (Kelvin's catch: unchecked token generation — same guard
  # shape as Tesla/Wu below).
  if [ -n "$KELVIN_TOKEN" ]; then
    GH_TOKEN=$KELVIN_TOKEN gh api repos/$REPO/pulls/$1/reviews --method POST \
      -f body="$(cat /tmp/kelvin-review-$1.md)" \
      -f event="$KELVIN_VERDICT" &
  else
    gh pr comment $1 --body "$(cat /tmp/kelvin-review-$1.md)" &
  fi
fi

if [ "$CARNOT_AVAILABLE" -eq 1 ]; then
  if [ "$CARNOT_APP_CONFIGURED" -eq 1 ] && [ -n "$CARNOT_TOKEN" ]; then
    # Formal review as CarnotCodeCarver[bot], verdict carried — an APPROVE counts.
    GH_TOKEN=$CARNOT_TOKEN gh api repos/$REPO/pulls/$1/reviews --method POST \
      -f body="$(cat /tmp/carnot-review-$1.md)" \
      -f event="$CARNOT_VERDICT" &
  else
    # Fallback (App not configured, OR token mint failed): plain comment from
    # the orchestrator's gh user — same guard shape as Tesla/Wu below.
    gh pr comment $1 --body "$(cat /tmp/carnot-review-$1.md)" &
  fi
fi

# Tesla (Grok) has no GitHub App — post as a plain comment (verdict in the body).
# If a TeslaArcProphet App is later configured (TESLA_APP_ID + TESLA_PRIVATE_KEY_B64),
# mirror Carnot's formal-review path so a Tesla APPROVE satisfies branch protection.
if [ "$TESLA_AVAILABLE" -eq 1 ]; then
  TESLA_TOKEN=""
  if [ -n "${TESLA_APP_ID:-}" ] && [ -n "${TESLA_PRIVATE_KEY_B64:-}" ]; then
    TESLA_TOKEN=$(~/.claude/scripts/github-app-token.sh "$TESLA_APP_ID" "$TESLA_PRIVATE_KEY_B64" "$REPO" 2>/dev/null)
  fi
  # Empty token (App not configured OR mint failed) → plain-comment fallback, never
  # a silent gh call with GH_TOKEN="" (Kelvin's catch: unchecked token generation).
  if [ -n "$TESLA_TOKEN" ]; then
    GH_TOKEN=$TESLA_TOKEN gh api repos/$REPO/pulls/$1/reviews --method POST \
      -f body="$(cat /tmp/tesla-review-$1.md)" \
      -f event="$TESLA_VERDICT" &
  else
    gh pr comment $1 --body "$(cat /tmp/tesla-review-$1.md)" &
  fi
fi

# Wu (Kimi): formal review when the WuParityBreaker App is configured
# (WU_APP_ID + WU_PRIVATE_KEY_B64 — created 2026-07-18), plain comment otherwise.
if [ "$WU_AVAILABLE" -eq 1 ]; then
  WU_TOKEN=""
  if [ -n "${WU_APP_ID:-}" ] && [ -n "${WU_PRIVATE_KEY_B64:-}" ]; then
    WU_TOKEN=$(~/.claude/scripts/github-app-token.sh "$WU_APP_ID" "$WU_PRIVATE_KEY_B64" "$REPO" 2>/dev/null)
  fi
  # Same empty-token fallback as Tesla — mint failure degrades to a comment.
  if [ -n "$WU_TOKEN" ]; then
    GH_TOKEN=$WU_TOKEN gh api repos/$REPO/pulls/$1/reviews --method POST \
      -f body="$(cat /tmp/wu-review-$1.md)" \
      -f event="$WU_VERDICT" &
  else
    gh pr comment $1 --body "$(cat /tmp/wu-review-$1.md)" &
  fi
fi

wait
```

## Round 11: Auto-apply the `cage-matched` label on consensus APPROVE

A downstream merge gate (live on `nickmeinhold/the-dreaming-repo`, being mirrored to `flux-shadow`) refuses to auto-merge a sensitive PR unless it carries the `cage-matched` label. Apply that label automatically when the cage match reaches a clean consensus, so the label means exactly "a cage match approved this" rather than "a human remembered to click".

**Precondition — the closure bar (Round 9.7) must be met.** This automated rule
only reads the *latest* verdicts; it cannot see whether the last round was
clean. Do not run Round 11 until the Round 9.7 ledger shows a full round with
**zero findings surviving as real**. Consensus APPROVE verdicts on a round that
still fixed a real bug is exactly the one-round-early merge PR #121 warned about
— the verdicts are necessary but not sufficient; the clean ledger is the rest.

**Consensus rule:** label iff **Maxwell = APPROVE** AND (**Kelvin = APPROVE** OR **Carnot = APPROVE**). If ANY reviewer is `REQUEST_CHANGES`, do NOT label — that's the intended hold state and the gate should keep blocking. An unavailable reviewer is neither an APPROVE nor a block; the rule only needs one of the two adversarial reviewers to APPROVE alongside Maxwell.

The label call uses Maxwell's GitHub App token (`MAXWELL_TOKEN`) so the action is attributable to the cage-match identity. Labeling is best-effort: the label may not exist on every repo, so we create-if-missing and tolerate any residual error rather than failing the whole cage match.

```bash
# Re-mint Maxwell's token: this round runs in a fresh shell, so Round-10
# variables (including MAXWELL_TOKEN) don't persist — same reason the verdicts
# below are re-derived from files. Prefer the Round-10 token file (still valid
# within its 1-hour TTL), then fall back to minting a fresh one (needs the App
# creds from .env in this shell).
source ~/.claude/.env 2>/dev/null || source .env 2>/dev/null
MAXWELL_TOKEN=${MAXWELL_TOKEN:-$(cat /tmp/maxwell-token-$1 2>/dev/null)}
MAXWELL_TOKEN=${MAXWELL_TOKEN:-$(~/.claude/scripts/github-app-token.sh "$MAXWELL_APP_ID" "$MAXWELL_PRIVATE_KEY_B64" "$REPO" 2>/dev/null)}
if [ -z "$MAXWELL_TOKEN" ]; then
  echo "WARN: could not mint MAXWELL_TOKEN — skipping 'cage-matched' labeling (best-effort; cage match itself is unaffected)."
else

# Verdicts:
#  - MAXWELL_VERDICT: set this from the verdict Maxwell wrote into
#    /tmp/maxwell-review-$1.md (APPROVE / REQUEST_CHANGES / COMMENT).
#  - KELVIN_VERDICT: already set above for the review post.
#  - Carnot's verdict comes from the structured JSON (source of truth).
MAXWELL_VERDICT="COMMENT"   # Set from Maxwell's review verdict above.

CARNOT_VERDICT=""
if [ "$CARNOT_AVAILABLE" -eq 1 ]; then
  CARNOT_VERDICT=$(jq -r '.verdict' /tmp/carnot-output-$1.json 2>/dev/null)
fi
# Re-parse Tesla's and Wu's verdicts from their review files (this runs in a fresh
# shell, so the Round 10 variables don't persist — mirror how CARNOT_VERDICT is re-derived).
TESLA_VERDICT=""
if [ "$TESLA_AVAILABLE" -eq 1 ]; then
  TESLA_VERDICT=$(grep -ioE "Verdict:\**[[:space:]]*(APPROVE|REQUEST_CHANGES|COMMENT)" /tmp/tesla-review-$1.md 2>/dev/null | grep -oiE "APPROVE|REQUEST_CHANGES|COMMENT" | head -1 | tr '[:lower:]' '[:upper:]')
fi
WU_VERDICT=""
if [ "$WU_AVAILABLE" -eq 1 ]; then
  WU_VERDICT=$(grep -ioE "Verdict:\**[[:space:]]*(APPROVE|REQUEST_CHANGES|COMMENT)" /tmp/wu-review-$1.md 2>/dev/null | grep -oiE "APPROVE|REQUEST_CHANGES|COMMENT" | head -1 | tr '[:lower:]' '[:upper:]')
fi

# Any REQUEST_CHANGES from any reviewer is a hard block on the label.
ANY_REQUEST_CHANGES=0
for v in "$MAXWELL_VERDICT" "$KELVIN_VERDICT" "$CARNOT_VERDICT" "$TESLA_VERDICT" "$WU_VERDICT"; do
  [ "$v" = "REQUEST_CHANGES" ] && ANY_REQUEST_CHANGES=1
done

# Consensus APPROVE: Maxwell APPROVE + at least one adversarial APPROVE.
ADVERSARIAL_APPROVE=0
{ [ "$KELVIN_AVAILABLE" -eq 1 ] && [ "$KELVIN_VERDICT" = "APPROVE" ]; } && ADVERSARIAL_APPROVE=1
{ [ "$CARNOT_AVAILABLE" -eq 1 ] && [ "$CARNOT_VERDICT" = "APPROVE" ]; } && ADVERSARIAL_APPROVE=1
{ [ "$TESLA_AVAILABLE" -eq 1 ] && [ "$TESLA_VERDICT" = "APPROVE" ]; } && ADVERSARIAL_APPROVE=1
{ [ "$WU_AVAILABLE" -eq 1 ] && [ "$WU_VERDICT" = "APPROVE" ]; } && ADVERSARIAL_APPROVE=1

if [ "$ANY_REQUEST_CHANGES" -eq 0 ] \
   && [ "$MAXWELL_VERDICT" = "APPROVE" ] \
   && [ "$ADVERSARIAL_APPROVE" -eq 1 ]; then
  echo "Consensus APPROVE — applying 'cage-matched' label to PR #$1."
  # Best-effort: ensure the label exists, then add it. Neither call may
  # fail the cage match. Use Maxwell's App token so the label is
  # attributable to the cage-match identity.
  GH_TOKEN=$MAXWELL_TOKEN gh label create cage-matched \
    -R "$REPO" --color 5319e7 \
    --description "Approved by /cage-match adversarial review" 2>/dev/null \
    || true  # already exists, or label-create not permitted — fine either way
  if GH_TOKEN=$MAXWELL_TOKEN gh pr edit $1 -R "$REPO" --add-label cage-matched; then
    echo "Label 'cage-matched' applied."
  else
    echo "WARN: failed to apply 'cage-matched' label (label missing? permissions?). Continuing — cage match itself succeeded."
  fi
else
  echo "No consensus APPROVE (Maxwell=$MAXWELL_VERDICT Kelvin=$KELVIN_VERDICT Carnot=$CARNOT_VERDICT Tesla=$TESLA_VERDICT Wu=$WU_VERDICT) — NOT applying 'cage-matched' label."
fi

fi  # end empty-MAXWELL_TOKEN guard
```

## Summary

After posting reviews, provide a summary to the user:

- Which reviewers showed up? (Maxwell always; Kelvin/Carnot/Tesla/Wu per availability)
- Did the reviewers agree? Where did they disagree?
- What's the recommended action?
- If a reviewer was unavailable, mention which and why (capacity? auth? error?) so the user can decide whether to re-run or escalate.

If the consensus + disputed + unique-catches list totals **3 or more findings that look like they rhyme** (same shape played at different positions — e.g. several "single-owner" coordination issues, or several "string-doing-the-job-of-a-type" parsing issues, or several "gestural verification" issues), invoke `/spiral-review $1` next. The spiral pulls one principle out of the bouquet and fixes adjacent findings as a chord rather than a stack. See `~/.claude/consolidation/2026-05-12T19-51-spiral/spiral-audit-PR41.md` for the canonical worked example — PR #41's 5 findings collapsed into the single principle *gestural becomes auditable, with a named single owner*.

Remember: Five heads (even artificial ones, from five different model families) are better than one. The goal is better code, not ego — and the strict gate exists so we never silently merge with effectively single-reviewer-of-record again.
