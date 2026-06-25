#!/usr/bin/env node
// live-game — a zero-dependency realtime audience quiz-game server.
//
// The Google Slide (or the host's /host screen) is the shared "TV"; the
// audience's phones are the buzzers. Claude is the Game Master, driving
// questions in via POST /host/ask. Realtime fan-out uses Server-Sent Events
// (one long-lived GET /events per client) so there are NO npm dependencies —
// just Node's built-in http module.
//
// Run:  node skills/live-game/server.mjs [--port 7373]
// Then: open the printed host URL on the big screen, /play on phones.
//
// Endpoints (see README for the full contract):
//   GET  /            host / big-screen view
//   GET  /play        audience phone view (PWA-ish)
//   GET  /events      SSE stream of public game state
//   GET  /state       JSON snapshot (for the slide updater / tests)
//   POST /join        {name, playerId?, secret?}  -> {playerId, secret, name}
//   POST /vote        {playerId, secret, option}
//   POST /me          {playerId, secret}  -> own score/gain/verdict
//   POST /host/ask     {question, options[], correct, timeLimit?}  (needs host token)
//   POST /host/stage   {question, options[], correct, timeLimit?}  (needs host token) — park next Q
//   POST /host/advance                                             (needs host token) — promote staged Q live
//   POST /host/reveal                                              (needs host token)
//   POST /host/next                                                (needs host token)
//   POST /host/reset                                               (needs host token)

import http from 'node:http';
import crypto from 'node:crypto';
import os from 'node:os';
import { readFileSync } from 'node:fs';
import { argv, env } from 'node:process';

// The QR encoder is a sibling ESM served verbatim to the host browser at
// GET /qr.mjs (the host page does `await import('/qr.mjs')`). Reading it here
// keeps ONE source of truth: the same file the test harness diffs against
// `qrencode` is the one the browser runs — no inlined copy to drift.
const QR_MODULE_SRC = readFileSync(new URL('./qr.mjs', import.meta.url), 'utf8');

// ---- config ----------------------------------------------------------------
const PORT = Number(argFlag('--port') ?? env.LIVE_GAME_PORT ?? 7373);
// A weak shared secret so randoms on the network can't drive the game. Printed
// at startup; the host view reads it from the URL fragment.
const HOST_TOKEN = env.LIVE_GAME_HOST_TOKEN ?? crypto.randomBytes(16).toString('hex');
const DEFAULT_TIME_LIMIT = 20; // seconds; speed bonus decays over this window
const MIN_TIME_LIMIT = 5;
const MAX_TIME_LIMIT = 300;
// Default 3·2·1 lead-in (ms) before a question goes live, so players notice it
// starting. Per-ask `leadMs` overrides; 0 disables (tests/fast runners boot with
// LIVE_GAME_LEAD_MS=0 to vote immediately).
const DEFAULT_LEAD_MS = Math.min(Math.max(Number(env.LIVE_GAME_LEAD_MS ?? 3000) || 0, 0), 10_000);
const MAX_PLAYERS = 500; // cap in-memory growth from a join loop

// --- public-hardening knobs (see SKILL.md "Going live") ---------------------
// Per-IP fixed-window rate limit on the audience endpoints (/join, /vote).
// MAX_PLAYERS bounds memory; this bounds request CHURN from a single source.
const RATE_WINDOW_MS = Number(env.LIVE_GAME_RATE_WINDOW_MS ?? 10_000);
const RATE_MAX = Number(env.LIVE_GAME_RATE_MAX ?? 60); // requests / window / IP
// Drop an SSE consumer that has let this many bytes pile up unsent (a slow or
// hostile client that never drains). Bounds per-connection server memory.
const MAX_SSE_BUFFER = Number(env.LIVE_GAME_MAX_SSE_BUFFER ?? 1_000_000); // 1MB
// Global cap on concurrent /events streams. MAX_SSE_BUFFER bounds each stream's
// memory; this bounds the COUNT (and the per-broadcast fan-out work), so an
// attacker on a public tunnel can't hold the box open with unbounded streams.
// Generous default: a large real audience all sits behind ONE venue-NAT public
// IP, so this is deliberately a GLOBAL cap, not per-IP — a per-IP cap would
// reject the (N+1)th legitimate phone at the same venue. It bounds RESOURCE use;
// it cannot stop a determined attacker from occupying slots without authing
// /events (which would kill zero-friction joins) — a named, accepted tradeoff.
// Fail SAFE on a bad value: a non-numeric/≤0 env would make `size >= NaN` always
// false and silently DISABLE the cap (fail-open) — so fall back to the default.
const MAX_SSE_CLIENTS = (() => {
  const n = Number(env.LIVE_GAME_MAX_SSE_CLIENTS);
  return Number.isFinite(n) && n > 0 ? n : 1000;
})();
// Behind a tunnel (ngrok / Tailscale Funnel) the socket peer is the tunnel
// agent, so the real client IP arrives in X-Forwarded-For. Only trust XFF when
// explicitly told to — otherwise a client could spoof its rate-limit bucket.
const TRUST_PROXY = /^(1|true|yes)$/i.test(String(env.LIVE_GAME_TRUST_PROXY ?? ''));

// The address phones should hit. A host screen is usually opened on localhost,
// but the QR/join URL must be a LAN-reachable address — so the SERVER resolves
// its own LAN IP rather than letting the browser guess from location.origin
// (which would be localhost). Override with LIVE_GAME_JOIN_HOST when tunnelling
// (e.g. a Tailscale/ngrok hostname).
function lanIp() {
  const ifaces = Object.values(os.networkInterfaces()).flat();
  const v4 = ifaces.filter((i) => i && i.family === 'IPv4' && !i.internal);
  // Prefer private LAN ranges (192.168/10/172.16-31) over anything else.
  const priv = v4.find((i) => /^(192\.168\.|10\.|172\.(1[6-9]|2\d|3[01])\.)/.test(i.address));
  return (priv ?? v4[0])?.address ?? 'localhost';
}
const JOIN_HOST = env.LIVE_GAME_JOIN_HOST ?? `${lanIp()}:${PORT}`;
// Scheme: an explicitly-provided host (LIVE_GAME_JOIN_HOST, i.e. a tunnel like
// *.trycloudflare.com) terminates TLS at the edge, so it is HTTPS by default; a
// resolved LAN host is plain HTTP. Hardcoding http:// here used to emit an
// http:// QR for an https-only tunnel (phones hit a redirect or fail). Override
// either way with LIVE_GAME_JOIN_SCHEME.
const JOIN_SCHEME = env.LIVE_GAME_JOIN_SCHEME ?? (env.LIVE_GAME_JOIN_HOST ? 'https' : 'http');
const JOIN_URL = `${JOIN_SCHEME}://${JOIN_HOST}/play`;

