// qr.mjs — a tiny, dependency-free QR Code encoder (byte mode, versions 1–6).
//
// WHY THIS EXISTS
// ---------------
// The /live-game host screen shows a join URL the audience scans with phones.
// We used to call api.qrserver.com to render the QR — an external runtime
// dependency that contradicted the skill's "zero-dependency / offline" promise
// AND leaked the (private, LAN) join URL to a third party. This module replaces
// that call: it encodes the URL into a QR matrix entirely in-process, with no
// npm dependencies and no network. It is pure ESM (no Node or browser APIs), so
// the SAME file runs three places:
//   1. the host browser  — imported via `await import('/qr.mjs')`, rendered to SVG
//   2. the Node server    — serves this file verbatim at GET /qr.mjs
//   3. the test harness   — imported directly, diffed bit-for-bit vs `qrencode`
//
// SCOPE (deliberately bounded — see CLAUDE.md "compute the boundary first")
// ------------------------------------------------------------------------
// Versions 1–6 only. A LAN join URL (~30 chars) fits v6-M (84 data bytes) with
// huge margin. This bound removes the two hardest sub-problems: byte-mode
// character-count is uniformly 8 bits (16-bit only from v10), and there are NO
// version-information bits (v7+) and AT MOST ONE alignment pattern (multi-pattern
// from v7). Block interleaving IS implemented (v4-M already has 2 blocks; v5-Q/H
// use mixed group sizes), because dropping it would be silently wrong, not bounded.
//
// Spec: ISO/IEC 18004. Verified bit-for-bit against `qrencode` 4.1.1.

// ---------------------------------------------------------------------------
// GF(256) arithmetic — generated programmatically (prime polynomial 0x11d) so a
// mis-typed table can't be a source of bugs. exp[i] = α^i, log is its inverse.
// ---------------------------------------------------------------------------
const GF_EXP = new Uint8Array(512);
const GF_LOG = new Uint8Array(256);
(function buildGF() {
  let x = 1;
  for (let i = 0; i < 255; i++) {
    GF_EXP[i] = x;
    GF_LOG[x] = i;
    x <<= 1;
    if (x & 0x100) x ^= 0x11d; // reduce by the QR primitive polynomial
  }
  // Duplicate the cycle so we can index exp[a+b] without a modulo on the hot path.
  for (let i = 255; i < 512; i++) GF_EXP[i] = GF_EXP[i - 255];
})();

const gfMul = (a, b) => (a === 0 || b === 0 ? 0 : GF_EXP[GF_LOG[a] + GF_LOG[b]]);

// Reed–Solomon generator polynomial for `degree` EC codewords:
//   g(x) = (x-α^0)(x-α^1)...(x-α^{degree-1})
// Returned LEADING-coefficient first (gen[0] = α^0 = 1), the order rsEncode's
// synthetic division requires. Verified against the spec's degree-7 exponents
// (0,87,229,146,149,238,102,21) — the convolution below builds the array
// constant-first, so we reverse it before returning.
function rsGenerator(degree) {
  let poly = [1];
  for (let i = 0; i < degree; i++) {
    const next = new Array(poly.length + 1).fill(0);
    for (let j = 0; j < poly.length; j++) {
      next[j] ^= gfMul(poly[j], GF_EXP[i]);
      next[j + 1] ^= poly[j];
    }
    poly = next;
  }
  return poly.reverse();
}

// Compute `degree` EC codewords for one data block (polynomial long division).
function rsEncode(data, degree) {
  const gen = rsGenerator(degree);
  const res = new Array(data.length + degree).fill(0);
  for (let i = 0; i < data.length; i++) res[i] = data[i];
  for (let i = 0; i < data.length; i++) {
    const coef = res[i];
    if (coef === 0) continue;
    for (let j = 0; j < gen.length; j++) res[i + j] ^= gfMul(gen[j], coef);
  }
  return res.slice(data.length); // the remainder = EC codewords
}

