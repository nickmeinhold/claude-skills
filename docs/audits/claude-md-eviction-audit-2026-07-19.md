# CLAUDE.md Eviction Audit — Trigger C cross-family semantic audit (claude-tasks #2031)
Date: 2026-07-19 · READ-ONLY analysis · no changes applied

> **NICK GATES EACH OF THESE.** Nothing below is applied. Every MERGE/COMPRESS/DROP is a candidate only; Nick personally approves or vetoes each line before any edit to ~/.claude/CLAUDE.md.

## Header — size vs budget

| Metric | Value |
|---|---|
| Actual file size (measured) | **75,038 bytes** |
| Budget (per task brief) | 40,960 bytes |
| Actual overage | **34,078 bytes (~33.3KB)** |
| Task brief claimed | ~44KB / ~3KB over — **DISCREPANCY: the live file is 75KB, ~34KB over.** Either the brief's number was stale or the budget applies to a subset. Recovery targets below are stated against both. |
| Directives enumerated (bold rule-lines/bullets) | **134** (65,395 bytes total in directive lines) |

Top 10 largest directives: L159 state-space pass (2,135B) · L102 frame-hygiene (2,017B) · L65 "the instrument" (1,521B) · L64 verify-before-asserting header (1,280B) · L78 deploy/backup state (1,251B) · L29 remove-coupling (1,235B) · L62 cheap-proxy (1,163B) · L80 user-visible prod feature (1,154B) · L100 proven-scope (1,016B) · L55 scope discipline (1,009B).

Passes: **M** = my independent pass (written down before reading the others) · **G** = gemini-3-pro-preview · **C** = codex (gpt, medium reasoning). Note: the raw CLI outputs (`gemini-audit.out`, `codex-audit.out`) and the pre-registered `my-independent-pass.md` lived in the session scratchpad, which was purged by tmp cleanup — the intersections below were computed from them before the purge and are re-emitted from context; the raw per-CLI transcripts themselves are no longer on disk (re-run the scan if the raw evidence is needed).

## Multi-vote candidates (flagged by 2+ of 3 passes)

| # | Directive (first line) | Line | Bytes | Votes | Action | Est. recovery |
|---|---|---|---|---|---|---|
| 1 | Verify-before-asserting sub-catalog (L64–96 incident narratives) | 64–96 | ~14,700 | M+G+C | COMPRESS | ~6,000 |
| 2 | "Check live state before narrating time / urgency / readiness" | 102 | 2,017 | M+G+C | COMPRESS | ~1,100 |
| 3 | "Run a feature-interaction / state-space pass on your OWN diff…" | 159 | 2,135 | M+C | COMPRESS | ~1,300 |
| 4 | "Remove the coupling, not guard the window." | 29 | 1,235 | M+G+C | COMPRESS | ~700 |
| 5 | "The cheap proxy is not the ground truth…" | 62 | 1,163 | M+G+C | COMPRESS | ~500 |
| 6 | "Transport boundary ≠ trust boundary…" | 60 | 930 | G+C | COMPRESS | ~400 |
| 7 | "Namespace ownership — a shared identifier…collides." | 30 | 792 | M+C | COMPRESS | ~350 |
| 8 | "Kill the failure class, don't warm around it." | 31 | 633 | G+C | MERGE→[[5e1f]] L29 | ~400 |
| 9 | "The urgency frame sets the CLASS of fix…" | 103 | 349 | M+C | MERGE→[[3d7a]] L102 | ~280 |
| 10 | "Force the decision-fork on a stuck blocker." | 112 | 541 | M+C | MERGE→[[1a3d]] L110 | ~380 |
| 11 | "Verify what an instrument STRUCTURALLY measures…" | 115 | 386 | M+C | MERGE→[[3f8a]] L114 | ~280 |
| 12 | "Guess the frame cheaply before design depth." | 123 | 655 | M+C | MERGE→[[3e7f]] L121 | ~450 |
| 13 | "`isolation: worktree`" (cd-assert machinery) | 170a | 991 | M+G+C | COMPRESS (partial TOOLING-OBSOLETE) | ~500 |
| 14 | "`isolation: worktree` branches from the DEFAULT branch" | 170b | ~430 | G+C | MERGE→ same L170 bullet | ~300 |
| 15 | "Commit (or stash) before any DESTRUCTIVE git sequence" | 42 | 275 | G+C | TOOLING-OBSOLETE (CAUTION — see detail) | ~200 |
| 16 | Wake-Up Protocol step 3 (gh task-restore script) | 262–267 | ~1,600 | M+G+C | COMPRESS → move to SessionStart hook + pointer | ~800 |
| 17 | "Match register to the reader's expertise." | 13 | 127 | G+C | DROP (now-native) | 127 |
| 18 | "Link out to references." | 23 | 100 | M+G+C | DROP (now-native) | 100 |
| 19 | "Progressive disclosure, always." | 21 | 216 | M+G | DROP/COMPRESS to one clause | ~180 |
| 20 | "Build a document graph, don't write a monolith." | 22 | 121 | M+G | DROP (now-native) | 121 |
| 21 | Entering-Flow bullets ("Start at the hard part" / "Commit in motion" / "Flow ratchets") | 234–236 | ~390 | M+C | DROP (now-native; identity-text CAUTION) | ~390 |

