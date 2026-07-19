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

**Pacing — prefetch the next question (lookahead-1).** The ~20 s answer window is
dead time for the Game Master: players are tapping phones, the server is just
tallying, and you are idle. *Use it.* The moment you open voting on question *n*,
compose question *n+1* in the same turn and hold it ready. Then `reveal` → `next` →
`ask` fires the already-composed question with no "thinking" gap — the room never
sits staring at a stale leaderboard while you write.

Generate exactly **one** question ahead, not the whole batch. Lookahead-1 hides the
generation latency (the expensive part — composing the question) off the critical
path *without* surrendering human pacing: you still decide *when* to advance by
reading the room. Full pre-batching removes that judgement and lets an eager loop
outrun a casually-engaged audience (an observed failure mode — 4 rounds of zero
answers). You are the metronome; prefetch the notes, but keep your hand on the beat.
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
| POST | `/host/ask` | host | `{question, options[], correct, timeLimit?}` — go live now |
| POST | `/host/stage` | host | `{question, options[], correct, timeLimit?}` — park the NEXT question (lookahead-1) |
| POST | `/host/advance` | host | promote the staged question live (no compose latency) |
| POST | `/host/reveal` | host | award points, reveal |
| POST | `/host/next` | host | back to lobby (keep scores) |
| POST | `/host/reset` | host | wipe players + scores (clears the staged slot) |

**Staging (decoupled prefetch).** `/host/stage` parks a validated next question
server-side (single-buffer — a second stage overwrites); `/host/advance` promotes it
live in one cheap call with zero compose latency. It's the fully-decoupled form of the
lookahead-1 pacing above: compose Q(n+1) during Q(n)'s answer window and `stage` it,
then `advance` instead of `ask` when you read the room as ready. Two invariants hold by
construction: the staged question is **never observable** (`correct` index included)
until advanced — it lives off `publicState()` entirely; and advancing stays
**host-triggered** (token-gated), never auto-fired on reveal, so you keep your hand on
the beat. `ask` and `reset` both clear the slot.

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
  cost-amplification path.
- **The join QR is encoded in-process, fully offline.** `qr.mjs` is a dependency-free QR
  encoder (byte mode, versions 1–6, Reed–Solomon EC) served at `GET /qr.mjs` and rendered
  to inline SVG on the host screen — no `api.qrserver.com`, no npm dep, no leak of the
  private LAN join URL. Verified bit-for-bit against `qrencode` (structural identity at a
  shared mask) and round-tripped through `zbarimg` (the auto-masked output decodes back to
  the join URL). See `tests/live-game/qr-matrixdiff.mjs` + `qr-unit.mjs`.

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

### Permanent hosting (the imagineering OCI box)