// ---- game state ------------------------------------------------------------
/** @type {{phase:'lobby'|'countdown'|'question'|'reveal'|'podium', question:string,
 *   options:string[], correct:number, startedAt:number, countdownTo:number,
 *   timeLimit:number, round:number}} */
const game = {
  phase: 'lobby',
  question: '',
  options: [],
  correct: -1,
  startedAt: 0,     // when the question went LIVE (scoring clock origin)
  countdownTo: 0,   // during 'countdown', when the question WILL go live
  timeLimit: DEFAULT_TIME_LIMIT,
  round: 0,
};
// Pending countdown→question flip. Held so any pre-empting transition
// (next/reset/another ask) can cancel it — otherwise a stale timer would flip a
// reset game back into a live question (lifecycle invariant: one pending start).
let pendingStart = null;
function cancelPendingStart() { if (pendingStart) { clearTimeout(pendingStart); pendingStart = null; } }
// Single-buffer staging slot (lookahead-1): a validated next question parked by
// POST /host/stage and promoted live by POST /host/advance. Held SEPARATELY from
// `game` so it can never enter publicState() — a staged question's `correct` index
// is unobservable until it's promoted. A second stage overwrites; cleared on reset
// and consumed (set back to null) on advance.
let staged = null;
/** playerId (server-issued, opaque) -> {secret, name, score, answer, answeredAt,
 *  lastGain, streak, lastStreakBonus, rank, prevRank}
 *  `secret` is a server-minted bearer credential: it is required to vote or read
 *  one's own score, and is NEVER included in any broadcast / public state. */
const players = new Map();
/** live SSE response objects */
const sseClients = new Set();
/** per-IP request counts for the current fixed window (cleared on an interval) */
let rateCounts = new Map();

// ---- helpers ---------------------------------------------------------------
function argFlag(name) {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : undefined;
}

// Server-issued identity. playerId is the public handle (safe to store in the
// client); secret is the bearer credential proving ownership of that handle.
// Regenerate on the (astronomically unlikely) collision so the id is provably
// unique — keeps "one playerId = one identity" an exact invariant, not a
// probabilistic one.
function mintId() {
  let id;
  do { id = crypto.randomBytes(9).toString('base64url'); } while (players.has(id)); // ~12 chars
  return id;
}
function mintSecret() { return crypto.randomBytes(24).toString('base64url'); }

// Extract the bearer credential pair, enforcing the {playerId, secret} CONTRACT
// at the boundary: both must be STRINGS. Rejecting array/object/missing here
// (rather than String()-coercing) stops a payload like {"secret":["..."]} from
// smuggling a scalar past the type-strict compare. Returns null if malformed.
function creds(body) {
  const id = body?.playerId, sec = body?.secret;
  if (typeof id !== 'string' || typeof sec !== 'string') return null;
  return { id, sec };
}

