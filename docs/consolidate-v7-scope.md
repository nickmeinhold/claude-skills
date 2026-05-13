# consolidate v7 — PR Scope Spec

**Executive summary.** v6's three-burst DAG is structurally sound but encodes its topology — agent count, model tiers, burst ordering, artifact formats, and transcript contract — as distributed prose across ~10 locations. Any v7 change (new extractor, model swap, cost-aware routing, streaming) requires multi-site edits with no single truth to validate against. This PR centralizes those four classes of structural debt before they compound.

**Estimated doc scope:** 200–280 lines changed (inserts + deletes). The largest chunks are the new manifest table (~25 lines), schema exemplar (~30 lines), model-capability mapping (~15 lines), and the orchestrator-section restructure (~40 lines). The remainder is replacing repeated prose with citations-by-name.

---

## 1. Single authoritative agent manifest (γ HIGH 1)

### Problem

The execution graph — agent identities, model tiers, burst assignments, input/output files, and spawn-order — is encoded in at least 5 locations:

- Line 7: intro paragraph (names three-burst DAG, agent roles, model tiers)
- Line 186: Phase 1 evolution note (repeats agent count, burst structure)
- Lines 188–193: file-ownership table (agents × output files)
- Lines 222–224: spawn-order list (Burst 1/2/3 with agent counts)
- Each embedded agent brief (e.g., lines 237–239, 316–320, 357–361): repeats model, inputs, outputs, and temporal claims about other agents

Adding a v7 agent (e.g., `emotional-arc-extractor` Haiku) requires touching all five. The γ-Sonnet review (finding 1) correctly names this: "There is no canonical agent manifest — the manifest is the prose."

The file-ownership table (lines 188–193) is the closest thing to a manifest but omits burst, dependencies, and model — so it can't serve as the single source.

### Proposed fix

Insert a **Phase 1 Agent Manifest** table immediately before the "Why specialization" section (after line 198). Columns:

| agent | role | model_capability | burst | inputs | output | dependencies | owner |
|---|---|---|---|---|---|---|---|
| marker-extractor | Phase 0a affective scan | cheap_extract | 0a | `<JSONL_PATH>` | `raw/marker-candidates.md` | none | orchestrator |
| memory-writer | file-and-index | synth_reasoning | 1 | session-summary, memory-path, task-snapshot | memory-dir files + scorecard + wins + open-tasks + pending-tasks | none | orchestrator |
| tla-extractor | TLA pre-pass | cheap_extract | 1 | session-summary | `raw/tla-candidates.md` | none | orchestrator |
| domain-term-extractor | domain-term pre-pass | cheap_extract | 1 | session-summary | `raw/domain-terms.md` | none | orchestrator |
| dropped-tangent-extractor | tangent pre-pass | cheap_extract | 1 | session-summary | `raw/dropped-tangents.md` | none | orchestrator |
| knowledge-mapper | graph synth | synth_reasoning | 2 | session-summary, raw/\*.md, memory-path | `consolidation.md` | tla-extractor, domain-term-extractor, dropped-tangent-extractor | orchestrator |
| next-session-prompter | cold-reader onboarding | voice_calibration | 3 | session-summary, consolidation, open-tasks, affective-highlights, multi-perspective-retro | `next-session-prompt.md` | knowledge-mapper | orchestrator |

All prose references to "three Haiku pre-extractors", "four agent calls in one message", and "six agents total" become citations by agent name. The intro paragraph (line 7) cites the table rather than re-encoding the topology. The file-ownership prose (lines 188–193) becomes a derived view, or collapses to a pointer to the manifest.

**Migration:** (1) insert table; (2) update intro para to cite it; (3) replace spawn-order bullet list with "see manifest, burst column"; (4) update the "After all three return" section (line 397) which still says "3 lines total" — a v5 fossil, since v6 has 6 agents; (5) update each brief's temporal claims (e.g., line 343: "memory-writer ran in Burst 1 and has completed by the time you run") to read "see manifest: knowledge-mapper's dependencies list memory-writer's burst as completed."

