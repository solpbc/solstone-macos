// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

(function () {
  "use strict";

  const Hosts = globalThis.SolstoneHosts;
  const Status = globalThis.SolstoneStatus;
  const Failures = globalThis.SolstoneFailures;
  const Disclosure = globalThis.SolstoneDisclosure;
  const Copy = globalThis.SolstoneCopy;
  const View = globalThis.SolstonePopupView;
  const Actions = globalThis.SolstoneActions;
  const $ = (id) => document.getElementById(id);
  const cmd = (message) => new Promise((resolve) => chrome.runtime.sendMessage(message, (response) => resolve(response || {})));

  function renderDisclosure(element) {
    if (!element || !Copy) return;
    element.replaceChildren();
    let list = null;
    for (const line of Copy.DISCLOSURE_BODY.split("\n")) {
      if (!line) {
        list = null;
      } else if (line.startsWith("- ")) {
        if (!list) {
          list = document.createElement("ul");
          element.append(list);
        }
        const item = document.createElement("li");
        item.textContent = line.slice(2);
        list.append(item);
      } else {
        list = null;
        const paragraph = document.createElement("p");
        paragraph.textContent = line;
        element.append(paragraph);
      }
    }
  }

  let state = null;
  let disclosureResolve = null;
  let step1Action = null;
  let paintSequence = 0;
  let appliedCaptureEpoch = -1;

  function normHost(input) {
    let host = input.trim();
    try {
      if (/^https?:\/\//.test(host)) host = new URL(host).host;
    } catch (_error) {
      /* leave as typed */
    }
    return host.replace(/\/.*$/, "").toLowerCase();
  }

  function announce(message, tone = "") {
    const region = $("actionMessage");
    if (!region) return;
    const next = message || "";
    const className = `action-message${next && tone ? ` ${tone}` : ""}`;
    if (region.textContent !== next) region.textContent = next;
    if (region.className !== className) region.className = className;
  }

  function clearAnnouncement() {
    announce("");
  }

  function showActionError(error) {
    announce(Failures.classify(error, state), "bad");
  }

  function siteEffects() {
    return {
      status: state,
      cmd,
      requestPermission: (request) => chrome.permissions.request(request),
    };
  }

  function closeDisclosure(confirmed) {
    if (!disclosureResolve) return;
    if ($("siteDisclosure")) $("siteDisclosure").hidden = true;
    if ($("sitesMain")) $("sitesMain").hidden = false;
    const resolve = disclosureResolve;
    disclosureResolve = null;
    if ($("newHost") && typeof $("newHost").focus === "function") $("newHost").focus();
    resolve(confirmed);
  }

  function presentDisclosure(host) {
    const copy = Disclosure.addSite(host, state);
    if ($("siteDisclosureTitle")) $("siteDisclosureTitle").textContent = copy.title;
    if ($("siteDisclosureWhat")) $("siteDisclosureWhat").textContent = copy.what;
    if ($("siteDisclosureUnsent")) $("siteDisclosureUnsent").textContent = copy.unsent;
    if ($("siteDisclosureDestination")) $("siteDisclosureDestination").textContent = copy.destination;
    if ($("siteDisclosureDestinationDetail")) $("siteDisclosureDestinationDetail").textContent = copy.destinationDetail;
    if ($("siteDisclosureChrome")) $("siteDisclosureChrome").textContent = copy.browser;
    if ($("siteDisclosureConfirm")) $("siteDisclosureConfirm").textContent = copy.confirmLabel;
    if ($("siteDisclosureCancel")) $("siteDisclosureCancel").textContent = copy.cancelLabel;
    if ($("sitesMain")) $("sitesMain").hidden = true;
    if ($("siteDisclosure")) $("siteDisclosure").hidden = false;
    if ($("siteDisclosureConfirm") && typeof $("siteDisclosureConfirm").focus === "function") {
      $("siteDisclosureConfirm").focus();
    }
    return new Promise((resolve) => {
      disclosureResolve = resolve;
    });
  }

  async function addSiteFromInput(inputElement) {
    clearAnnouncement();
    const raw = inputElement ? inputElement.value : "";
    if (!Hosts.isValidHostInput(raw)) {
      return;
    }
    let input = normHost(raw);
    try {
      if (/^https?:\/\//i.test(raw.trim())) input = new URL(raw.trim()).origin;
    } catch (_e) {}
    const displayHost = input.startsWith("http") ? new URL(input).hostname : input;
    const result = await View.addSite(input, Object.assign(siteEffects(), { disclose: presentDisclosure }));
    if (result.cancelled) return;
    if (result.ok && inputElement) inputElement.value = "";
    await refresh();
    if (inputElement && typeof inputElement.focus === "function") inputElement.focus();
    if (result.error) {
      showActionError(result.error);
    } else if (result.ok) {
      const origin = input.startsWith("http") ? input : `https://${input}`;
      const row = Status.siteRow(origin, state);
      if (row.kind === "on-now") {
        announce(`${displayHost} added. what you share there now goes into your journal.`, "ok");
      } else {
        announce(`${displayHost} added.`, "ok");
      }
    }
  }

  async function runSiteAction(action) {
    clearAnnouncement();
    await Actions.run(action, sharedActionEffects());
  }

  function sharedActionEffects() {
    return {
      cmd, refresh,
      openSettings: () => chrome.runtime.openOptionsPage(),
      openApp: () => chrome.tabs.create({ url: "https://solstone.app" }),
      reload: () => chrome.runtime.reload(),
      grantSite: (origin) => View.grantSite(origin, siteEffects()),
      showError: showActionError,
      showDenied: () => announce("permission declined. this site stays paused.", "bad"),
      lossSeq: () => state?.lossNotice?.seq,
    };
  }

  function renderSiteRowsInto(containerId, allowlist) {
    const list = $(containerId);
    if (!list) return;
    list.replaceChildren();

    for (const entry of allowlist) {
      let host = entry;
      try {
        if (entry.startsWith("http")) host = new URL(entry).hostname;
      } catch (_e) {}

      const rowState = Status.siteRow(entry, state);
      const row = document.createElement("div");
      row.className = "site";
      const copyEl = document.createElement("div");
      copyEl.className = "site-copy";
      const hostEl = document.createElement("div");
      hostEl.className = "site-host";
      hostEl.textContent = host;
      const statusEl = document.createElement("div");
      statusEl.className = `site-state${rowState.kind === "on-now" ? " ok" : rowState.kind === "paused-by-browser" ? " bad" : ""}`;
      statusEl.textContent = rowState.label;
      copyEl.append(hostEl, statusEl);

      const actions = document.createElement("div");
      actions.className = "site-actions";
      if (rowState.action) {
        const actionBtn = document.createElement("button");
        actionBtn.type = "button";
        actionBtn.textContent = rowState.action.label;
        actionBtn.addEventListener("click", () => runSiteAction(Object.assign({ host, origin: entry }, rowState.action)));
        actions.append(actionBtn);
      }
      const remove = document.createElement("button");
      remove.type = "button";
      remove.textContent = "remove";
      remove.addEventListener("click", () => runSiteAction({ id: "remove-site", host, origin: entry }));
      actions.append(remove);
      row.append(copyEl, actions);
      list.append(row);
    }

    for (const [origin, notice] of Object.entries(state?.truncationByOrigin || {})) {
      if (!(notice?.count > 0)) continue;
      const attention = document.createElement("div");
      attention.className = "site-issue";
      const sentence = document.createElement("div");
      sentence.className = "w";
      sentence.textContent = Copy.TRUNCATION_ATTENTION;
      const count = document.createElement("div");
      count.className = "count";
      count.textContent = String(notice.count);
      const dismiss = document.createElement("button");
      dismiss.type = "button";
      dismiss.textContent = "dismiss";
      dismiss.addEventListener("click", () => runSiteAction({ id: "dismiss-truncation", origin, bound: notice.newestId }));
      const site = document.createElement("div");
      site.className = "site-host";
      site.textContent = origin;
      attention.append(site, sentence, count, dismiss);
      list.append(attention);
    }
  }

  function getStep1State(st) {
    if (!st || typeof st !== "object" || st.ok === false || !st.inst) {
      return {
        heading: "looking for the solstone app on this computer\u2026",
        body: "",
        action: null,
        met: false,
      };
    }
    const hold = Status.welcomeHold(st);
    return {
      heading: hold.heading,
      body: hold.body,
      action: hold.action,
      met: hold.met,
    };
  }

  function renderWelcome(derived) {
    if ($("pageSubTitle")) $("pageSubTitle").textContent = "in your browser";
    if ($("welcomeView")) $("welcomeView").hidden = false;
    if ($("settingsView")) $("settingsView").hidden = true;

    // Warm Card
    if (Copy && Copy.WARM_CARD) {
      if ($("warmKinship0")) $("warmKinship0").textContent = Copy.WARM_CARD[0];
      if ($("warmKinship1")) $("warmKinship1").textContent = Copy.WARM_CARD[1];
      if ($("warmKinship2")) $("warmKinship2").textContent = Copy.WARM_CARD[2];
    }

    // Step 1
    const step1 = getStep1State(state);
    step1Action = step1.action;
    if ($("step1Heading")) $("step1Heading").textContent = step1.heading;
    if ($("step1Check")) $("step1Check").hidden = !step1.met;
    if ($("step1Body")) $("step1Body").textContent = step1.body;

    const actionBtn = $("step1ActionBtn");
    if (actionBtn) {
      if (step1.action) {
        actionBtn.hidden = false;
        actionBtn.textContent = step1.action.label;
      } else {
        actionBtn.hidden = true;
      }
    }

    // Step 2
    const consentGiven = state && state.consentVersion === 1;
    if ($("step2Heading")) $("step2Heading").textContent = "what the solstone extension takes in";

    if (consentGiven) {
      if ($("step2Check")) $("step2Check").hidden = false;
      if ($("step2Content")) $("step2Content").hidden = true;
      if ($("step2Completed")) $("step2Completed").hidden = false;
    } else {
      if ($("step2Check")) $("step2Check").hidden = true;
      if ($("step2Content")) $("step2Content").hidden = false;
      if ($("step2Completed")) $("step2Completed").hidden = true;
      if (!step1.met) {
        if ($("step2PendingText")) {
          $("step2PendingText").hidden = false;
          $("step2PendingText").textContent = "you'll agree to this once step 1 is done.";
        }
        if ($("agreeDisclosureBtn")) $("agreeDisclosureBtn").hidden = true;
      } else {
        if ($("step2PendingText")) $("step2PendingText").hidden = true;
        if ($("agreeDisclosureBtn")) {
          $("agreeDisclosureBtn").hidden = false;
          $("agreeDisclosureBtn").textContent = "agree and go on";
        }
      }
    }

    // Step 3
    if ($("step3Heading")) $("step3Heading").textContent = "choose your first site";
    const step3Open = consentGiven;
    if ($("step3Content")) $("step3Content").hidden = !step3Open;
    if ($("step3Check")) {
      const chosenList = Array.isArray(state && state.chosenOrigins) ? state.chosenOrigins : [];
      $("step3Check").hidden = !step3Open || chosenList.length === 0;
    }
    if ($("step3Body") && Copy) {
      $("step3Body").textContent = Copy.step3Body(state ? state.brand : "");
    }
    if ($("welcomeShowPageIndicator")) {
      $("welcomeShowPageIndicator").checked = !!(state && state.showPageIndicator);
    }

    const allowlist = Array.isArray(state && state.chosenOrigins)
      ? state.chosenOrigins
      : Array.isArray(state && state.grantedOrigins)
      ? state.grantedOrigins
      : [];
    renderSiteRowsInto("welcomeSiteList", allowlist);
  }

  function renderSettings(derived) {
    if ($("pageSubTitle")) $("pageSubTitle").textContent = "in your browser";
    if ($("welcomeView")) $("welcomeView").hidden = true;
    if ($("settingsView")) $("settingsView").hidden = false;

    // Status Section
    if ($("statusLead")) $("statusLead").textContent = derived.sub || derived.headline;
    if ($("statusStateChip")) {
      $("statusStateChip").textContent = derived.headline;
      $("statusStateChip").className = `state-chip ${derived.mark === "healthy" ? "ok" : derived.mark === "attention" ? "attention" : derived.mark === "error" ? "unavailable" : "calm"}`;
    }
    if ($("statusReason")) {
      $("statusReason").textContent = derived.reason || "";
      $("statusReason").hidden = !derived.reason;
    }
    const also = $("statusAlso");
    if (also) {
      also.replaceChildren();
      for (const item of derived.also || []) {
        const headline = document.createElement("div");
        headline.className = "status-also";
        headline.textContent = item.headline;
        if (item.action) {
          const button = document.createElement("button");
          button.type = "button";
          button.textContent = item.action.label;
          button.addEventListener("click", () => Actions.run(item.action, sharedActionEffects()));
          headline.append(button);
        }
        also.append(headline);
      }
    }
    const actions = $("statusActions");
    if (actions) {
      actions.replaceChildren();
      if (derived.action) {
        const button = document.createElement("button");
        button.type = "button";
        button.textContent = derived.action.label;
        button.addEventListener("click", () => Actions.run(derived.action, sharedActionEffects()));
        actions.append(button);
      }
    }

    // Sites Section
    const allowlist = Array.isArray(state && state.chosenOrigins)
      ? state.chosenOrigins
      : Array.isArray(state && state.grantedOrigins)
      ? state.grantedOrigins
      : [];
    renderSiteRowsInto("siteList", allowlist);

    // Indicator Section
    if ($("showPageIndicator")) $("showPageIndicator").checked = !!(state && state.showPageIndicator);

  }

  function paint(nextState, sequence) {
    if (sequence !== paintSequence) return;
    state = nextState;
    if ($("ver")) $("ver").textContent = state && state.version ? `v${state.version}` : "";

    const derived = Status.derive(state);

    if ($("optionsMark")) {
      $("optionsMark").src = `brand/mark-${derived.mark || "healthy"}.svg`;
    }

    const chosen = Array.isArray(state && state.chosenOrigins)
      ? state.chosenOrigins
      : Array.isArray(state && state.grantedOrigins)
      ? state.grantedOrigins
      : [];

    const isWelcome = (!state || state.consentVersion !== 1) || chosen.length === 0;

    if (isWelcome) {
      renderWelcome(derived);
    } else {
      renderSettings(derived);
    }

    return { derived };
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
    return paint(nextState, sequence);
  }

  for (const id of ["step2DisclosureBody", "step2ReReadBody", "settingsDisclosureBody"]) {
    renderDisclosure($(id));
  }

  // Welcome Step 2 Agree Button
  if ($("agreeDisclosureBtn")) {
    $("agreeDisclosureBtn").addEventListener("click", async () => {
      clearAnnouncement();
      const result = await cmd({ cmd: "acknowledgeDisclosure", version: 1 });
      if (result.error) showActionError(result.error);
      await refresh();
    });
  }

  if ($("step1ActionBtn")) {
    $("step1ActionBtn").addEventListener("click", () => {
      if (step1Action) Actions.run(step1Action, sharedActionEffects());
    });
  }

  // Welcome Step 3 Marker Checkbox
  if ($("welcomeShowPageIndicator")) {
    $("welcomeShowPageIndicator").addEventListener("change", async () => {
      await cmd({ cmd: "setConfig", showPageIndicator: $("welcomeShowPageIndicator").checked });
      await refresh();
    });
  }

  // Settings Add Form
  if ($("addForm")) {
    $("addForm").addEventListener("submit", async (event) => {
      event.preventDefault();
      await addSiteFromInput($("newHost"));
    });
  }

  // Settings Marker Checkbox
  if ($("showPageIndicator")) {
    $("showPageIndicator").addEventListener("change", async () => {
      await cmd({ cmd: "setConfig", showPageIndicator: $("showPageIndicator").checked });
      await refresh();
    });
  }

  // Site Disclosure confirmation
  if ($("siteDisclosureConfirm")) {
    $("siteDisclosureConfirm").addEventListener("click", () => closeDisclosure(true));
  }
  if ($("siteDisclosureCancel")) {
    $("siteDisclosureCancel").addEventListener("click", () => closeDisclosure(false));
  }
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && $("siteDisclosure") && !$("siteDisclosure").hidden) closeDisclosure(false);
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

  globalThis.SolstoneOptions = { refresh };
  refresh();
})();
