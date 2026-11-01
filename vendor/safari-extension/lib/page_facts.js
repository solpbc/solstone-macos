// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

(function () {
  "use strict";

  function readDomFacts(doc) {
    if (!doc) return {};
    const facts = {};

    try {
      const htmlEl = doc.documentElement || (doc.querySelector ? doc.querySelector("html") : null);
      const rawLang = htmlEl && typeof htmlEl.getAttribute === "function" ? htmlEl.getAttribute("lang") : (htmlEl ? htmlEl.lang : null);
      if (typeof rawLang === "string") {
        const trimmed = rawLang.trim();
        if (trimmed.length > 0) {
          facts.lang = Array.from(trimmed).slice(0, 35).join("");
        }
      }
    } catch (_e) {}

    try {
      const elements = doc.querySelectorAll ? Array.from(doc.querySelectorAll("audio, video")) : [];
      if (elements.length > 0) {
        const isPlaying = (el) => !el.paused && !el.ended && typeof el.readyState === "number" && el.readyState >= 2;
        const playing = elements.some(isPlaying);
        const isSilent = (el) => el.muted === true || el.volume === 0;
        const everyPlayingSilent = playing && elements.filter(isPlaying).every(isSilent);
        facts.media = { hasElement: true, playing, everyPlayingSilent };
      }
    } catch (_e) {}

    try {
      if (typeof doc.visibilityState === "string") {
        facts.visibilityState = doc.visibilityState;
      }
    } catch (_e) {}

    try {
      if (typeof doc.hasFocus === "function") {
        const focused = doc.hasFocus();
        if (typeof focused === "boolean") {
          facts.hasFocus = focused;
        }
      }
    } catch (_e) {}

    return facts;
  }

  function mapBrowser({ browserInfo, userAgentData, userAgent } = {}) {
    if (browserInfo && typeof browserInfo.name === "string" && /^firefox$/i.test(browserInfo.name.trim())) {
      const vendor = "firefox";
      const version = (typeof browserInfo.version === "string" && browserInfo.version.trim().length > 0)
        ? browserInfo.version.trim()
        : undefined;
      return version ? { vendor, version } : { vendor };
    }

    if (userAgentData && (Array.isArray(userAgentData.fullVersionList) || Array.isArray(userAgentData.brands))) {
      const list = (Array.isArray(userAgentData.fullVersionList) && userAgentData.fullVersionList.length > 0)
        ? userAgentData.fullVersionList
        : (Array.isArray(userAgentData.brands) ? userAgentData.brands : []);

      const edgeEntry = list.find((b) => b && b.brand === "Microsoft Edge");
      if (edgeEntry) {
        const vendor = "edge";
        const version = (typeof edgeEntry.version === "string" && edgeEntry.version.length > 0)
          ? edgeEntry.version
          : undefined;
        return version ? { vendor, version } : { vendor };
      }

      const chromeEntry = list.find((b) => b && b.brand === "Google Chrome");
      if (chromeEntry) {
        const vendor = "chrome";
        const version = (typeof chromeEntry.version === "string" && chromeEntry.version.length > 0)
          ? chromeEntry.version
          : undefined;
        return version ? { vendor, version } : { vendor };
      }

      const vendor = "chromium";
      const chromiumEntry = list.find((b) => b && b.brand === "Chromium");
      const version = (chromiumEntry && typeof chromiumEntry.version === "string" && chromiumEntry.version.length > 0)
        ? chromiumEntry.version
        : undefined;
      return version ? { vendor, version } : { vendor };
    }

    if (typeof userAgent === "string") {
      const isSafari = !/Chrome\/|Chromium\/|Edg\//.test(userAgent) && /Version\/[^\s]+.*Safari\//.test(userAgent);
      if (isSafari) {
        const m = /Version\/([^\s]+)/.exec(userAgent);
        const version = m && m[1] ? m[1] : undefined;
        return version ? { vendor: "safari", version } : { vendor: "safari" };
      }
    }

    return null;
  }

  function assemble({ tabId, frameId, page, tab, window: win, ageMs, browser, ext, solstonePaused } = {}) {
    const res = {};

    const tabObj = {};
    if (Number.isInteger(tabId)) {
      tabObj.id = tabId;
    }
    if (typeof ageMs === "number" && Number.isFinite(ageMs)) {
      tabObj.age_ms = Math.max(0, ageMs);
    }
    if (tab && win && typeof tab === "object" && typeof win === "object") {
      tabObj.front = tab.active === true && win.state !== "minimized";
      if (typeof win.focused === "boolean") {
        tabObj.focused = win.focused;
      }
    } else {
      if (typeof page?.visibilityState === "string") {
        tabObj.front = page.visibilityState === "visible";
      }
      const isTopFrame = frameId === undefined || frameId === 0 || frameId === null;
      if (isTopFrame && typeof page?.hasFocus === "boolean") {
        tabObj.focused = page.hasFocus;
      }
    }
    if (Object.keys(tabObj).length > 0) {
      res.tab = tabObj;
    }

    const hasMediaElement = page?.media?.hasElement === true;
    const tabAudible = tab?.audible === true;
    if (hasMediaElement || tabAudible) {
      const playing = tabAudible || page?.media?.playing === true;
      let muted = false;
      if (tab?.mutedInfo?.muted === true) {
        muted = true;
      } else if (tabAudible) {
        muted = false;
      } else if (page?.media?.playing === true && page?.media?.everyPlayingSilent === true) {
        muted = true;
      } else {
        muted = false;
      }
      res.media = { playing, muted };
    }

    if (typeof page?.lang === "string" && page.lang.length > 0) {
      res.lang = page.lang;
    }

    if (browser && typeof browser === "object" && typeof browser.vendor === "string" && browser.vendor.length > 0) {
      const bObj = { vendor: browser.vendor };
      if (typeof browser.version === "string" && browser.version.length > 0) {
        bObj.version = browser.version;
      }
      res.browser = bObj;
    }

    if (typeof ext === "string" && ext.length > 0) {
      res.ext = ext;
    }

    if (solstonePaused === true) {
      res.solstone_paused = true;
    }

    return res;
  }

  globalThis.SolstonePageFacts = {
    readDomFacts,
    mapBrowser,
    assemble,
  };
})();
