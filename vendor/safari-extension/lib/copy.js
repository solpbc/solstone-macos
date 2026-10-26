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
    if (brand === "safari") return "Safari";
    return "your browser";
  }

  const WARM_CARD = [
    "welcome to solstone.",
    "the solstone app takes in what you share with it, and all of it goes into your journal.",
    "your journal is always private, only yours.",
  ];

  const DISCLOSURE_BODY = `you choose which sites to share. by default, you add sites one at a time. you can also choose all sites after a separate agreement and leave sites out. on the sites you choose, the solstone extension takes in the page's text and rough layout whenever a tab is open, and all of it goes into your journal:
- the text you can see, the text you'd see by scrolling, text in background tabs, some labels pages provide for screen readers and tooltips, and text the page has but doesn't show you
- each page's address, without anything after a ? or #, its title, when you were on it, and the sites its links point to
- on a mail or chat site you choose, your messages
- some words you've typed but haven't sent, and anything a site shows, even something you'd consider secret, like a code in an email

never pixels. never raw HTML. sites you leave out aren't taken in, but other sites shown inside those pages still are.

where it goes: nothing leaves this browser except to the solstone app on this computer. from there it goes into your journal over the link the solstone app already uses.

the solstone extension takes in nothing from private windows, even where your browser lets it run there. that covers this extension only.

pause any time in the solstone extension, or pause the solstone app to stop everything at once. pausing doesn't hold back what's already taken in. if you remove a site, nothing new comes from it; what's already in your journal stays there.

no analytics. no telemetry. no phone home. nobody counted.`;

  const STEP1_CANT_REACH_BODY = "the solstone extension works with the solstone app on this computer, and nothing is taken in without it. if the solstone app isn't on this computer yet, get it at solstone.app. this page moves on by itself once the solstone app answers.";
  const STEP1_NOT_PAIRED_BODY = "pair the solstone app on this computer with your journal. this page moves on by itself once it is.";
  const STEP1_INTAKE_OFF_BODY = "turn them on under sources in the solstone app's settings. this page moves on by itself.";
  const TRUNCATION_ATTENTION = "part of what you shared on this site was too long to keep";

  function plural(n, one, many) {
    return n === 1 ? one : many.replace("{n}", String(n));
  }

  // The separate all-sites agreement. `context` carries the counts that carry over
  // between modes, so the owner sees what is kept before agreeing.
  function allSitesCopy(brand, context) {
    const bName = browserName(brand);
    const excluded = Number(context?.excludedCount) || 0;
    const chosen = Number(context?.chosenCount) || 0;
    const kept = [];
    if (excluded > 0) kept.push(plural(excluded, "the site you left out before stays left out.", "the {n} sites you left out before stay left out."));
    if (chosen > 0) kept.push(plural(chosen, "your added site is kept for when you switch back.", "your {n} added sites are kept for when you switch back."));
    return {
      title: "share all sites?",
      what: "on every website your browser allows, including sites you visit later, the solstone extension takes in the page's text, address and rough layout whenever a tab is open, and all of it goes into your journal. this includes background tabs and text the page has but doesn't show you.",
      unsent: "that includes messages on mail and chat sites, words you've typed into a page's editor but haven't sent, and anything a site shows, even something you'd consider secret.",
      leaveOut: ["you can leave sites out at any time. private windows are still left out.", ...kept].join(" "),
      destination: "your journal, through the solstone app on this computer",
      destinationDetail: "nothing leaves this browser except to the solstone app on this computer.",
      browser: brand === "safari"
        ? "next, you allow it in Safari's own settings, and this page shows you how. nothing new is taken in until you do."
        : `${bName} asks you to allow access to all websites next. if you don't, nothing changes.`,
      confirmLabel: "agree and share all sites", cancelLabel: "cancel",
    };
  }

  // The two ways of choosing what to share, as the settings page offers them.
  const SITE_MODES = {
    selected: { title: "sites you add", body: "only the sites you add, one at a time." },
    all: { title: "all sites", body: "every website, including ones you visit later, except sites you leave out. it has its own agreement." },
    current: "sharing this way",
    chooseAll: "choose all sites",
    chooseSelected: "switch to sites you add",
  };

  const LEAVE_OUT_HELP = "a site you leave out isn't taken in, even inside another page. other sites shown inside its pages are still shared, unless you leave them out too. leave out each exact address, like mail.google.com: google.com and mail.google.com are separate sites.";

  function keptNote(mode, count) {
    if (!(count > 0)) return "";
    return mode === "all"
      ? plural(count, "your added site is kept for when you switch back.", "your {n} added sites are kept for when you switch back.")
      : plural(count, "the site you left out stays left out if you choose all sites again.", "the {n} sites you left out stay left out if you choose all sites again.");
  }

  function leftOutAnnouncement(host) {
    return `${escapeToken(host)} left out. other subdomains, and other sites shown inside its pages, are still shared.`;
  }

  // What the settings page says about the browser's own grant in all-sites mode.
  function accessCopy(brand) {
    const bName = browserName(brand);
    const safari = brand === "safari";
    return {
      granted: `${bName} allows solstone on all websites.`,
      grantedNote: safari ? "a site set to Deny in Safari's website settings stays off." : "",
      missingTitle: safari ? "allow all websites in Safari" : `${bName} isn't allowing all websites`,
      missingBody: safari
        ? "Safari allows this only in its own settings. nothing new is taken in until you allow it:"
        : "nothing new is taken in until it does. allow it, or switch back to sites you add.",
      steps: safari ? [
        "in Safari, choose Safari \u203a Settings, then Websites.",
        "under Extensions on the left, choose solstone.",
        "set For other websites to Allow.",
      ] : [],
      returnNote: safari ? "this page checks again when you come back to it." : "",
      allowLabel: `allow in ${bName}`,
      checkLabel: "check again",
      checking: `checking ${bName}\u2026`,
      nowAllowed: `${bName} now allows all websites. all sites are on.`,
      stillMissing: safari
        ? "Safari still isn't allowing all websites. set For other websites to Allow."
        : `${bName} still isn't allowing all websites.`,
      declined: "permission declined. nothing new is taken in until you allow it.",
      failedTitle: "couldn't start on your sites",
      failedBody: `something went wrong turning on all sites in ${bName}.`,
      retryLabel: "try again",
      deniedTitle: safari ? "Safari is denying these sites, so they aren't taken in:" : `${bName} doesn't let this extension take in these sites:`,
      deniedHelp: safari ? "to include one, set it to Allow in Safari's website settings for solstone." : "",
    };
  }

  // The page block's own words for pages the extension can't or won't read.
  function pageCopy(brand) {
    const bName = browserName(brand);
    const safari = brand === "safari";
    return {
      privateState: "private window",
      privateNote: "this extension takes in nothing from private windows.",
      restrictedState: `${bName} doesn't let extensions work on this page`,
      unknownState: "this extension can't reach this page",
      unknownNote: safari ? "if it's set to Deny in Safari's website settings, it isn't taken in." : "",
      deniedState: `${bName} is denying this site`,
      deniedNote: safari ? "to include it, set it to Allow in Safari's website settings." : "",
      leaveOutNote: (host) => `leaving it out covers ${escapeToken(host)} only. other subdomains, and other sites shown inside its pages, are still shared.`,
    };
  }

  function regrantCopy(brand, count) {
    return {
      line: plural(count, `${browserName(brand)} needs to allow 1 of your sites again.`, `${browserName(brand)} needs to allow {n} of your sites again.`),
      label: count === 1 ? "allow it again" : "allow them again",
    };
  }

  function sharingSummary(mode, excludedCount, siteLine) {
    if (mode === "all") return excludedCount > 0 ? `all sites \u00b7 ${excludedCount} left out` : "all sites";
    return `sites you add \u00b7 ${siteLine || "none yet"}`;
  }

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
    allSitesCopy,
    SITE_MODES,
    LEAVE_OUT_HELP,
    keptNote,
    leftOutAnnouncement,
    accessCopy,
    pageCopy,
    regrantCopy,
    sharingSummary,
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
