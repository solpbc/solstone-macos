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

  // Where the solstone app runs. Safari on iPhone and iPad carries it on the same
  // device, and reads while it is closed; everywhere else it is a computer.
  const PLACE = (() => {
    const nav = typeof navigator !== "undefined" ? navigator : {};
    const ua = nav.userAgent || "";
    if (/iPad/.test(ua) || (nav.platform === "MacIntel" && nav.maxTouchPoints > 1)) return "this ipad";
    if (/iPhone|iPod/.test(ua)) return "this iphone";
    return "this computer";
  })();
  const MOBILE = PLACE !== "this computer";

  const DESKTOP_DISCLOSURE = `you choose which sites to share. by default, you add sites one at a time. you can also choose all sites after a separate agreement and leave sites out. on the sites you choose, the solstone extension takes in the page's text and rough layout whenever a tab is open, and all of it goes into your journal:
- the text you can see, the text you'd see by scrolling, text in background tabs, some labels pages provide for screen readers and tooltips, and text the page has but doesn't show you
- each page's address, without anything after a ? or #, its title, when you were on it, and the sites its links point to
- whether the tab was in front, whether its window had focus, whether audio or video was playing, the page's language, which browser it is, and how long the tab has been open
- on a mail or chat site you choose, your messages
- some words you've typed but haven't sent, and anything a site shows, even something you'd consider secret, like a code in an email

never pixels. never raw HTML. sites you leave out aren't taken in, but other sites shown inside those pages still are.

where it goes: nothing leaves this browser except to the solstone app on this computer. from there it goes into your journal over the link the solstone app already uses.

the solstone extension takes in nothing from private windows, even where your browser lets it run there. that covers this extension only.

pause any time in the solstone extension. pausing the solstone app stops this extension too, unless you turn that off in settings. pausing doesn't hold back what's already taken in. if you remove a site, nothing new comes from it; what's already in your journal stays there.

no analytics. no telemetry. no phone home. nobody counted.`;
  const MOBILE_WHILE_CLOSED = `the solstone extension keeps taking in the sites you choose while the solstone app is closed. what it takes in waits on ${PLACE} and goes into your journal the next time you open the solstone app.`;
  const DISCLOSURE_BODY = MOBILE
    ? DESKTOP_DISCLOSURE
      .replace("to the solstone app on this computer. from there it goes into your journal over the link the solstone app already uses.",
        `to the solstone app on ${PLACE}. from there it goes into your journal over the link the solstone app already uses. ${MOBILE_WHILE_CLOSED}`)
      .replace("pausing the solstone app stops this extension too, unless you turn that off in settings.", "pausing Safari in the solstone app stops this extension too.")
      .replace("the solstone extension takes in nothing from private windows, even where your browser lets it run there.", "the solstone extension takes in nothing from private browsing, even where Safari lets it run there.")
    : DESKTOP_DISCLOSURE;

  const STEP1_CANT_REACH_BODY = `the solstone extension works with the solstone app on ${PLACE}, and nothing is taken in without it. if the solstone app isn't on ${PLACE} yet, get it at solstone.app. this page moves on by itself once the solstone app answers.`;
  const STEP1_OPEN_APP_BODY = MOBILE
    ? `the solstone extension works with the solstone app on ${PLACE}, and nothing is taken in without it. the solstone app isn't answering right now. this extension tries again on its own, and this page moves on by itself once it answers.`
    : `the solstone extension works with the solstone app on ${PLACE}, and nothing is taken in without it. open the solstone app to go on. this page moves on by itself once it answers.`;
  const STEP2_PENDING = "you'll agree to this once the step above is done.";
  const STEP1_NOT_PAIRED_BODY = MOBILE
    ? `pair the solstone app on ${PLACE} with your journal and confirm your journal's mark. this page moves on by itself once you have.`
    : `pair the solstone app on ${PLACE} with your journal. this page moves on by itself once it is.`;
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
      what: "on every website your browser allows, including sites you visit later, the solstone extension takes in the page's text, address and rough layout whenever a tab is open, and all of it goes into your journal. this includes background tabs, text the page has but doesn't show you, whether the tab was in front, whether its window had focus, whether audio or video was playing, the page's language, which browser it is, and how long the tab has been open.",
      unsent: "that includes messages on mail and chat sites, words you've typed into a page's editor but haven't sent, and anything a site shows, even something you'd consider secret.",
      leaveOut: [MOBILE ? "you can leave sites out at any time. private browsing is still left out." : "you can leave sites out at any time. private windows are still left out.", ...kept].join(" "),
      destination: `your journal, through the solstone app on ${PLACE}`,
      destinationDetail: `nothing leaves this browser except to the solstone app on ${PLACE}.`,
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

  // A named site covers every address under it (see hosts.js coversSubdomains).
  const LEAVE_OUT_HELP = "leaving out bank.com leaves out all bank.com sites and pages, like www.bank.com and login.bank.com, even inside another page. other sites shown inside its pages are still shared, unless you leave them out too.";
  const ADD_HELP = "adding bank.com shares all bank.com sites and pages, like www.bank.com and login.bank.com. to share only part, add that address, like mail.google.com.";
  const FIELD_ERROR = "enter a website address, like mail.google.com.";

  function addHelp(brand) {
    return `${ADD_HELP} a site you allow in ${browserName(brand)}'s own settings is added here too.`;
  }

  function broadInSelected(brand) {
    return `${browserName(brand)} allows the solstone extension on all websites. only the sites you add are taken in.`;
  }

  function leftOutSummary(n) {
    return `sites left out (${n})`;
  }

  function leftOutRefusal(site) {
    return `${escapeToken(site)} is left out. stop leaving it out first.`;
  }

  function offerLine(brand) {
    return `${browserName(brand)} already allows the solstone extension on these sites:`;
  }

  const appOnlyLeftOut = "left out in the solstone app";
  const desktopScreenOn = "the solstone extension isn't taking in this site. your screen still goes into your journal.";
  const desktopActivityOn = "the solstone extension isn't taking in this site. this browser's activity still goes into your journal.";
  function desktopNeedsAccess(brand) {
    return `the solstone extension isn't taking in this site. the solstone app can't check addresses right now, so this page may not go into your journal from your screen. the solstone app's settings say why.`;
  }
  function appLeftOutSitesOn(brand) {
    return `${browserName(brand)} windows showing it stay out of your journal, on your screen and in activity.`;
  }
  function appLeftOutNeedsAccess(brand) {
    return `${browserName(brand)} windows showing it stay out of your journal, on your screen and in activity. the solstone app can't check addresses right now, so it's keeping out more than this site. its settings say why.`;
  }
  function appLeftOutNotChecked(brand) {
    return `the solstone extension leaves it out. ${browserName(brand)} windows showing it can still go into your journal, on your screen and in activity.`;
  }
  const appLeftOutAppAway = "the solstone app leaves it out too.";
  const extensionLeftOut = "the solstone extension leaves it out.";
  const OFFER_ADD = "add";
  const OFFER_DECLINE = "don't add";

  function popupNoteKey(status, page, kind) {
    status = status || {};
    page = page || {};
    const H = globalThis.SolstoneHosts;
    let pageHost = page.host || "";
    if (!pageHost && page.origin) {
      try { pageHost = new URL(page.origin).hostname; } catch (_e) {}
    }
    const desktop = status.desktop;

    if (kind === "not-added") {
      const appHasList = Array.isArray(status.appLeftOut) && status.appLeftOut.length > 0;
      if (desktop?.screen === true && desktop?.sites === "needs_access" && appHasList) return "desktopNeedsAccess";
      if (desktop?.screen === true) return "desktopScreenOn";
      if (desktop?.screen !== true && desktop?.activity === true) return "desktopActivityOn";
      return "";
    }

    if (kind === "left-out") {
      const appLeftOut = Array.isArray(status.appLeftOut) ? status.appLeftOut : [];
      const appCovers = !!(pageHost && appLeftOut.some((entry) => H?.hostCovers ? H.hostCovers(entry, pageHost) : false));
      if (appCovers) {
        // With neither the screen nor activity going in, the app's list is all that matters.
        if (!desktop || (desktop.screen !== true && desktop.activity !== true)) return "appLeftOutAppAway";
        if (desktop.sites === "on") return "appLeftOutSitesOn";
        if (desktop.sites === "needs_access") return "appLeftOutNeedsAccess";
        return "appLeftOutNotChecked";
      }
      return "extensionLeftOut";
    }

    return "";
  }

  function wholeSite(host) {
    const H = globalThis.SolstoneHosts;
    return !!H?.coversSubdomains?.(H.matchHostFor(String(host || "").replace(/^https?:\/\//i, "")));
  }
  const ADD_DENIED = "permission declined. nothing added.";

  // Safari on a Mac doesn't ask about a site while it allows a site under it,
  // and says the request succeeded without granting anything. Elsewhere a
  // failed add is an ordinary decline.
  function addBlockedBelow(brand, host, under) {
    if (brand !== "safari" || MOBILE || !host || !under) return "";
    const h = escapeToken(host);
    return `Safari won't ask about ${h} while it allows ${escapeToken(under)}. to add ${h}, set it to Allow in Safari's website settings.`;
  }
  const ADD_NOT_NOW = "can't add a site right now. the status above says why.";

  function alreadyAdded(host) {
    return `${escapeToken(host)} is already on your list.`;
  }

  function removedAnnouncement(host) {
    return `${escapeToken(host)} removed. nothing new comes from it; what's already in your journal stays there.`;
  }

  function includedAnnouncement(host) {
    return wholeSite(host)
      ? `all ${escapeToken(host)} sites and pages are no longer left out.`
      : `${escapeToken(host)} is no longer left out.`;
  }

  function addedAnnouncement(host, onNow) {
    const named = wholeSite(host) ? `all ${escapeToken(host)} sites and pages added.` : `${escapeToken(host)} added.`;
    return onNow ? `${named} what you share there now goes into your journal.` : named;
  }

  function adoptedAnnouncement(brand, sites) {
    const bName = browserName(brand);
    const list = Array.isArray(sites) ? sites : [sites].filter(Boolean);
    if (list.length > 1) {
      return `${list.length} sites added. you allowed them in ${bName}. what you share there goes into your journal.`;
    }
    if (list.length === 1) {
      const item = list[0];
      const host = typeof item === "string" ? item : (item.host || item.site || "");
      const H = globalThis.SolstoneHosts;
      const isLocal = H?.isLocalHostname ? H.isLocalHostname(host) : false;
      const isSiteWide = typeof item === "object" && item.siteWide !== undefined ? item.siteWide : (H?.coversSubdomains ? H.coversSubdomains(host) : false);
      const escaped = escapeToken(host);
      if (isSiteWide && !isLocal) {
        return `all ${escaped} sites and pages added. you allowed them in ${bName}. what you share there goes into your journal.`;
      }
      return `${escaped} added. you allowed it in ${bName}. what you share there goes into your journal.`;
    }
    return "";
  }

  // A site added before sites covered their subdomains, which the browser still
  // allows on its exact address alone.
  function exactOnlyCopy(brand, hosts) {
    const bName = browserName(brand);
    const list = Array.from(hosts || []);
    // Safari can't widen a site it already allows, so there's no button there.
    if (brand === "safari") {
      if (list.length === 1) {
        const host = escapeToken(list[0]);
        return {
          line: `${host} covers only that address. to include all ${host} sites and pages, remove it and add it again.`,
          label: "",
          declined: "",
        };
      }
      // Named, since each one is removed and added again by hand.
      const names = list.map((h) => escapeToken(h));
      const named = `${names.slice(0, -1).join(", ")} and ${names[names.length - 1]}`;
      return {
        line: `${named} cover only their exact address. to include all their sites and pages, remove each one and add it again.`,
        label: "",
        declined: "",
      };
    }
    if (list.length === 1) {
      const host = escapeToken(list[0]);
      return {
        line: `${host} covers only that address. to include all ${host} sites and pages, allow them in ${bName}.`,
        label: `allow all ${host} sites`,
        declined: `permission declined. ${host} keeps its exact address only.`,
      };
    }
    return {
      line: `${list.length} of your sites cover only their exact address. to include all their sites and pages, allow them in ${bName}.`,
      label: "allow them",
      declined: "permission declined. those sites keep their exact address only.",
    };
  }



  function keptNote(mode, count) {
    if (!(count > 0)) return "";
    return mode === "all"
      ? plural(count, "your added site is kept for when you switch back.", "your {n} added sites are kept for when you switch back.")
      : plural(count, "the site you left out stays left out if you choose all sites again.", "the {n} sites you left out stay left out if you choose all sites again.");
  }

  function leftOutAnnouncement(host) {
    return wholeSite(host)
      ? `all ${escapeToken(host)} sites and pages left out. other sites shown inside them are still shared.`
      : `${escapeToken(host)} left out. other sites shown inside its pages are still shared.`;
  }

  // What the settings page says about the browser's own grant in all-sites mode.
  function accessCopy(brand) {
    const bName = browserName(brand);
    const safari = brand === "safari";
    return {
      granted: `${bName} allows solstone on all websites.`,
      grantedNote: safari ? (MOBILE ? "in Settings, under Apps, Safari, Extensions, solstone, a site set to Deny stays off." : "a site set to Deny in Safari's website settings stays off.") : "",
      missingTitle: safari ? "allow all websites in Safari" : `${bName} isn't allowing all websites`,
      missingBody: safari
        ? "Safari allows this only in its own settings. nothing new is taken in until you allow it:"
        : "nothing new is taken in until it does. allow it, or switch back to sites you add.",
      steps: safari && MOBILE ? [
        "in Settings, open Apps, then Safari, then Extensions, then solstone.",
        "set Other Websites to Allow.",
      ] : safari ? [
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
        ? (MOBILE ? "Safari still isn't allowing all websites. set Other Websites to Allow." : "Safari still isn't allowing all websites. set For other websites to Allow.")
        : `${bName} still isn't allowing all websites.`,
      declined: "permission declined. nothing new is taken in until you allow it.",
      failedTitle: "couldn't start on your sites",
      failedBody: `something went wrong turning on all sites in ${bName}.`,
      retryLabel: "try again",
      deniedTitle: safari ? "Safari is denying these sites, so they aren't taken in:" : `${bName} doesn't let this extension take in these sites:`,
      deniedHelp: safari ? (MOBILE ? "to include one, set it to Allow in Settings, under Apps, Safari, Extensions, solstone." : "to include one, set it to Allow in Safari's website settings for solstone.") : "",
    };
  }

  // The page block's own words for pages the extension can't or won't read.
  function pageCopy(brand) {
    const bName = browserName(brand);
    const safari = brand === "safari";
    return {
      privateState: MOBILE ? "private browsing" : "private window",
      privateNote: MOBILE ? "this extension takes in nothing from private browsing." : "this extension takes in nothing from private windows.",
      restrictedState: `${bName} doesn't let extensions work on this page`,
      unknownState: "this extension can't reach this page",
      unknownNote: safari ? (MOBILE ? "if it's set to Deny in Settings, under Apps, Safari, Extensions, solstone, it isn't taken in." : "if it's set to Deny in Safari's website settings, it isn't taken in.") : "",
      deniedState: `${bName} is denying this site`,
      deniedNote: safari ? (MOBILE ? "to include it, set it to Allow in Settings, under Apps, Safari, Extensions, solstone." : "to include it, set it to Allow in Safari's website settings.") : "",
      leaveOutNote: (host) => wholeSite(host)
        ? `leaving it out covers all ${escapeToken(host)} sites and pages. other sites shown inside them are still shared.`
        : `leaving it out covers ${escapeToken(host)}. other sites shown inside its pages are still shared.`,
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
    return MOBILE
      ? `open a site you want to share, open solstone from Safari's page menu, and choose add this site. ${browserName(brand)} will ask you to allow it.`
      : `open a site you want to share, open solstone from your browser's toolbar or extensions menu, and choose add this site. ${browserName(brand)} will ask you to allow it.`;
  }

  // Linux reasons. Only the can't-reach one is called: the others wait on
  // command names the Linux app doesn't have yet.
  function linuxUpdateAppReason(cmd) {
    return `this extension needs a newer version of the solstone app on ${PLACE}. run ${escapeToken(cmd)} to get it.`;
  }

  function linuxCantReachAppReason(cmd = "solstone-linux doctor") {
    return `start the solstone app on ${PLACE}. if it's already running, ${escapeToken(cmd)} says what's wrong.`;
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
    const whole = wholeSite(hostInput);
    return {
      title: whole ? `add all ${host} sites and pages?` : `add ${host}?`,
      what: `${whole ? `on every ${host} site and page` : `on ${host}`}, the solstone extension takes in the page's text and rough layout whenever a tab is open, and all of it goes into your journal: what you can see, what you'd see by scrolling, background tabs, some labels meant for screen readers, text the page has but doesn't show you, each page's address, title and time, the sites its links point to. it also takes in whether the tab was in front, whether its window had focus, whether audio or video was playing, the page's language, which browser it is, and how long the tab has been open. never pixels.`,
      unsent: `that can include words you've typed but haven't sent, and anything the site shows, even something you'd consider secret.`,
      destinationLabel: `it goes to`,
      destination: `your journal, through the solstone app on ${PLACE}`,
      destinationDetail: `nothing leaves this browser except to the solstone app on ${PLACE}.`,
      browser: `${bName} will ask you to allow this next. you can remove the site any time; what's already in your journal stays there.`,
      confirmLabel: `add this site`,
      cancelLabel: `cancel`,
    };
  }

  const RESTRICTED = /Cannot access|chrome:\/\/|moz-extension:\/\/|about:|Web Store|match pattern/i;

  // What a site's row says when something went wrong there. Internal codes
  // never reach the owner; each line says what happened and what follows.
  function classifyFailure(raw, brandInput) {
    const s = raw == null ? "" : String(raw);
    if (RESTRICTED.test(s)) return `${browserName(brandInput)} doesn't let extensions work on this page`;
    if (s === "failed" || s === "registration_failed") return "couldn't start on this site. remove it and add it again.";
    if (s === "enqueue_failed" || s === "storage_error") return "a page from this site couldn't be kept. the extension tries again when the page changes.";
    if (s === "outbox-full") return "no room for more from this site right now";
    if (s === "batch-oversize" || s === "schema-refuse") return "a page from this site couldn't be kept";
    return "something went wrong on this site";
  }

  // What a button says when its action didn't work.
  function actionFailure(raw, brandInput) {
    const s = raw == null ? "" : String(raw);
    if (RESTRICTED.test(s)) return `${browserName(brandInput)} doesn't let extensions work on this page`;
    if (s === "storage_error") return "couldn't save that. try again.";
    if (s === "permissions_changed") return `${browserName(brandInput)}'s permissions changed while saving. try again.`;
    if (["capture_unavailable", "permission_not_granted", "registration_failed", "invalid_phase"].includes(s)) return "couldn't add the site. try again.";
    if (s === "missing_consent") return "finish setting up first.";
    if (s === "invalid_host" || s === "invalid_origin") return FIELD_ERROR;
    if (s === "site_excluded") return "this site is left out. stop leaving it out first.";
    if (s === "declined") return `you chose not to add this site. to add it, allow it in ${browserName(brandInput)} again.`;
    if (s === "permissions_unavailable") return `couldn't check what ${browserName(brandInput)} allows. try again.`;
    return "something went wrong. try again.";
  }

  globalThis.SolstoneCopy = {
    PLACE,
    MOBILE,
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
    STEP1_OPEN_APP_BODY,
    STEP2_PENDING,
    ADD_HELP,
    FIELD_ERROR,
    ADD_DENIED,
    addBlockedBelow,
    ADD_NOT_NOW,
    alreadyAdded,
    removedAnnouncement,
    includedAnnouncement,
    addedAnnouncement,
    exactOnlyCopy,
    actionFailure,
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
    addHelp,
    adoptedAnnouncement,
    broadInSelected,
    leftOutSummary,
    leftOutRefusal,
    offerLine,
    popupNoteKey,
    appOnlyLeftOut,
    desktopScreenOn,
    desktopActivityOn,
    appLeftOutSitesOn,
    appLeftOutNeedsAccess,
    desktopNeedsAccess,
    appLeftOutNotChecked,
    appLeftOutAppAway,
    extensionLeftOut,
    OFFER_ADD,
    OFFER_DECLINE,
  };
})();