### Migration cost

Moderate. ~40 lines changed (table insert + 5 prose patches). Non-invasive — no behavioral change, no agent-brief rewrite. High payoff: every future v7 agent add is a 1-row manifest edit.

### Breaks

None. Pure structural reorganization. The file-ownership invariant (lines 188–195) is preserved; the manifest adds columns, doesn't replace the invariant.

---

## 2. Versioned JSON schemas for `raw/*.md` (γ HIGH 2)

### Problem

The inter-agent contract for the four Haiku-to-Sonnet handoff files (`raw/tla-candidates.md`, `raw/domain-terms.md`, `raw/dropped-tangents.md`, `raw/marker-candidates.md`) is currently one-line prose in each Haiku brief:

- Line 292: `TLA — short expansion or "unknown"` (one line per entry)
- Line 299: `term — one-sentence definition`
- Line 306: `<tangent in ≤2 lines> — why dropped (if stated)`
- Lines 86–90: marker-extractor format (multi-line dotpoint with time, emoji, quote, arrow)

The knowledge-mapper synth (line 322) reads `raw/*.md` with a glob and applies the two-pass validation rule, but the validation rule's "supporting span" check is defined in terms of a text string — not a field name. Adding confidence scores, source spans, or switching to JSONL cascades through every brief independently.

The γ-Sonnet finding (finding 3): "a future Haiku writer producing a file that doesn't fit the current schema breaks the synth's two-pass validation without a loud signal."

### Proposed fix

Define a versioned JSON schema per artifact kind at `~/.claude/schemas/consolidate-v7/<kind>.schema.json`. Haiku extractors write JSONL; the knowledge-mapper synth reads + validates.

