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
//   POST /host/ask    {question, options[], correct, timeLimit?}   (needs host token)
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
const MAX_PLAYERS = 500; // cap in-memory growth from a join loop

// --- public-hardening knobs (see SKILL.md "Going live") ---------------------
// Per-IP fixed-window rate limit on the audience endpoints (/join, /vote).
// MAX_PLAYERS bounds memory; this bounds request CHURN from a single source.
const RATE_WINDOW_MS = Number(env.LIVE_GAME_RATE_WINDOW_MS ?? 10_000);
const RATE_MAX = Number(env.LIVE_GAME_RATE_MAX ?? 60); // requests / window / IP
// Drop an SSE consumer that has let this many bytes pile up unsent (a slow or
// hostile client that never drains). Bounds per-connection server memory.
const MAX_SSE_BUFFER = Number(env.LIVE_GAME_MAX_SSE_BUFFER ?? 1_000_000); // 1MB
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
/** @type {{phase:'lobby'|'question'|'reveal', question:string, options:string[],
 *   correct:number, startedAt:number, timeLimit:number, round:number}} */
const game = {
  phase: 'lobby',
  question: '',
  options: [],
  correct: -1,
  startedAt: 0,
  timeLimit: DEFAULT_TIME_LIMIT,
  round: 0,
};
/** playerId (server-issued, opaque) -> {secret, name, score, answer, answeredAt, lastGain}
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

function leaderboard() {
  return [...players.values()]
    .map((p) => ({ name: p.name, score: p.score, lastGain: p.lastGain ?? 0 }))
    // Deterministic tie-break (score desc, then name asc) so equal scores
    // don't jitter between broadcasts.
    .sort((a, b) => b.score - a.score || a.name.localeCompare(b.name))
    .slice(0, 10);
}

// What everyone is allowed to see. Counts and the correct answer are hidden
// while a question is live (Kahoot-style) and revealed at reveal time.
function publicState() {
  const revealed = game.phase === 'reveal';
  return {
    phase: game.phase,
    round: game.round,
    joinUrl: JOIN_URL,
    question: game.question,
    options: game.options,
    timeLimit: game.timeLimit,
    startedAt: game.startedAt,
    playerCount: players.size,
    answered: [...players.values()].filter((p) => p.answer != null).length,
    counts: revealed ? tallies() : null,
    correct: revealed ? game.correct : null,
    leaderboard: revealed ? leaderboard() : null,
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

  // --- SSE stream ---
  if (req.method === 'GET' && path === '/events') {
    res.writeHead(200, {
      'content-type': 'text/event-stream',
      'cache-control': 'no-cache',
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
    players.set(playerId, { secret, name, score: 0, answer: null, answeredAt: 0, lastGain: 0 });
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
    const revealed = game.phase === 'reveal';
    return json(res, 200, {
      ok: true,
      name: p.name,
      score: p.score,
      lastGain: p.lastGain ?? 0,
      answer: p.answer,
      correct: revealed ? (p.answer === game.correct) : null,
    });
  }

  // --- host: ask a new question ---
  if (req.method === 'POST' && path === '/host/ask') {
    const body = await readBody(req);
    if (!hostOk(req, body)) return json(res, 403, { error: 'bad host token' });
    const options = Array.isArray(body.options) ? body.options.map(String).slice(0, 6) : [];
    if (!body.question || options.length < 2)
      return json(res, 400, { error: 'need question + >=2 options' });
    // Range-check correct against the options actually given — an out-of-range
    // index would make the question unwinnable (no one can match it at reveal).
    const correct = Number.isInteger(body.correct) ? body.correct : -1;
    if (correct < 0 || correct >= options.length)
      return json(res, 400, { error: `correct must be 0..${options.length - 1}` });
    game.phase = 'question';
    game.question = String(body.question);
    game.options = options;
    game.correct = correct;
    // Clamp timeLimit to a sane window so an extreme value can't distort scoring.
    const t = Number(body.timeLimit);
    game.timeLimit = Number.isFinite(t) && t > 0
      ? Math.min(Math.max(t, MIN_TIME_LIMIT), MAX_TIME_LIMIT)
      : DEFAULT_TIME_LIMIT;
    game.startedAt = Date.now();
    game.round++;
    for (const p of players.values()) { p.answer = null; p.answeredAt = 0; p.lastGain = 0; }
    broadcast();
    return json(res, 200, { ok: true, round: game.round });
  }

  // --- host: reveal answer + award points ---
  if (req.method === 'POST' && path === '/host/reveal') {
    const body = await readBody(req);
    if (!hostOk(req, body)) return json(res, 403, { error: 'bad host token' });
    if (game.phase !== 'question') return json(res, 409, { error: 'no live question' });
    for (const p of players.values()) {
      if (p.answer === game.correct && game.correct >= 0) {
        const gain = scoreFor(p.answeredAt);
        p.score += gain;
        p.lastGain = gain;
      } else {
        p.lastGain = 0;
      }
    }
    game.phase = 'reveal';
    broadcast();
    return json(res, 200, { ok: true, counts: tallies(), leaderboard: leaderboard() });
  }

  // --- host: next (back to lobby, keep scores) ---
  if (req.method === 'POST' && path === '/host/next') {
    const body = await readBody(req);
    if (!hostOk(req, body)) return json(res, 403, { error: 'bad host token' });
    game.phase = 'lobby';
    game.question = '';
    game.options = [];
    game.correct = -1;
    broadcast();
    return json(res, 200, { ok: true });
  }

  // --- host: reset (wipe scores + players) ---
  if (req.method === 'POST' && path === '/host/reset') {
    const body = await readBody(req);
    if (!hostOk(req, body)) return json(res, 403, { error: 'bad host token' });
    players.clear();
    game.phase = 'lobby';
    game.question = '';
    game.options = [];
    game.correct = -1;
    game.round = 0;
    broadcast();
    return json(res, 200, { ok: true });
  }

  res.writeHead(404, { 'content-type': 'text/plain' });
  res.end('not found');
});

// ---- embedded views (kept inline so the prototype is a single file) --------
const HOST_HTML = /* html */ `<!doctype html><html><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>Live Game — Host</title><style>
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
 .lb{margin-top:24px}.lb div{display:flex;justify-content:space-between;padding:6px 10px;border-bottom:1px solid #2a2a3a}
 .lb .g{color:#3ddc84}
 small{color:#778}
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
function render(s){
  setJoin(s.joinUrl);
  document.getElementById('pc').textContent = s.playerCount;
  document.getElementById('rd').textContent = s.round;
  if(s.phase==='lobby'){ stage.innerHTML='<div class=q>Waiting for the next question…</div>'; }
  else {
    const total = (s.counts||[]).reduce((a,b)=>a+b,0) || 1;
    const letters='ABCDEF';
    let html='<div class=q>'+esc(s.question)+'</div>';
    html += '<div class=meta>'+(s.phase==='reveal'?'Revealed':(s.answered+' / '+s.playerCount+' answered'))+'</div>';
    s.options.forEach((o,i)=>{
      const c=(s.counts&&s.counts[i])||0;
      const w=s.counts? Math.round(c/total*600):4;
      const isC = s.phase==='reveal' && s.correct===i;
      html+='<div class="opt'+(isC?' correct':'')+'"><span class=label>'+letters[i]+'</span>'+
            '<span class=bar style="width:'+w+'px"></span>'+
            '<span>'+esc(o)+'</span>'+(s.counts?'<span class=cnt>'+c+'</span>':'')+'</div>';
    });
    stage.innerHTML=html;
  }
  const lb=document.getElementById('lb');
  if(s.leaderboard){ lb.innerHTML='<h1>🏆 Leaderboard</h1>'+s.leaderboard.map(p=>
    '<div><span>'+esc(p.name)+'</span><span>'+p.score+(p.lastGain?' <span class=g>(+'+p.lastGain+')</span>':'')+'</span></div>').join(''); }
  else lb.innerHTML='';
}
function esc(s){return String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))}
const ev=new EventSource('/events'); ev.onmessage=e=>render(JSON.parse(e.data));
</script></body></html>`;

