// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc
//
// adapters.js — thin per-app config that scopes the skim and supplies stable
// ids for the marquee apps, over a solid generic fallback. An adapter is data,
// not code: ~10-20 lines per app. The generic walker handles everything else.
//
// Classic content script -> publishes `globalThis.SolstoneAdapters`.

(function () {
  "use strict";

  // Each adapter:
  //   name           label for the journal line
  //   match(host)    does this adapter own the current site?
  //   roots          ordered selectors for the app content root (first match wins)
  //   boundary       selector marking a structural unit (message/row/conversation)
  //   stableIdAttrs  attributes to read an app-stable id off a boundary element
  //   skip           selectors whose subtrees are chrome we never observe
  const GMAIL = {
    name: "gmail",
    match: (h) => h === "mail.google.com",
    roots: ['div[role="main"]'],
    boundary: 'tr.zA, div[role="listitem"], div[data-message-id], div[role="article"]',
    stableIdAttrs: ["data-legacy-message-id", "data-message-id", "data-thread-perm-id", "id"],
    skip: ['[role="navigation"]', '[gh="cm"]', "[aria-label='Search mail']"],
  };

  const SLACK = {
    name: "slack",
    match: (h) => h === "app.slack.com",
    roots: ['.p-workspace__primary_view_body', '[role="main"]', '.p-view_contents'],
    boundary: '[data-qa="message_container"], [data-qa="virtual-list-item"], [role="listitem"]',
    stableIdAttrs: ["data-item-key", "data-qa-message-id", "id"],
    skip: ['[data-qa="message_input"]', '.p-workspace__sidebar', '[data-qa="channel_sidebar"]'],
  };

  const GENERIC = {
    name: "generic",
    match: () => true,
    roots: ['[role="main"]', "main", "body"],
    boundary: '[role="listitem"], [role="article"], [role="row"], article, [data-message-id], [data-item-id]',
    stableIdAttrs: ["data-message-id", "data-item-id", "data-id", "data-testid", "id"],
    skip: ['[role="navigation"]', "nav", "header", "footer", '[role="search"]'],
  };

  const ADAPTERS = [GMAIL, SLACK, GENERIC];

  function adapterForHost(host) {
    return ADAPTERS.find((a) => a.match(host)) || GENERIC;
  }

  function pickRoot(adapter, doc) {
    for (const sel of adapter.roots) {
      const el = doc.querySelector(sel);
      if (el) return el;
    }
    return doc.body || doc.documentElement;
  }

  // An id is only useful as a delta key if it's STABLE across re-renders. Some
  // apps (notably Gmail) put volatile per-render ids on elements — Gmail's are
  // colon-prefixed (`:mk`, `:my`, `:1vxl9at`) and get reassigned on every
  // re-render, so keying on them turns each render into remove-old + add-new
  // churn. Reject those; the walker falls back to content-hash keying, which is
  // stable while the text is stable.
  function isVolatileId(v) {
    return !v || v.startsWith(":");
  }

  function stableIdFor(el, adapter) {
    if (!el || !el.getAttribute) return null;
    for (const attr of adapter.stableIdAttrs) {
      const v = el.getAttribute(attr);
      if (v && !isVolatileId(v)) return v;
    }
    return null;
  }

  globalThis.SolstoneAdapters = {
    ADAPTERS,
    GMAIL,
    SLACK,
    GENERIC,
    adapterForHost,
    pickRoot,
    stableIdFor,
    isVolatileId,
  };
})();