// ---------------------------------------------------------------------------
// Error-correction block structure, ISO/IEC 18004 Table 9, versions 1–6.
// Each entry: ecPerBlock, and `groups` = [[numBlocks, dataCodewordsPerBlock], …].
// ECC level keys: L M Q H.
// ---------------------------------------------------------------------------
const EC_TABLE = {
  1: { L: [7, [[1, 19]]],  M: [10, [[1, 16]]], Q: [13, [[1, 13]]], H: [17, [[1, 9]]] },
  2: { L: [10, [[1, 34]]], M: [16, [[1, 28]]], Q: [22, [[1, 22]]], H: [28, [[1, 16]]] },
  3: { L: [15, [[1, 55]]], M: [26, [[1, 44]]], Q: [18, [[2, 17]]], H: [22, [[2, 13]]] },
  4: { L: [20, [[1, 80]]], M: [18, [[2, 32]]], Q: [26, [[2, 24]]], H: [16, [[4, 9]]] },
  5: { L: [26, [[1, 108]]], M: [24, [[2, 43]]], Q: [18, [[2, 15], [2, 16]]], H: [22, [[2, 11], [2, 12]]] },
  6: { L: [18, [[2, 68]]], M: [16, [[4, 27]]], Q: [24, [[4, 19]]], H: [28, [[4, 15]]] },
};

// Total data codewords available for a (version, level) — sum over all blocks.
function dataCapacity(version, level) {
  const [, groups] = EC_TABLE[version][level];
  return groups.reduce((sum, [n, d]) => sum + n * d, 0);
}

// Byte-mode payload capacity in CHARACTERS = data codewords minus the overhead
// of the mode indicator (4 bits) + char-count (8 bits) + terminator. Each data
// byte costs one codeword; the 12 bits of header cost ~1.5 codewords, so the
// usable character count is (dataCodewords - 2). Conservative and exact enough
// for version selection; the real packer below is the source of truth.
function byteCapacity(version, level) {
  return dataCapacity(version, level) - 2;
}

// Pick the smallest version (1–6) whose byte-mode capacity fits `byteLen`.
function pickVersion(byteLen, level) {
  for (let v = 1; v <= 6; v++) if (byteCapacity(v, level) >= byteLen) return v;
  throw new Error(`live-game QR: ${byteLen} bytes exceeds version-6 ${level} capacity; URL too long`);
}

// ---------------------------------------------------------------------------
// Bitstream: mode indicator + char count + data + terminator + byte-align + pad.
// ---------------------------------------------------------------------------
function buildBitstream(bytes, version, level) {
  const totalDataCodewords = dataCapacity(version, level);
  const bits = [];
  const push = (value, len) => { for (let i = len - 1; i >= 0; i--) bits.push((value >> i) & 1); };

  push(0b0100, 4);          // byte mode indicator
  push(bytes.length, 8);    // char count — 8 bits for byte mode, versions 1–9
  for (const b of bytes) push(b, 8);

  // Terminator: up to 4 zero bits, but no more than the remaining capacity.
  const capacityBits = totalDataCodewords * 8;
  const terminator = Math.min(4, capacityBits - bits.length);
  for (let i = 0; i < terminator; i++) bits.push(0);

  // Byte-align.
  while (bits.length % 8 !== 0) bits.push(0);

  // Pad bytes: alternate 0xEC, 0x11 until full.
  const padBytes = [0xec, 0x11];
  let p = 0;
  while (bits.length < capacityBits) { push(padBytes[p & 1], 8); p++; }

  // Pack bits -> codewords (bytes).
  const codewords = [];
  for (let i = 0; i < bits.length; i += 8) {
    let v = 0;
    for (let j = 0; j < 8; j++) v = (v << 1) | bits[i + j];
    codewords.push(v);
  }
  return codewords;
}

// Split data codewords into blocks, compute EC per block, then INTERLEAVE data
// codewords across blocks and EC codewords across blocks (ISO/IEC 18004 §8.6).
function buildFinalSequence(dataCodewords, version, level) {
  const [ecPerBlock, groups] = EC_TABLE[version][level];
  const dataBlocks = [];
  let offset = 0;
  for (const [numBlocks, dataPerBlock] of groups) {
    for (let b = 0; b < numBlocks; b++) {
      dataBlocks.push(dataCodewords.slice(offset, offset + dataPerBlock));
      offset += dataPerBlock;
    }
  }
  const ecBlocks = dataBlocks.map((blk) => rsEncode(blk, ecPerBlock));

  const result = [];
  const maxData = Math.max(...dataBlocks.map((b) => b.length));
  for (let i = 0; i < maxData; i++)
    for (const blk of dataBlocks) if (i < blk.length) result.push(blk[i]);
  for (let i = 0; i < ecPerBlock; i++)
    for (const blk of ecBlocks) result.push(blk[i]);

  return result;
}