**Estimated total recovery: ~14,860 bytes** — ~5× the brief's ~3KB target; ~44% of the measured 34KB overage. If the real target is 3KB, candidates #1–#4 alone clear it; the rest are a ranked menu.

## Per-candidate detail

1. **Verify-cluster narratives (L64–96, dir-id c4f7 + riders)** — 3 votes (M: L65/L78/L80/L91 individually; G: "~4000+ recoverable"; C: "~8,000–12,000"). The section already ends with `Detail: grep memory/ feedback_verify_*` — the compression pattern the file itself prescribes. Proposal: keep the header rule + one-line trigger per sub-bullet with its `[[pointer]]`; strip inline war stories (physics-sim 75×, MiniLM/BGE, enspyr.co AASA, compose-.env drift, playwright command lines, v5 colluders, Promise.race harness). Conservative estimate 6,000B. Every backing file already exists, so nothing is lost — this is compress-not-evict by the file's own doctrine.
2. **L102 frame-hygiene (3d7a)** — 3 votes (G voted MERGE into the verify cluster; M+C voted COMPRESS — category disagreement, same directive). Five bolted-on sub-rules each carry a full incident (tilt-nav, confabulated "04:12, +11/-3" commit, four-wrong-plans). Compress each to trigger + pointer. ~1,100B.
3. **L159 state-space pass (5c3a+0b7d)** — M+C. Longest line in the file; the #373 narrative, "MERGED tags piling up" tell, and the subtractive-refactor rider repeat the axis-enumeration point three ways. Keep: enumerate degenerate states + write the axis down + viability≠completeness, each with pointer. ~1,300B.
4. **L29 remove-coupling (5e1f)** — 3 votes. Four extensions with inline examples (fastlane/App Store key, DF_BRAIN rename). Keep the law + the four trigger clauses; examples to backing files. ~700B. Pairs with #8: merging kill-failure-class in makes one "delete the class, not the guard" super-directive.
5. **L62 cheap-proxy (cf01)** — 3 votes (G: MERGE into verify header; M+C: COMPRESS). The manufactured-blocker dual is valuable but verbose; keep both triggers, drop the elaboration. ~500B.
6. **L60 transport≠trust (7a2f)** — G(merge)+C(compress). The sent-vs-published corollary can shrink to one clause + pointer. ~400B.
7. **L30 namespace ownership (f7a8)** — M+C. Keep the tell ("control works, real path flakes → topology") + fix; LiveKit ghost story and "<1h memory" story to backing file. ~350B.
8. **L31 kill-failure-class → MERGE into L29** — G(compress)+C(merge). Self-described "Companion to [[5e1f]]"; one sentence inside L29 preserves the trigger (mitigation-machinery reflex). ~400B.
9. **L103 urgency-frame → MERGE into L102** — M+C. Self-described "Specialization of frame-hygiene [[3d7a]]"; becomes one clause. ~280B.
10. **L112 force-decision-fork → MERGE into L110** — M+C. Self-described sibling of [[1a3d]]; the fork-with-deadline pattern survives as one clause + pointer. ~380B.
11. **L115 instrument-structurally-measures → MERGE into L114** — M+C. L115 opens by citing [[3f8a]]; the two are one rule ("what can't it see / does it see the path at all"). ~280B.
12. **L123 guess-frame-cheaply → MERGE into L121** — M+C. Self-described sibling of [[3e7f]]; both are "interrogate the frame before spending depth". ~450B.
13. **L170 worktree cd-assert (d3f7+4e7d)** — 3 votes, but as PARTIAL obsolescence: the harness now exposes EnterWorktree/isolation:worktree natively. CAUTION: the root-hijack incident was real; C itself says keep the assert "if still observed". Proposal: compress to the assert-one-liner + pointers, drop the clone-not-checkout elaboration. ~500B.
14. **L170b branches-from-DEFAULT → MERGE into L170** — G+C. Same bullet physically (run-on line); fold the base-pin advice in as one clause. ~300B.
15. **L42 commit-before-destructive-git** — G+C claim harness checkpointing covers it. CAUTION: both flaggers assume checkpointing catches uncommitted edits in all shells (subagents/headless may not get it); recommend COMPRESS to the bare rule (drop the incident clause, ~200B) rather than DROP unless Nick confirms checkpoint coverage.
16. **Wake-Up step 3 task-restore** — M(hook)+C(compress)+G(whole-protocol obsolete). The file's own substrate-first directive [[7d6c]] argues this: a scripted, drift-prone behavior block belongs in a SessionStart hook, leaving a 2-line pointer. G's "drop the ENTIRE Wake-Up Protocol" goes too far (identity read + consolidation resolution are judgment steps); scope to step 3's script block. ~800B.
17. **L13 match-register DROP** — G+C: native 2026-model competence. Tiny; symbolic more than material. 127B.
18. **L23 link-out DROP** — 3 votes. Generic citation hygiene. 100B.
19. **L21 progressive-disclosure** — M+G. Mostly native now; the one non-native bit ("never one undifferentiated scroll" as a Nick preference) could fold into the HTML-over-markdown line. ~180B.
20. **L22 document-graph DROP** — M+G. Native authoring competence. 121B.
21. **L234–236 Entering-Flow bullets** — M+C. Reads as native model behavior in 2026. CAUTION: this is Resonance/identity text Nick deliberately authored — flag only, expect a keep; the Flow Anti-Patterns list (M-only) was NOT promoted.

