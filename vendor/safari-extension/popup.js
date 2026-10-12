// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

(function () {
  "use strict";

  const Status = globalThis.SolstoneStatus;
  const Failures = globalThis.SolstoneFailures;
  const Disclosure = globalThis.SolstoneDisclosure;
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

  function originFor(url) {
    try {
      const parsed = new URL(url);
      return {
        origin: parsed.origin,
        host: parsed.hostname,
        ok: parsed.protocol === "http:" || parsed.protocol === "https:",
      };
    } catch (_error) {
      return { origin: "", host: "", ok: false };
    }
  }

  let state = null;
  let page = { origin: "", host: "", ok: false };
  let disclosureResolve = null;
  let previousActiveElement = null;
  let paintSequence = 0;
  let appliedCaptureEpoch = -1;

  function showActionMessage(message) {
    $("actionMessage").textContent = message || "";
  }

  function showActionError(error) {
    showActionMessage(Failures.classify(error, state));
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
      showDenied: () => showActionMessage("permission declined. this site stays paused."),
      lossSeq: () => state?.lossNotice?.seq,
    });
  }

  function renderVerdict(section) {
    if (!section) return;
    const treatment = TONE[section.tone] || TONE.unavailable;
    const verdict = $("verdict");
    verdict.className = `verdict ${treatment.bandClass}`;
    $("verdictDot").className = `dot ${treatment.dotClass}`;
    $("verdictHeadline").textContent = section.headline;
    $("verdictSub").textContent = section.sub;
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
      if (typeof row.count === "number") {
        const count = document.createElement("div");
        count.className = "count";
        count.textContent = String(row.count);
        item.append(count);
      }
      rows.append(item);
    }
  }

  async function runPageSiteAction(action) {
    showActionMessage("");
    if (action.id === "remove-site") {
      const origin = page.origin || `https://${page.host}`;
      const result = await cmd({ cmd: "removeGrantedOrigin", origin });
      if (result.error) showActionError(result.error);
      await refresh();
      return;
    }
    const result = await View.addSite(page.origin || page.host, Object.assign(siteEffects(), {
      disclose: presentDisclosure,
    }));
    if (result.cancelled) return;
    if (result.denied) showActionMessage("permission declined. nothing added.");
    else if (result.error) showActionError(result.error);
    await refresh();
  }

  function renderPage(section) {
    if (!section) return;
    $("pageHost").textContent = section.host;
    $("currentPageState").textContent = section.state;

    const siteAction = $("pageSiteAction");
    siteAction.textContent = section.siteAction.label;
    siteAction.disabled = section.siteAction.disabled;
    siteAction.className = section.siteAction.primary ? "primary" : "";
    siteAction.onclick = () => runPageSiteAction(section.siteAction);

    const pauseAction = $("pauseAction");
    pauseAction.hidden = !section.pauseAction;
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

  function closeDisclosure(confirmed) {
    if (!disclosureResolve) return;
    $("disclosure").hidden = true;
    $("popupMain").hidden = false;
    $("popupFooter").hidden = false;
    const resolve = disclosureResolve;
    disclosureResolve = null;
    if (previousActiveElement && typeof previousActiveElement.focus === "function") {
      previousActiveElement.focus();
    }
    resolve(confirmed);
  }

  function presentDisclosure(host) {
    previousActiveElement = document.activeElement;
    const copy = Disclosure.addSite(host, state);
    $("disclosureTitle").textContent = copy.title;
    $("disclosureWhat").textContent = copy.what;
    $("disclosureUnsent").textContent = copy.unsent;
    $("disclosureDestination").textContent = copy.destination;
    $("disclosureDestinationDetail").textContent = copy.destinationDetail;
    $("disclosureChrome").textContent = copy.browser;
    $("disclosureConfirm").textContent = copy.confirmLabel;
    $("disclosureCancel").textContent = copy.cancelLabel;
    $("popupMain").hidden = true;
    $("popupFooter").hidden = true;
    $("disclosure").hidden = false;
    $("disclosureConfirm").focus();
    return new Promise((resolve) => {
      disclosureResolve = resolve;
    });
  }

  function renderCurrent() {
    const about = globalThis.SolstoneAbout.block(chrome.runtime.getManifest().version, state?.about);
    if ($("aboutBlock").textContent !== about) {
      $("aboutBlock").textContent = about;
      $("aboutCopy").textContent = "copy";
      $("aboutMessage").textContent = "";
    }
    const extras = {};
    const derived = Status.derive(state, extras);
    const sections = View.arrange(derived, state, page, extras);
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
    const current = tab && tab.url ? originFor(tab.url) : { origin: "", host: "", ok: false };
    page = { origin: current.origin, host: current.host, ok: current.ok };
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

  $("disclosureConfirm").addEventListener("click", () => closeDisclosure(true));
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
  $("disclosureCancel").addEventListener("click", () => closeDisclosure(false));
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && !$("disclosure").hidden) closeDisclosure(false);
  });
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
  function subscribeStatus() {
    const generation = ++subscriptionEpoch;
    appliedCaptureEpoch = -1;
    const disconnected = () => {
      if (generation !== subscriptionEpoch) return;
      subscriptionEpoch++;
      appliedCaptureEpoch = -1;
      const closed = { ...(state || {}), connected: false, handshake: "closed",
        about: state?.about ? { ...state.about, journal_current: false } : null,
        lease: null, hostCapture: null, hostDelivery: null, hostFailure: null,
        custody: null, capturePermitted: false, addSiteEligible: false };
      paint(closed, ++paintSequence);
      refresh();
      if (reconnectTimer == null) reconnectTimer = setTimeout(() => {
        reconnectTimer = null;
        subscribeStatus();
      }, 1000);
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

  globalThis.SolstonePopup = { refresh };
  refresh();
})();