// Constant-time secret compare so a peer can't probe a secret byte-by-byte via
// timing. Lengths differ → definitely not equal (and timingSafeEqual throws on
// length mismatch), so guard that first.
function secretOk(stored, given) {
  if (typeof stored !== 'string' || typeof given !== 'string') return false;
  const a = Buffer.from(stored), b = Buffer.from(given);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

// The IP we attribute a request to for rate-limiting. Behind a trusted proxy,
// the leftmost X-Forwarded-For entry is the origin client; otherwise the socket
// peer. Trusting XFF without TRUST_PROXY would let a client forge its bucket.
function clientIp(req) {
  if (TRUST_PROXY) {
    const xff = req.headers['x-forwarded-for'];
    if (xff) {
      // X-Forwarded-For is `client, proxy1, proxy2…`, each hop APPENDING. A
      // client can pre-seed a forged leftmost entry, so the leftmost is
      // attacker-controlled. The RIGHTMOST entry is what our (single, trusted)
      // proxy actually observed — use that for rate-limit attribution.
      const parts = String(xff).split(',').map((s) => s.trim()).filter(Boolean);
      if (parts.length) return parts[parts.length - 1];
    }
  }
  return req.socket?.remoteAddress ?? 'unknown';
}

// Fixed-window per-IP limiter. Returns true if the request is allowed. The
// window is reset wholesale by a timer (see boot), which also bounds the map.
function rateOk(ip) {
  const n = (rateCounts.get(ip) ?? 0) + 1;
  rateCounts.set(ip, n);
  return n <= RATE_MAX;
}

function tallies() {
  const counts = new Array(game.options.length).fill(0);
  for (const p of players.values()) {
    if (p.answer != null && p.answer >= 0 && p.answer < counts.length) counts[p.answer]++;
  }
  return counts;
}

// Full standings, sorted, with a 1-based rank stamped on each. Deterministic
// tie-break (score desc, then name asc) so equal scores don't jitter between
// broadcasts AND so rank is stable. Returns ALL players (callers slice).
function standings() {
  return [...players.values()]
    .sort((a, b) => b.score - a.score || a.name.localeCompare(b.name))
    .map((p, i) => ({ p, rank: i + 1 }));
}

function leaderboard() {
  return standings()
    .slice(0, 10)
    .map(({ p }) => ({
      name: p.name, score: p.score, lastGain: p.lastGain ?? 0, streak: p.streak ?? 0,
    }));
}

// What everyone is allowed to see. Counts and the correct answer are hidden
// while a question is live (Kahoot-style) and revealed at reveal time.
function publicState() {
  const revealed = game.phase === 'reveal';
  const ended = game.phase === 'podium';
  return {
    phase: game.phase,
    round: game.round,
    joinUrl: JOIN_URL,
    question: game.question,
    options: game.options,
    timeLimit: game.timeLimit,
    startedAt: game.startedAt,
    // When counting down to a question, when it goes live (so clients can render
    // the 3·2·1 lead-in). 0 in every other phase.
    countdownTo: game.phase === 'countdown' ? game.countdownTo : 0,
    playerCount: players.size,
    answered: [...players.values()].filter((p) => p.answer != null).length,
    counts: revealed ? tallies() : null,
    correct: revealed ? game.correct : null,
    // Standings show on reveal AND on the final podium.
    leaderboard: (revealed || ended) ? leaderboard() : null,
  };
}

function broadcast() {
  const payload = `data: ${JSON.stringify(publicState())}\n\n`;
  for (const res of sseClients) {
    // Drop a consumer that isn't draining: if the socket already has a large
    // unsent backlog, this client is slow/dead/hostile and would otherwise grow
    // server memory unbounded. res.write() returning false signals kernel-buffer
    // backpressure but is itself harmless for one frame; the buffered-bytes
    // threshold is what actually bounds memory.
    try {
      if (res.writableLength > MAX_SSE_BUFFER) {
        sseClients.delete(res);
        res.destroy();
        continue;
      }
      res.write(payload);
    } catch { sseClients.delete(res); }
  }
}

function scoreFor(answeredAt) {
  // Correct answers earn 500 base + up to 500 speed bonus that decays linearly
  // across the time limit. Answer instantly → 1000; at the buzzer → ~500.
  const elapsed = Math.max(0, (answeredAt - game.startedAt) / 1000);
  const frac = Math.min(elapsed / game.timeLimit, 1);
  return Math.round(500 + 500 * (1 - frac));
}

// Validate + normalize a question payload. Shared by /host/ask and /host/stage so
// a staged question is range-checked and clamped IDENTICALLY to a directly-asked one
// (an out-of-range `correct` would be unwinnable; an extreme timeLimit distorts
// scoring). Returns {error} on bad input, else {question, options, correct, timeLimit}.
function parseQuestion(body) {
  const options = Array.isArray(body.options) ? body.options.map(String).slice(0, 6) : [];
  if (!body.question || options.length < 2) return { error: 'need question + >=2 options' };
  const correct = Number.isInteger(body.correct) ? body.correct : -1;
  if (correct < 0 || correct >= options.length) return { error: `correct must be 0..${options.length - 1}` };
  const t = Number(body.timeLimit);
  const timeLimit = Number.isFinite(t) && t > 0
    ? Math.min(Math.max(t, MIN_TIME_LIMIT), MAX_TIME_LIMIT)
    : DEFAULT_TIME_LIMIT;
  return { question: String(body.question), options, correct, timeLimit };
}

// Take a validated question (from parseQuestion) live. Shared by /host/ask and
// /host/advance: increments the round, resets per-player answer state, and either
// goes live immediately or runs the 3·2·1 countdown lead-in (leadMs clamped 0..10s).
function goLive(q, leadMs) {
  cancelPendingStart();
  game.question = q.question;
  game.options = q.options;
  game.correct = q.correct;
  game.timeLimit = q.timeLimit;
  game.round++;
  for (const p of players.values()) { p.answer = null; p.answeredAt = 0; p.lastGain = 0; p.lastStreakBonus = 0; }
  const lead = Math.min(Math.max(Number(leadMs ?? DEFAULT_LEAD_MS) || 0, 0), 10_000);
  if (lead > 0) {
    game.phase = 'countdown';
    game.countdownTo = Date.now() + lead;
    game.startedAt = 0;
    broadcast();
    const r = game.round;
    pendingStart = setTimeout(() => {
      pendingStart = null;
      // Only flip if THIS round's countdown is still the live one.
      if (game.phase === 'countdown' && game.round === r) {
        game.phase = 'question';
        game.startedAt = Date.now();
        game.countdownTo = 0;
        broadcast();
      }
    }, lead);
  } else {
    game.phase = 'question';
    game.startedAt = Date.now();
    game.countdownTo = 0;
    broadcast();
  }
}

function readBody(req) {
  return new Promise((resolve) => {
    let buf = '';
    req.on('data', (c) => {
      buf += c;
      if (buf.length > 1e6) req.destroy(); // 1MB cap — cheap DoS guard
    });
    req.on('end', () => {
      try { resolve(buf ? JSON.parse(buf) : {}); }
      catch { resolve({}); }
    });
    // Settle the promise on abnormal termination too, so a destroyed/aborted
    // request never leaves the handler awaiting forever. resolve() is
    // idempotent — whichever fires first wins.
    req.on('error', () => resolve({}));
    req.on('close', () => resolve({}));
  });
}

function json(res, code, obj) {
  res.writeHead(code, { 'content-type': 'application/json' });
  res.end(JSON.stringify(obj));
}

function hostOk(req, body) {
  const url = new URL(req.url, 'http://x');
  const token = body?.token ?? url.searchParams.get('token');
  return token === HOST_TOKEN;
}

// ---- request router --------------------------------------------------------
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  const path = url.pathname;

  // --- static views ---
  if (req.method === 'GET' && path === '/') {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    return res.end(HOST_HTML);
  }
  if (req.method === 'GET' && path === '/play') {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    return res.end(PLAY_HTML);
  }
  if (req.method === 'GET' && path === '/qr.mjs') {
    res.writeHead(200, { 'content-type': 'text/javascript; charset=utf-8' });
    return res.end(QR_MODULE_SRC);
  }
  // Browsers auto-request /favicon.ico; without a route it 404s and clutters the
  // console. Serve a tiny inline 🎮 SVG so the tab gets an icon instead.
  if (req.method === 'GET' && path === '/favicon.ico') {
    res.writeHead(200, { 'content-type': 'image/svg+xml; charset=utf-8', 'cache-control': 'max-age=86400' });
    return res.end('<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><text y="52" font-size="52">🎮</text></svg>');
  }

  // --- SSE stream ---
  if (req.method === 'GET' && path === '/events') {
    // Admission cap (checked BEFORE the SSE headers go out, so a rejection is a
    // clean 503 not a half-open stream). See MAX_SSE_CLIENTS for why global, not
    // per-IP. EventSource will auto-retry, so a transient 503 self-heals.
    if (sseClients.size >= MAX_SSE_CLIENTS)
      return json(res, 503, { error: 'too many live connections, retry shortly' });
    res.writeHead(200, {
      'content-type': 'text/event-stream',
      // no-transform stops a CDN (Cloudflare) from buffering/compressing the
      // stream; X-Accel-Buffering disables proxy buffering (nginx convention).
      // Without these the event-stream is buffered end-to-end behind a tunnel and
      // no frame reaches the client (clients fall back to /state polling anyway).
      'cache-control': 'no-cache, no-transform',
      'x-accel-buffering': 'no',
      connection: 'keep-alive',
    });
    res.write(`data: ${JSON.stringify(publicState())}\n\n`);
    sseClients.add(res);
    // Keep-alive ping also honors the backpressure bound, so an idle-but-stuck
    // consumer can't slip past the broadcast-side drop between questions.
    const keepAlive = setInterval(() => {
      try {
        if (res.writableLength > MAX_SSE_BUFFER) { clearInterval(keepAlive); sseClients.delete(res); res.destroy(); return; }
        res.write(': ping\n\n');
      } catch {}
    }, 15000);
    req.on('close', () => { clearInterval(keepAlive); sseClients.delete(res); });
    return;
  }

  // --- JSON snapshot (for the slide updater / tests) ---
  if (req.method === 'GET' && path === '/state') {
    return json(res, 200, publicState());
  }

  // --- player join (server issues identity) ---
  if (req.method === 'POST' && path === '/join') {
    if (!rateOk(clientIp(req))) return json(res, 429, { error: 'slow down' });
    const body = await readBody(req);
    const name = String(body.name || '').trim().slice(0, 24) || 'anon';

    // Re-auth path: a returning client presents the {playerId, secret} the
    // server issued earlier. Only well-formed (string) creds whose secret
    // matches may reclaim that identity (and rename it) — this is what stops a
    // peer from hijacking another's id. Anything else falls through to a mint.
    const c = creds(body);
    const existing = c && players.get(c.id);
    if (existing && secretOk(existing.secret, c.sec)) {
      existing.name = name;
      broadcast();
      return json(res, 200, { ok: true, playerId: c.id, secret: existing.secret, name });
    }

    // Fresh identity: mint a new opaque id + secret. A stale/forged playerId
    // falls through to here and simply gets a brand-new identity (no hijack).
    if (players.size >= MAX_PLAYERS) return json(res, 503, { error: 'game full' });
    const playerId = mintId();
    const secret = mintSecret();
    players.set(playerId, { secret, name, score: 0, answer: null, answeredAt: 0, lastGain: 0, streak: 0, lastStreakBonus: 0, rank: 0, prevRank: 0 });
    broadcast();
    return json(res, 200, { ok: true, playerId, secret, name });
  }

  // --- player vote (secret-authenticated) ---
  if (req.method === 'POST' && path === '/vote') {
    if (!rateOk(clientIp(req))) return json(res, 429, { error: 'slow down' });
    const body = await readBody(req);
    const c = creds(body);
    const p = c && players.get(c.id);
    // A vote is only honored for the identity whose secret it proves. Malformed
    // creds, unknown id, OR wrong secret → same opaque 403 (don't reveal which
    // ids exist, and enforce the string contract before the compare).
    if (!c || !p || !secretOk(p.secret, c.sec))
      return json(res, 403, { error: 'bad credentials' });
    if (game.phase !== 'question') return json(res, 409, { error: 'no live question' });
    if (p.answer != null) return json(res, 200, { ok: true, locked: true }); // first answer locks
    const opt = Number(body.option);
    if (!Number.isInteger(opt) || opt < 0 || opt >= game.options.length)
      return json(res, 400, { error: 'bad option' });
    p.answer = opt;
    p.answeredAt = Date.now();
    broadcast();
    return json(res, 200, { ok: true });
  }

  // --- player self-state (secret-authenticated) ---
  // The leaderboard is broadcast with NAMES only (never playerIds — that would
  // leak the credential handle). So a phone can't reliably find itself in a
  // shared broadcast when names collide or it's outside the top 10. This endpoint
  // returns the caller's OWN authoritative score/gain/verdict, id-based and
  // authenticated, with no public leak.
  if (req.method === 'POST' && path === '/me') {
    if (!rateOk(clientIp(req))) return json(res, 429, { error: 'slow down' });
    const body = await readBody(req);
    const c = creds(body);
    const p = c && players.get(c.id);
    if (!c || !p || !secretOk(p.secret, c.sec))
      return json(res, 403, { error: 'bad credentials' });
    const revealed = game.phase === 'reveal' || game.phase === 'podium';
    return json(res, 200, {
      ok: true,
      name: p.name,
      score: p.score,
      lastGain: p.lastGain ?? 0,
      streak: p.streak ?? 0,
      streakBonus: p.lastStreakBonus ?? 0,
      rank: p.rank ?? 0,        // 1-based, computed at the last reveal
      prevRank: p.prevRank ?? 0, // rank BEFORE that reveal (for ▲/▼ movement)
      playerCount: players.size,
      answer: p.answer,
      correct: revealed ? (p.answer === game.correct) : null,
    });
  }

  // --- host: ask a new question ---
  if (req.method === 'POST' && path === '/host/ask') {
    const body = await readBody(req);
    if (!hostOk(req, body)) return json(res, 403, { error: 'bad host token' });
    const q = parseQuestion(body);
    if (q.error) return json(res, 400, { error: q.error });
    // Asking directly clears any staged question — the host chose this one instead,
    // so a stale parked question must not linger and surprise the next advance.
    staged = null;
    goLive(q, body.leadMs);
    return json(res, 200, { ok: true, round: game.round });
  }

  // --- host: stage the NEXT question (lookahead-1 prefetch, parked server-side) ---
  // Decouples question GENERATION from advancing: the Game Master composes Q(n+1)
  // during Q(n)'s answer window and parks it here, so /host/advance later promotes
  // it live in one cheap call with zero compose latency. Validated/clamped exactly
  // like /host/ask. Single-buffer — a second stage overwrites. Held off publicState
  // (anti-peek): the parked `correct` is unobservable until advanced.
  if (req.method === 'POST' && path === '/host/stage') {
    const body = await readBody(req);
    if (!hostOk(req, body)) return json(res, 403, { error: 'bad host token' });
    const q = parseQuestion(body);
    if (q.error) return json(res, 400, { error: q.error });
    staged = q;
    return json(res, 200, { ok: true, staged: true });
  }

  // --- host: advance (promote the staged question live) ---
  // Host-triggered (token-gated), NOT auto-fired on reveal: advancing stays a
  // deliberate beat the operator controls (full autonomy once collapsed a room by
  // outrunning a casually-engaged audience). Consumes the slot.
  if (req.method === 'POST' && path === '/host/advance') {
    const body = await readBody(req);
    if (!hostOk(req, body)) return json(res, 403, { error: 'bad host token' });
    if (!staged) return json(res, 409, { error: 'nothing staged' });
    // Phase guard: refuse to advance over a LIVE or counting-down question.
    // goLive() wipes every player's in-flight answer (and bumps the round), so a
    // /host/reveal meant for the current question would then score the promoted
    // one instead — the players' answers silently lost. Advancing is a
    // between-questions beat (from reveal/lobby/podium), never mid-question; the
    // host must reveal (or /next) first. (Anti-peek stays intact regardless — a
    // staged question is unobservable until this promotion either way.)
    if (game.phase === 'question' || game.phase === 'countdown')
      return json(res, 409, { error: 'reveal the live question before advancing' });
    const q = staged;
    staged = null;
    goLive(q, body.leadMs);
    return json(res, 200, { ok: true, round: game.round, advanced: true });
  }

  // --- host: reveal answer + award points ---
  if (req.method === 'POST' && path === '/host/reveal') {
    const body = await readBody(req);
    if (!hostOk(req, body)) return json(res, 403, { error: 'bad host token' });
    if (game.phase !== 'question') return json(res, 409, { error: 'no live question' });
    cancelPendingStart();
    // Snapshot rank BEFORE awarding so the phone can show movement (▲/▼).
    for (const { p, rank } of standings()) p.prevRank = rank;
    for (const p of players.values()) {
      if (p.answer === game.correct && game.correct >= 0) {
        p.streak = (p.streak ?? 0) + 1;
        // Streak bonus rewards consecutive correct: +100 per extra in the run,
        // capped at +500 (so 2nd→+100, 3rd→+200 … 6th+→+500). On top of the
        // 500 base + up-to-500 speed bonus.
        const bonus = Math.min((p.streak - 1) * 100, 500);
        const gain = scoreFor(p.answeredAt) + bonus;
        p.score += gain;
        p.lastGain = gain;
        p.lastStreakBonus = bonus;
      } else {
        p.streak = 0;
        p.lastGain = 0;
        p.lastStreakBonus = 0;
      }
    }
    // Stamp the new rank after awarding.
    for (const { p, rank } of standings()) p.rank = rank;
    game.phase = 'reveal';
    broadcast();
    return json(res, 200, { ok: true, counts: tallies(), leaderboard: leaderboard() });
  }

  // --- host: next (back to lobby, keep scores) ---
  if (req.method === 'POST' && path === '/host/next') {
    const body = await readBody(req);
    if (!hostOk(req, body)) return json(res, 403, { error: 'bad host token' });
    cancelPendingStart();
    game.phase = 'lobby';
    game.question = '';
    game.options = [];
    game.correct = -1;
    game.startedAt = 0;
    game.countdownTo = 0;
    broadcast();
    return json(res, 200, { ok: true });
  }

  // --- host: end (final podium; keeps scores so /me + leaderboard stay valid) ---
  if (req.method === 'POST' && path === '/host/end') {
    const body = await readBody(req);
    if (!hostOk(req, body)) return json(res, 403, { error: 'bad host token' });
    cancelPendingStart();
    // End is a terminal state — drop any parked question so a stray /host/advance
    // can't silently restart the game from the podium.
    staged = null;
    // Make sure ranks reflect final scores even if /end follows a non-reveal.
    for (const { p, rank } of standings()) { p.prevRank = p.rank || rank; p.rank = rank; }
    game.phase = 'podium';
    game.question = '';
    game.options = [];
    game.correct = -1;
    game.startedAt = 0;
    game.countdownTo = 0;
    broadcast();
    return json(res, 200, { ok: true, leaderboard: leaderboard() });
  }

  // --- host: reset (wipe scores + players) ---
  if (req.method === 'POST' && path === '/host/reset') {
    const body = await readBody(req);
    if (!hostOk(req, body)) return json(res, 403, { error: 'bad host token' });
    cancelPendingStart();
    staged = null;
    players.clear();
    game.phase = 'lobby';
    game.question = '';
    game.options = [];
    game.correct = -1;
    game.round = 0;
    game.startedAt = 0;
    game.countdownTo = 0;
    broadcast();
    return json(res, 200, { ok: true });
  }

  res.writeHead(404, { 'content-type': 'text/plain' });
  res.end('not found');
});