// ---------------------------------------------------------------------------
// Matrix construction. We track a parallel `reserved` grid so the data-placement
// zigzag and masking skip the function patterns (finders, timing, alignment,
// format/dark module).
// ---------------------------------------------------------------------------
function newMatrix(size) {
  const m = [];
  const reserved = [];
  for (let r = 0; r < size; r++) {
    m.push(new Array(size).fill(0));
    reserved.push(new Array(size).fill(false));
  }
  return { m, reserved, size };
}

function placeFinder(M, row, col) {
  for (let r = -1; r <= 7; r++) {
    for (let c = -1; c <= 7; c++) {
      const rr = row + r, cc = col + c;
      if (rr < 0 || rr >= M.size || cc < 0 || cc >= M.size) continue;
      // 7x7 finder = outer ring + center 3x3; the -1/7 border is the separator (light).
      const inFinder = r >= 0 && r <= 6 && c >= 0 && c <= 6;
      const dark = inFinder &&
        ((r === 0 || r === 6 || c === 0 || c === 6) || (r >= 2 && r <= 4 && c >= 2 && c <= 4));
      M.m[rr][cc] = dark ? 1 : 0;
      M.reserved[rr][cc] = true;
    }
  }
}

function placeAlignment(M, version) {
  if (version < 2) return; // v1 has no alignment pattern
  const center = 4 * version + 10; // single pattern for v2–v6
  for (let r = -2; r <= 2; r++) {
    for (let c = -2; c <= 2; c++) {
      const dark = Math.max(Math.abs(r), Math.abs(c)) !== 1; // ring + center, gap at radius 1
      M.m[center + r][center + c] = dark ? 1 : 0;
      M.reserved[center + r][center + c] = true;
    }
  }
}

function placeTimingAndDark(M, version) {
  for (let i = 8; i < M.size - 8; i++) {
    const bit = i % 2 === 0 ? 1 : 0;
    if (!M.reserved[6][i]) { M.m[6][i] = bit; M.reserved[6][i] = true; }
    if (!M.reserved[i][6]) { M.m[i][6] = bit; M.reserved[i][6] = true; }
  }
  // The dark module — always set, always reserved.
  const dark = 4 * version + 9;
  M.m[dark][8] = 1;
  M.reserved[dark][8] = true;
}

// Reserve the format-information areas (filled later, after mask selection).
function reserveFormat(M) {
  for (let i = 0; i <= 8; i++) {
    if (i !== 6) { M.reserved[8][i] = true; M.reserved[i][8] = true; }
  }
  for (let i = 0; i < 8; i++) {
    M.reserved[8][M.size - 1 - i] = true;
    M.reserved[M.size - 1 - i][8] = true;
  }
  M.reserved[8][6] = true; // the 6th column position on row 8
  M.reserved[6][8] = true;
}

// Build a matrix with all function patterns placed and format areas reserved
// (but data not yet placed). Shared by the encoder and the test harness.
function buildFunctionMatrix(version) {
  const size = 17 + 4 * version;
  const M = newMatrix(size);
  placeFinder(M, 0, 0);
  placeFinder(M, 0, size - 7);
  placeFinder(M, size - 7, 0);
  placeAlignment(M, version);
  placeTimingAndDark(M, version);
  reserveFormat(M);
  return M;
}

// The zigzag order in which data/EC bits fill the matrix: column PAIRS from the
// right, each pair traversed up then down alternately, skipping the timing
// column (col 6) and any reserved (function) module. Returned as ordered [r,c].
function zigzagPositions(M) {
  const order = [];
  let upward = true;
  for (let col = M.size - 1; col > 0; col -= 2) {
    if (col === 6) col = 5; // skip the vertical timing column
    for (let i = 0; i < M.size; i++) {
      const row = upward ? M.size - 1 - i : i;
      for (let c = 0; c < 2; c++) {
        const cc = col - c;
        if (!M.reserved[row][cc]) order.push([row, cc]);
      }
    }
    upward = !upward;
  }
  return order;
}

function placeData(M, codewords) {
  const bits = [];
  for (const cw of codewords) for (let i = 7; i >= 0; i--) bits.push((cw >> i) & 1);
  const order = zigzagPositions(M);
  for (let idx = 0; idx < order.length; idx++) {
    const [r, c] = order[idx];
    M.m[r][c] = idx < bits.length ? bits[idx] : 0;
  }
}

