// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

(function () {
  "use strict";

  function getConsts() {
    const c = globalThis.SolstoneNativeBrowserConstants;
    if (!c) {
      throw new Error("missing SolstoneNativeBrowserConstants");
    }
    return c;
  }

  function requireConst(c, name) {
    if (c[name] === undefined) {
      throw new Error("missing constant: " + name);
    }
    return c[name];
  }

  // --- Canonical JSON Encoder ---

  function isLoneSurrogate(str) {
    for (let i = 0; i < str.length; i++) {
      const code = str.charCodeAt(i);
      if (code >= 0xd800 && code <= 0xdbff) {
        if (i + 1 < str.length) {
          const next = str.charCodeAt(i + 1);
          if (next >= 0xdc00 && next <= 0xdfff) {
            i++;
            continue;
          }
        }
        return true;
      }
      if (code >= 0xdc00 && code <= 0xdfff) {
        return true;
      }
    }
    return false;
  }

  function escapeString(str) {
    if (isLoneSurrogate(str)) {
      const err = new Error("lone surrogate in string");
      err.code = "lone_surrogate";
      throw err;
    }
    let out = '"';
    for (let i = 0; i < str.length; i++) {
      const ch = str[i];
      const code = str.charCodeAt(i);
      if (code >= 0xd800 && code <= 0xdbff && i + 1 < str.length) {
        const next = str.charCodeAt(i + 1);
        if (next >= 0xdc00 && next <= 0xdfff) {
          out += ch + str[i + 1];
          i++;
          continue;
        }
      }
      if (ch === '"') {
        out += '\\"';
      } else if (ch === "\\") {
        out += "\\\\";
      } else if (code < 0x20) {
        out += "\\u00" + code.toString(16).padStart(2, "0");
      } else {
        out += ch;
      }
    }
    out += '"';
    return out;
  }

  function canonicalStringify(val, keyOrderMap) {
    if (val === null) return "null";
    if (typeof val === "boolean") return val ? "true" : "false";
    if (typeof val === "number") {
      if (!Number.isFinite(val)) throw new Error("bad number");
      return String(val);
    }
    if (typeof val === "string") {
      return escapeString(val);
    }
    if (Array.isArray(val)) {
      return "[" + val.map((item) => canonicalStringify(item, keyOrderMap)).join(",") + "]";
    }
    if (typeof val === "object") {
      const type = val.type || (val.t === "segment_start" ? "snapshot_record" : val.t === "delta" ? "delta_record" : null);
      let knownKeys = [];
      if (keyOrderMap && type && keyOrderMap[type]) {
        knownKeys = keyOrderMap[type];
      } else if (keyOrderMap && val.t && keyOrderMap[val.t === "segment_start" ? "snapshot_record" : "delta_record"]) {
        knownKeys = keyOrderMap[val.t === "segment_start" ? "snapshot_record" : "delta_record"];
      } else if (keyOrderMap && (val.id !== undefined || val.text !== undefined) && keyOrderMap.block) {
        knownKeys = keyOrderMap.block;
      } else if (keyOrderMap && (val.label !== undefined || val.level !== undefined || val.linkHost !== undefined) && keyOrderMap.block_attrs) {
        knownKeys = keyOrderMap.block_attrs;
      }

      const allKeys = Object.keys(val);
      const presentKnown = knownKeys.filter((k) => Object.prototype.hasOwnProperty.call(val, k) && val[k] !== undefined);
      const unknownKeys = allKeys.filter((k) => !knownKeys.includes(k) && val[k] !== undefined);
      unknownKeys.sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));

      const ordered = presentKnown.concat(unknownKeys);
      const pairs = ordered.map((k) => escapeString(k) + ":" + canonicalStringify(val[k], keyOrderMap));
      return "{" + pairs.join(",") + "}";
    }
    throw new Error("unsupported type");
  }

  function exceedsObjectDepth(value, maximum) {
    const pending = [{value, depth: 0}];
    while (pending.length) {
      const item = pending.pop();
      if (item.value !== null && typeof item.value === "object") {
        const depth = item.depth + 1;
        if (depth > maximum) return true;
        for (const key of Object.keys(item.value)) pending.push({value: item.value[key], depth});
      }
    }
    return false;
  }

  function exceedsJsonDepth(text, maximum) {
    let depth = 0;
    let inString = false;
    let escaped = false;
    for (let index = 0; index < text.length; index++) {
      const character = text[index];
      if (inString) {
        if (escaped) escaped = false;
        else if (character === "\\") escaped = true;
        else if (character === '"') inString = false;
      } else if (character === '"') inString = true;
      else if (character === "{" || character === "[") {
        if (++depth > maximum) return true;
      } else if (character === "}" || character === "]") depth--;
    }
    return false;
  }

  function encode(msg) {
    const consts = getConsts();
    const keyOrder = requireConst(consts, "CANONICAL_KEY_ORDER");
    if (exceedsObjectDepth(msg, requireConst(consts, "JSON_MAX_DEPTH"))) {
      const error = new Error("bad_json"); error.code = "bad_json"; throw error;
    }
    const jsonStr = canonicalStringify(msg, keyOrder);
    return new TextEncoder().encode(jsonStr);
  }

  // --- Offline schema validation and decoder ---

  let validateSchema;
  function validator() {
    if (!validateSchema) {
      const schemas = globalThis.SolstoneNativeBrowserSchemas;
      const evaluator = globalThis.SolstoneNativeBrowserSchemaValidator;
      if (!schemas || !evaluator) throw new Error("missing native-browser schema bundle or validator");
      validateSchema = evaluator.compile([schemas.envelope, schemas.journal]);
    }
    return validateSchema;
  }

  function refuse(code, detail) {
    const error = new Error(code);
    error.code = code;
    if (detail) error.recordError = {code, ...detail};
    return {status: "refuse", error, code, ...detail};
  }

  function invalidValues(value) {
    const pending = [value];
    while (pending.length) {
      const item = pending.pop();
      if (typeof item === "string" && isLoneSurrogate(item)) return "lone_surrogate";
      if (typeof item === "number" && !Number.isFinite(item)) return "bad_number";
      if (item !== null && typeof item === "object") {
        for (const key of Object.keys(item)) {
          if (isLoneSurrogate(key)) return "lone_surrogate";
          pending.push(item[key]);
        }
      }
    }
    return null;
  }

  function schemaRefusal(type, error) {
    const {path, keyword} = error;
    const field = path[0];
    if (field === "records") {
      if (path.length === 1 && keyword === "maxItems") return refuse("too_many_deltas");
      if (path.at(-1) === "id" && ["maxLength", "required"].includes(keyword)) {
        return refuse("bad_record", {row: path[1], field: "id", cause: keyword === "required" ? "missing" : "too_long"});
      }
      return refuse("bad_record");
    }
    if (type === "accepted") return refuse("invalid_receipt");
    if (keyword === "required" && !(["state", "hello_ack"].includes(type) && ["destination_generation", "period_id"].includes(field))) return refuse("missing_field");
    if (field === "batch_id") return refuse("bad_batch_id");
    if (field === "freshness_ms") return refuse("freshness_range");
    if (["protocol", "queued_at_ms"].includes(field)) return refuse("bad_number");
    if (["state", "hello_ack"].includes(type) &&
        (["destination_generation", "period_id"].includes(field) || keyword === "not")) return refuse("bad_state_ids");
    if (keyword === "enum" || keyword === "const") return refuse("invalid_enum");
    return refuse("missing_field");
  }

  function decode(input, direction) {
    const consts = getConsts();
    const extCap = requireConst(consts, "EXTENSION_TO_HOST_MAX");
    const controlMax = requireConst(consts, "CONTROL_MAX");
    const directions = requireConst(consts, "DIRECTIONS");
    if (!Object.prototype.hasOwnProperty.call(directions, direction)) return refuse("bad_direction");
    const maximum = direction === "host_to_extension" ? controlMax : extCap;
    let text;
    let byteLength;
    if (typeof input === "string") {
      // UTF-8 is never shorter than the UTF-16 length, including unpaired surrogates.
      if (input.length > maximum) return refuse("oversize");
      byteLength = new TextEncoder().encode(input).byteLength;
      if (byteLength > maximum) return refuse("oversize");
      text = input;
    } else if (input instanceof Uint8Array) {
      byteLength = input.byteLength;
      if (byteLength > maximum) return refuse("oversize");
      try {
        text = new TextDecoder("utf-8", {fatal: true, ignoreBOM: true}).decode(input);
      } catch (_error) {
        return refuse("bad_utf8");
      }
    } else {
      return refuse("empty_payload");
    }
    if (byteLength === 0 || text.trim() === "") return refuse("empty_payload");
    if (exceedsJsonDepth(text, requireConst(consts, "JSON_MAX_DEPTH"))) return refuse("bad_json");
    let obj;
    try {
      // Strict parsing preserves additive fields and never repairs malformed JSON.
      obj = JSON.parse(text);
    } catch (_error) {
      return refuse("bad_json");
    }
    const invalid = invalidValues(obj);
    if (invalid) return refuse(invalid);
    if (obj === null || typeof obj !== "object" || Array.isArray(obj)) return refuse("bad_json");
    if (!Object.prototype.hasOwnProperty.call(obj, "type") || typeof obj.type !== "string") return refuse("missing_field");
    const type = obj.type;
    const knownTypes = [...directions.extension_to_host, ...directions.host_to_extension];
    if (!knownTypes.includes(type)) return refuse("bad_type");
    if (!directions[direction].includes(type)) return refuse("bad_direction");
    if (type !== "batch" && byteLength > controlMax) return refuse("oversize");

    const schemas = globalThis.SolstoneNativeBrowserSchemas;
    const check = validator();
    const schemaError = check(schemas.envelope, "#/$defs/" + type, obj);
    if (schemaError) return schemaRefusal(type, schemaError);

    if (type === "hello" && obj.protocol !== consts.WIRE_PROTOCOL) {
      return {status: "unsupported", value: {
        type: "unsupported", protocol: obj.protocol, version: obj.version,
        behind: obj.protocol > consts.WIRE_PROTOCOL ? "app" : "extension",
      }};
    }

    if (type === "state" || type === "hello_ack") {
      const gen = obj.destination_generation;
      const period = obj.period_id;
      const hasGen = typeof gen === "string" && gen.length > 0;
      const hasPeriod = typeof period === "string" && period.length > 0;
      if ((obj.capture === "unavailable" || obj.capture === "not_paired") && (gen != null || period != null)) return refuse("bad_state_ids");
      if (obj.capture === "permitted" && (!hasGen || !hasPeriod)) return refuse("bad_state_ids");
      if ((obj.capture === "paused" || obj.capture === "intake_off") && !hasGen) return refuse("bad_state_ids");
      if (hasPeriod && !hasGen) return refuse("bad_state_ids");
    }

    if (type === "accepted" && obj.result === "rejected") {
      const reasons = consts.RECEIPT_CLASSES[obj.class];
      const legacyPermanent = obj.class === "permanent" && consts.LEGACY_PERMANENT_REASONS.includes(obj.reason);
      if ((!reasons || !reasons.includes(obj.reason)) && !legacyPermanent) return refuse("invalid_receipt");
    }

    if (type === "batch") {
      const first = obj.records[0];
      const snapshot = first.t === "segment_start";
      if (snapshot && obj.records.length !== 1) return refuse("bad_record");
      const own = (value, key) => Object.prototype.hasOwnProperty.call(value, key);
      for (let row = 0; row < obj.records.length; row++) {
        const record = obj.records[row];
        if (record.t !== (snapshot ? "segment_start" : "delta")) return refuse("bad_record");
        if (!own(record, "ctx") || record.ctx === "") return refuse("bad_record", {row, field: "ctx", cause: own(record, "ctx") ? "empty" : "missing"});
        if (own(record, "inst") && record.inst !== obj.inst) return refuse("bad_record", {row, field: "inst", cause: "mismatch"});
        if (own(record, "ctx") !== own(first, "ctx") || record.ctx !== first.ctx) return refuse("mixed_context");
        if (own(record, "snapshot_reason") && record.snapshot_reason !== "delivery_recovery") return refuse("invalid_enum");
        const blocks = snapshot ? record.blocks : [record.block];
        for (let blockIndex = 0; blockIndex < blocks.length; blockIndex++) {
          const block = blocks[blockIndex];
          // Canonical schema owns type and upper bound; native batches add presence/nonempty.
          if (!own(block, "id") || block.id === "") {
            return refuse("bad_record", {row, field: "id", cause: own(block, "id") ? "empty" : "missing"});
          }
        }
      }
    }
    return {status: "accept", value: obj};
  }

  // --- Receipt Builder ---

  function buildReply(receipt) {
    const consts = getConsts();
    let result = receipt.result;
    if (!result) {
      if (receipt.reason !== undefined) result = "rejected";
      else if (receipt.outcome === "accepted" || receipt.outcome === "duplicate") result = receipt.duplicate || receipt.outcome === "duplicate" ? "duplicate" : "accepted";
    }
    const has = key => Object.prototype.hasOwnProperty.call(receipt, key);
    if ((result === "rejected" && has("period_id")) ||
        (["accepted", "duplicate"].includes(result) && (has("reason") || has("class")))) {
      throw refuse("invalid_receipt").error;
    }
    const reply = {
      type: "accepted", result,
      destination_generation: receipt.destination_generation,
      inst: receipt.inst, batch_id: receipt.batch_id,
    };
    if (result === "accepted" || result === "duplicate") {
      reply.period_id = receipt.period_id;
    } else if (result === "rejected") {
      reply.reason = receipt.reason;
      reply.class = receipt.class;
      if (consts.LEGACY_PERMANENT_REASONS.includes(reply.reason)) throw refuse("invalid_receipt").error;
      if (reply.class === undefined) for (const [kind, reasons] of Object.entries(consts.RECEIPT_CLASSES)) {
        if (reasons.includes(reply.reason)) reply.class = kind;
      }
    }
    const validation = decode(JSON.stringify(reply), "host_to_extension");
    if (validation.status !== "accept") throw validation.error;
    return reply;
  }

  // --- Registration Renderer ---

  function renderRegistration(channel, browser, os, execPath, configRoot) {
    const consts = getConsts();
    const hostsAndIds = requireConst(consts, "HOSTS_AND_IDS");
    const regConfig = requireConst(consts, "REGISTRATION");
    const hostInfo = hostsAndIds[channel];
    if (!hostInfo) throw new Error("unknown channel: " + channel);

    const host = hostInfo.host;
    let id;
    if (browser === "chrome") id = hostInfo.chrome_id;
    else if (browser === "edge") id = hostInfo.edge_id;
    else if (browser === "firefox") id = hostInfo.firefox_id;
    else throw new Error("unknown browser: " + browser);

    const description = regConfig.description;
    const type = regConfig.type;
    const path = execPath || regConfig.path_placeholder;

    const manifest = {
      name: host,
      description,
      path,
      type,
    };

    if (browser === "firefox") {
      manifest.allowed_extensions = [id];
    } else {
      manifest.allowed_origins = [`chrome-extension://${id}/`];
    }

    const key = `${browser}_${os}`;
    const suffixTemplate = regConfig.suffixes[key];
    if (!suffixTemplate) throw new Error("unknown registration platform: " + key);

    const suffix = suffixTemplate.replace("<host>", host);
    let fullPath = suffix;
    if (configRoot) {
      const trimmedRoot = configRoot.replace(/[/\\]+$/, "");
      fullPath = trimmedRoot + (os === "windows" ? "\\" : "/") + suffix;
    }

    const filename = os === "windows" ? host : `${host}.json`;

    return {
      channel,
      browser,
      os,
      host,
      filename,
      path: fullPath,
      json: JSON.stringify(manifest, null, 2) + "\n",
      manifest,
    };
  }

  // --- Predicates ---

  function handshakeExpired(startedMs, nowMs, budgetMs) {
    return Math.max(0, nowMs - startedMs) >= budgetMs;
  }

  function stateRenewalDue(lastMs, nowMs, intervalMs) {
    return Math.max(0, nowMs - lastMs) >= intervalMs;
  }

  function freshnessValueAllowed(freshnessMs) {
    return Number.isInteger(freshnessMs) && freshnessMs >= 0 && freshnessMs <= getConsts().FRESHNESS_MS_MAX;
  }

  function freshnessAuthorizesSkim(issuedMs, freshnessMs, nowMs) {
    return freshnessValueAllowed(freshnessMs) && nowMs >= issuedMs && nowMs - issuedMs < freshnessMs;
  }

  function freshnessAuthorizesDeletion(_issuedMs, _freshnessMs, _nowMs) {
    return false;
  }

  function partialFrameExpired(firstByteMs, nowMs, lifetimeMs) {
    return Math.max(0, nowMs - firstByteMs) >= lifetimeMs;
  }

  function futureBeyondTolerance(observedMs, nowMs, toleranceMs) {
    return Math.max(0, observedMs - nowMs) > toleranceMs;
  }

  function queuedPastOutboxAge(queuedAtMs, nowMs, maxAgeMs) {
    return Math.max(0, nowMs - queuedAtMs) >= maxAgeMs;
  }

  function acceptedPastMinRetention(acceptedAtMs, nowMs, retentionMs) {
    return Math.max(0, nowMs - acceptedAtMs) >= retentionMs;
  }

  function connectionTokenMatches(live, presented) {
    return live === presented;
  }

  function mayRenewOnConnection(live, presented, lastMs, nowMs, intervalMs) {
    return live === presented && nowMs >= lastMs && nowMs - lastMs < intervalMs;
  }

  function captureIsPermitted(state) {
    if (!state || !["state", "hello_ack"].includes(state.type) || state.capture !== "permitted" || !freshnessValueAllowed(state.freshness_ms) || state.freshness_ms === 0 || state.custody?.full === true) return false;
    try {
      return decode(JSON.stringify(state), "host_to_extension").status === "accept";
    } catch (_error) {
      return false;
    }
  }

  // --- Recipes Builder ---

  function buildRecipe(recipeId) {
    const consts = getConsts();
    const extMax = requireConst(consts, "EXTENSION_TO_HOST_MAX");
    const controlMax = requireConst(consts, "CONTROL_MAX");

    let targetLen;
    let baseObj;
    if (recipeId === "extension_to_host_batch_max") {
      targetLen = extMax;
      baseObj = {
        type: "batch",
        destination_generation: "g",
        inst: "i",
        batch_id: "0123456789abcdef0123456789abcdef",
        queued_at_ms: 0,
        records: [
          {
            t: "segment_start",
            ts: 0,
            ctx: "c",
            blocks: [{ id: "b", text: "x" }],
          },
        ],
        pad: "",
      };
    } else if (recipeId === "extension_to_host_batch_oversize") {
      targetLen = extMax + 1;
      baseObj = {
        type: "batch",
        destination_generation: "g",
        inst: "i",
        batch_id: "0123456789abcdef0123456789abcdef",
        queued_at_ms: 0,
        records: [
          {
            t: "segment_start",
            ts: 0,
            ctx: "c",
            blocks: [{ id: "b", text: "x" }],
          },
        ],
        pad: "",
      };
    } else if (recipeId === "control_payload_max") {
      targetLen = controlMax;
      baseObj = {
        type: "hello",
        protocol: 1,
        version: "1.0.0",
        brand: "chrome",
        inst: "inst1",
        pad: "",
      };
    } else if (recipeId === "control_payload_oversize") {
      targetLen = controlMax + 1;
      baseObj = {
        type: "hello",
        protocol: 1,
        version: "1.0.0",
        brand: "chrome",
        inst: "inst1",
        pad: "",
      };
    } else if (recipeId === "batch_delta_cap_3000") {
      const deltas = [];
      for (let i = 0; i < 1500; i++) {
        deltas.push({ t: "delta", ts: 0, ctx: "c", op: "add", block: { id: "a" + i, text: "t" } });
        deltas.push({ t: "delta", ts: 0, ctx: "c", op: "remove", block: { id: "r" + i } });
      }
      baseObj = {
        type: "batch",
        destination_generation: "g",
        inst: "i",
        batch_id: "0123456789abcdef0123456789abcdef",
        queued_at_ms: 0,
        records: deltas,
      };
      const bytes = encode(baseObj);
      return { bytes, length: bytes.byteLength };
    } else if (recipeId === "batch_delta_oversize_3001") {
      const deltas = [];
      for (let i = 0; i < 1500; i++) {
        deltas.push({ t: "delta", ts: 0, ctx: "c", op: "add", block: { id: "a" + i, text: "t" } });
        deltas.push({ t: "delta", ts: 0, ctx: "c", op: "remove", block: { id: "r" + i } });
      }
      deltas.push({ t: "delta", ts: 0, ctx: "c", op: "add", block: { id: "extra", text: "t" } });
      baseObj = {
        type: "batch",
        destination_generation: "g",
        inst: "i",
        batch_id: "0123456789abcdef0123456789abcdef",
        queued_at_ms: 0,
        records: deltas,
      };
      const bytes = encode(baseObj);
      return { bytes, length: bytes.byteLength };
    } else {
      throw new Error("unknown recipe: " + recipeId);
    }

    const emptyBytes = encode(baseObj);
    const padLen = targetLen - emptyBytes.byteLength;
    if (padLen < 0) throw new Error("base obj exceeds target length");
    baseObj.pad = "a".repeat(padLen);
    const finalBytes = encode(baseObj);
    if (finalBytes.byteLength !== targetLen) {
      throw new Error(`recipe length mismatch: expected ${targetLen}, got ${finalBytes.byteLength}`);
    }
    return { bytes: finalBytes, length: finalBytes.byteLength };
  }

  globalThis.SolstoneNativeBrowser = {
    encode,
    decode,
    buildReply,
    renderRegistration,
    captureIsPermitted,
    handshakeExpired,
    stateRenewalDue,
    freshnessValueAllowed,
    freshnessAuthorizesSkim,
    freshnessAuthorizesDeletion,
    partialFrameExpired,
    futureBeyondTolerance,
    queuedPastOutboxAge,
    acceptedPastMinRetention,
    connectionTokenMatches,
    mayRenewOnConnection,
    buildRecipe,
  };
})();