// ---- embedded views (kept inline so the prototype is a single file) --------
const HOST_HTML = /* html */ `<!doctype html><html><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>Live Game — Host</title><link rel="icon" href="/favicon.ico" type="image/svg+xml"><style>
 *{box-sizing:border-box}body{margin:0;font:16px/1.4 system-ui,sans-serif;background:#16161e;color:#eee}
 .wrap{max-width:900px;margin:0 auto;padding:24px}
 h1{font-size:20px;color:#6cf;margin:0 0 4px}
 .join{display:flex;gap:20px;align-items:center;background:#1f1f2b;border-radius:12px;padding:16px;margin:16px 0}
 .qr{background:#fff;border-radius:8px;padding:8px;line-height:0;flex:0 0 auto}
 .qr svg{display:block;width:200px;height:200px}
 .qr:empty{display:none}
 .q{font-size:34px;font-weight:700;margin:18px 0}
 .opt{display:flex;align-items:center;gap:12px;margin:10px 0;font-size:22px}
 .bar{height:34px;border-radius:6px;background:#3a3a52;min-width:4px;transition:width .4s}
 .opt.correct .bar{background:#3ddc84}.opt .label{width:34px;text-align:center;font-weight:700;color:#6cf}
 .opt .cnt{width:48px;text-align:right;color:#9aa}
 .meta{color:#9aa;margin:8px 0}
 .lb{margin-top:24px}.lb div.row{display:flex;justify-content:space-between;padding:6px 10px;border-bottom:1px solid #2a2a3a}
 .lb .g{color:#3ddc84;animation:pop .5s ease}
 .lb .streak{color:#ffb74d;font-size:15px}
 small{color:#778}
 /* countdown + live timer */
 .timer{font-size:22px;font-weight:800;color:#ffd54f;float:right}
 .timer.low{color:#ff5252}
 .getready{text-align:center;margin:30px 0}
 .getready .lead{font-size:26px;color:#9aa;letter-spacing:3px;text-transform:uppercase}
 .getready .num{font-size:120px;font-weight:900;color:#6cf;line-height:1;animation:pop .6s ease}
 @keyframes pop{0%{transform:scale(.4);opacity:0}60%{transform:scale(1.15)}100%{transform:scale(1);opacity:1}}
 /* podium */
 .podium{display:flex;justify-content:center;align-items:flex-end;gap:14px;margin:30px 0}
 .pod{background:#1f1f2b;border-radius:12px 12px 0 0;padding:14px;text-align:center;min-width:120px}
 .pod .nm{font-weight:800;font-size:22px;margin-bottom:6px}.pod .sc{color:#9aa}
 .pod.p1{height:200px;background:linear-gradient(#3a2f00,#1f1f2b)}.pod.p2{height:160px}.pod.p3{height:130px}
 .pod .medal{font-size:40px}
</style></head><body><div class=wrap>
 <h1>🎮 Live Game — Host screen</h1>
 <div class=join>
   <div id=qr class=qr></div>
   <div style="flex:1"><div style="font-size:14px;color:#9aa">Players join at</div>
   <div id=joinurl style="font-size:40px;font-weight:800;color:#fff;letter-spacing:.5px"></div>
   <div class=meta><span id=pc>0</span> players · round <span id=rd>0</span></div></div>
 </div>
 <div id=stage></div>
 <div class=lb id=lb></div>
 <small>Game Master drives questions via <code>POST /host/ask</code>. Host token in this page's URL.</small>
</div><script>
const stage = document.getElementById('stage');
let joinSet = false;
// The QR encoder is served by THIS server at /qr.mjs (no external call, no npm
// dep). We load it once; if the join URL arrives before it finishes loading, the
// pending URL is drawn as soon as the module resolves.
let qrLib = null, pendingQr = null;
import('/qr.mjs').then(m => { qrLib = m; if(pendingQr) drawQr(pendingQr); })
  .catch(e => console.error('QR module load failed', e));
function drawQr(joinUrl){
  if(!qrLib){ pendingQr = joinUrl; return; }
  try {
    // ECC level Q tolerates a projector glare / phone-camera angle better than L.
    document.getElementById('qr').innerHTML = qrLib.qrSvg(qrLib.qrMatrix(joinUrl, 'Q'));
  } catch(e){ console.error('QR render failed', e); }
}
function setJoin(joinUrl){
  // The server resolves a LAN-reachable join URL; do NOT use location.origin
  // (the host screen is usually on localhost, which a phone can't reach).
  if(joinSet || !joinUrl) return; joinSet = true;
  document.getElementById('joinurl').textContent = joinUrl.replace(/^https?:\\/\\//,'');
  drawQr(joinUrl);
}
let last=null;
const letters='ABCDEF';
function secsLeft(s){ return Math.max(0, Math.ceil((s.startedAt + s.timeLimit*1000 - Date.now())/1000)); }
function render(s){
  if(!s) return; last=s;
  setJoin(s.joinUrl);
  document.getElementById('pc').textContent = s.playerCount;
  document.getElementById('rd').textContent = s.round;
  const lb=document.getElementById('lb');
  if(s.phase==='lobby'){ stage.innerHTML='<div class=q>Waiting for the next question…</div>'; lb.innerHTML=''; return; }
  if(s.phase==='countdown'){
    const n=Math.max(0,Math.ceil((s.countdownTo-Date.now())/1000));
    stage.innerHTML='<div class=q>'+esc(s.question)+'</div>'+
      '<div class=getready><div class=lead>Get ready</div><div class=num>'+(n||'GO')+'</div></div>';
    lb.innerHTML=''; return;
  }
  if(s.phase==='podium'){
    const top=(s.leaderboard||[]).slice(0,3), rest=(s.leaderboard||[]).slice(3);
    const order=[1,0,2], medals=['🥇','🥈','🥉'];
    let pod='<div class=podium>'+order.filter(i=>top[i]).map(i=>
      '<div class="pod p'+(i+1)+'"><div class=medal>'+medals[i]+'</div>'+
      '<div class=nm>'+esc(top[i].name)+'</div><div class=sc>'+top[i].score+' pts</div></div>').join('')+'</div>';
    stage.innerHTML='<div class=q style="text-align:center">🏁 Final results</div>'+pod;
    lb.innerHTML=rest.length?('<h1>Also played</h1>'+rest.map((p,i)=>
      '<div class=row><span>'+(i+4)+'. '+esc(p.name)+'</span><span>'+p.score+' pts</span></div>').join('')):'';
    return;
  }
  // countdown-less live question OR reveal
  const total=(s.counts||[]).reduce((a,b)=>a+b,0)||1;
  const timer = s.phase==='question'
    ? '<span class="timer'+(secsLeft(s)<=5?' low':'')+'">⏱ '+secsLeft(s)+'</span>' : '';
  let html='<div class=q>'+timer+esc(s.question)+'</div>';
  html+='<div class=meta>'+(s.phase==='reveal'?'Revealed':(s.answered+' / '+s.playerCount+' answered'))+'</div>';
  s.options.forEach((o,i)=>{
    const c=(s.counts&&s.counts[i])||0;
    const w=s.counts? Math.round(c/total*600):4;
    const isC=s.phase==='reveal'&&s.correct===i;
    html+='<div class="opt'+(isC?' correct':'')+'"><span class=label>'+letters[i]+'</span>'+
          '<span class=bar style="width:'+w+'px"></span>'+
          '<span>'+esc(o)+'</span>'+(s.counts?'<span class=cnt>'+c+'</span>':'')+'</div>';
  });
  stage.innerHTML=html;
  if(s.leaderboard){ lb.innerHTML='<h1>🏆 Leaderboard</h1>'+s.leaderboard.map(p=>
    '<div class=row><span>'+esc(p.name)+(p.streak>1?' <span class=streak>🔥'+p.streak+'</span>':'')+'</span>'+
    '<span>'+p.score+(p.lastGain?' <span class=g>(+'+p.lastGain+')</span>':'')+'</span></div>').join(''); }
  else lb.innerHTML='';
}
function esc(s){return String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))}
// Re-render once a second while a timer/countdown is ticking (cheap; bars only
// exist at reveal, so nothing animated is disrupted).
setInterval(()=>{ if(last&&(last.phase==='question'||last.phase==='countdown')) render(last); },300);
// Realtime via SSE only — EventSource auto-reconnects on a drop and the server
// re-sends a full snapshot on connect, so no polling is needed.
const ev=new EventSource('/events'); ev.onmessage=e=>render(JSON.parse(e.data));
</script></body></html>`;

