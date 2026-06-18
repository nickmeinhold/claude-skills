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
//   POST /join        {clientId, name}
//   POST /vote        {clientId, option}
//   POST /host/ask    {question, options[], correct, timeLimit?}   (needs host token)
//   POST /host/reveal                                              (needs host token)
//   POST /host/next                                                (needs host token)
//   POST /host/reset                                               (needs host token)

import http from 'node:http';
import crypto from 'node:crypto';
import os from 'node:os';
import { argv, env } from 'node:process';

// ---- config ----------------------------------------------------------------
const PORT = Number(argFlag('--port') ?? env.LIVE_GAME_PORT ?? 7373);
// A weak shared secret so randoms on the network can't drive the game. Printed
// at startup; the host view reads it from the URL fragment.
const HOST_TOKEN = env.LIVE_GAME_HOST_TOKEN ?? crypto.randomBytes(4).toString('hex');
const DEFAULT_TIME_LIMIT = 20; // seconds; speed bonus decays over this window

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
const JOIN_URL = `http://${JOIN_HOST}/play`;

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
/** clientId -> {name, score, answer, answeredAt, lastGain} */
const players = new Map();
/** live SSE response objects */
const sseClients = new Set();

// ---- helpers ---------------------------------------------------------------
function argFlag(name) {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : undefined;
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
    .sort((a, b) => b.score - a.score)
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
    try { res.write(payload); } catch { sseClients.delete(res); }
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

  // --- SSE stream ---
  if (req.method === 'GET' && path === '/events') {
    res.writeHead(200, {
      'content-type': 'text/event-stream',
      'cache-control': 'no-cache',
      connection: 'keep-alive',
    });
    res.write(`data: ${JSON.stringify(publicState())}\n\n`);
    sseClients.add(res);
    const keepAlive = setInterval(() => { try { res.write(': ping\n\n'); } catch {} }, 15000);
    req.on('close', () => { clearInterval(keepAlive); sseClients.delete(res); });
    return;
  }

  // --- JSON snapshot (for the slide updater / tests) ---
  if (req.method === 'GET' && path === '/state') {
    return json(res, 200, publicState());
  }

  // --- player join ---
  if (req.method === 'POST' && path === '/join') {
    const body = await readBody(req);
    const id = String(body.clientId || '').slice(0, 64);
    const name = String(body.name || '').trim().slice(0, 24) || 'anon';
    if (!id) return json(res, 400, { error: 'clientId required' });
    const existing = players.get(id);
    players.set(id, existing
      ? { ...existing, name }
      : { name, score: 0, answer: null, answeredAt: 0, lastGain: 0 });
    broadcast();
    return json(res, 200, { ok: true });
  }

  // --- player vote ---
  if (req.method === 'POST' && path === '/vote') {
    const body = await readBody(req);
    const p = players.get(String(body.clientId || ''));
    if (!p) return json(res, 404, { error: 'join first' });
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

  // --- host: ask a new question ---
  if (req.method === 'POST' && path === '/host/ask') {
    const body = await readBody(req);
    if (!hostOk(req, body)) return json(res, 403, { error: 'bad host token' });
    const options = Array.isArray(body.options) ? body.options.map(String).slice(0, 6) : [];
    if (!body.question || options.length < 2)
      return json(res, 400, { error: 'need question + >=2 options' });
    game.phase = 'question';
    game.question = String(body.question);
    game.options = options;
    game.correct = Number.isInteger(body.correct) ? body.correct : -1;
    game.timeLimit = Number(body.timeLimit) > 0 ? Number(body.timeLimit) : DEFAULT_TIME_LIMIT;
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
 .join img{background:#fff;border-radius:8px}
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
   <img id=qr width=120 height=120 alt="join QR">
   <div><div style="font-size:14px;color:#9aa">Players join at</div>
   <div id=joinurl style="font-size:26px;font-weight:700;color:#fff"></div>
   <div class=meta><span id=pc>0</span> players · round <span id=rd>0</span></div></div>
 </div>
 <div id=stage></div>
 <div class=lb id=lb></div>
 <small>Game Master drives questions via <code>POST /host/ask</code>. Host token in this page's URL.</small>
</div><script>
const token = location.hash.slice(1);
const stage = document.getElementById('stage');
let qrSet = false;
function setJoin(joinUrl){
  // The server resolves a LAN-reachable join URL; do NOT use location.origin
  // (the host screen is usually on localhost, which a phone can't reach).
  if(qrSet || !joinUrl) return; qrSet = true;
  document.getElementById('joinurl').textContent = joinUrl.replace(/^https?:\\/\\//,'');
  document.getElementById('qr').src =
    'https://api.qrserver.com/v1/create-qr-code/?size=120x120&data=' + encodeURIComponent(joinUrl);
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
function esc(s){return String(s).replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]))}
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
let clientId = localStorage.getItem('lg-id');
if(!clientId){ clientId = Math.random().toString(36).slice(2); localStorage.setItem('lg-id',clientId); }
let name = localStorage.getItem('lg-name') || '';
let myAnswer = null, myScore = 0, lastRound = -1;
const app=document.getElementById('app');
function esc(s){return String(s).replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]))}
async function post(p,b){return fetch(p,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(b)})}

