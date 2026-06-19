---
argument-hint: <topic or question> | start | reveal | next | reset | scores
description: Run a live multiplayer audience quiz-game — phones are buzzers, the big screen is the board, Claude is the Game Master
---

# Live Game

A realtime, Kahoot-style audience quiz game. The **big screen** (the host view, or
a Google Slide) is the board; the **audience's phones** are the buzzers; **Claude
is the Game Master** — generating questions, opening voting, revealing answers, and
narrating the leaderboard.

This is the multiplayer cousin of `/live-qa`: where `/live-qa` researches one
question and paints the answer on a slide, `/live-game` turns the room into players
who vote in realtime and compete on a speed-scored leaderboard.

The backend is a single **zero-dependency** Node server (`server.mjs`) — realtime
fan-out is Server-Sent Events, so there is no `npm install`.

## Quickstart

```bash
# 1. Start the server (prints the host URL + a host token)
node skills/live-game/server.mjs --port 7373

# Host screen (big screen / projector):  http://localhost:7373/#<token>
# Phones join at:                          http://localhost:7373/play
```

Open the host URL on the projector. Players scan the QR (shown on the host screen)
or browse to `/play`, enter a name, and wait. The host view shows the join QR, live
answer bars, and the leaderboard — all driven by SSE, no clicking.

## Game Master loop (what Claude does)

The argument in `$ARGUMENTS` selects the move:

- **`<topic or question>`** — generate ONE quiz question on the topic (or use the
  literal question), with 2–6 short options and the correct index, then open voting:
  ```bash
  curl -s -X POST "http://localhost:7373/host/ask?token=$TOKEN" \
    -H 'content-type: application/json' \
    -d '{"question":"Which planet has the most moons?",
         "options":["Earth","Jupiter","Saturn","Mars"],
         "correct":2,"timeLimit":20}'
  ```
  Keep options SHORT (readable from the back of the room). Pick a genuinely
  interesting/surprising correct answer when the topic allows.

- **`reveal`** — close voting, award points, show the distribution + leaderboard:
  ```bash
  curl -s -X POST "http://localhost:7373/host/reveal?token=$TOKEN" -d '{}'
  ```
  Scoring: a correct answer earns **500 base + up to 500 speed bonus** that decays
  linearly across `timeLimit`. Answer instantly → ~1000; at the buzzer → ~500. Wrong
  or no answer → 0. (This is the "it's a game, not a poll" mechanic.)

- **`next`** — return to the lobby (scores kept), ready for the next `ask`.
- **`reset`** — wipe all players and scores, start a fresh game.
- **`scores` / `start`** — read the snapshot and narrate it:
  ```bash
  curl -s http://localhost:7373/state   # JSON: phase, counts, correct, leaderboard
  ```

Between moves, poll `/state` (or watch `/events`) to narrate progress ("12 of 15 in!")
and to read the final leaderboard aloud after a reveal.

**Config:** the host token is printed at startup, or pin it with
`LIVE_GAME_HOST_TOKEN=...`. Port via `--port` or `LIVE_GAME_PORT`.

## Endpoints

| Method | Path | Who | Purpose |
|---|---|---|---|
| GET | `/` | host | big-screen view (QR, bars, leaderboard) |
| GET | `/play` | audience | phone view (join + vote) |
| GET | `/events` | all | SSE stream of public state |
| GET | `/state` | all | JSON snapshot (slide updater / tests) |
| POST | `/join` | audience | `{name, playerId?, secret?}` → server issues `{playerId, secret}` |
| POST | `/vote` | audience | `{playerId, secret, option}` — first answer locks |
| POST | `/me` | audience | `{playerId, secret}` → caller's own score/gain/verdict |
| POST | `/host/ask` | host | `{question, options[], correct, timeLimit?}` |
| POST | `/host/reveal` | host | award points, reveal |
| POST | `/host/next` | host | back to lobby (keep scores) |
| POST | `/host/reset` | host | wipe players + scores |