const PLAY_HTML = /* html */ `<!doctype html><html><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>Live Game</title><link rel="icon" href="/favicon.ico" type="image/svg+xml"><style>
 *{box-sizing:border-box}body{margin:0;font:18px/1.4 system-ui,sans-serif;background:#16161e;color:#eee}
 .wrap{max-width:480px;margin:0 auto;padding:20px;min-height:100vh;display:flex;flex-direction:column}
 input{font-size:20px;padding:12px;border-radius:10px;border:1px solid #444;background:#22222e;color:#fff;width:100%}
 button{font-size:20px;padding:14px;border:0;border-radius:12px;background:#3a6;color:#fff;width:100%;margin-top:10px}
 .q{font-size:24px;font-weight:700;margin:10px 0 16px}
 .opt{font-size:22px;padding:18px;border-radius:14px;margin:8px 0;border:0;color:#fff;width:100%;text-align:left}
 .o0{background:#e44}.o1{background:#36c}.o2{background:#3a6}.o3{background:#d92}.o4{background:#94c}.o5{background:#2aa}
 .opt:disabled{opacity:.5}
 .big{font-size:28px;text-align:center;margin-top:30px}
 .me{color:#9aa;text-align:center;margin-top:auto;padding-top:16px}
 .gain{color:#3ddc84;font-weight:700}
 .qhead{display:flex;justify-content:space-between;align-items:center;margin:10px 0}
 .qtimer{font-size:30px;font-weight:900;color:#ffd54f}.qtimer.low{color:#ff5252}
 .count{font-size:120px;font-weight:900;text-align:center;color:#6cf;margin:24px 0;animation:pop .6s ease}
 .lead{text-align:center;color:#9aa;letter-spacing:3px;text-transform:uppercase;font-size:18px}
 @keyframes pop{0%{transform:scale(.4);opacity:0}60%{transform:scale(1.15)}100%{transform:scale(1);opacity:1}}
 .card{text-align:center;margin-top:24px;padding:24px;border-radius:18px;background:#1f1f2b;animation:pop .5s ease}
 .card.win{background:linear-gradient(#143d22,#1f1f2b)}.card.lose{background:linear-gradient(#3d1414,#1f1f2b)}
 .card .verdict{font-size:30px;font-weight:800}
 .card .pts{font-size:44px;font-weight:900;color:#3ddc84;margin:8px 0}
 .card .sub{color:#cbd}.card .streak{color:#ffb74d;font-weight:700}
 .card .rank{font-size:22px;margin-top:8px}.card .up{color:#3ddc84}.card .down{color:#ff8a80}
</style></head><body><div class=wrap id=app></div><script>
// Identity is SERVER-issued: we hold an opaque playerId + a secret credential,
// both minted by /join and persisted locally. We never invent our own id — a
// self-asserted id is exactly the hijack vector this view was hardened against.
let playerId = localStorage.getItem('lg-id') || '';
let secret = localStorage.getItem('lg-secret') || '';
let name = localStorage.getItem('lg-name') || '';
let myAnswer = null, lastRound = -1, lastPhase = '', mySelf = null;
// Guard so a /state poll or SSE tick can't rebuild the join <input> while the
// player is typing in it (innerHTML= would drop focus + wipe the field — it
// "jumped to the button"). Render the join form once; the user's typing owns it.
let joinShown = false;
const app=document.getElementById('app');
function esc(s){return String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))}
async function post(p,b){return fetch(p,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(b)})}

// Join (or re-auth). The server returns our identity; store whatever it issues.
async function join(){
  const r=await post('/join',{name,playerId,secret});
  const d=await r.json().catch(()=>null);
  if(d&&d.playerId){ playerId=d.playerId; secret=d.secret;
    localStorage.setItem('lg-id',playerId); localStorage.setItem('lg-secret',secret); }
  return d;
}
// Fetch OUR authoritative score/verdict (id-based, authenticated — works even
// with duplicate names or when we're outside the broadcast top-10). Retries a
// couple of times so a transient throttle/network blip doesn't strand the
// reveal view on its pending state.
let meFetching=false;
async function fetchMe(tries){
  if(!playerId||!secret||meFetching) return;
  meFetching=true;
  try{
    const r=await post('/me',{playerId,secret});
    const d=await r.json().catch(()=>null);
    if(d&&d.ok){ mySelf=d; render(lastState); return; }
  }catch(e){}
  finally{ meFetching=false; }
  if((tries||0)<3) setTimeout(()=>fetchMe((tries||0)+1), 400);
}

function joinView(){
  app.innerHTML='<h2>🎮 Join the game</h2><input id=nm placeholder="Your name" value="'+esc(name)+'">'+
    '<button id=go>Join</button>';
  document.getElementById('go').onclick=async()=>{
    name=document.getElementById('nm').value.trim()||'anon';
    localStorage.setItem('lg-name',name);
    await join(); render(lastState);
  };
}
let lastState=null;
function joined(){ return !!playerId && !!name; }
function secsLeft(s){ return Math.max(0,Math.ceil((s.startedAt+s.timeLimit*1000-Date.now())/1000)); }
function ord(n){ const t=n%100; if(t>=11&&t<=13) return n+'th'; return n+({1:'st',2:'nd',3:'rd'}[n%10]||'th'); }
function render(s){
  lastState=s; if(!s) return;
  if(!joined()){ if(!joinShown){ joinView(); joinShown=true; } return; }
  joinShown=false;
  if(s.round!==lastRound){ myAnswer=null; mySelf=null; lastRound=s.round; }
  if(s.phase!==lastPhase){
    lastPhase=s.phase;
    if(s.phase==='reveal'||s.phase==='podium') fetchMe();
    // Buzz the phone when a question actually goes live so a heads-down player
    // doesn't miss it (the attention failure we watched in the first play-test).
    if(s.phase==='question'&&navigator.vibrate) navigator.vibrate(180);
    if(s.phase==='countdown'&&navigator.vibrate) navigator.vibrate(60);
  }
  const letters='ABCDEF';
  if(s.phase==='lobby'){ app.innerHTML='<div class=big>Hang tight…<br>next question incoming</div>'+meTag(); return; }
  if(s.phase==='countdown'){
    const n=Math.max(0,Math.ceil((s.countdownTo-Date.now())/1000));
    app.innerHTML='<div class=q>'+esc(s.question)+'</div><div class=lead>Get ready</div>'+
      '<div class=count>'+(n||'GO')+'</div>'+meTag();
    return;
  }
  if(s.phase==='question'){
    const n=secsLeft(s);
    let html='<div class=qhead><span id=qt class="qtimer'+(n<=5?' low':'')+'">⏱ '+n+'</span></div>'+
      '<div class=q>'+esc(s.question)+'</div>';
    s.options.forEach((o,i)=>{ html+='<button class="opt o'+i+'" data-i="'+i+'" '+(myAnswer!=null?'disabled':'')+'>'+
      letters[i]+'. '+esc(o)+'</button>'; });
    if(myAnswer!=null) html+='<div class=big>✅ Locked in '+letters[myAnswer]+'</div>';
    app.innerHTML=html+meTag();
    app.querySelectorAll('.opt').forEach(b=>b.onclick=async()=>{
      myAnswer=Number(b.dataset.i);
      if(navigator.vibrate) navigator.vibrate(40);
      render(s); await post('/vote',{playerId,secret,option:myAnswer});
    });
    return;
  }
  if(s.phase==='reveal'){
    // Verdict/gain/rank are ALWAYS the SERVER's (mySelf, via /me), never the local
    // click cache (which can be optimistically set for a throttled vote). Show a
    // pending state until /me resolves rather than flash a wrong verdict.
    if(!mySelf){ if(!meFetching) fetchMe(); app.innerHTML='<div class=big>⏳ Checking your answer…</div>'+meTag(); return; }
    app.innerHTML=card(s)+meTag();
    return;
  }
  if(s.phase==='podium'){
    if(!mySelf){ if(!meFetching) fetchMe(); app.innerHTML='<div class=big>🏁 Final results…</div>'+meTag(); return; }
    const medal=mySelf.rank===1?'🥇':mySelf.rank===2?'🥈':mySelf.rank===3?'🥉':'🎉';
    app.innerHTML='<div class="card win"><div class=verdict>'+medal+' '+ord(mySelf.rank)+' place</div>'+
      '<div class=pts>'+mySelf.score+'</div><div class=sub>final score · '+mySelf.playerCount+' players</div></div>'+meTag();
    return;
  }
}
// The post-reveal personal card: verdict, points won (with streak-bonus split),
// streak flame, and rank movement vs the previous round.
function card(s){
  const letters='ABCDEF';
  const win=mySelf.correct, none=mySelf.answer==null;
  const cls=none?'':(win?' win':' lose');
  let h='<div class="card'+cls+'">';
  h+='<div class=verdict>'+(none?'⏳ No answer':(win?'🎉 Correct!':'❌ '+letters[s.correct]+' was right'))+'</div>';
  if(mySelf.lastGain){
    h+='<div class=pts>+'+mySelf.lastGain+'</div>';
    if(mySelf.streakBonus>0) h+='<div class=sub>incl. <span class=streak>🔥 +'+mySelf.streakBonus+' streak</span></div>';
  }
  if(win&&mySelf.streak>1) h+='<div class=sub><span class=streak>🔥 '+mySelf.streak+' in a row!</span></div>';
  if(mySelf.rank){
    let mv='';
    if(mySelf.prevRank>0&&mySelf.rank<mySelf.prevRank) mv=' <span class=up>▲ up from '+ord(mySelf.prevRank)+'</span>';
    else if(mySelf.prevRank>0&&mySelf.rank>mySelf.prevRank) mv=' <span class=down>▼ down from '+ord(mySelf.prevRank)+'</span>';
    h+='<div class=rank>You\\'re '+ord(mySelf.rank)+' of '+mySelf.playerCount+mv+'</div>';
  }
  return h+'</div>';
}
function meTag(){ return '<div class=me>'+esc(name)+(mySelf?' · '+mySelf.score+' pts':'')+'</div>'; }
// Tick the live timer/countdown without a full rebuild during a question (so taps
// aren't disrupted); countdown is just a number, safe to fully re-render.
setInterval(()=>{
  if(!lastState) return;
  if(lastState.phase==='countdown') render(lastState);
  else if(lastState.phase==='question'){ const t=document.getElementById('qt'); if(t){ const n=secsLeft(lastState); t.textContent='⏱ '+n; t.className='qtimer'+(n<=5?' low':''); } }
},300);
// Realtime via SSE only — EventSource auto-reconnects on a drop and the server
// re-sends a full snapshot on connect, so no polling is needed.
const ev=new EventSource('/events'); ev.onmessage=e=>render(JSON.parse(e.data));
if(joined()) join();   // re-auth a returning player on load
</script></body></html>`;

// ---- boot ------------------------------------------------------------------
// Reset the per-IP rate window wholesale on a timer. Swapping the map (rather
// than mutating) also bounds its growth — stale IPs vanish each window. unref()
// so this timer never by itself keeps the process alive.
setInterval(() => { rateCounts = new Map(); }, RATE_WINDOW_MS).unref();

// Bind address. Defaults to all interfaces (LAN play: phones hit the Mac's IP).
// Behind a reverse proxy (e.g. Caddy on a server) set LIVE_GAME_BIND=127.0.0.1
// so the port isn't reachable except through the proxy.
const BIND = env.LIVE_GAME_BIND || '0.0.0.0';
server.listen(PORT, BIND, () => {
  const host = `http://localhost:${PORT}`;
  console.log(`\n🎮 live-game running`);
  console.log(`   Host screen : ${host}/#${HOST_TOKEN}`);
  console.log(`   Phones join : ${JOIN_URL}   ← LAN-reachable (QR encodes this)`);
  console.log(`   Host token  : ${HOST_TOKEN}  (POST /host/ask?token=${HOST_TOKEN})`);
  console.log(`   Snapshot    : ${host}/state\n`);
});

export { server, game, players };
