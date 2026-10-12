// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

(function () {
  "use strict";

  const B = globalThis.SolstoneBlocks;

  function getMaxBlocks() {
    const C = globalThis.SolstoneNativeBrowserConstants;
    return (C && C.BLOCKS_MAX) || (B && B.MAX_BLOCKS) || 1500;
  }

  function isVisible(el) {
    if (!el || el.nodeType !== 1) return false;
    if (typeof el.checkVisibility === "function") {
      return el.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true });
    }
    if (el.getClientRects && el.getClientRects().length === 0) return false;
    if ("offsetParent" in el && el.offsetParent === null) {
      if (el.getClientRects && el.getClientRects().length > 0) return true;
      return false;
    }
    return true;
  }

  function directTextResult(el) {
    if (B.createTextResultBuilder) {
      const builder = B.createTextResultBuilder(B.MAX_TEXT);
      for (const node of el.childNodes || []) {
        if (node.nodeType === 3 && !builder.append(node.nodeValue)) break;
      }
      return builder.result();
    }
    let s = "";
    for (const node of el.childNodes || []) if (node.nodeType === 3) s += node.nodeValue;
    return B.normalizeTextResult ? B.normalizeTextResult(s) : { text: B.normalizeText(s), truncated: false };
  }

  function directText(el) {
    return directTextResult(el).text;
  }

  function matchesAny(el, selector) {
    if (!selector || !el.matches) return false;
    try {
      return el.matches(selector);
    } catch (_e) {
      return false;
    }
  }

  function walk(el, adapter, out, depth, boundaryId, maxBlocks, state) {
    if (state.stopped) return;
    if (!isVisible(el)) return;
    if (matchesAny(el, adapter.skip)) return;

    const tag = el.tagName;
    if (tag === "SCRIPT" || tag === "STYLE" || tag === "NOSCRIPT" || tag === "SVG") return;

    let nextBoundaryId = boundaryId;

    if (matchesAny(el, adapter.boundary)) {
      const A = globalThis.SolstoneAdapters;
      const sid = A.stableIdFor(el, adapter);
      const attrs = B.readAttrs(el, state);
      const label = attrs.label || "";
      if (sid || label) {
        if (out.length >= maxBlocks) {
          state.omitted = true;
          state.clips.add("blocks");
          state.stopped = true;
          return;
        }
        const role = el.getAttribute && el.getAttribute("role");
        const type = B.typeFromRoleTag(role, tag, false);
        const utype = type === "text" ? "unit" : type;
        const id = B.blockId(sid, utype, depth, label);
        const block = { id, type: utype, depth, text: label };
        if (Object.keys(attrs).length) block.attrs = attrs;
        out.push(block);
      }
      if (sid) nextBoundaryId = sid;
    }

    const textRes = directTextResult(el);
    const text = textRes.text;
    if (textRes.truncated) {
      state.omitted = true;
      state.clips.add("text");
    }

    if (text && B.visibleLen(text) > 1) {
      if (out.length >= maxBlocks) {
        state.omitted = true;
        state.clips.add("blocks");
        state.stopped = true;
        return;
      }
      const role = el.getAttribute && el.getAttribute("role");
      const hasLevel = !!(el.getAttribute && el.getAttribute("aria-level"));
      const type = B.typeFromRoleTag(role, tag, hasLevel);
      const attrs = B.readAttrs(el, state);
      const keyed = boundaryId ? boundaryId + ":" + B.hashStr(text) : null;
      const id = B.blockId(keyed, type, depth, text);
      const block = { id, type, depth, text };
      if (Object.keys(attrs).length) block.attrs = attrs;
      out.push(block);
    }

    if (el.shadowRoot) {
      for (const child of el.shadowRoot.children) {
        walk(child, adapter, out, depth + 1, nextBoundaryId, maxBlocks, state);
      }
    }
    for (const child of el.children) {
      walk(child, adapter, out, depth + 1, nextBoundaryId, maxBlocks, state);
    }
  }

  function skim(root, adapter) {
    const out = [];
    const state = { omitted: false, clips: new Set(), stopped: false };
    if (!root) return { blocks: out, omitted: false, clips: [] };
    const maxBlocks = getMaxBlocks();
    walk(root, adapter, out, 0, null, maxBlocks, state);
    return { blocks: out, omitted: !!state.omitted, clips: Array.from(state.clips).sort() };
  }

  globalThis.SolstoneSkim = { skim, isVisible, directText, directTextResult };
})();