**Exemplar schema** (`tla-candidates.schema.json`, v1):

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "$id": "consolidate-v7/tla-candidates/v1",
  "type": "object",
  "required": ["kind", "tla", "expansion"],
  "properties": {
    "kind":        { "const": "tla-candidate" },
    "tla":         { "type": "string", "description": "The acronym, e.g. CLS" },
    "expansion":   { "type": "string", "description": "Short expansion or 'unknown'" },
    "source_span": { "type": "string", "description": "Verbatim quote from session-summary.md where this TLA appears" },
    "confidence":  { "enum": ["low", "med", "high"], "default": "med" }
  }
}
```

`domain-terms.schema.json` replaces `tla` with `term` and adds `definition`. `dropped-tangents.schema.json` uses `tangent` (≤2 lines) and `dropped_reason` (optional string). `marker-candidates.schema.json` uses `time` (HH:MM), `category` (enum of 6 emoji categories), `quote` (≤120 chars), `signal` (one-line).

Each Haiku brief changes from "one line per entry in format X" to "write JSONL conforming to `~/.claude/schemas/consolidate-v7/<kind>.schema.json` v1." The knowledge-mapper synth's verification gate (line 322) changes from prose description to: validate each line against schema, then apply the two-pass rule against `source_span` field — no ambiguity about what "supporting span" means.

**Migration:** (1) write 4 schema files; (2) update 4 Haiku briefs; (3) update knowledge-mapper synth's verification-gate description; (4) update file-ownership table to note `.jsonl` extension.

### Migration cost

Moderate-high for the schema files (new artifacts), low-moderate for the brief updates (~20 lines). The `.md` → `.jsonl` extension change needs to propagate to every glob reference (`raw/*.md` → `raw/*.jsonl`, or keep both during migration).

### Breaks

The knowledge-mapper synth's `raw/*.md` glob (line 322) breaks if files are renamed to `.jsonl`. Migration path: use `raw/*.jsonl` glob, or keep `.md` extension for backward compatibility (JSONL is valid in an `.md` file). Recommend `.jsonl` extension for correctness.

---

## 3. Named capabilities → concrete models mapping (γ MEDIUM 1)

### Problem

`haiku` / `sonnet` / `opus` appear as both executable spawn parameters (lines 69, 291, 298, 305, 315, 354) and as normative reasoning in briefs (lines 238, 316, 361). There is no single place that declares the model mapping. A cost-aware routing change, model-family swap, or capability rename forces a doc-wide text search.

γ-Codex finding (MEDIUM 1): "A future cost-aware routing change...forces edits across the doc."

### Proposed fix

Define named capabilities in the manifest (section 1 above, `model_capability` column) and add a **Model Capability Map** block near the top of Phase 1, immediately after the tiering rationale (after line 17):

```
## Model capability map (v7 — edit here only)

| capability        | concrete model | rationale                                |
|-------------------|---------------|------------------------------------------|
| cheap_extract     | haiku         | read-and-extract; spawn overhead < savings |
| synth_reasoning   | sonnet        | graph edges, judgment, verification gate  |
| voice_calibration | opus          | cold-reader voice; sets flow for tomorrow |
```

Every agent brief replaces `MODEL: sonnet` / `model: "haiku"` / `model: "opus"` with `MODEL: synth_reasoning (see capability map)`. The `Agent({model: "haiku"})` spawn param stays executable but references the map in a comment: `// cheap_extract — see capability map`.

A future `haiku-3-5` → `haiku-4` upgrade is a one-row table edit.

**Migration:** (1) insert capability map block; (2) update 7 `model:` spawn params to include capability comment; (3) update `MODEL:` prose lines in 3 briefs.

### Migration cost

Low. ~20 lines changed, all additive. The spawn params keep their executable values — this is documentation discipline, not a behavioral change.

### Breaks

None.

---

## 4. Tighten transcript parsing contract (γ MEDIUM 2)

### Problem

Lines 61–62 and 71–73 (marker-extractor Haiku brief) specify the transcript extraction as:

> `.role == "user"` OR `.type == "user"`, "try both — verify against the actual JSONL structure"

This is the ambiguity γ-Codex flagged. "Try both" is not a contract — it's a fallback for an unknown schema. The actual Claude Code JSONL schema (verified against `/Users/nick/.claude/projects/-Users-nick-git/2d6e3f19-cbc5-4f54-af38-f753b0bda553.jsonl` as of 2026-05-12):

- Top-level: `{type: "user"|"assistant"|..., message: {role: "user"|"assistant", content: <string|array>}, ...}`
- User messages are selected by `.type == "user"` (top-level) — not `.role`
- `message.role` is `"user"` but `.role` at top level does not exist
- `message.content` is either a plain string (for simple messages) or an array of content blocks
- Content blocks have `type` field: `"text"`, `"tool_use"`, `"tool_result"`
- Text extraction: `.message.content` if string, else `.message.content[] | select(.type=="text") | .text`

The correct `jq` filter (pinned to v6 schema):

```bash
jq -rc 'select(.type == "user") |
  if (.message.content | type) == "string"
  then .message.content
  else (.message.content[] | select(.type == "text") | .text)
  end' <JSONL_PATH>
```

### Proposed fix

Define a canonical transcript-extraction step in the **orchestrator setup** (after the `mkdir -p` block, line 28), producing `$SD/raw/transcript-user-messages.jsonl` — one plain-text message per line. The marker-extractor Haiku brief changes from specifying `jq` logic inline to reading `{{SESSION_DIR}}/raw/transcript-user-messages.jsonl` directly.

```bash
# Canonical transcript extraction — run once in orchestrator setup
jq -rc 'select(.type == "user") |
  if (.message.content | type) == "string"
  then .message.content
  else (.message.content[] | select(.type == "text") | .text)
  end' "$JSONL_PATH" > "$SD/raw/transcript-user-messages.jsonl"
```

All downstream extractors read from that file. If the JSONL schema changes at v7, there is exactly one place to update.

The file-ownership table adds: `transcript-extractor (orchestrator step) → raw/transcript-user-messages.jsonl`.

**Migration:** (1) add extraction block to Setup; (2) update marker-extractor brief to read from the pre-extracted file; (3) note the file in the ownership table and manifest.

### Migration cost

Low-moderate. ~15 lines added (extraction block + ownership table row + brief patch). The marker-extractor brief is simplified — the `jq` logic moves out of the agent prompt entirely.

### Breaks

None for current behavior. Locks in the JSONL schema — if Claude Code changes the wire format, the extraction block fails loudly rather than silently producing wrong output (an improvement).

---

## 5. Phase 0b/Phase 1 paradigm collision (γ ARCH DEBT)

### Problem

Phase 0b (lines 148–161) uses shell-backgrounded CLI calls with PID polling:

```bash
gemini ... < $SD/session-summary.md > $SD/kelvin-retro.md 2>&1 &
KELVIN_PID=$!
...
until ! ps -p $KELVIN_PID $CARNOT_PID > /dev/null 2>&1; do sleep 5; done
```

Phase 1 uses harness-level `Agent({...})` invocations. These are incompatible abstraction layers. The γ-Sonnet review (concern 3): "v7 merging `/nap`...will immediately hit this mismatch."

Two options:

**Option A: Migrate Phase 0b to `Agent({...})`**
- Kelvin and Carnot become subagents with harness-managed context.
- Gains: same paradigm as Phase 1; composable with streaming; failure mode is a harness exception, not a silent zombie PID.
- Loses: direct control over CLI flags and sub-second PID lifecycle. If the harness doesn't expose `gemini` or `codex` as model IDs, this requires a proxy agent or model shim.
- Estimated cost: ~50 lines rewritten in Phase 0b (the parallel block + PID polling + synthesis step). Medium complexity — requires verifying whether harness can invoke non-Anthropic models.

**Option B: Migrate Phase 1 to backgrounded shells**
- All agents become shell subprocesses.
- Loses: harness-native context-window budget management, automatic spawn isolation, and the `Agent()` API's subagent-type/model parameters.
- Estimated cost: significant rewrite (~150+ lines); loses the coordination-invariant enforcement that the harness currently provides.
- Assessment: impractical. The harness auto-context-window-budget is not reproducible in bare shell.

**Recommendation:** Defer. Neither option is free, and there is no v7 use case today that requires cross-paradigm work. Mark Phase 0b as tech debt with an inline comment (1-2 lines) so the collision is named and findable:

```bash
# TECH DEBT: Phase 0b uses shell-backgrounded CLIs + PID polling; Phase 1 uses Agent({}).
# If v7 adds streaming or merges /nap, migrate Phase 0b to Agent() first — Option A in the v7 scope spec.
```

**Migration cost (deferred path):** 2 lines added. The friction is documented, not resolved.

### Breaks

N/A — no implementation change proposed.

---

## 6. Additional structural findings from source read

### 6a. Marker category list duplicated without cross-reference (γ-Sonnet finding 7)

**Problem.** The marker category taxonomy is defined twice: in full in the marker-extractor Haiku brief (lines 76–84, 8 categories) and summarized again in the "Maxwell: filter + triage" section (lines 102–109). These can diverge silently. The Haiku brief is the executable spec; the Maxwell section is a prose summary that will drift.

**Proposed fix.** The Haiku brief is authoritative. The Maxwell section replaces its category list with: "Apply the marker categories from the Haiku brief above — do not maintain a separate list here." Delete lines 102–109's duplicate taxonomy.

**Migration cost:** Low. ~8 lines deleted.

**Breaks:** None.

### 6b. "After all three return" status count is a v5 fossil (γ-Sonnet finding from line 397)

**Problem.** Line 397: "Show Nick a one-line status per agent (3 lines total)." v6 has 6 agents (marker-extractor + 3 Haiku pre-extractors + knowledge-mapper synth + next-session-prompter). "3" was correct for v5's 3-agent sequential shape. With the agent manifest (section 1), this becomes a derived count — "one status line per terminal agent (those in the final burst + memory-writer)."

**Proposed fix.** Line 397 changes to: "Show Nick one status line per terminal agent (next-session-prompter, memory-writer, and any Burst 1 agents that reported an error). Haiku pre-extractors are intermediate — suppress their status unless they errored."

**Migration cost:** Low. ~3 lines changed.

**Breaks:** None.

### 6c. `2*` year-prefix glob is a time-bomb (γ-Sonnet finding from line 38)

**Problem.** Line 38: `ls -t "$HOME"/.claude/consolidation/2*/next-session-prompt.md`. The `2*` glob hardcodes the millennium. Silently returns nothing in 2100 (or if naming convention changes).

**Proposed fix.** Change to: `ls -t "$HOME"/.claude/consolidation/[0-9]*/next-session-prompt.md`. More robust without being precious. Also appears in CLAUDE.md wake-up protocol — fix both.

**Migration cost:** Trivial. 1-2 line changes.

**Breaks:** None.

### 6d. Implicit orchestrator procedure has no explicit section

**Problem.** The orchestrator's responsibilities are scattered: setup (lines 23–55), Phase 0a spawn + filter (lines 63–135), Phase 0b (lines 143–180), pre-Burst-1 TaskList collection (lines 214–218), Burst sequencing (lines 222–224), and Wrap-up (lines 403–414). A v7 author wanting to add a new orchestration step has no single place to look.

**Proposed fix.** Add an **Orchestrator Checklist** section immediately before Phase 0a. Format: numbered list with phases, each naming preconditions and outputs. Not a spec rewrite — just a navigational table of contents for the implicit procedure.

Content (~12 lines):
1. Create `$SD/` and `$SD/raw/` (Setup)
2. Resolve memory-path → write `memory-path.txt`
3. Write `session-summary.md`
4. Extract transcript → `raw/transcript-user-messages.jsonl` (new in v7 per §4)
5. Phase 0a: spawn marker-extractor; filter; write `affective-highlights.md`
6. Phase 0b: fire Kelvin + Carnot + Maxwell; synthesize → `multi-perspective-retro.md`
7. Collect TaskList snapshot
8. Burst 1: spawn memory-writer + 3 Haiku extractors
9. Burst 2: spawn knowledge-mapper synth
10. Burst 3: spawn next-session-prompter
11. Wrap-up: merge wins; show status + prompt

**Migration cost:** Low. ~15 lines added. No existing text removed.

**Breaks:** None.

---

## 7. Additions from Round 2 panel review

### 7a. Separate display-timestamp from uniqueness-key (γ-Codex v2 HIGH)

**Problem.** `SID="$(date +%Y-%m-%dT%H-%M-%S)"` currently serves as both human-readable ordering key and uniqueness guarantee. Second-granularity collisions stop being "rare enough to ignore" as v7 concurrency grows — burst jobs, streaming writers, `/nap` or `/graph` merging into the same consolidation namespace all increase the collision surface.

**Proposed fix.** SID stays as the display timestamp (human-readable, sortable). Add a separate uniqueness suffix: `UID="$(uuidgen | cut -c1-8)"` and construct the session directory as `$SD = $HOME/.claude/consolidation/$SID-$UID`. The UID suffix is invisible to human readers scanning dir names (timestamp still leads) but makes collisions astronomically unlikely.

**Migration:** Low-cost path rename — all consumer `mtime`-based lookups continue to work because the timestamp prefix still sorts correctly. The manifest table (§1) should document `$SID` and `$UID` as separate variables with distinct purposes.

**Breaks:** Consumers that glob on exact timestamp strings (not `mtime`) would need updating. The canonical resolver in CLAUDE.md (`ls -t .../[0-9]*/next-session-prompt.md`) is unaffected.

### 7b. Per-artifact dependencies, not per-burst (γ-Codex v2 MEDIUM)

**Problem.** Burst 2 waits for ALL 4 Burst 1 jobs to complete before knowledge-mapper synth spawns, even though knowledge-mapper only consumes the 3 Haiku `raw/*.md` files. memory-writer's output (`open-tasks.md`, `scorecard.json`, etc.) is independent of knowledge-mapper's inputs. The burst boundary forces an unnecessary serial wait.

**Proposed fix.** Specify spawn dependencies as artifact-level reads rather than burst membership. The manifest table (§1) already has an `inputs` column — extend it with a `reads` field listing exact file paths. Knowledge-mapper's entry becomes `reads: [raw/tla-candidates.md, raw/domain-terms.md, raw/dropped-tangents.md]`. The orchestrator can spawn knowledge-mapper as soon as those three files exist on disk, regardless of memory-writer's progress. This is a v7 streaming optimization; the current burst model is a safe fallback for v6.

**Migration:** The manifest table is the natural home. Implementation requires the orchestrator to switch from "wait for burst N to complete" to "poll for artifact existence before spawning." Non-trivial orchestration change — defer implementation to v7, document intent here.

**Breaks:** None for v6 (burst model unchanged). v7 orchestrator must implement artifact-existence polling.

### 7c. Decouple session-accounting from memory-writer (γ-Codex v2 MEDIUM)

**Problem.** memory-writer currently owns `open-tasks.md`, `pending-tasks.json`, `scorecard.json`, and `wins.md` for cost-efficiency reasons ("cheap enough to ride along"). v7 may want to reorganize ownership — for instance, a streaming architecture where session-accounting artifacts are written independently of memory graph updates, or a sidecar that owns session state across `/nap`, `/consolidate`, and `/graph` invocations.

**Proposed fix.** Redraw the file-ownership table (§1 manifest) to make session-accounting a named responsibility with its own `owner` column entry — either a dedicated `session-accounting` agent/sidecar or an explicit note that it's deliberately bundled into memory-writer with a rationale. Currently the bundling is implicit and undocumented. Naming it makes future unbundling a deliberate decision rather than a refactor that discovers surprise coupling.

**Migration:** Documentation change only for v6. v7 may introduce a separate `session-accounting` agent; the manifest table is the right place to track the decision.

**Breaks:** None for current behavior.

### 7d. Authoritative session identity (α-Codex v2 + γ-Codex v2 convergent HIGH)

**Problem.** Both Panel α (backward-facing) and Panel γ (forward-facing) independently flagged the JSONL mtime resolver (`ls -t .../*.jsonl | head -1`) as a fragile heuristic. α framed it as a `latest/`-shape workaround — multi-tab scenarios pick the wrong session's JSONL. γ framed it as coupling Phase 0a to a non-authoritative recency heuristic (fragile under multi-tab, streaming, and resumed sessions). Same underlying shape: **single shared mutable pointer to "current" state** — convergent across panels with incompatible orientations.

The current fix (documented in db9ee71, this session's third round) narrows the glob to the project-keyed directory and adds a recency guard. This is the floor — it reduces but does not eliminate the fragility.

**Proposed fix.** Add an explicit **Session Identity Resolution** subsection to the spec. Content:

1. **Preferred:** query the Claude Code harness for the authoritative session ID via an env var (e.g., `$CLAUDE_SESSION_ID`) — if/when the harness exposes this, use it and skip the mtime heuristic entirely.
2. **Current floor (v6):** project-keyed JSONL glob + mtime-newest, with the recency guard from db9ee71. Document the known failure modes (multi-tab writes, streaming duplication, resumed sessions) so future maintainers know what "floor" means.
3. **Revisit trigger:** if Claude Code adds a session identity env var in any future release, replace the heuristic immediately. Add a comment in the orchestrator setup block: `# TODO: replace mtime heuristic with $CLAUDE_SESSION_ID when harness exposes it`.

**Migration:** Documentation + one inline comment. No behavior change for v6.

**Breaks:** None.
