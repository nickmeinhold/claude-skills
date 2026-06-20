#!/usr/bin/env node
// qr-matrixdiff.mjs — the deterministic oracle for the live-game QR encoder.
//
// Two foreign-oracle gates, each isolating a different correctness claim:
//
//   1. STRUCTURAL IDENTITY (vs `qrencode`). For a (text, version, ecc) triple,
//      force our encoder to the SAME mask qrencode chose (decoded from its
//      format bits), then require the matrices be IDENTICAL bit-for-bit. This
//      proves data encoding, Reed–Solomon EC, block interleaving, module
//      placement, format info, alignment and timing are all correct —
//      independent of mask-SELECTION policy. (libqrencode's mask choice deviates
//      from the ISO penalty spec, so we deliberately do NOT compare auto-masks
//      here; our penalty is spec-faithful and validated by gate 2 instead.)
//
//   2. ROUND-TRIP DECODE (vs `zbarimg`). Render our AUTO-masked output to PNG and
//      require a real QR decoder reads back exactly the input. This proves our
//      spec-faithful mask choice yields a genuinely scannable code.
//
// Usage:
//   node qr-matrixdiff.mjs --suite        # run both gates over the built-in matrix
//   node qr-matrixdiff.mjs <text> <v> <e> # structural diff for one case
//
// Requires `qrencode` and `zbarimg` on PATH (brew install qrencode zbar).

import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const { qrMatrix, _internals } = await import(path.join(HERE, '../../skills/live-game/qr.mjs'));
const { matrixToPng } = await import(path.join(HERE, './qr-png.mjs'));

const LEVELS = ['L', 'M', 'Q', 'H'];

// Parse qrencode's `-t ASCII -m 0` output: each module is two chars, "##" = dark.
function qrencodeMatrix(text, version, ecc) {
  const out = execFileSync(
    'qrencode',
    ['-8', '-v', String(version), '-l', ecc, '-m', '0', '-t', 'ASCII', text],
    { encoding: 'utf8' }
  );
  return out.split('\n').filter((l) => l.length > 0).map((line) => {
    const row = [];
    for (let i = 0; i < line.length; i += 2) row.push(line[i] === '#' ? 1 : 0);
    return row;
  });
}

// Decode the mask index from a matrix's top-left format information copy.
function decodeMask(m) {
  const b = [];
  for (let i = 0; i <= 5; i++) b[14 - i] = m[8][i];
  b[8] = m[8][7]; b[7] = m[8][8]; b[6] = m[7][8];
  for (let i = 9; i <= 14; i++) b[14 - i] = m[14 - i][8];
  let fmt = 0;
  for (let i = 14; i >= 0; i--) fmt = (fmt << 1) | b[i];
  return ((fmt ^ 0b101010000010010) >> 10) & 7;
}

function countMismatch(a, b) {
  if (a.length !== b.length) return Infinity;
  let n = 0;
  for (let r = 0; r < a.length; r++)
    for (let c = 0; c < a[r].length; c++) if (a[r][c] !== b[r][c]) n++;
  return n;
}

function render(matrix, mismatches = []) {
  const set = new Set(mismatches.map(([r, c]) => `${r},${c}`));
  return matrix
    .map((row, r) => row.map((v, c) => (set.has(`${r},${c}`) ? '✗' : v ? '█' : '·')).join(''))
    .join('\n');
}

// Gate 1: structural identity at qrencode's own mask.
function structuralCheck(text, version, ecc, { verbose = false } = {}) {
  const ref = qrencodeMatrix(text, version, ecc);
  const refMask = decodeMask(ref);
  const mine = qrMatrix(text, ecc, version, refMask);
  const n = countMismatch(mine, ref);
  if (n !== 0 && verbose) {
    const mm = [];
    for (let r = 0; r < ref.length; r++)
      for (let c = 0; c < ref.length; c++) if (mine[r][c] !== ref[r][c]) mm.push([r, c]);
    console.error(`\nSTRUCTURAL MISMATCH: ${JSON.stringify(text)} v${version} ${ecc} (mask ${refMask}), ${mm.length} modules`);
    console.error('mine (✗ = differs):');
    console.error(render(mine, mm));
  }
  return n === 0;
}

// Gate 2: round-trip the auto-masked output through a real decoder.
let TMP;
function roundTripCheck(text, ecc, { verbose = false } = {}) {
  const matrix = qrMatrix(text, ecc); // auto version + auto (spec) mask
  const png = matrixToPng(matrix, 8, 4);
  TMP = TMP || mkdtempSync(path.join(tmpdir(), 'qrrt-'));
  const file = path.join(TMP, 'rt.png');
  writeFileSync(file, png);
  let decoded;
  try {
    decoded = execFileSync('zbarimg', ['--quiet', '--raw', file], { encoding: 'utf8' }).replace(/\n$/, '');
  } catch (e) {
    decoded = `<zbarimg error: ${e.message}>`;
  }
  const ok = decoded === text;
  if (!ok && verbose) console.error(`ROUND-TRIP FAIL: ${JSON.stringify(text)} ${ecc} -> ${JSON.stringify(decoded)}`);
  return ok;
}

function pickSmallestVersion(text, ecc) {
  try { _internals.pickVersion(_internals.utf8Bytes(text).length, ecc); return true; }
  catch { return false; }
}

const SUITE = [
  'http://192.168.1.42:7373/play',
  'http://10.0.0.1:7373/play',
  'http://my-macbook-pro.local:7373/play',
  'HELLO',
  'A',
  'https://example.com/a/b/c/d/e/f/g/h/i/j',
];

if (process.argv[2] === '--suite') {
  let sPass = 0, sFail = 0, rPass = 0, rFail = 0;

  // Gate 1: structural identity across v1–6 × L/M/Q/H for every fitting payload.
  for (const text of SUITE) {
    for (const ecc of LEVELS) {
      for (let v = 1; v <= 6; v++) {
        let fits = true;
        try { qrMatrix(text, ecc, v); } catch { fits = false; }
        if (!fits) continue;
        if (structuralCheck(text, v, ecc, { verbose: true })) sPass++;
        else { sFail++; console.error(`  STRUCT FAIL: ${JSON.stringify(text)} v${v} ${ecc}`); }
      }
    }
  }

  // Gate 2: round-trip the auto-masked output for every payload/level.
  for (const text of SUITE) {
    for (const ecc of LEVELS) {
      if (!pickSmallestVersion(text, ecc)) continue;
      if (roundTripCheck(text, ecc, { verbose: true })) rPass++;
      else rFail++;
    }
  }

  console.log(`\nstructural (vs qrencode): ${sPass} passed, ${sFail} failed`);
  console.log(`round-trip (vs zbarimg):  ${rPass} passed, ${rFail} failed`);
  process.exit(sFail === 0 && rFail === 0 ? 0 : 1);
} else {
  const [, , text, version, ecc] = process.argv;
  if (!text || !version || !ecc) {
    console.error('usage: qr-matrixdiff.mjs <text> <version> <ecc>  |  --suite');
    process.exit(2);
  }
  const ok = structuralCheck(text, Number(version), ecc, { verbose: true });
  console.log(ok ? 'MATCH' : 'MISMATCH');
  process.exit(ok ? 0 : 1);
}