const PLAY_HTML = /* html */ `<!doctype html><html><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>Live Game</title><style>
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
</style></head><body><div class=wrap id=app></div><script>
// Identity is SERVER-issued: we hold an opaque playerId + a secret credential,
// both minted by /join and persisted locally. We never invent our own id — a
// self-asserted id is exactly the hijack vector this view was hardened against.
let playerId = localStorage.getItem('lg-id') || '';
let secret = localStorage.getItem('lg-secret') || '';
let name = localStorage.getItem('lg-name') || '';
let myAnswer = null, lastRound = -1, lastPhase = '', mySelf = null;
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
function render(s){
  lastState=s; if(!s) return;
  if(!joined()){ joinView(); return; }
  if(s.round!==lastRound){ myAnswer=null; mySelf=null; lastRound=s.round; }
  // On entering reveal, pull our own authoritative score once.
  if(s.phase!==lastPhase){ lastPhase=s.phase; if(s.phase==='reveal') fetchMe(); }
  const letters='ABCDEF';
  if(s.phase==='lobby'){ app.innerHTML='<div class=big>Hang tight…<br>next question incoming</div>'+meTag(); return; }
  if(s.phase==='question'){
    let html='<div class=q>'+esc(s.question)+'</div>';
    s.options.forEach((o,i)=>{ html+='<button class="opt o'+i+'" data-i="'+i+'" '+(myAnswer!=null?'disabled':'')+'>'+
      letters[i]+'. '+esc(o)+'</button>'; });
    if(myAnswer!=null) html+='<div class=big>✅ Locked in '+letters[myAnswer]+'</div>';
    app.innerHTML=html+meTag();
    app.querySelectorAll('.opt').forEach(b=>b.onclick=async()=>{
      myAnswer=Number(b.dataset.i); render(s); await post('/vote',{playerId,secret,option:myAnswer});
    });
    return;
  }
  if(s.phase==='reveal'){
    // Verdict + gain are ALWAYS the SERVER's (mySelf, via /me) — never the local
    // click cache, which can be optimistically set for a vote the server
    // throttled/never recorded. Until /me resolves we show a pending state
    // rather than risk a wrong correct/incorrect flash.
    if(!mySelf){ if(!meFetching) fetchMe(); app.innerHTML='<div class=big>⏳ Checking your answer…</div>'+meTag(); return; }
    app.innerHTML='<div class=big>'+(mySelf.answer==null?'⏳ No answer':(mySelf.correct?'🎉 Correct!':'❌ '+letters[s.correct]+' was right'))+
      (mySelf.lastGain?'<div class=gain>+'+mySelf.lastGain+'</div>':'')+'</div>'+meTag();
    return;
  }
}
function meTag(){ return '<div class=me>'+esc(name)+(mySelf?' · '+mySelf.score+' pts':'')+'</div>'; }
const ev=new EventSource('/events'); ev.onmessage=e=>render(JSON.parse(e.data));
// Returning player (already has identity + name): re-auth on load.
if(joined()) join();
</script></body></html>`;

// ---- boot ------------------------------------------------------------------
// Reset the per-IP rate window wholesale on a timer. Swapping the map (rather
// than mutating) also bounds its growth — stale IPs vanish each window. unref()
// so this timer never by itself keeps the process alive.
setInterval(() => { rateCounts = new Map(); }, RATE_WINDOW_MS).unref();

server.listen(PORT, () => {
  const host = `http://localhost:${PORT}`;
  console.log(`\n🎮 live-game running`);
  console.log(`   Host screen : ${host}/#${HOST_TOKEN}`);
  console.log(`   Phones join : ${JOIN_URL}   ← LAN-reachable (QR encodes this)`);
  console.log(`   Host token  : ${HOST_TOKEN}  (POST /host/ask?token=${HOST_TOKEN})`);
  console.log(`   Snapshot    : ${host}/state\n`);
});

export { server, game, players };
