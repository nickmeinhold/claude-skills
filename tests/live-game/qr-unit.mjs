#!/usr/bin/env node
// qr-unit.mjs — pure, dependency-free unit checks for the QR encoder.
//
// These run anywhere (no qrencode/zbarimg needed), so CI always exercises the
// load-bearing internals even if the foreign-oracle tools are absent. The
// matrix-diff harness (qr-matrixdiff.mjs) is the heavier correctness gate;
// this is the always-on floor.

import { fileURLToPath } from 'node:url';
import path from 'node:path';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const { qrMatrix, qrSvg, _internals: I } = await import(path.join(HERE, '../../skills/live-game/qr.mjs'));

let failed = 0;
const ok = (cond, msg) => { if (!cond) { console.error('FAIL:', msg); failed++; } };
const eq = (a, b, msg) => ok(a === b, `${msg} (got ${a}, want ${b})`);

// GF(256) exp/log for translating generator coeffs to α-exponents.
const EXP = new Uint8Array(512), LOG = new Uint8Array(256);
{ let x = 1; for (let i = 0; i < 255; i++) { EXP[i] = x; LOG[x] = i; x <<= 1; if (x & 0x100) x ^= 0x11d; } }

// 1. Reed–Solomon generator polynomial (degree 7) must match the spec exponents,
//    leading coefficient first. This is the bug the matrix-diff caught: a reversed
//    generator silently produced wrong EC codewords that a same-construction
//    cross-check also got wrong — only a foreign oracle exposed it.
const gen7 = I.rsGenerator(7).map((c) => LOG[c]).join(',');
eq(gen7, '0,87,229,146,149,238,102,21', 'RS generator degree-7 exponents');

// 2. Format-information BCH strings against known spec values.
eq(I.formatBits('M', 0).toString(2).padStart(15, '0'), '101010000010010', 'format M/mask0');
eq(I.formatBits('L', 0).toString(2).padStart(15, '0'), '111011111000100', 'format L/mask0');

// 3. Byte-mode capacity + version selection at the boundary.
eq(I.byteCapacity(1, 'L'), 17, 'v1-L byte capacity');
eq(I.pickVersion(17, 'L'), 1, '17 bytes -> v1');
eq(I.pickVersion(18, 'L'), 2, '18 bytes -> v2 (boundary spills)');
ok((() => { try { I.pickVersion(9999, 'H'); return false; } catch { return true; } })(),
  'oversized payload throws rather than silently truncating');

// 4. qrSvg must render exactly the module matrix (parse rects, reconstruct, compare).
{
  const text = 'http://192.168.1.42:7373/play';
  const m = qrMatrix(text, 'M');
  const quiet = 4;
  const svg = qrSvg(m, { quiet });
  const recon = m.map((row) => row.map(() => 0));
  for (const mm of svg.matchAll(/<rect x="(\d+)" y="(\d+)" width="1" height="1"\/>/g)) {
    const x = Number(mm[1]) - quiet, y = Number(mm[2]) - quiet;
    if (y >= 0 && y < m.length && x >= 0 && x < m.length) recon[y][x] = 1;
  }
  let diff = 0;
  for (let r = 0; r < m.length; r++) for (let c = 0; c < m.length; c++) if (m[r][c] !== recon[r][c]) diff++;
  eq(diff, 0, 'qrSvg renders the exact module matrix');
}

// 5. Determinism: same input -> identical matrix (no Date/random leakage).
{
  const a = JSON.stringify(qrMatrix('HELLO', 'M'));
  const b = JSON.stringify(qrMatrix('HELLO', 'M'));
  ok(a === b, 'encoding is deterministic');
}

// 6. Higher versions with block interleaving and an alignment pattern still build
//    a square matrix of the right dimension (v6 = 41x41).
{
  const m = qrMatrix('https://example.com/a/b/c/d/e/f/g/h/i/j', 'H', 6);
  eq(m.length, 41, 'v6 matrix is 41 rows');
  ok(m.every((row) => row.length === 41), 'v6 matrix is 41 cols');
}

if (failed) { console.error(`\n${failed} unit check(s) failed`); process.exit(1); }
console.log('qr-unit: all checks passed');