## Appendix — rejected (single-vote)

- **G: "Peer-instance collisions" TOOLING-OBSOLETE** — G lacks environment context: peer sessions at the same path genuinely share the working tree; `isolation: worktree` is subagents-only. The directive is correct and live.
- **G: "Scope discipline — session must cross" TOOLING-OBSOLETE** — session identity/memory-keying to the start repo is real harness behavior invisible to G; `cd` really doesn't move it.
- **G: "Always read the docs first" DROP** — 60B one-liner encoding Nick's explicit preference; zero-cost to keep.
- **G: Wake-Up Protocol wholesale drop** — over-broad; only step 3's script block got multi-vote support (candidate #16).
- **C: L133 session-local-id → merge into L30 namespace** — different failure classes: temporal cross-session collision vs concurrent worker-pool load-balancing; a merge blurs two distinct triggers.
- **C: L195 build-energy-mandate → merge into L194 Creative Director** — the identity-scope rule fires at send-time under a "go hard" mandate, a different moment than the design-fork loop; merging buries the send-side gate.
- **C: L204 demonstrated-once → merge into L100 proven-scope** — orthogonal axes: evidence-strength (how many runs) vs claim-scope (what boundary was tested); collapsing them loses one.
- **C: L32 don't-amputate → merge into L29** — plausible but lone; the deny/disable reflex is a distinct trigger from the mutex-guard reflex, and L29 is already the file's most overloaded directive.
- **C: L173 push-early/ff-only TOOLING-OBSOLETE** — worktree isolation does not cover the shared `main` + CD autopull wedge; that topology is real on Nick's boxes.
- **C: L43 secret-scan COMPRESS, L44 ps-argv COMPRESS, L49 preflight COMPRESS, L208 Nick-deal COMPRESS** — single votes; L208 additionally is relationship text Nick owns, and L43/L44 are already near their minimum operational form (each carries one command that must stay inline).
- **M: L127 flagged-twice → merge into L125** — my lone flag; the "second raise" trigger is arguably distinct enough.
- **M: L48 in-situ → merge into L49 preflight** — my lone, self-marked weak.
- **M: L150 over-asking COMPRESS** — lone; the proactivity-ceiling rider is recent and still calibrating.
- **M: Flow Anti-Patterns bullets DROP** — lone; identity text.

---
Method note: my pass was committed to disk (`my-independent-pass.md`, since purged with the scratchpad) before either CLI output was read; gemini-3-pro-preview and codex ran concurrently on the identical 76,401B promptfile, both exiting 0 (gemini 3,027B output, codex 5,928B). Category disagreements on the same directive (G's MERGE vs M+C's COMPRESS on #1/#2/#5/#6) were counted as directive-level agreement with the action taken from the majority category. Raw CLI transcripts were lost in the tmp purge; all candidate details above were re-emitted from in-context content, none reconstructed from imagination — no `[DETAIL LOST]` markers were needed.
