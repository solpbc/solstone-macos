// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

(function () {
  "use strict";

  const t = (...args) => globalThis.SolstoneI18n.t(...args);

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
    return t("browser.copy.browsername", {brand: ["firefox", "edge", "chrome", "safari"].includes(brand) ? brand : "other"});
  }

  const WARM_CARD = [
    t("browser.copy.warm1"),
    t("browser.copy.warm2"),
    t("browser.copy.warm3"),
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
  const SAFARI_MENU = PLACE === "this ipad" ? t("browser.extension.extensionsbuttonsafaris") : t("browser.extension.safarispagemenu");

  const disclosure = (place) => {
    const surface = place === "computer" ? "desktop" : "mobile";
    const [intro, limits, footer] = t("browser.copy.disclosurerest").split("\n\n");
    return [intro, limits, t("browser.copy.disclosure", {place}),
      t("browser.copy.disclosureprivate", {surface}), t("browser.copy.disclosurepause", {surface}), footer].join("\n\n");
  };
  const DESKTOP_DISCLOSURE = disclosure("computer");
  const DISCLOSURE_BODY = disclosure(PLACE.replace(/^this /, ""));

  const STEP1_CANT_REACH_BODY = t("browser.copy.step1cantreach", { place: PLACE });
  const STEP1_OPEN_APP_BODY = t("browser.copy.step1openapp", { place: PLACE });
  const STEP2_PENDING = t("browser.copy.step2pending");
  const STEP1_NOT_PAIRED_BODY = t("browser.copy.step1notpaired", { place: PLACE });
  const STEP1_INTAKE_OFF_BODY = t("browser.copy.step1intakeoff");
  const TRUNCATION_ATTENTION = t("browser.copy.truncation");

  function plural(n, one, many) {
    return n === 1 ? one : many.replace("{n}", String(n));
  }

  const SHARE_EVERY_SITE = t("browser.options.shareeverysite");
  const STOP_SHARING_EVERY_SITE = t("browser.extension.stopsharingeverysite");

  function fenceQuestion(brand, kind, host) {
    const browser = browserName(brand);
    let body = "";
    let shareId = "share-them-too";
    let shareLabel = t("browser.extension.sharethemtoo");

    if (kind === "every") {
      body = t("browser.copy.allowsthesolstoneextensionon", {value1: String(browser)});
      shareId = "share-every-site";
      shareLabel = SHARE_EVERY_SITE;
    } else if (kind === "wider") {
      body = t("browser.copy.allowsallofbutthe", {value1: String(browser), value2: String(host)});
      shareId = "share-them-too";
      shareLabel = t("browser.extension.shareall");
    } else if (kind === "more") {
      body = t("browser.copy.allowsmoreofsomesites", {value1: String(browser), value2: String(host)});
      shareId = "share-them-too";
      shareLabel = t("browser.extension.sharethemtoo");
    } else {
      body = t("browser.copy.allowsthesolstoneextensionon2", {value1: String(browser), value2: String(host)});
      shareId = "share-them-too";
      shareLabel = t("browser.extension.sharethemtoo");
    }

    return {
      body,
      shareId,
      shareLabel,
      keepId: "keep-my-sites",
      keepLabel: t("browser.options.keepmysites"),
    };
  }

  function fenceQuiet(brand, allowsMore = true) {
    const browser = browserName(brand);
    const kept = t("browser.extension.extensiontakesonlysites");
    return allowsMore ? t("browser.copy.allowsmorethanyoursites", {value1: String(browser), value2: String(kept)}) : kept;
  }

  function clearedStorageNotice() {
    if (MOBILE) {
      return t("browser.extension.clearedextensionsstorage");
    }
    return t("browser.extension.clearedextensionsstorage2");
  }

  function stopResultCopy(brand, code) {
    if (code === undefined && typeof brand === "string") {
      code = brand;
      brand = undefined;
    }
    const browser = browserName(brand);
    if (code === "still_every_site") {
      return t("browser.copy.stillallowseverywebsite", {value1: String(browser)});
    }
    if (code === "every_site_off_none") {
      return t("browser.extension.everysiteoffincluding");
    }
    if (code === "every_site_off_some") {
      return t("browser.extension.everysiteoffexcept");
    }
    return "";
  }

  function everySiteOnLine(brand) {
    const browser = browserName(brand);
    return t("browser.copy.allowseverywebsitesoevery", {value1: String(browser)});
  }

  function safariStopLine() {
    if (MOBILE) {
      return t("browser.extension.stopsharingeverysite2");
    }
    return t("browser.extension.stopsharingeverysite3");
  }

  // A named site covers every address under it (see hosts.js coversSubdomains).
  const LEAVE_OUT_HELP = t("browser.copy.leaveouthelp");
  const ADD_HELP = t("browser.copy.addhelp");
  const FIELD_ERROR = t("browser.copy.fielderror");
  const LEAVE_OUT_FIELD_ERROR = t("browser.extension.enterwebsiteaddresslike");

  // Leaving a site out is solstone's list, not the browser's, so the browser's own settings can't show it.
  function leftOutListNote(brand) {
    return t("browser.copy.sownsettingsdont", {value1: String(browserName(brand))});
  }

  function addHelp(brand) {
    if (MOBILE) return t("browser.extension.addingsitecoversevery");
    return `${ADD_HELP} ${t("browser.copy.addhelpjoined", {browser:brand || "other"})}`;
  }

  function leftOutSummary(n) {
    return t("browser.copy.leftoutsummary", {count: n});
  }

  function leftOutRefusal(site) {
    return t("browser.copy.isleftoutstopleaving", {value1: String(escapeToken(site))});
  }

  const appOnlyLeftOut = t("browser.copy.apponlyleftout");
  const desktopScreenOn = t("browser.copy.desktopscreenon");
  const desktopActivityOn = t("browser.copy.desktopactivityon");
  const appLeftOutSitesOn = t("browser.copy.appleftoutsiteson");
  const appLeftOutNeedsAccess = t("browser.extension.solstoneextensionleavesout");
  function appLeftOutNotChecked(brand) {
    return t("browser.copy.thesolstoneextensionleavesit", {value1: String(browserName(brand))});
  }
  const appLeftOutAppAway = t("browser.copy.appleftoutaway");
  const extensionLeftOut = t("browser.copy.extensionleftout");
  function appLeftOutUnreadable(brand) {
    return t("browser.copy.appleftoutunreadable", {value1: String(browserName(brand))});
  }
  const LEAVE_OUT_NEEDS_ACCESS = t("browser.copy.leaveoutneedsaccess");

  // On a Mac the app holds the website list, and without Accessibility it can't keep a site
  // out, so the extension offers no leave-out there either.
  function leaveOutNeedsAccess(status) {
    return !!(status && status.leftOutCapable === true && status.desktop && status.desktop.sites === "needs_access");
  }

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
        if (desktop.sites === "unreadable") return "appLeftOutUnreadable";
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
  const ADD_DENIED = t("browser.copy.adddenied");

  // Safari on a Mac doesn't ask about a site while it allows a site under it,
  // and says the request succeeded without granting anything. Elsewhere a
  // failed add is an ordinary decline.
  function addBlockedBelow(brand, host, under) {
    if (brand !== "safari" || MOBILE || !host || !under) return "";
    const h = escapeToken(host);
    return t("browser.copy.addblockedbelow", { arg1: h, under: escapeToken(under), arg3: h });
  }
  const ADD_NOT_NOW = t("browser.copy.addnotnow");

  function alreadyAdded(host) {
    return t("browser.copy.hostalready", { host: escapeToken(host) });
  }

  function removedAnnouncement(host) {
    return t("browser.copy.hostremoved", { host: escapeToken(host) });
  }

  function includedAnnouncement(host) {
    return wholeSite(host)
      ? t("browser.copy.allsitesandpagesare", {value1: String(escapeToken(host))})
      : t("browser.copy.isnolongerleftout", {value1: String(escapeToken(host))});
  }

  function addedAnnouncement(host, onNow) {
    const named = wholeSite(host) ? t("browser.copy.added", { host: escapeToken(host), scope: "whole" }) : t("browser.copy.added", { host: escapeToken(host), scope: "exact" });
    return onNow ? t("browser.copy.sharegoesin", { arg1: named }) : named;
  }

  function leftOutAnnouncement(host) {
    return wholeSite(host)
      ? t("browser.copy.leftoutannouncement", { host: escapeToken(host), scope: "whole" })
      : t("browser.copy.leftoutannouncement", { host: escapeToken(host), scope: "exact" });
  }

  // What the settings page says about the browser's own grant.
  function accessCopy(brand) {
    const bName = browserName(brand);
    const safari = brand === "safari";
    return {
      granted: everySiteOnLine(brand),
      grantedNote: safari ? (MOBILE ? t("browser.extension.sitesetdenythere") : t("browser.copy.accessgrantednote", { surface: "safari-desktop" })) : "",
      // No title on Safari either: an owner who chose one site at a time reads
      // this too, and it isn't a step they owe.
      missingTitle: safari ? "" : t("browser.copy.isntallowingeverywebsite", {value1: String(bName)}),
      missingBody: safari
        ? t("browser.extension.onlysitessafarialready")
        : t("browser.copy.onlythesitesalreadyallows", {value1: String(bName)}),
      steps: safari && MOBILE ? [
        t("browser.copy.stepsettingsapps"),
        t("browser.extension.setallwebsitesother"),
      ] : safari ? [
        t("browser.copy.stepsafariwebsites"),
        t("browser.copy.stepextensionsleft"),
        t("browser.copy.stepotherwebsites"),
      ] : [],
      returnNote: safari ? t("browser.copy.returnnote") : "",
      allowLabel: safari ? t("browser.copy.allowin", { browser: bName }) : SHARE_EVERY_SITE,
      checkLabel: t("browser.copy.checkagain"),
      checking: t("browser.copy.checking", { browser: bName }),
      nowAllowed: t("browser.copy.nowallowseverywebsiteevery", {value1: String(bName)}),
      stillMissing: safari
        ? (MOBILE ? t("browser.extension.safaristillisnt") : t("browser.extension.safaristillisnt2"))
        : t("browser.copy.stillisntallowingevery", {value1: String(bName)}),
      declined: t("browser.copy.permissiondeclinedonlythesites", {value1: String(bName), value2: String(safari && MOBILE ? SAFARI_MENU : t("browser.copy.browsermenu"))}),
      failedTitle: t("browser.copy.couldntstart"),
      failedBody: t("browser.copy.failedbody", { browser: bName }),
      retryLabel: t("browser.copy.tryagain"),
      deniedTitle: safari ? t("browser.copy.deniedtitle", { browser: "safari" }) : t("browser.copy.deniedtitle", { browser: bName }),
      deniedHelp: safari ? (MOBILE ? t("browser.copy.accessdeniedhelp", { surface: "safari-mobile" }) : t("browser.copy.accessdeniedhelp", { surface: "safari-desktop" })) : "",
    };
  }

  // The page block's own words for pages the extension can't or won't read.
  function pageCopy(brand) {
    const bName = browserName(brand);
    const safari = brand === "safari";
    return {
      privateState: MOBILE ? t("browser.copy.privatestate", { surface: "mobile" }) : t("browser.copy.privatestate", { surface: "desktop" }),
      privateNote: MOBILE ? t("browser.copy.privatenote", { surface: "mobile" }) : t("browser.extension.extensiontakesnothingfrom"),
      restrictedState: t("browser.copy.restricted", { browser: bName }),
      unknownState: t("browser.copy.unknownstate"),
      unknownNote: safari ? (MOBILE ? t("browser.copy.unknownnote", { surface: "safari-mobile" }) : t("browser.copy.unknownnote", { surface: "safari-desktop" })) : "",
      deniedState: t("browser.copy.denyingsite", { browser: bName }),
      deniedNote: safari ? (MOBILE ? t("browser.copy.deniednote", { surface: "safari-mobile" }) : t("browser.copy.deniednote", { surface: "safari-desktop" })) : "",
      leaveOutNote: (host) => wholeSite(host)
        ? t("browser.copy.leaveoutnote", { host: escapeToken(host), scope: "whole" })
        : t("browser.copy.leaveoutnote", { host: escapeToken(host), scope: "exact" }),
    };
  }

  function sharingSummary(isEverySite, siteCount, excludedCount = 0) {
    if (isEverySite) return excludedCount > 0 ? t("browser.copy.sharingexcluded", {count:String(excludedCount)}) : t("browser.copy.sharingevery");
    if (siteCount === 0) return t("browser.status.nosites");
    return t("browser.popup.sitecountonly", {count:siteCount});
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
    return t("browser.copy.linuxcantreach", {place:PLACE}).replace("solstone-linux doctor", escapeToken(cmd));
  }

  function linuxIntakeOffReason(cmd) {
    return `turn them back on with ${escapeToken(cmd)}.`;
  }

  function linuxStep1IntakeOffBody(cmd) {
    return `turn them on with ${escapeToken(cmd)}.`;
  }

  const VERSION_ONE_SHARE_NOTE = t("browser.extension.sharingeverysiteincludes");

  function everySiteQuestionBody() {
    return t("browser.extension.everywebsiteincludingones");
  }

  function oneSiteQuestionBody() {
    return t("browser.extension.onlysitesallowopen");
  }

  function alreadyAllowedBody(brand) {
    const browser = browserName(brand);
    return t("browser.copy.alreadyallowseverywebsiteso", {value1: String(browser), value2: String(browser)});
  }

  const RESTRICTED = /Cannot access|chrome:\/\/|moz-extension:\/\/|about:|Web Store|match pattern/i;

  // What a site's row says when something went wrong there. Internal codes
  // never reach the owner; each line says what happened and what follows.
  function classifyFailure(raw, brandInput) {
    const s = raw == null ? "" : String(raw);
    if (RESTRICTED.test(s)) return t("browser.copy.restricted", { browser: browserName(brandInput) });
    if (s === "failed" || s === "registration_failed") return t("browser.copy.failrestartsite");
    if (s === "enqueue_failed" || s === "storage_error") return t("browser.copy.failpageretry");
    if (s === "outbox-full") return t("browser.copy.failsitefull");
    if (s === "batch-oversize" || s === "schema-refuse") return t("browser.copy.failpage");
    return t("browser.copy.failsite");
  }

  // What a button says when its action didn't work.
  function actionFailure(raw, brandInput) {
    const s = raw == null ? "" : String(raw);
    if (RESTRICTED.test(s)) return t("browser.copy.restricted", { browser: browserName(brandInput) });
    if (s === "storage_error") return t("browser.copy.failsave");
    if (s === "permissions_changed") return t("browser.copy.permissionschanged", { browser: browserName(brandInput) });
    if (["capture_unavailable", "permission_not_granted", "registration_failed", "invalid_phase"].includes(s)) return t("browser.copy.failadd");
    if (s === "missing_consent") return t("browser.copy.failsetupfirst");
    if (s === "invalid_host" || s === "invalid_origin") return FIELD_ERROR;
    if (s === "site_excluded") return t("browser.copy.failleftout");
    if (s === "permissions_unavailable") return t("browser.copy.couldntcheck", { browser: browserName(brandInput) });
    return t("browser.copy.failgeneric");
  }

  globalThis.SolstoneCopy = {
    PLACE,
    MOBILE,
    escapeToken,
    browserName,
    WARM_CARD,
    DESKTOP_DISCLOSURE,
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
    LEAVE_OUT_FIELD_ERROR,
    leftOutListNote,
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
    appLeftOutUnreadable,
    LEAVE_OUT_NEEDS_ACCESS,
    leaveOutNeedsAccess,
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
