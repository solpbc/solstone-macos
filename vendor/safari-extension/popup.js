// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

(function () {
  "use strict";

  const Status = globalThis.SolstoneStatus;
  const Failures = globalThis.SolstoneFailures;
  if (globalThis.SolstoneCopy?.MOBILE === true) document.documentElement.classList.add("mobile");
  // Safari on iPad opens the popup in a popover that shrinks to its content, so it takes a width of its own.
  if (globalThis.SolstoneCopy?.PLACE === "this ipad") document.documentElement.classList.add("ipad");
  const View = globalThis.SolstonePopupView;
  const Actions = globalThis.SolstoneActions;
  const $ = (id) => document.getElementById(id);

  const TONE = {
    ok: { bandClass: "ok", dotClass: "ok" },
    calm: { bandClass: "calm", dotClass: "neutral" },
    attention: { bandClass: "attention", dotClass: "bad" },
    unavailable: { bandClass: "unavailable", dotClass: "warn" },
  };

  function cmd(message) {
    return new Promise((resolve) => chrome.runtime.sendMessage(message, (response) => resolve(response || {})));
  }

  async function currentTab() {
    try {
      const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
      return tab;
    } catch (_error) {
      return undefined;
    }
  }

  // What kind of page the active tab is. A tab with no address is one the browser
  // didn't show this extension (Safari hides a page it denies), so it's "unknown",
  // never assumed to be a page that could be read.
  // Store pages: no browser lets an extension read its own add-on store.
  const STORE_PAGES = [
    { host: "chromewebstore.google.com", path: "/" },
    { host: "chrome.google.com", path: "/webstore" },
    { host: "microsoftedge.microsoft.com", path: "/addons" },
    { host: "addons.mozilla.org", path: "/" },
  ];

  function pageFor(tab) {
    if (tab?.incognito === true) {
      let host = "";
      try { host = new URL(tab.url).hostname; } catch (_error) {}
      return { origin: "", host, ok: false, kind: "private" };
    }
    if (!tab || !tab.url) return { origin: "", host: "", ok: false, kind: "unknown" };
    try {
      const parsed = new URL(tab.url);
      const web = parsed.protocol === "http:" || parsed.protocol === "https:";
      const store = web && STORE_PAGES.some((page) => parsed.hostname === page.host && parsed.pathname.startsWith(page.path));
      const ok = web && !store;
      return { origin: ok ? parsed.origin : "", host: ok ? parsed.hostname : "", ok, kind: ok ? "web" : "restricted" };
    } catch (_error) {
      return { origin: "", host: "", ok: false, kind: "unknown" };
    }
  }

  let state = null;
  let page = { origin: "", host: "", ok: false, kind: "" };
  let paintSequence = 0;
  let appliedCaptureEpoch = -1;
  // What the popup shows of the app connection, with the toolbar's timing.
  let link = null;
  let linkTimer = null;

  // The message sits at the end of a popup that scrolls, so bring it into view:
  // otherwise a refused add or a removal says nothing the owner can see.
  // A confirmation reads in plain text; only a failure is coloured as one.
  function showActionMessage(message, tone = "ok") {
    const region = $("actionMessage");
    region.textContent = message || "";
    region.classList?.toggle?.("bad", tone === "bad");
    if (message && typeof region.scrollIntoView === "function") {
      try { region.scrollIntoView({ block: "nearest" }); } catch (_e) {}
    }
  }

  function showActionError(error) {
    showActionMessage(Failures.classify(error, state), "bad");
  }

  function openSettings() {
    showActionMessage("");
    chrome.runtime.openOptionsPage();
  }

  async function runAction(action) {
    if (!action) return;
    showActionMessage("");
    await Actions.run(action, {
      cmd, refresh, openSettings,
      openApp: () => chrome.tabs.create({ url: "https://solstone.app" }),
      reload: () => chrome.runtime.reload(),
      grantSite: (origin) => View.grantSite(origin, siteEffects()),
      showError: showActionError,
      brand: state?.brand,
      requestPermission: (request) => chrome.permissions.request(request),
      showDenied: () => showActionMessage(globalThis.SolstoneCopy.accessCopy(state?.brand).declined, "bad"),
      showOk: (message) => showActionMessage(message),
      lossSeq: () => state?.lossNotice?.seq,
    });
  }

  function renderVerdict(section) {
    if (!section) return;
    const treatment = TONE[section.tone] || TONE.unavailable;
    const verdict = $("verdict");
    verdict.className = `verdict ${treatment.bandClass}`;
    verdict.hidden = section.quiet === true;
    $("verdictDot").className = `dot ${treatment.dotClass}`;
    $("verdictHeadline").textContent = section.headline;
    $("verdictSub").textContent = section.sub;
    if ($("verdictNote")) {
      const note = section.appPausedNote || "";
      $("verdictNote").textContent = note;
      $("verdictNote").hidden = !note;
    }
    $("verdictReason").textContent = section.reason;
    $("verdictReason").hidden = !section.reason;

    const actions = $("verdictActions");
    actions.replaceChildren();
    if (section.action) {
      const button = document.createElement("button");
      button.type = "button";
      button.textContent = section.action.label;
      button.addEventListener("click", () => runAction(section.action));
      actions.append(button);
    }
  }

  function siteEffects() {
    return {
      status: state,
      cmd,
      requestPermission: (request) => chrome.permissions.request(request),
      getAllPermissions: () => chrome.permissions.getAll(),
      removePermission: (request) => chrome.permissions.remove(request),
    };
  }

  function renderSiteIssues(section) {
    const block = $("siteIssues");
    const rows = $("siteIssueRows");
    rows.replaceChildren();
    if (!section || !section.rows || section.rows.length === 0) {
      block.hidden = true;
      return;
    }
    block.hidden = false;
    for (const row of section.rows) {
      const item = document.createElement("div");
      item.className = "site-issue";
      if (row.isAlso) {
        const h = document.createElement("div");
        h.className = "h";
        h.textContent = row.headline;
        item.append(h);
      } else {
        const host = document.createElement("div");
        host.className = "h";
        host.textContent = row.host;
        const why = document.createElement("div");
        why.className = "w";
        why.textContent = row.label;
        item.append(host, why);
      }
      if (row.action) {
        const button = document.createElement("button");
        button.type = "button";
        button.textContent = row.action.label;
        button.addEventListener("click", () => runAction(row.action));
        item.append(button);
      }
      rows.append(item);
    }
  }

  async function runPageSiteAction(action) {
    showActionMessage("");
    const Copy = globalThis.SolstoneCopy;
    const Hosts = globalThis.SolstoneHosts;
    if (action.id === "exclude-site" || action.id === "include-site" || action.id === "leave-out") {
      if (page.kind === "private" || page.kind === "restricted" || page.kind === "unknown") return;
      // The site this page belongs to: www.bank.com leaves out all of bank.com.
      const site = action.site || Hosts.siteHostname(page.host);
      await runAction({ ...action, host: site, origin: page.origin });
      if (!$("actionMessage").textContent) {
        showActionMessage(action.id === "include-site" ? Copy.includedAnnouncement(site) : Copy.leftOutAnnouncement(site));
      }
      return;
    }
    if (action.id === "remove-site") {
      const origin = action.origin || page.origin || `https://${page.host}`;
      const result = await cmd({ cmd: "removeGrantedOrigin", origin });
      await refresh();
      const named = Hosts.displayOrigin(origin);
      if (result.error || result.ok === false) showActionError(result.error || "storage_error");
      else if (result.result === "left_out_instead") showActionMessage(Copy.leftOutAnnouncement(named));
      else showActionMessage(Copy.removedAnnouncement(named));
      return;
    }
    const result = await View.addSite(Hosts.chosenOrigin(page.origin) || page.origin || page.host, siteEffects());
    if (result.cancelled) return;
    if (result.denied) {
      const blocked = result.blockedBy ? Copy.addBlockedBelow(state?.brand, Hosts.matchHostFor(page.host), result.blockedBy) : "";
      showActionMessage(blocked || "permission declined. nothing added.", "bad");
    }
    else if (result.error) showActionError(result.error);
    await refresh();
  }

  // On a phone adding takes one tap. What it takes in is there for whoever wants it.
  function renderPageLearn(section) {
    if (!$("pageLearn")) return;
    const adding = globalThis.SolstoneCopy.MOBILE === true && section.siteAction?.id === "add-site";
    $("pageLearn").hidden = !adding;
    $("pageHint").hidden = !adding || section.siteAction.disabled === true;
    if (!adding) return;
    $("pageLearnWhat").textContent = globalThis.SolstoneCopy.DISCLOSURE_BODY;
    $("pageLearnUnsent").textContent = "";
    $("pageLearnWhere").textContent = "";
  }

  function renderPage(section) {
    if (!section) return;
    $("pageHost").textContent = section.host;
    $("currentPageState").textContent = section.state;
    $("currentPageState").className = `page-state${section.state === "on now" ? " ok" : ""}`;
    if ($("pageNote")) {
      $("pageNote").textContent = section.note || "";
      $("pageNote").hidden = !section.note;
    }

    renderPageLearn(section);

    const siteAction = $("pageSiteAction");
    siteAction.hidden = !section.siteAction;
    if (section.siteAction) {
      siteAction.textContent = section.siteAction.label;
      siteAction.disabled = section.siteAction.disabled;
      siteAction.className = section.siteAction.primary ? "primary" : "";
      siteAction.onclick = () => runPageSiteAction(section.siteAction);
    }

    const siteSecondary = $("pageSiteSecondary");
    if (siteSecondary) {
      siteSecondary.hidden = !section.siteSecondary;
      if (section.siteSecondary) {
        siteSecondary.textContent = section.siteSecondary.label;
        siteSecondary.disabled = !!section.siteSecondary.disabled;
        siteSecondary.className = section.siteSecondary.primary ? "primary" : "";
        siteSecondary.onclick = () => runPageSiteAction(section.siteSecondary);
      }
    }

    const pauseAction = $("pauseAction");
    // The Clear Storage notice carries its own resume; one is enough.
    pauseAction.hidden = !section.pauseAction || state?.clearedNotice === true;
    if (section.pauseAction) {
      pauseAction.textContent = section.pauseAction.label;
      pauseAction.className = section.pauseAction.primary ? "primary" : "";
      pauseAction.onclick = async () => {
        showActionMessage("");
        const result = await cmd({ cmd: "setPaused", paused: !state.paused });
        if (result.error) showActionError(result.error);
        await refresh();
      };
    }
  }

  function renderSiteCount(section) {
    $("siteCount").hidden = !section;
    if (section) $("siteCountText").textContent = section.text;
  }

  function childById(parent, id) {
    if (!parent || !parent.children) return null;
    for (const child of parent.children) {
      if (child.id === id) return child;
    }
    return null;
  }

  function detach(parent, node) {
    if (!parent || !node) return;
    if (typeof node.remove === "function") node.remove();
    if (Array.isArray(parent.children)) {
      parent.children = parent.children.filter((child) => child !== node);
    }
  }

  // Real pages anchor on the existing sections. The test document keeps those
  // sections by id and not as children, so a missing anchor uses a stable index.
  function placePinned(parent, node, before, fallbackIndex) {
    if (!parent || !node) return;
    if (before && before.parentNode === parent && typeof parent.insertBefore === "function") {
      parent.insertBefore(node, before);
      return;
    }
    if (!Array.isArray(parent.children)) {
      if (typeof parent.insertBefore === "function") parent.insertBefore(node, before || null);
      return;
    }
    parent.children = parent.children.filter((child) => child !== node);
    const at = before ? parent.children.indexOf(before) : -1;
    const index = at >= 0 ? at : Math.min(fallbackIndex, parent.children.length);
    parent.children.splice(index, 0, node);
    node.parentNode = parent;
  }

  function fillNotice(section, text, onResume) {
    section.replaceChildren();
    const paragraph = document.createElement("p");
    paragraph.textContent = text;
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = "resume";
    button.addEventListener("click", onResume);
    section.append(paragraph, button);
  }

  async function resumeFromNotice() {
    showActionMessage("");
    const result = await cmd({ cmd: "setPaused", paused: false });
    if (result?.error) showActionError(result.error);
    await refresh();
  }

  function renderPopupExtras(shown, sections) {
    const main = $("popupMain");
    if (!main) return;
    const Copy = globalThis.SolstoneCopy;
    let notice = childById(main, "clearedNotice");
    if (shown?.clearedNotice) {
      if (!notice) {
        notice = document.createElement("section");
        notice.id = "clearedNotice";
        notice.className = "blk";
      }
      notice.hidden = false;
      fillNotice(notice, Copy.clearedStorageNotice(), resumeFromNotice);
      placePinned(main, notice, $("verdict"), 0);
    } else {
      detach(main, notice);
    }

    const question = sections.find((section) => section.id === "upgradeQuestion");
    let block = childById(main, "upgradeQuestion");
    if (question) {
      if (!block) {
        block = document.createElement("section");
        block.id = "upgradeQuestion";
        block.className = "blk question";
      }
      block.hidden = false;
      block.replaceChildren();
      const body = document.createElement("p");
      body.textContent = question.body;
      const actions = document.createElement("div");
      actions.className = "qact";
      for (const spec of question.buttons || []) {
        const button = document.createElement("button");
        button.type = "button";
        button.id = spec.id;
        button.dataset.shareId = spec.id;
        button.textContent = spec.label;
        button.className = spec.primary ? "primary" : "";
        button.addEventListener("click", () => runAction({ id: spec.id, label: spec.label, primary: spec.primary, shown: question.shown }));
        actions.append(button);
      }
      block.append(body, actions);
      placePinned(main, block, $("page"), 1);
    } else {
      detach(main, block);
    }
  }

  function renderCurrent() {
    const about = globalThis.SolstoneAbout.block(chrome.runtime.getManifest().version, state?.about);
    if ($("aboutBlock").textContent !== about) {
      $("aboutBlock").textContent = about;
      $("aboutCopy").textContent = "copy";
      $("aboutMessage").textContent = "";
    }
    const extras = {};
    link = Status.present(link, state, extras, Date.now());
    if (linkTimer != null) clearTimeout(linkTimer);
    linkTimer = link.wakeAt == null ? null : setTimeout(() => {
      linkTimer = null;
      renderCurrent();
    }, Math.max(0, link.wakeAt - Date.now()));
    // Nothing heard yet: the popup keeps its neutral first look.
    if (!link.status) return;
    const shown = link.status;
    const derived = Status.derive(shown, extras);
    const sections = View.arrange(derived, shown, page, extras);
    renderPopupExtras(shown, sections);
    renderVerdict(sections.find((section) => section.id === "verdict"));
    renderSiteIssues(sections.find((section) => section.id === "siteIssues"));
    renderPage(sections.find((section) => section.id === "page"));
    renderSiteCount(sections.find((section) => section.id === "siteCount"));
    if ($("headerMark")) {
      $("headerMark").src = `brand/mark-${derived.mark || "healthy"}.svg`;
    }
  }

  async function paint(nextState, sequence) {
    if (sequence !== paintSequence) return;
    state = nextState;
    // Host authority is independent of a tab-details query.
    renderCurrent();
    const tab = await currentTab();
    if (sequence !== paintSequence) return;
    page = tab ? pageFor(tab) : { origin: "", host: "", ok: false, kind: "unknown" };
    renderCurrent();
  }

  function applyStatus(nextState) {
    const epoch = Number.isSafeInteger(nextState?.captureEpoch) ? nextState.captureEpoch : appliedCaptureEpoch;
    if (epoch < appliedCaptureEpoch) return;
    appliedCaptureEpoch = Math.max(appliedCaptureEpoch, epoch);
    const sequence = ++paintSequence;
    paint(nextState, sequence);
  }

  async function refresh() {
    const sequence = ++paintSequence;
    const nextState = await cmd({ cmd: "getState" });
    if (sequence !== paintSequence) return;
    const epoch = Number.isSafeInteger(nextState?.captureEpoch) ? nextState.captureEpoch : appliedCaptureEpoch;
    if (epoch < appliedCaptureEpoch) return;
    appliedCaptureEpoch = Math.max(appliedCaptureEpoch, epoch);
    await paint(nextState, sequence);
  }

  $("aboutCopy").addEventListener("click", async () => {
    const displayed = $("aboutBlock").textContent;
    try {
      await navigator.clipboard.writeText(displayed);
      if ($("aboutBlock").textContent === displayed) {
        $("aboutCopy").textContent = "copied";
        $("aboutMessage").textContent = "";
      }
    } catch (_error) {
      if ($("aboutBlock").textContent === displayed) {
        $("aboutCopy").textContent = "copy";
        $("aboutMessage").textContent = "couldn't copy. select the text and copy it.";
      }
    }
  });
  if (globalThis.SolstoneCopy?.MOBILE === true) $("allSitesLink").textContent = "settings \u203a";
  $("allSitesLink").addEventListener("click", (event) => {
    event.preventDefault();
    openSettings();
  });
  $("settingsLink").addEventListener("click", (event) => {
    event.preventDefault();
    openSettings();
  });

  let subscriptionEpoch = 0;
  let reconnectTimer = null;
  let subscribedAt = 0;
  function subscribeStatus() {
    const generation = ++subscriptionEpoch;
    appliedCaptureEpoch = -1;
    subscribedAt = Date.now();
    // The channel closes when the background restarts. What the popup knew is
    // void, but it holds what it shows briefly while the new background
    // answers, and resubscribes at once (a channel that fails again right away
    // waits a second).
    const disconnected = () => {
      if (generation !== subscriptionEpoch) return;
      subscriptionEpoch++;
      appliedCaptureEpoch = -1;
      if (reconnectTimer == null) reconnectTimer = setTimeout(() => {
        reconnectTimer = null;
        subscribeStatus();
      }, Date.now() - subscribedAt >= 1000 ? 0 : 1000);
      link = Status.resume(link, Date.now());
      paint(Status.withdrawn(state, true), ++paintSequence);
      refresh();
    };
    try {
      const port = chrome.runtime.connect({ name: "status" });
      port.onMessage.addListener(msg => {
        if (generation === subscriptionEpoch && msg?.type === "status" && msg.status) applyStatus(msg.status);
      });
      port.onDisconnect.addListener(disconnected);
    } catch (_e) { disconnected(); }
  }
  subscribeStatus();

  // Safari doesn't always deliver the status channel's messages to an open
  // popup, and can restart the background without closing the channel. So an
  // answer from the app, such as a site left out or included, would show only
  // on reopening. While the popup is open it also reads the state each second,
  // and repaints only when something changed. A lower epoch means a restarted
  // background, so the popup resubscribes.
  function sameState(a, b) {
    return JSON.stringify({ ...(a || {}), ok: undefined }) === JSON.stringify({ ...(b || {}), ok: undefined });
  }
  async function readState() {
    const sequence = paintSequence;
    const nextState = await cmd({ cmd: "getState" });
    if (sequence !== paintSequence || nextState.ok === false || sameState(nextState, state)) return;
    const epoch = Number.isSafeInteger(nextState.captureEpoch) ? nextState.captureEpoch : appliedCaptureEpoch;
    if (epoch < appliedCaptureEpoch) subscribeStatus();
    appliedCaptureEpoch = Math.max(appliedCaptureEpoch, epoch);
    await paint(nextState, ++paintSequence);
  }
  function watchState() {
    if (typeof document.visibilityState !== "string") return;
    setTimeout(async () => {
      if (document.visibilityState === "visible") {
        try { await readState(); } catch (_e) { /* the next read tries again */ }
      }
      watchState();
    }, 1000);
  }
  watchState();

  // Safari focuses the popup's first keyboard stop as it opens, which drew a
  // focus ring around "about" on every open. Nobody chose it, so drop focus
  // that arrives before the owner presses a key or the pointer.
  let ownerActed = false;
  const acted = () => { ownerActed = true; };
  function dropOpeningFocus() {
    const active = document.activeElement;
    if (!ownerActed && active && active !== document.body && typeof active.blur === "function") active.blur();
  }
  if (typeof document.addEventListener === "function") {
    document.addEventListener("keydown", acted, { capture: true, once: true });
    document.addEventListener("pointerdown", acted, { capture: true, once: true });
    document.addEventListener("focusin", dropOpeningFocus);
    dropOpeningFocus();
  }

  globalThis.SolstonePopup = { refresh, readState };
  refresh();
})();
