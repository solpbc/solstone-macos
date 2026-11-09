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
  // Safari on iPad opens extensions from a button in its address bar; its page menu lists none.
  const SAFARI_MENU = PLACE === "this ipad" ? "the extensions button in Safari's address bar" : "Safari's page menu";

  const DESKTOP_DISCLOSURE = `the sites you allow in your browser are the sites the solstone extension takes in, and that can be every site. on those sites, it takes in the page's text and rough layout whenever a tab is open, and all of it goes into your journal:
- the text you can see, the text you'd see by scrolling, text in background tabs, some labels pages provide for screen readers and tooltips, and text the page has but doesn't show you
- each page's address, without anything after a ? or #, its title, when you were on it, and the sites its links point to
- whether the tab was in front, whether its window had focus, whether audio or video was playing, the page's language, which browser it is, and how long the tab has been open
- on a mail or chat site, your messages
- some words you've typed but haven't sent, and anything a site shows, even something you'd consider secret, like a code in an email

never pixels. never raw HTML. sites you leave out aren't taken in, but other sites shown inside those pages still are.

where it goes: nothing leaves this browser except to the solstone app on this computer. from there it goes into your journal over the link the solstone app already uses.

the solstone extension takes in nothing from private windows, even where your browser lets it run there. that covers this extension only.

pause any time in the solstone extension. pausing the solstone app stops this extension too, unless you turn that off in settings. pausing doesn't hold back what's already taken in. if you remove a site, nothing new comes from it; what's already in your journal stays there.

no analytics. no telemetry. no phone home. nobody counted.`;
  const MOBILE_WHILE_CLOSED = `the solstone extension keeps taking in the sites you allow while the solstone app is closed. what it takes in waits on ${PLACE} and goes into your journal the next time you open the solstone app.`;
  const MOBILE_DISCLOSURE_EDITS = [
    [
      "to the solstone app on this computer. from there it goes into your journal over the link the solstone app already uses.",
      `to the solstone app on ${PLACE}. from there it goes into your journal over the link the solstone app already uses. ${MOBILE_WHILE_CLOSED}`,
    ],
    [
      " pausing the solstone app stops this extension too, unless you turn that off in settings.",
      "",
    ],
    [
      "the solstone extension takes in nothing from private windows, even where your browser lets it run there.",
      "the solstone extension takes in nothing from private browsing, even where Safari lets it run there.",
    ],
  ];
  const DISCLOSURE_BODY = MOBILE
    ? MOBILE_DISCLOSURE_EDITS.reduce((text, edit) => text.replace(edit[0], edit[1]), DESKTOP_DISCLOSURE)
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

  const SHARE_EVERY_SITE = "share every site";
  const STOP_SHARING_EVERY_SITE = "stop sharing every site";

  function fenceQuestion(brand, kind, host) {
    const browser = browserName(brand);
    let body = "";
    let shareId = "share-them-too";
    let shareLabel = "share them too";

    if (kind === "every") {
      body = `${browser} allows the solstone extension on every website, but only the sites you added are taken in. sharing every site includes messages on mail and chat sites, and words you've typed but haven't sent, and all of it goes into your journal.`;
      shareId = "share-every-site";
      shareLabel = "share every site";
    } else if (kind === "wider") {
      body = `${browser} allows all of ${host}, but the solstone extension takes in only the part of it you added. sharing all of it can include messages on mail and chat sites, and words you've typed but haven't sent, and all of it goes into your journal.`;
      shareId = "share-them-too";
      shareLabel = "share all of it";
    } else if (kind === "more") {
      body = `${browser} allows more of some sites you added, like ${host}, but the solstone extension takes in only the parts of them you added. sharing all of them can include messages on mail and chat sites, and words you've typed but haven't sent, and all of it goes into your journal.`;
      shareId = "share-them-too";
      shareLabel = "share them too";
    } else {
      body = `${browser} allows the solstone extension on sites you didn't add, like ${host}, but only the sites you added are taken in. sharing them can include messages on mail and chat sites, and words you've typed but haven't sent, and all of it goes into your journal.`;
      shareId = "share-them-too";
      shareLabel = "share them too";
    }

    return {
      body,
      shareId,
      shareLabel,
      keepId: "keep-my-sites",
      keepLabel: "keep my sites",
    };
  }

  function fenceQuiet(brand, allowsMore = true) {
    const browser = browserName(brand);
    const kept = "this extension takes in only the sites you added, and all of it goes into your journal.";
    return allowsMore ? `${browser} allows more than your sites. ${kept}` : kept;
  }

  function clearedStorageNotice() {
    if (MOBILE) {
      return "you cleared this extension's storage, so it's paused, and sites you left out aren't left out any more. when you resume, every site Safari allows goes into your journal.";
    }
    return "you cleared this extension's storage, so it's paused. when you resume, every site Safari allows goes into your journal, except what you've left out in the solstone app.";
  }

  function stopResultCopy(brand, code) {
    if (code === undefined && typeof brand === "string") {
      code = brand;
      brand = undefined;
    }
    const browser = browserName(brand);
    if (code === "still_every_site") {
      return `${browser} still allows every website.`;
    }
    if (code === "every_site_off_none") {
      return "every site is off, including sites you added one at a time. add a site to share it again.";
    }
    if (code === "every_site_off_some") {
      return "every site is off, except sites you added one at a time.";
    }
    return "";
  }

  function everySiteOnLine(brand) {
    const browser = browserName(brand);
    return `${browser} allows every website, so every site is on, except what you leave out.`;
  }

  function safariStopLine() {
    if (MOBILE) {
      return "to stop sharing every site, set All Websites (or Other Websites) to Ask in Settings, under Apps, Safari, Extensions, solstone.";
    }
    return "to stop sharing every site, set For other websites to Ask in Safari's website settings.";
  }

  // A named site covers every address under it (see hosts.js coversSubdomains).
  const LEAVE_OUT_HELP = "leaving out bank.com leaves out all bank.com sites and pages, like www.bank.com and login.bank.com, even inside another page. other sites shown inside its pages are still shared, unless you leave them out too.";
  const ADD_HELP = "adding bank.com shares every bank.com site and page, like www.bank.com and login.bank.com. to share only part, add that address, like mail.google.com.";
  const FIELD_ERROR = "enter a website address, like mail.google.com.";

  function addHelp(brand) {
    if (MOBILE) return "adding a site covers every site and page under it.";
    return `${ADD_HELP} a site you allow in ${browserName(brand)}'s own settings is on too.`;
  }

  function leftOutSummary(n) {
    return `sites left out (${n})`;
  }

  function leftOutRefusal(site) {
    return `${escapeToken(site)} is left out. stop leaving it out first.`;
  }

  const appOnlyLeftOut = "left out in the solstone app";
  const desktopScreenOn = "the solstone extension isn't taking in this site. your screen still goes into your journal.";
  const desktopActivityOn = "the solstone extension isn't taking in this site. this browser's activity still goes into your journal.";
  const appLeftOutSitesOn = "kept out of your journal, including this browser window on your screen and activity.";
  const appLeftOutNeedsAccess = "the solstone extension leaves it out. the solstone app needs Accessibility to keep it off your screen and out of activity.";
  function appLeftOutNotChecked(brand) {
    return `the solstone extension leaves it out. the solstone app doesn't check ${browserName(brand)} windows on your screen.`;
  }
  const appLeftOutAppAway = "the solstone app leaves it out too.";
  const extensionLeftOut = "the solstone extension leaves it out.";
  const desktopNeedsAccess = "the solstone app needs access before it shares sites on this computer.";

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

  function leftOutAnnouncement(host) {
    return wholeSite(host)
      ? `all ${escapeToken(host)} sites and pages left out. other sites shown inside them are still shared.`
      : `${escapeToken(host)} left out. other sites shown inside its pages are still shared.`;
  }

  // What the settings page says about the browser's own grant.
  function accessCopy(brand) {
    const bName = browserName(brand);
    const safari = brand === "safari";
    return {
      granted: everySiteOnLine(brand),
      grantedNote: safari ? (MOBILE ? "a site set to Deny there stays off." : "a site set to Deny in Safari's website settings stays off.") : "",
      // No title on Safari either: an owner who chose one site at a time reads
      // this too, and it isn't a step they owe.
      missingTitle: safari ? "" : `${bName} isn't allowing every website`,
      missingBody: safari
        ? "only the sites Safari already allows are on. to share every site:"
        : `only the sites ${bName} already allows are on.`,
      steps: safari && MOBILE ? [
        "in Settings, open Apps, then Safari, then Extensions, then solstone.",
        "set All Websites (or Other Websites) to Allow.",
      ] : safari ? [
        "in Safari, choose Safari \u203a Settings, then Websites.",
        "under Extensions on the left, choose solstone.",
        "set For other websites to Allow.",
      ] : [],
      returnNote: safari ? "this page checks again when you come back to it." : "",
      allowLabel: safari ? `allow in ${bName}` : "share every site",
      checkLabel: "check again",
      checking: `checking ${bName}\u2026`,
      nowAllowed: `${bName} now allows every website. every site is on, except what you leave out.`,
      stillMissing: safari
        ? (MOBILE ? "Safari still isn't allowing every website. set All Websites (or Other Websites) to Allow." : "Safari still isn't allowing every website. set For other websites to Allow.")
        : `${bName} still isn't allowing every website.`,
      declined: `permission declined. only the sites ${bName} already allows are on. to add a site, open it, open solstone from ${safari && MOBILE ? SAFARI_MENU : "your browser's toolbar or extensions menu"}, and choose add this site.`,
      failedTitle: "couldn't start on your sites",
      failedBody: `something went wrong turning on every site in ${bName}.`,
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

  function sharingSummary(isEverySite, siteCount, excludedCount = 0) {
    if (isEverySite) return excludedCount > 0 ? `every site \u00b7 ${excludedCount} left out` : "every site";
    if (siteCount === 0) return "no sites yet";
    if (siteCount === 1) return "1 site";
    return `${siteCount} sites`;
  }

  function step3Body(brand) {
    return MOBILE
      ? `open a site you want to share, open solstone from ${SAFARI_MENU}, and choose add this site. ${browserName(brand)} will ask you to allow it.`
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

  const VERSION_ONE_SHARE_NOTE = "sharing every site includes messages on mail and chat sites, and words you've typed but haven't sent, and all of it goes into your journal.";

  function everySiteQuestionBody() {
    return "every website, including ones you visit later, once your browser allows it. you can leave sites out.";
  }

  function oneSiteQuestionBody() {
    return "only the sites you allow. open a site, open solstone from your browser's toolbar or extensions menu, and choose add this site.";
  }

  function alreadyAllowedBody(brand) {
    const browser = browserName(brand);
    return `${browser} already allows every website, so agreeing shares every site. to choose sites one at a time instead, change that in ${browser} first.`;
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
    if (s === "permissions_unavailable") return `couldn't check what ${browserName(brandInput)} allows. try again.`;
    return "something went wrong. try again.";
  }

  globalThis.SolstoneCopy = {
    PLACE,
    MOBILE,
    escapeToken,
    browserName,
    WARM_CARD,
    DESKTOP_DISCLOSURE,
    MOBILE_DISCLOSURE_EDITS,
    DISCLOSURE_BODY,
    VERSION_ONE_SHARE_NOTE,
    everySiteQuestionBody,
    oneSiteQuestionBody,
    alreadyAllowedBody,
    LEAVE_OUT_HELP,
    leftOutAnnouncement,
    accessCopy,
    pageCopy,
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
    actionFailure,
    STEP1_NOT_PAIRED_BODY,
    STEP1_INTAKE_OFF_BODY,
    TRUNCATION_ATTENTION,
    step3Body,
    linuxUpdateAppReason,
    linuxCantReachAppReason,
    linuxIntakeOffReason,
    linuxStep1IntakeOffBody,
    classifyFailure,
    addHelp,
    leftOutSummary,
    leftOutRefusal,
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
    SHARE_EVERY_SITE,
    STOP_SHARING_EVERY_SITE,
    stopResultCopy,
    fenceQuestion,
    fenceQuiet,
    clearedStorageNotice,
    everySiteOnLine,
    safariStopLine,
  };
})();