## Going live to a real room (blast radius — read before exposing publicly)

For a real audience the phones need to reach the server, so you tunnel it
(Tailscale Funnel or `ngrok http 7373`). That makes it a **public endpoint**. The
audience surface has been hardened for an *untrusted* public game (per the security
doctrine in `~/.claude/CLAUDE.md`):

- **Control is host-token-gated.** All state-mutating *game* actions (`ask`, `reveal`,
  `next`, `reset`) require the token. Audience can only `join`/`vote`/`me`. Keep the
  token off the projected screen (it lives in the URL `#fragment`, which is not sent to
  the server).
- **Identity is SERVER-issued, not client-asserted.** On first `join` the server mints an
  opaque `playerId` plus a `secret` bearer credential; `vote` and `me` require the
  matching secret (constant-time compared), and the secret is *never* broadcast. A peer
  who observes/guesses a `playerId` therefore can neither vote as that player nor rename
  them — a stale/forged id just gets a fresh identity. This closes the hijack the
  client-asserted-id prototype had.
- **Audience input is the injection surface, and it's contained:** names/options are
  HTML-escaped on render *including quotes* (`& < > " '`) — no stored XSS; votes are
  integer/range-validated; `correct`/`timeLimit` are range-checked/clamped server-side;
  bodies capped at 1 MB; the player table capped at `MAX_PLAYERS` (500); a vote *locks*.
  State is **in-memory only** — nothing to persist or corrupt.
- **Per-IP rate limiting** throttles `join`/`vote` (fixed window, `LIVE_GAME_RATE_MAX`
  per `LIVE_GAME_RATE_WINDOW_MS`, default 60 / 10 s). Bounds request churn that
  `MAX_PLAYERS` alone wouldn't.
- **SSE fan-out drops a backed-up consumer.** `broadcast()` destroys any client whose
  unsent buffer exceeds `LIVE_GAME_MAX_SSE_BUFFER` (default 1 MB), so a slow/hostile
  client can't grow server memory unbounded.
- **No external quota is wired to audience actions.** The Game Master (Claude) generates
  questions out-of-band; an audience vote never triggers an LLM/API call — no
  cost-amplification path. The host QR no longer calls a third party (the join URL is
  rendered prominently instead — fully offline; an inline QR encoder is a tracked
  follow-up).

### Remaining caveats (named, not absorbed)

- **Rate limiting attributes by socket IP** unless `LIVE_GAME_TRUST_PROXY=1`, in which
  case it reads the **rightmost** `X-Forwarded-For` entry — the address the nearest
  (trusted) proxy actually observed, not the spoofable client-seeded leftmost entry.
  This is correct for a **single** trusted proxy (the common tunnel case). With a
  multi-proxy chain the rightmost is the nearest proxy rather than the origin client, so
  per-player attribution can collapse to a proxy IP — set `TRUST_PROXY` only when exactly
  one proxy you trust sits in front, otherwise the limit becomes coarser (per-proxy /
  global) rather than per-player.
- **The `secret` is a bearer token in `localStorage`.** Names are escaped (no stored
  XSS path to read it), but it is device-local — clearing storage or switching devices
  starts a fresh identity (score not transferred). Acceptable for a session-scoped game.
- **The host token is a single shared secret** — fine for one operator; there is no
  multi-host/role model.

## Pairing with a Google Slide (optional)

The host view is a complete big-screen board on its own. To instead render the live
game ON a Google Slide (so it lives inside your deck, like `/live-qa`), poll `/state`
and map it onto a slide config via the `claude-slides` build — same mechanism
`/live-qa` uses. Left as a follow-up; the host view is the zero-setup path.

## Testing

`tests/live-game/live-game.bats` boots the server and drives a full game loop,
pinning the load-bearing invariants: counts/correct hidden during a live question,
the speed bonus ordering faster-correct above slower-correct, vote-lock, and
host-token enforcement. Run with `bats tests/live-game/live-game.bats`.
