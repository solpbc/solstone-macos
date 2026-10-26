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

  const SITES_CARD_ACTIONS = new Set(["open-settings", "allow-all-sites", "retry-all-sites"]);
  let state = null;
  let disclosureResolve = null;
  let allSitesDisclosure = false;
  let disclosureReturnFocus = null;
  let accessCheck = null;
  let lastBroadReady = null;
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
      removePermission: (request) => chrome.permissions.remove(request),
    };
  }

  function focus(id) {
    const element = typeof id === "string" ? $(id) : id;
    if (element && !element.hidden && typeof element.focus === "function") element.focus();
  }

  function closeDisclosure(confirmed) {
    if (!disclosureResolve) return;
    if ($("siteDisclosure")) $("siteDisclosure").hidden = true;
    if ($("sitesMain")) $("sitesMain").hidden = false;
    const resolve = disclosureResolve;
    disclosureResolve = null;
    focus(disclosureReturnFocus || "newHost");
    disclosureReturnFocus = null;
    resolve(confirmed);
  }

  function presentDisclosure(host, allSites = false) {
    allSitesDisclosure = allSites;
    const copy = allSites
      ? Copy.allSitesCopy(state?.brand, { excludedCount: (state?.excludedHosts || []).length, chosenCount: chosenList().length })
      : Disclosure.addSite(host, state);
    if ($("siteDisclosureLeaveOut")) {
      $("siteDisclosureLeaveOut").textContent = copy.leaveOut || "";
      $("siteDisclosureLeaveOut").hidden = !copy.leaveOut;
    }
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
    // A wider agreement is read from its title, never confirmed by a stray Enter.
    focus(allSites ? "siteDisclosureTitle" : "siteDisclosureConfirm");
    return new Promise((resolve) => {
      disclosureResolve = resolve;
    });
  }

  function chosenList() {
    return Array.isArray(state && state.chosenOrigins)
      ? state.chosenOrigins
      : Array.isArray(state && state.grantedOrigins)
      ? state.grantedOrigins
      : [];
  }

  function fieldError(message) {
    const error = $("siteInputError");
    if (!error) return;
    error.textContent = message || "";
    error.hidden = !message;
  }

  async function addSiteFromInput(inputElement) {
    clearAnnouncement();
    fieldError("");
    const raw = inputElement ? inputElement.value : "";
    if (state?.siteMode === "all") {
      const host = Hosts.excludedHostname(raw.trim());
      if (!host) { fieldError("enter a website address, like mail.google.com."); focus(inputElement); return; }
      const result = await cmd({ cmd: "setExcludedHost", host, excluded: true });
      if (result.error) showActionError(result.error);
      else { inputElement.value = ""; announce(Copy.leftOutAnnouncement(host), "ok"); }
      await refresh();
      return;
    }
    if (!Hosts.isValidHostInput(raw)) {
      if (raw.trim()) { fieldError("enter a website address, like mail.google.com."); focus(inputElement); }
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
      allowAllSites: () => View.regrantAllSites(siteEffects()),
      showError: showActionError,
      showDenied: (action) => announce(action?.id === "allow-all-sites"
        ? Copy.accessCopy(state?.brand).declined : "permission declined. this site stays paused.", "bad"),
      lossSeq: () => state?.lossNotice?.seq,
    };
  }

  function renderSiteRowsInto(containerId, allowlist) {
    const list = $(containerId);
    if (!list) return;
    list.replaceChildren();
    if (state?.siteMode === "all" && allowlist.length === 0 && containerId === "siteList") {
      const empty = document.createElement("p");
      empty.className = "muted";
      empty.textContent = "no sites left out.";
      list.append(empty);
    }

    for (const entry of allowlist) {
      let host = entry;
      try {
        if (entry.startsWith("http")) host = new URL(entry).hostname;
      } catch (_e) {}

      const excluded = state?.siteMode === "all";
      const rowState = excluded ? { kind: "excluded", label: "left out" } : Status.siteRow(entry, state);
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
      remove.textContent = excluded ? "include again" : "remove";
      remove.addEventListener("click", () => runSiteAction({ id: excluded ? "include-site" : "remove-site", host, origin: entry }));
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
        if (item.action && !SITES_CARD_ACTIONS.has(item.action.id)) {
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
      // This page is settings, and its sites card carries the browser-access
      // actions, so the status card doesn't repeat them or point at itself.
      if (derived.action && !SITES_CARD_ACTIONS.has(derived.action.id)) {
        const button = document.createElement("button");
        button.type = "button";
        button.textContent = derived.action.label;
        button.addEventListener("click", () => Actions.run(derived.action, sharedActionEffects()));
        actions.append(button);
      }
    }

    // Sites Section
    renderSites();

    // Indicator Section
    if ($("showPageIndicator")) $("showPageIndicator").checked = !!(state && state.showPageIndicator);

  }

  function renderMode(id, mode, current) {
    const words = Copy.SITE_MODES[mode];
    $(`${id}Title`).textContent = words.title;
    $(`${id}Body`).textContent = words.body;
    $(id).className = `mode${current ? " current" : ""}`;
    $(`${id}Current`).textContent = Copy.SITE_MODES.current;
    $(`${id}Current`).hidden = !current;
    const button = $(`${id}Btn`);
    button.hidden = current || state?.sitePolicyPending === true;
    button.textContent = mode === "all" ? Copy.SITE_MODES.chooseAll : Copy.SITE_MODES.chooseSelected;
  }

  function renderAccess(allSites) {
    const panel = $("accessPanel");
    if (!panel) return;
    panel.hidden = !allSites || state?.sitePolicyPending === true;
    if (panel.hidden) return;
    const words = Copy.accessCopy(state?.brand);
    const safari = state?.brand === "safari";
    const granted = state.broadGranted === true;
    const failed = granted && state.allSitesRegistration === "failed";

    $("accessGranted").hidden = !granted || failed;
    $("accessGranted").textContent = [words.granted, words.grantedNote].filter(Boolean).join(" ");

    $("accessMissing").hidden = granted && !failed;
    $("accessTitle").textContent = failed ? words.failedTitle : words.missingTitle;
    $("accessBody").textContent = failed ? words.failedBody : words.missingBody;
    const steps = $("accessSteps");
    steps.replaceChildren();
    for (const step of failed ? [] : words.steps) {
      const item = document.createElement("li");
      item.textContent = step;
      steps.append(item);
    }
    steps.hidden = failed || words.steps.length === 0;
    $("accessReturn").textContent = words.returnNote;
    $("accessReturn").hidden = failed || !words.returnNote;
    // Chrome, Edge and Firefox ask in a prompt; Safari only answers in its settings.
    $("accessAllow").hidden = failed || safari;
    $("accessAllow").textContent = words.allowLabel;
    $("accessCheck").hidden = !failed && !safari;
    $("accessCheck").textContent = failed ? words.retryLabel : words.checkLabel;
    $("accessChecking").textContent = accessCheck ? words.checking : "";

    const denied = granted ? (state.browserDeniedOrigins || []) : [];
    $("accessDenied").hidden = denied.length === 0;
    $("accessDeniedTitle").textContent = words.deniedTitle;
    const list = $("accessDeniedList");
    list.replaceChildren();
    for (const origin of denied) {
      const item = document.createElement("li");
      try { item.textContent = new URL(origin).hostname; } catch (_e) { item.textContent = origin; }
      list.append(item);
    }
    $("accessDeniedHelp").textContent = words.deniedHelp;
    $("accessDeniedHelp").hidden = !words.deniedHelp;
  }

  function renderSites() {
    const allSites = state?.siteMode === "all";
    const chosen = chosenList();
    const excluded = state?.excludedHosts || [];
    // All sites is current only under the current agreement; an older one is
    // agreed again from the all-sites tile.
    const agreedAll = allSites && state.allSitesConsent === Hosts.ALL_SITES_CONSENT_VERSION;
    renderMode("modeSelected", "selected", !allSites);
    renderMode("modeAll", "all", agreedAll);
    renderAccess(agreedAll);

    $("listHeading").textContent = allSites ? "sites left out" : "your sites";
    $("siteModeHelp").textContent = allSites ? Copy.LEAVE_OUT_HELP : "";
    $("siteModeHelp").hidden = !allSites;
    $("siteInputLabel").textContent = allSites ? "leave out a site" : "add a site";
    $("addBtn").textContent = allSites ? "leave out" : "add this site";

    const inactive = !allSites ? (state?.inactiveOrigins || []).filter(origin => chosen.includes(origin)) : [];
    const regrant = $("regrant");
    regrant.hidden = inactive.length < 2;
    if (!regrant.hidden) {
      const words = Copy.regrantCopy(state?.brand, inactive.length);
      $("regrantLine").textContent = words.line;
      $("regrantBtn").textContent = words.label;
    }

    renderSiteRowsInto("siteList", allSites ? excluded : chosen);
    const kept = Copy.keptNote(allSites ? "all" : "selected", allSites ? chosen.length : excluded.length);
    $("keptNote").textContent = kept;
    $("keptNote").hidden = !kept;

    // Coming back from the browser's settings: say so once access arrives.
    const broadReady = agreedAll && state.broadGranted === true && state.allSitesRegistration !== "failed" &&
      state.sitePolicyPending !== true;
    if (lastBroadReady === false && broadReady) announce(Copy.accessCopy(state?.brand).nowAllowed, "ok");
    lastBroadReady = agreedAll && state.sitePolicyPending !== true ? broadReady : null;
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

    const isWelcome = !state || state.consentVersion !== 1;

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
    $("siteDisclosureConfirm").addEventListener("click", () => {
      if (allSitesDisclosure) {
        // Invoke permission request in this actual confirming gesture.
        const result = View.grantAllSites(siteEffects());
        closeDisclosure(true);
        result.then(async value => {
          await refresh();
          if (value.denied) announce("permission declined. your mode hasn't changed.", "bad");
          else if (value.error) showActionError(value.error);
          else if (state?.siteMode === "all" && state.broadGranted !== true) focus("accessTitle");
          else if (state?.siteMode === "all") {
            announce("all sites are shared now. leave out any site below.", "ok");
            focus("sitesHeading");
          }
        });
      } else closeDisclosure(true);
    });
  }
  if ($("siteDisclosureCancel")) {
    $("siteDisclosureCancel").addEventListener("click", () => closeDisclosure(false));
  }
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && $("siteDisclosure") && !$("siteDisclosure").hidden) closeDisclosure(false);
  });

  $("modeAllBtn").addEventListener("click", async () => {
    if (state?.siteMode === "all" && state.allSitesConsent === Hosts.ALL_SITES_CONSENT_VERSION) return;
    clearAnnouncement();
    disclosureReturnFocus = $("modeAllBtn");
    await presentDisclosure(null, true);
  });
  $("modeSelectedBtn").addEventListener("click", async () => {
    clearAnnouncement();
    const result = await cmd({ cmd: "setSiteMode", mode: "selected" });
    if (result.error) showActionError(result.error);
    await refresh();
    if (!result.error) {
      const lost = (state?.inactiveOrigins || []).length;
      announce(lost > 0
        ? `only the sites you add are shared now. ${Copy.regrantCopy(state?.brand, lost).line}`
        : "only the sites you add are shared now.", "ok");
    }
    focus("sitesHeading");
  });
  $("accessAllow").addEventListener("click", async () => {
    clearAnnouncement();
    await Actions.run({ id: "allow-all-sites" }, sharedActionEffects());
  });

  // Safari's grant is made in its own settings window, so this page re-reads the
  // browser whenever the owner comes back to it, and on request.
  async function checkAccess(explicit) {
    if (state?.siteMode !== "all") { await refresh(); return; }
    if (accessCheck) return;
    // A check that doesn't answer gives up, so check again always works; the
    // status channel still brings the answer whenever the browser gives it.
    accessCheck = Promise.race([cmd({ cmd: "refreshSiteAccess" }),
      new Promise((resolve) => setTimeout(() => resolve({ timedOut: true }), 10000))]);
    renderSites();
    const result = await accessCheck;
    accessCheck = null;
    await refresh();
    if (result?.timedOut) renderSites();
    else if (result?.error) showActionError(result.error);
    else if (explicit && state?.siteMode === "all" && state.broadGranted !== true) {
      announce(Copy.accessCopy(state?.brand).stillMissing, "bad");
    }
  }
  $("accessCheck").addEventListener("click", () => checkAccess(true));
  // Safari can unload and restart the background without closing this page's
  // status channel, so coming back reconnects before trusting what is shown.
  function onReturn() {
    subscribeStatus();
    checkAccess(false);
  }
  window.addEventListener("focus", onReturn);
  if (typeof document.addEventListener === "function") {
    document.addEventListener("visibilitychange", () => {
      if (document.visibilityState === "visible") onReturn();
    });
  }
  $("regrantBtn").addEventListener("click", async () => {
    clearAnnouncement();
    const result = await View.grantChosenSites(state?.inactiveOrigins || [], siteEffects());
    if (result.denied) announce("permission declined. those sites stay paused.", "bad");
    else if (result.error) showActionError(result.error);
    await refresh();
  });

  let subscriptionEpoch = 0;
  let reconnectTimer = null;
  let statusPort = null;
  let lastStatusAt = Date.now();
  function subscribeStatus() {
    const generation = ++subscriptionEpoch;
    appliedCaptureEpoch = -1;
    lastStatusAt = Date.now();
    try { statusPort?.disconnect?.(); } catch (_e) {}
    statusPort = null;
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
      statusPort = port;
      port.onMessage.addListener(msg => {
        if (generation === subscriptionEpoch && msg?.type === "status" && msg.status) {
          lastStatusAt = Date.now();
          applyStatus(msg.status);
        }
      });
      port.onDisconnect.addListener(disconnected);
    } catch (_e) { disconnected(); }
  }
  subscribeStatus();

  // The background pushes status every few seconds while the app is connected.
  // A visible page that hears nothing for a while resubscribes rather than keep
  // showing a state from a background that is gone.
  function watchStatus() {
    if (typeof document.visibilityState !== "string") return;
    setTimeout(() => {
      if (document.visibilityState === "visible" && Date.now() - lastStatusAt > 12000) {
        subscribeStatus();
        refresh();
      }
      watchStatus();
    }, 5000);
  }
  watchStatus();

  globalThis.SolstoneOptions = { refresh };
  refresh();
})();