function joinView(){
  app.innerHTML='<h2>🎮 Join the game</h2><input id=nm placeholder="Your name" value="'+esc(name)+'">'+
    '<button id=go>Join</button>';
  document.getElementById('go').onclick=async()=>{
    name=document.getElementById('nm').value.trim()||'anon';
    localStorage.setItem('lg-name',name);
    await post('/join',{clientId,name}); joined=true; render(lastState);
  };
}
let joined = !!name, lastState=null;
function render(s){
  lastState=s; if(!s) return;
  if(!joined){ joinView(); return; }
  if(s.round!==lastRound){ myAnswer=null; lastRound=s.round; }
  const letters='ABCDEF';
  if(s.phase==='lobby'){ app.innerHTML='<div class=big>Hang tight…<br>next question incoming</div>'+meId(); return; }
  if(s.phase==='question'){
    let html='<div class=q>'+esc(s.question)+'</div>';
    s.options.forEach((o,i)=>{ html+='<button class="opt o'+i+'" data-i="'+i+'" '+(myAnswer!=null?'disabled':'')+'>'+
      letters[i]+'. '+esc(o)+'</button>'; });
    if(myAnswer!=null) html+='<div class=big>✅ Locked in '+letters[myAnswer]+'</div>';
    app.innerHTML=html+meId();
    app.querySelectorAll('.opt').forEach(b=>b.onclick=async()=>{
      myAnswer=Number(b.dataset.i); render(s); await post('/vote',{clientId,option:myAnswer});
    });
    return;
  }
  if(s.phase==='reveal'){
    const me=(s.leaderboard||[]).find(p=>p.name===name);
    const right = myAnswer===s.correct;
    app.innerHTML='<div class=big>'+(myAnswer==null?'⏳ No answer':(right?'🎉 Correct!':'❌ '+letters[s.correct]+' was right'))+
      (me&&me.lastGain?'<div class=gain>+'+me.lastGain+'</div>':'')+'</div>'+meId();
    return;
  }
}
function meId(){ const me=(lastState&&lastState.leaderboard||[]).find(p=>p.name===name);
  return '<div class=me>'+esc(name)+(me?' · '+me.score+' pts':'')+'</div>'; }
const ev=new EventSource('/events'); ev.onmessage=e=>render(JSON.parse(e.data));
if(joined) post('/join',{clientId,name});
</script></body></html>`;

// ---- boot ------------------------------------------------------------------
server.listen(PORT, () => {
  const host = `http://localhost:${PORT}`;
  console.log(`\n🎮 live-game running`);
  console.log(`   Host screen : ${host}/#${HOST_TOKEN}`);
  console.log(`   Phones join : ${JOIN_URL}   ← LAN-reachable (QR encodes this)`);
  console.log(`   Host token  : ${HOST_TOKEN}  (POST /host/ask?token=${HOST_TOKEN})`);
  console.log(`   Snapshot    : ${host}/state\n`);
});

export { server, game, players };
