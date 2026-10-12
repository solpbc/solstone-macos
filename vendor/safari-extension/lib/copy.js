// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

(function () {
  "use strict";

  const Blocks = globalThis.SolstoneBlocks;

  function escapeToken(str) {
    if (str == null) return "";
    let s = String(str);
    if (Blocks && Blocks.sliceCodePoints) s = Blocks.sliceCodePoints(s, 180);
    else if (s.length > 180) s = s.slice(0, 180);
    // strip control characters (0-31 except space, and 127)
    s = s.replace(/[\x00-\x1f\x7f]/g, "");
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }

  function browserName(brand) {
    if (brand === "firefox") return "Firefox";
    if (brand === "edge") return "Edge";
    if (brand === "chrome") return "Chrome";
    return "your browser";
  }

  const WARM_CARD = [
    "welcome to solstone.",
    "the solstone app takes in what you share with it, and all of it goes into your journal.",
    "your journal is always private, only yours.",
  ];

  const DISCLOSURE_BODY = `you choose which sites to share. on a site you add, the solstone extension takes in the page's text and rough layout whenever a tab is open, and all of it goes into your journal:
- the text you can see, the text you'd see by scrolling, text in background tabs, some labels pages provide for screen readers and tooltips, and text the page has but doesn't show you
- each page's address, without anything after a ? or #, its title, when you were on it, and the sites its links point to
- on a mail or chat site you add, your messages
- some words you've typed but haven't sent, and anything a site shows, even something you'd consider secret, like a code in an email

never pixels. never raw HTML. never a site you didn't add.

where it goes: nothing leaves this browser except to the solstone app on this computer. from there it goes into your journal over the link the solstone app already uses.

the solstone extension takes in nothing from private windows, even where your browser lets it run there. that covers this extension only.

pause any time in the solstone extension, or pause the solstone app to stop everything at once. pausing doesn't hold back what's already taken in. if you remove a site, nothing new comes from it; what's already in your journal stays there.

no analytics. no telemetry. no phone home. nobody counted.`;

  const STEP1_CANT_REACH_BODY = "the solstone extension works with the solstone app on this computer, and nothing is taken in without it. if the solstone app isn't on this computer yet, get it at solstone.app. this page moves on by itself once the solstone app answers.";
  const STEP1_NOT_PAIRED_BODY = "pair the solstone app on this computer with your journal. this page moves on by itself once it is.";
  const STEP1_INTAKE_OFF_BODY = "turn them on under sources in the solstone app's settings. this page moves on by itself.";
  const TRUNCATION_ATTENTION = "part of what you shared on this site was too long to keep";

  function step3Body(brand) {
    return `open a site you want to share, open solstone from your browser's toolbar or extensions menu, and choose add this site. ${browserName(brand)} will ask you to allow it.`;
  }

  // Linux pure functions (not called in production derivation or UI)
  function linuxUpdateAppReason(cmd) {
    return `this extension needs a newer version of the solstone app on this computer. run ${escapeToken(cmd)} to get it.`;
  }

  function linuxCantReachAppReason(cmd = "solstone-linux doctor") {
    return `start the solstone app on this computer. if it's already running, ${escapeToken(cmd)} says what's wrong.`;
  }

  function linuxIntakeOffReason(cmd) {
    return `turn them back on with ${escapeToken(cmd)}.`;
  }

  function linuxStep1IntakeOffBody(cmd) {
    return `turn them on with ${escapeToken(cmd)}.`;
  }

  function sheetCopy(hostInput, brandInput) {
    const host = escapeToken(hostInput);
    const bName = browserName(brandInput);
    return {
      title: `add ${host}?`,
      what: `on ${host}, the solstone extension takes in the page's text and rough layout whenever a tab is open, and all of it goes into your journal: what you can see, what you'd see by scrolling, background tabs, some labels meant for screen readers, text the page has but doesn't show you, each page's address, title and time, and the sites its links point to. never pixels.`,
      unsent: `that can include words you've typed but haven't sent, and anything the site shows, even something you'd consider secret.`,
      destinationLabel: `it goes to`,
      destination: `your journal, through the solstone app on this computer`,
      destinationDetail: `nothing leaves this browser except to the solstone app on this computer.`,
      browser: `${bName} will ask you to allow this next. you can remove the site any time; what's already in your journal stays there.`,
      confirmLabel: `add this site`,
      cancelLabel: `cancel`,
    };
  }

  function classifyFailure(raw, brandInput) {
    const bName = browserName(brandInput);
    const s = raw == null ? "" : String(raw);
    if (/Cannot access|chrome:\/\/|moz-extension:\/\/|about:|Web Store|match pattern/i.test(s)) {
      return `${bName} doesn't let extensions work on this page`;
    }
    let short = s.replace(/\s+/g, " ").trim();
    if (short.length > 80) short = short.slice(0, 80) + "\u2026";
    return `something went wrong on this site: ${escapeToken(short)}`;
  }

  globalThis.SolstoneCopy = {
    escapeToken,
    browserName,
    WARM_CARD,
    DISCLOSURE_BODY,
    STEP1_CANT_REACH_BODY,
    STEP1_NOT_PAIRED_BODY,
    STEP1_INTAKE_OFF_BODY,
    TRUNCATION_ATTENTION,
    step3Body,
    linuxUpdateAppReason,
    linuxCantReachAppReason,
    linuxIntakeOffReason,
    linuxStep1IntakeOffBody,
    sheetCopy,
    classifyFailure,
  };
})();