// The eight data-mask predicates (ISO/IEC 18004 §8.8.1).
const MASKS = [
  (r, c) => (r + c) % 2 === 0,
  (r, c) => r % 2 === 0,
  (r, c) => c % 3 === 0,
  (r, c) => (r + c) % 3 === 0,
  (r, c) => (Math.floor(r / 2) + Math.floor(c / 3)) % 2 === 0,
  (r, c) => ((r * c) % 2) + ((r * c) % 3) === 0,
  (r, c) => (((r * c) % 2) + ((r * c) % 3)) % 2 === 0,
  (r, c) => (((r + c) % 2) + ((r * c) % 3)) % 2 === 0,
];

function applyMask(M, maskFn) {
  const size = M.size;
  const out = M.m.map((row) => row.slice());
  for (let r = 0; r < size; r++)
    for (let c = 0; c < size; c++)
      if (!M.reserved[r][c] && maskFn(r, c)) out[r][c] ^= 1;
  return out;
}

// The four penalty rules used to choose the lowest-penalty mask (§8.8.2).
function penalty(grid) {
  const n = grid.length;
  let score = 0;

  // Rule 1: runs of 5+ same-colour modules in a row/column. 3 pts for 5, +1 each beyond.
  const runScore = (line) => {
    let s = 0, run = 1;
    for (let i = 1; i < line.length; i++) {
      if (line[i] === line[i - 1]) { run++; }
      else { if (run >= 5) s += 3 + (run - 5); run = 1; }
    }
    if (run >= 5) s += 3 + (run - 5);
    return s;
  };
  for (let r = 0; r < n; r++) score += runScore(grid[r]);
  for (let c = 0; c < n; c++) score += runScore(grid.map((row) => row[c]));

  // Rule 2: 2x2 blocks of the same colour, 3 pts each.
  for (let r = 0; r < n - 1; r++)
    for (let c = 0; c < n - 1; c++) {
      const v = grid[r][c];
      if (v === grid[r][c + 1] && v === grid[r + 1][c] && v === grid[r + 1][c + 1]) score += 3;
    }

  // Rule 3: finder-like pattern 1:1:3:1:1 with 4 light either side, in rows and columns. 40 pts each.
  const A = [1, 0, 1, 1, 1, 0, 1, 0, 0, 0, 0];
  const B = [0, 0, 0, 0, 1, 0, 1, 1, 1, 0, 1];
  const matchAt = (line, i, pat) => pat.every((v, k) => line[i + k] === v);
  const lineRule3 = (line) => {
    let s = 0;
    for (let i = 0; i + 11 <= line.length; i++)
      if (matchAt(line, i, A) || matchAt(line, i, B)) s += 40;
    return s;
  };
  for (let r = 0; r < n; r++) score += lineRule3(grid[r]);
  for (let c = 0; c < n; c++) score += lineRule3(grid.map((row) => row[c]));

  // Rule 4: deviation of dark-module proportion from 50%.
  let dark = 0;
  for (let r = 0; r < n; r++) for (let c = 0; c < n; c++) dark += grid[r][c];
  const pct = (dark * 100) / (n * n);
  const k = Math.floor(Math.abs(pct - 50) / 5);
  score += k * 10;

  return score;
}

// 15-bit format information = 5 data bits (2 ECC-level + 3 mask), BCH(15,5)-coded,
// XOR'd with the spec mask 0x5412 (§8.9).
const ECC_FORMAT_BITS = { L: 0b01, M: 0b00, Q: 0b11, H: 0b10 };
function formatBits(level, mask) {
  const data = (ECC_FORMAT_BITS[level] << 3) | mask;
  let rem = data << 10;
  for (let i = 14; i >= 10; i--) if ((rem >> i) & 1) rem ^= 0b10100110111 << (i - 10);
  return ((data << 10) | rem) ^ 0b101010000010010;
}

