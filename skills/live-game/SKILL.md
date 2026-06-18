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
| POST | `/join` | audience | `{clientId, name}` |
| POST | `/vote` | audience | `{clientId, option}` — first answer locks |
| POST | `/host/ask` | host | `{question, options[], correct, timeLimit?}` |
| POST | `/host/reveal` | host | award points, reveal |
| POST | `/host/next` | host | back to lobby (keep scores) |
| POST | `/host/reset` | host | wipe players + scores |

## Going live to a real room (blast radius — read before exposing publicly)

For a real audience the phones need to reach the server, so you tunnel it
(Tailscale Funnel or `ngrok http 7373`). That makes it a **public endpoint** — name
the exposure before opening it (per the security doctrine in `~/.claude/CLAUDE.md`):

- **Control is host-token-gated.** All state-mutating *game* actions (`ask`, `reveal`,
  `next`, `reset`) require the token. Audience can only `join`/`vote`. Keep the token
  off the projected screen (it lives in the URL `#fragment`, which is not sent to the
  server and not shown in the QR).
- **Audience input is the injection surface, and it's contained:** player names and
  options are HTML-escaped on render *including quotes* (`& < > " '`), so a name cannot
  break out of an HTML attribute — no stored XSS. Votes are integer-validated and
  range-checked, `correct`/`timeLimit` are range-checked/clamped server-side, request
  bodies are capped at 1 MB, the player table is capped at `MAX_PLAYERS` (500), and a
  vote *locks* (no flooding a re-vote). State is **in-memory only** — no persistence, no
  DB, nothing to corrupt.
- **No external quota is wired to audience actions.** The Game Master (Claude) generates
  questions out-of-band; an audience vote never triggers an LLM/API call. So there is no
  cost-amplification path from the public surface.

### Named residuals (real, but prototype-acceptable in a *trusted* room)

These are known compromises, stated explicitly rather than absorbed silently. Each is
fine for a trusted-room demo; address before an untrusted public game.

- **Identity is client-asserted, not server-issued.** A player's `clientId` is supplied
  by the client, so on the tunnel a malicious peer who observes/guesses another's id
  could overwrite their name or cast a vote as them. Trusted-room-acceptable; the real
  fix is a server-issued opaque id + per-client secret required on `vote`.
- **No per-IP rate limit** on `join`/`vote`. The `MAX_PLAYERS` cap bounds memory, but a
  loop can still churn joins/votes within the cap. Add a per-IP limiter for public use.
- **SSE fan-out has no backpressure / flow control.** `broadcast()` writes to every
  client on each `join`/`vote` and never drops a slow consumer, so a deliberately-slow
  client can accumulate buffered state. Fine at room scale; cap/drop slow clients for
  large or hostile audiences.
- **The host QR uses an external image service** (`api.qrserver.com`). "Zero-dependency"
  means zero *npm* deps and offline *gameplay*; the QR convenience makes a runtime call
  to a third party and leaks the (private-IP) join URL to it. Show the printed join URL
  instead for a fully-offline/private setup, or self-host a QR encoder.
- **The phone reveal view finds "you" by name within the top-10 leaderboard.** Duplicate
  names or players outside the top 10 may see a wrong/missing self-score+gain (the
  correct/incorrect verdict is always right — it's computed from the player's own vote).

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