The tunnel above is for an ad-hoc room. The durable home is the imagineering OCI box,
where it serves at **https://quiz-game.imagineering.cc**. Two pieces: a systemd unit
for the Node server, and a Caddy route (Caddy is the box's shared reverse proxy).

**1. Ship the app.** `scp server.mjs qr.mjs` to `~/apps/live-game/` on the box (the
server is self-contained — no `node_modules`, `qr.mjs` is the only sibling it loads).

**2. systemd unit** at `/etc/systemd/system/live-game.service` (`systemctl enable --now
live-game`). The server binds **localhost only** — Caddy terminates TLS and proxies in,
so the Node process is never directly exposed:

```ini
[Unit]
Description=Live Game (Kahoot-style audience quiz) — skills/live-game
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=nick
WorkingDirectory=/home/nick/apps/live-game
ExecStart=/usr/bin/node /home/nick/apps/live-game/server.mjs --port 7373
Environment=LIVE_GAME_HOST_TOKEN=<generate: openssl rand -hex 16 — do NOT commit the real value>
Environment=LIVE_GAME_JOIN_HOST=quiz-game.imagineering.cc
Environment=LIVE_GAME_JOIN_SCHEME=https
Environment=LIVE_GAME_TRUST_PROXY=1
Environment=LIVE_GAME_BIND=127.0.0.1
Restart=always
RestartSec=2
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/home/nick/apps/live-game

[Install]
WantedBy=multi-user.target
```

Key env knobs: `LIVE_GAME_BIND=127.0.0.1` (loopback-only — Caddy fronts it),
`LIVE_GAME_JOIN_HOST` + `LIVE_GAME_JOIN_SCHEME=https` (so the join URL/QR point at the
public HTTPS host, not `localhost`), `LIVE_GAME_TRUST_PROXY=1` (read the rightmost
`X-Forwarded-For` from Caddy for rate-limit attribution — see caveats above), and a
strong pinned `LIVE_GAME_HOST_TOKEN` (the unit is the source of truth; keep the real
value out of git). Optional tuning knobs (unset on the box → server defaults):
`LIVE_GAME_LEAD_MS` (the 3·2·1 countdown lead before a question goes live, ms),
`LIVE_GAME_RATE_MAX` / `LIVE_GAME_RATE_WINDOW_MS` (per-IP audience rate limit),
`LIVE_GAME_MAX_SSE_BUFFER` (per-client SSE backpressure cap), and
`LIVE_GAME_MAX_SSE_CLIENTS` (global cap on concurrent `/events` streams, default
1000 — bounds total connections; raise it for an audience above ~1000 phones).

**3. Caddy route.** Caddy on this box runs as a Docker container with the Caddyfile at
`/home/nick/apps/caddy/Caddyfile` (version-controlled in
[`imagineering-cc/imagineering-infra`](https://github.com/imagineering-cc/imagineering-infra) under `caddy/`). The route is a normal block — **not** an admin-API
injection (an earlier ad-hoc `localhost:2019` injection was lost on the next container
restart; it's now durable in the Caddyfile, added in imagineering-infra PR #115):

```
quiz-game.imagineering.cc {
    reverse_proxy localhost:7373
}
```

Edit the Caddyfile in the repo, deploy it to the box, and `docker exec caddy caddy
reload --config /etc/caddy/Caddyfile --adapter caddyfile` (graceful, no downtime).
⚠️ That box's Caddyfile has no automatic repo→box CD yet — see the imagineering-infra
backlog (the box once drifted from the repo). Verify a route change actually landed with
`curl -s https://quiz-game.imagineering.cc/state` (a **GET** — see the redeploy note below).

**4. Redeploying an update.** There's no auto-CD for the Node app either: the box runs
whatever `server.mjs` was last copied, so it can lag `main`. The systemd env (token,
join host, bind) is unit-pinned, so a restart preserves it — only the code files change:

```bash
# from the repo root (assumes an `imagineering` ssh host → user nick)
scp skills/live-game/server.mjs skills/live-game/qr.mjs imagineering:apps/live-game/
ssh imagineering 'sudo systemctl restart live-game'
```

Verify the new build is actually live — and **GET, never HEAD, with no exceptions**:
every route handler is gated on `req.method === 'GET'`, so a `curl -I` (HEAD) returns
404 on `/` and `/play` even when the server is healthy, and on `/events` it returns
`text/plain` instead of the SSE content-type (verified on the live box during the
2026-07-19 deploy — HEAD hits the GET-only mismatch, the same instrument-lie as `/`).
Even a headers-only check must be a GET: use `-D -` to dump headers from a real GET
rather than `-I`. Confirm with GETs plus a content check that proves the *new* code
is running, not just that *a* server answers:

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://quiz-game.imagineering.cc/   # expect 200 (GET)
curl -s -N -D - --max-time 5 https://quiz-game.imagineering.cc/events -o /dev/null | grep -i content-type
                                                                               # expect text/event-stream (GET headers; -I lies here)
ssh imagineering 'grep -c host/advance apps/live-game/server.mjs'             # >0 = staging-slot build is live
shasum -a256 skills/live-game/server.mjs                                       # compare against the box to confirm parity
```

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
