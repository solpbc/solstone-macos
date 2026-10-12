// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

(function () {
  "use strict";

  function bytesFromUuidString(s) {
    const raw = String(s || "").toLowerCase();
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(raw)) {
      throw new Error("invalid UUID");
    }
    return Uint8Array.from(raw.replace(/-/g, "").match(/../g).map((x) => Number.parseInt(x, 16)));
  }

  function uuidv7Bytes(nowMs, randomBytes) {
    const rand = randomBytes instanceof Uint8Array ? randomBytes : new Uint8Array(randomBytes || []);
    if (rand.byteLength < 10) throw new Error("uuidv7 needs at least 10 random bytes");
    const ts = BigInt(Math.floor(Number(nowMs)));
    if (ts < 0n || ts > 0xffffffffffffn) throw new Error("timestamp out of UUIDv7 range");
    const out = new Uint8Array(16);
    out[0] = Number((ts >> 40n) & 255n);
    out[1] = Number((ts >> 32n) & 255n);
    out[2] = Number((ts >> 24n) & 255n);
    out[3] = Number((ts >> 16n) & 255n);
    out[4] = Number((ts >> 8n) & 255n);
    out[5] = Number(ts & 255n);
    out[6] = 0x70 | (rand[0] & 0x0f);
    out[7] = rand[1];
    out[8] = 0x80 | (rand[2] & 0x3f);
    out[9] = rand[3];
    out[10] = rand[4];
    out[11] = rand[5];
    out[12] = rand[6];
    out[13] = rand[7];
    out[14] = rand[8];
    out[15] = rand[9];
    return out;
  }

  function uuidv7String(bytes) {
    const b = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes || []);
    if (b.byteLength !== 16) throw new Error("UUID must be 16 bytes");
    const hex = [...b].map((x) => x.toString(16).padStart(2, "0")).join("");
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
  }

  globalThis.SolstoneUuid = { uuidv7Bytes, uuidv7String, bytesFromUuidString };
})();
