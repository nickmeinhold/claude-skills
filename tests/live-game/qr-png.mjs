// qr-png.mjs — minimal grayscale PNG writer for the QR round-trip test.
//
// Test-only (Node): renders a QR module matrix to a real PNG so `zbarimg` can
// decode it back. Uses only node:zlib (built-in) — no npm dependencies, matching
// the skill's zero-dep constraint. Not shipped to the browser (qr.mjs renders
// SVG there); this exists purely so the test harness can prove scannability
// against a foreign decoder.

import zlib from 'node:zlib';

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length, 0);
  const typeBuf = Buffer.from(type, 'ascii');
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(Buffer.concat([typeBuf, data])), 0);
  return Buffer.concat([len, typeBuf, data, crc]);
}

/**
 * Render a QR matrix to an 8-bit grayscale PNG Buffer.
 * @param {number[][]} matrix  0 = light, 1 = dark
 * @param {number} [scale=8]   pixels per module
 * @param {number} [quiet=4]   quiet-zone modules
 */
export function matrixToPng(matrix, scale = 8, quiet = 4) {
  const n = matrix.length;
  const dim = (n + quiet * 2) * scale;

  // One filter byte (0 = none) per scanline, then `dim` grayscale pixels.
  const raw = Buffer.alloc((dim + 1) * dim);
  for (let y = 0; y < dim; y++) {
    raw[y * (dim + 1)] = 0; // filter type
    const my = Math.floor(y / scale) - quiet;
    for (let x = 0; x < dim; x++) {
      const mx = Math.floor(x / scale) - quiet;
      const dark = my >= 0 && my < n && mx >= 0 && mx < n && matrix[my][mx];
      raw[y * (dim + 1) + 1 + x] = dark ? 0x00 : 0xff;
    }
  }

  const sig = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(dim, 0);
  ihdr.writeUInt32BE(dim, 4);
  ihdr[8] = 8;  // bit depth
  ihdr[9] = 0;  // color type: grayscale
  ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0; // compression / filter / interlace
  const idat = zlib.deflateSync(raw);
  return Buffer.concat([
    sig,
    chunk('IHDR', ihdr),
    chunk('IDAT', idat),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}