function placeFormat(grid, M, level, mask) {
  const fmt = formatBits(level, mask);
  const n = M.size;
  const bit = (i) => (fmt >> i) & 1; // bit 14 is the MSB, placed first
  // Around the top-left finder.
  for (let i = 0; i <= 5; i++) grid[8][i] = bit(14 - i);
  grid[8][7] = bit(8);
  grid[8][8] = bit(7);
  grid[7][8] = bit(6);
  for (let i = 9; i <= 14; i++) grid[14 - i][8] = bit(14 - i);
  // The duplicate copy: bits 14→8 up column 8 (rows n-1..n-7), then bits 7→0
  // along row 8 (cols n-8..n-1). The dark module sits at (n-8, 8) and is NOT a
  // format module — the vertical run stops one short of it.
  for (let i = 0; i <= 6; i++) grid[n - 1 - i][8] = bit(14 - i);
  for (let i = 0; i <= 7; i++) grid[8][n - 8 + i] = bit(7 - i);
}

// ---------------------------------------------------------------------------
// Public API.
// ---------------------------------------------------------------------------

/**
 * Encode `text` into a QR module matrix.
 * @param {string} text  payload (UTF-8, byte mode)
 * @param {'L'|'M'|'Q'|'H'} [level='M']  error-correction level
 * @param {number} [forceVersion]  pin a version (1–6); otherwise smallest that fits
 * @returns {number[][]}  size×size grid of 0 (light) / 1 (dark)
 */
export function qrMatrix(text, level = 'M', forceVersion = 0, forceMask = -1) {
  const bytes = utf8Bytes(text);
  const version = forceVersion || pickVersion(bytes.length, level);
  if (bytes.length > byteCapacity(version, level))
    throw new Error(`live-game QR: ${bytes.length} bytes exceed version-${version} ${level} capacity`);

  const codewords = buildBitstream(bytes, version, level);
  const finalSeq = buildFinalSequence(codewords, version, level);

  const M = buildFunctionMatrix(version);
  placeData(M, finalSeq);

  // Choose the lowest-penalty mask (or honour a pinned mask for testing).
  let best = null, bestScore = Infinity;
  for (let mask = 0; mask < 8; mask++) {
    if (forceMask >= 0 && mask !== forceMask) continue;
    const grid = applyMask(M, MASKS[mask]);
    placeFormat(grid, M, level, mask);
    const score = penalty(grid);
    if (score < bestScore) { bestScore = score; best = grid; }
  }
  return best;
}

// Test hooks — not part of the rendering API, but stable enough for the harness
// to inspect the codeword pipeline without re-deriving it.
export const _internals = {
  buildBitstream, buildFinalSequence, dataCapacity, byteCapacity, pickVersion,
  rsEncode, rsGenerator, formatBits, utf8Bytes, buildFunctionMatrix, zigzagPositions, MASKS,
  placeData, applyMask, placeFormat, penalty,
};

/** UTF-8 encode without depending on TextEncoder (works everywhere). */
function utf8Bytes(str) {
  const out = [];
  for (let i = 0; i < str.length; i++) {
    let code = str.charCodeAt(i);
    if (code < 0x80) out.push(code);
    else if (code < 0x800) { out.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f)); }
    else if (code >= 0xd800 && code <= 0xdbff) {
      // surrogate pair
      const hi = code, lo = str.charCodeAt(++i);
      code = 0x10000 + ((hi - 0xd800) << 10) + (lo - 0xdc00);
      out.push(0xf0 | (code >> 18), 0x80 | ((code >> 12) & 0x3f), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
    } else { out.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f)); }
  }
  return out;
}

/**
 * Render a QR matrix as a crisp, scalable inline SVG string.
 * @param {number[][]} matrix
 * @param {{quiet?:number, size?:number, dark?:string, light?:string}} [opts]
 */
export function qrSvg(matrix, opts = {}) {
  const quiet = opts.quiet ?? 4;            // quiet-zone modules (spec minimum is 4)
  const dark = opts.dark ?? '#000';
  const light = opts.light ?? '#fff';
  const n = matrix.length;
  const dim = n + quiet * 2;
  const px = opts.size ?? dim * 8;          // rendered pixel size
  let rects = '';
  for (let r = 0; r < n; r++)
    for (let c = 0; c < n; c++)
      if (matrix[r][c]) rects += `<rect x="${c + quiet}" y="${r + quiet}" width="1" height="1"/>`;
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" width="${px}" height="${px}" ` +
    `viewBox="0 0 ${dim} ${dim}" shape-rendering="crispEdges">` +
    `<rect width="${dim}" height="${dim}" fill="${light}"/>` +
    `<g fill="${dark}">${rects}</g></svg>`
  );
}
