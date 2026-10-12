// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc
//
// blocks.js — the block model + pure helpers shared by the skim walker
// (content script) and the segment differ (service worker).
//
// Authored as a classic script that publishes `globalThis.SolstoneBlocks`, so
// it works three ways with no build step:
//   - injected first in a content script `js: [...]` array  -> global
//   - `importScripts('lib/blocks.js')` in the MV3 worker     -> global on `self`
//   - `await import(...)` from a node test                   -> sets globalThis
//
// A "block" is the unit of observed structure:
//   { id, type, depth, text, attrs }
// `type` is derived from ARIA role first, then semantic tag, then a heuristic.
// `text` is normalized direct text-node content (isVisible-gated, capped).
// `attrs` carries a few semantic attributes (aria-label or title, href host,
// level) — never raw HTML.

(function () {
  "use strict";

  const MAX_TEXT = 2000; // per-block visible-text cap
  const MAX_BLOCKS = 1500; // per-skim block cap (virtualized lists only render a window anyway)

  // ARIA role -> block type. Roles we care about for inbox/chat/tracker structure.
  const ROLE_TYPE = {
    heading: "heading",
    article: "message",
    listitem: "listitem",
    row: "row",
    gridcell: "cell",
    cell: "cell",
    rowheader: "cell",
    columnheader: "cell",
    list: "list",
    listbox: "list",
    grid: "list",
    table: "list",
    navigation: "region",
    main: "region",
    complementary: "region",
    region: "region",
    banner: "region",
    contentinfo: "region",
    dialog: "region",
    alert: "alert",
    status: "alert",
    link: "link",
    button: "button",
    textbox: "field",
    searchbox: "field",
  };

  // Semantic tag -> block type (fallback when no usable role).
  const TAG_TYPE = {
    H1: "heading",
    H2: "heading",
    H3: "heading",
    H4: "heading",
    H5: "heading",
    H6: "heading",
    LI: "listitem",
    TR: "row",
    TD: "cell",
    TH: "cell",
    ARTICLE: "message",
    SECTION: "region",
    NAV: "region",
    MAIN: "region",
    ASIDE: "region",
    HEADER: "region",
    FOOTER: "region",
    A: "link",
    BUTTON: "button",
    BLOCKQUOTE: "quote",
  };

  // Pure: derive a block type from role/tag/level strings. Unit-testable with
  // no DOM. `role` may be "" / null; `tag` is an uppercase tagName; `hasLevel`
  // marks an explicit aria-level (forces heading).
  function typeFromRoleTag(role, tag, hasLevel) {
    if (hasLevel) return "heading";
    const r = (role || "").trim().toLowerCase();
    if (r && Object.prototype.hasOwnProperty.call(ROLE_TYPE, r)) return ROLE_TYPE[r];
    const t = (tag || "").toUpperCase();
    if (Object.prototype.hasOwnProperty.call(TAG_TYPE, t)) return TAG_TYPE[t];
    return "text";
  }

  // Pure: small stable string hash (FNV-1a, 32-bit) -> base36. Used for content
  // identity when an app-stable id is unavailable.
  function hashStr(s) {
    let h = 0x811c9dc5;
    const str = String(s);
    for (let i = 0; i < str.length; i++) {
      h ^= str.charCodeAt(i);
      h = Math.imul(h, 0x01000193);
    }
    return (h >>> 0).toString(36);
  }

  // Zero-width / invisible chars that email preheaders + trackers stuff into the
  // DOM (soft-hyphen, CGJ, Mongolian vowel separator, ZWSP/ZWNJ/ZWJ, word-joiner,
  // BOM). Stripping them makes identical content hash identically (kills
  // preheader-junk churn) and collapses pure-invisible runs to empty.
  const INVISIBLE = /[\u00ad\u034f\u180e\u200b-\u200d\u2060\ufeff]/;

  // Pure: count of non-whitespace characters — used to drop junk (single-char,
  // separator-only, or invisible-only) blocks.
  function visibleLen(s) {
    return String(s || "").replace(/\s/g, "").length;
  }

  function sliceCodePoints(s, maxPoints) {
    if (s == null) return "";
    const str = String(s);
    let count = 0;
    let index = 0;
    while (index < str.length && count < maxPoints) {
      const code = str.charCodeAt(index);
      if (code >= 0xd800 && code <= 0xdbff && index + 1 < str.length) {
        const next = str.charCodeAt(index + 1);
        if (next >= 0xdc00 && next <= 0xdfff) {
          index += 2;
          count++;
          continue;
        }
      }
      index++;
      count++;
    }
    return str.slice(0, index);
  }

  function createTextResultBuilder(maxPoints = MAX_TEXT) {
    let out = "";
    let points = 0;
    let pendingWhitespace = "";
    let pendingOverflow = false;
    let truncated = false;

    function appendPoint(point) {
      if (!point || truncated) return;
      if (points === maxPoints) {
        truncated = true;
        return;
      }
      out += point;
      points++;
    }

    function flushWhitespace() {
      if (!out) {
        pendingWhitespace = "";
        pendingOverflow = false;
        return;
      }
      if (pendingOverflow) truncated = true;
      else {
        for (const point of pendingWhitespace) {
          appendPoint(point);
          if (truncated) break;
        }
      }
      pendingWhitespace = "";
      pendingOverflow = false;
    }

    function queueWhitespace(point) {
      if (pendingWhitespace.length > maxPoints) pendingOverflow = true;
      else pendingWhitespace += point;
    }

    function append(value) {
      if (value == null || truncated) return !truncated;
      for (const point of String(value)) {
        if (INVISIBLE.test(point)) continue;
        if (point === "\n") {
          pendingWhitespace = "\n";
          pendingOverflow = false;
          continue;
        }
        if (/[ \t\u00a0]/.test(point)) {
          if (pendingWhitespace !== "\n" && !pendingWhitespace.endsWith(" ")) queueWhitespace(" ");
          continue;
        }
        if (/\s/.test(point)) {
          if (pendingWhitespace !== "\n") queueWhitespace(point);
          continue;
        }
        flushWhitespace();
        appendPoint(point);
        if (truncated) break;
      }
      return !truncated;
    }

    function result() {
      return { text: out + (truncated ? "\u2026" : ""), truncated };
    }

    return { append, result, get truncated() { return truncated; } };
  }

  // Pure: strip invisibles, collapse whitespace, trim, cap length, record truncation.
  function normalizeTextResult(s, maxPoints = MAX_TEXT) {
    const builder = createTextResultBuilder(maxPoints);
    builder.append(s);
    return builder.result();
  }

  function normalizeText(s) {
    return normalizeTextResult(s).text;
  }

  // Pure: derive a block id. Prefer an app-stable id from `stableId` (e.g. a
  // data-message-id the adapter pulled off the node); else hash type+depth+text.
  // Stable across virtualized-list node recycling when an app id exists.
  function blockId(stableId, type, depth, text) {
    if (stableId) return "k:" + sliceCodePoints(stableId, 80);
    return "h:" + hashStr(type + "|" + depth + "|" + sliceCodePoints(text, 200));
  }

  // Pure: reduce the page address before it leaves the page, so query strings,
  // fragments, and user:pass@ credentials never reach the worker, storage, or
  // the wire. `.origin` drops credentials and keeps an explicit port, matching
  // `site` = `location.host`.
  function originPath(href) {
    if (typeof href !== "string") return "";
    try {
      const u = new URL(href);
      if (u.protocol !== "https:" && u.protocol !== "http:") return "";
      return u.origin + u.pathname;
    } catch (_e) {
      return "";
    }
  }

  // DOM helper (browser-only): read the few semantic attrs worth keeping.
  function readAttrs(el, report) {
    const attrs = {};
    const label = el.getAttribute && (el.getAttribute("aria-label") || el.getAttribute("title"));
    if (label) {
      const normalized = normalizeTextResult(label, 300);
      if (normalized.truncated) {
        if (report) {
          report.omitted = true;
          if (report.clips instanceof Set) report.clips.add("label");
        }
      }
      attrs.label = sliceCodePoints(normalized.text, 300);
    }
    const level = el.getAttribute && el.getAttribute("aria-level");
    if (level) attrs.level = level;
    if (el.tagName === "A" && el.getAttribute("href")) {
      // keep only the host, never the full URL (privacy: no query strings/tokens)
      try {
        const u = new URL(el.getAttribute("href"), "http://x.invalid");
        if (u.host && u.host !== "x.invalid") attrs.linkHost = u.host;
      } catch (_e) {
        /* ignore unparseable hrefs */
      }
    }
    return attrs;
  }

  globalThis.SolstoneBlocks = {
    MAX_TEXT,
    MAX_BLOCKS,
    ROLE_TYPE,
    TAG_TYPE,
    typeFromRoleTag,
    hashStr,
    normalizeText,
    normalizeTextResult,
    createTextResultBuilder,
    visibleLen,
    blockId,
    originPath,
    readAttrs,
    sliceCodePoints,
  };
})();
