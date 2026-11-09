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
  let accessCheck = null;
  let everySiteRequestPending = false;
  let firstRunAutoSent = false;
  let lastBroadReady = null;
  let step1Action = null;
  let paintSequence = 0;
  let appliedCaptureEpoch = -1;
  // The latest status from the background; state is what the page shows of
  // it, with the toolbar's timing for the app connection.
  let latest = null;
  let link = null;
  let linkTimer = null;
  // With every site on there is nothing to add, so the site field leaves a site out instead.
  let fieldLeavesOut = false;

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
      getAllPermissions: () => chrome.permissions.getAll(),
      removePermission: (request) => chrome.permissions.remove(request),
    };
  }

  function focus(id) {
    const element = typeof id === "string" ? $(id) : id;
    if (element && !element.hidden && typeof element.focus === "function") element.focus();
  }

  function chosenList() {
    if (state?.fence && Array.isArray(state.fence.entries)) return state.fence.entries;
    if (Array.isArray(state && state.livePatterns)) {
      const H = globalThis.SolstoneHosts;
      const res = [];
      for (const p of state.livePatterns) {
        if (H?.isBroadPattern?.(p)) continue;
        const row = H?.grantRowOrigin?.(p);
        if (row) res.push(row);
      }
      return res;
    }
    return [];
  }

  function fieldError(message) {
    const error = $("siteInputError");
    if (!error) return;
    error.textContent = message || "";
    error.hidden = !message;
  }

  // Typing a site to leave out keeps it out before it's ever opened.
  async function leaveOutFromInput(inputElement) {
    clearAnnouncement();
    fieldError("");
    const raw = inputElement ? inputElement.value.trim() : "";
    // Leaving out is whole-site, so a typed path names its site.
    const host = raw ? Hosts.excludedHostname(/^https?:\/\//i.test(raw) ? raw : `https://${raw}`) : null;
    if (!host) {
      if (raw) { fieldError(Copy.LEAVE_OUT_FIELD_ERROR); focus(inputElement); }
      return;
    }
    const result = await cmd({ cmd: "setLeftOut", host, out: true });
    if (result?.error || result?.ok === false) {
      showActionError(result?.error || "storage_error");
      focus(inputElement);
      return;
    }
    if (inputElement) inputElement.value = "";
    await refresh();
    announce(Copy.leftOutAnnouncement(host), "ok");
    focus(inputElement);
  }

  async function addSiteFromInput(inputElement) {
    clearAnnouncement();
    fieldError("");
    const raw = inputElement ? inputElement.value : "";
    const origin = Hosts.chosenOrigin(raw);
    if (!origin) {
      if (raw.trim()) { fieldError(Copy.FIELD_ERROR); focus(inputElement); }
      return;
    }
    let rawHost = "";
    try { rawHost = new URL(origin).hostname; } catch (_e) {}
    const effectiveList = (state?.excludedHosts || []).concat(state?.appLeftOut || []);
    // Name the left-out entry that covers it (google.com for mail.google.com).
    const coveringEntry = rawHost ? effectiveList.find((s) => Hosts?.hostCovers ? Hosts.hostCovers(s, rawHost) : false) : null;
    if (coveringEntry) {
      announce(Copy.leftOutRefusal(coveringEntry), "bad");
      return;
    }
    const displayHost = Hosts.displayOrigin(origin);
    if (chosenList().includes(origin)) {
      if (inputElement) inputElement.value = "";
      announce(Copy.alreadyAdded(displayHost), "ok");
      focus(inputElement);
      return;
    }
    const result = await View.addSite(origin, siteEffects());
    // Adding needs the solstone app answering and nothing paused; the status
    // card says which, and the owner is never left with a silent button.
    if (result.ineligible) {
      announce(Copy.ADD_NOT_NOW, "bad");
      focus(inputElement);
      return;
    }
    if (result.cancelled) return;
    if (result.ok && inputElement) inputElement.value = "";
    await refresh();
    if (inputElement && typeof inputElement.focus === "function") inputElement.focus();
    if (result.denied) {
      const blocked = result.blockedBy ? Copy.addBlockedBelow(state?.brand, rawHost, result.blockedBy) : "";
      // Declining Safari's prompt is the owner's answer, not a failure, so it reads plain; a policy block stays red.
      announce(blocked || Copy.ADD_DENIED, blocked ? "bad" : "");
    } else if (result.error) {
      showActionError(result.error);
    } else if (result.ok) {
      const row = Status.siteRow(origin, state);
      announce(Copy.addedAnnouncement(displayHost, row.kind === "on-now"), "ok");
    }
  }

  async function runSiteAction(action) {
    clearAnnouncement();
    let failed = false;
    const effects = sharedActionEffects();
    const showError = effects.showError;
    effects.showError = (error) => { failed = true; showError(error); };
    const outcome = await Actions.run(action, effects);
    if (failed) return;
    // Say what the click did; the row it came from is gone now.
    if (action.id === "remove-site") {
      const named = action.label || action.host;
      const said = outcome?.result === "left_out_instead"
        ? Copy.leftOutAnnouncement(named)
        : Copy.removedAnnouncement(named);
      announce(said, "ok");
      focus("newHost");
    } else if (action.id === "include-site") {
      announce(Copy.includedAnnouncement(action.host), "ok");
      focus("newHost");
    }
  }

  function sharedActionEffects() {
    return {
      cmd, refresh,
      openSettings: () => chrome.runtime.openOptionsPage(),
      openApp: () => chrome.tabs.create({ url: "https://solstone.app" }),
      reload: () => chrome.runtime.reload(),
      grantSite: (origin) => View.grantSite(origin, siteEffects()),
      showError: showActionError,
      brand: state?.brand,
      requestPermission: (request) => chrome.permissions.request(request),
      showDenied: () => announce(Copy.accessCopy(state?.brand).declined),
      showOk: (message) => announce(message, "ok"),
      lossSeq: () => state?.lossNotice?.seq,
    };
  }

  function renderSiteRowsInto(containerId, allowlist) {
    const list = $(containerId);
    if (!list) return;
    list.replaceChildren();

    for (const entry of allowlist) {
      // A chosen origin shows its port and an http:// scheme, so two entries
      // for one machine never look alike; a left-out entry is a bare host.
      const host = entry.startsWith("http") ? Hosts.displayOrigin(entry) : entry;
      let hostname = entry;
      try { if (entry.startsWith("http")) hostname = new URL(entry).hostname; } catch (_e) {}

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
        actionBtn.addEventListener("click", () => runSiteAction(Object.assign({ host: hostname, origin: entry }, rowState.action)));
        actions.append(actionBtn);
      }
      const remove = document.createElement("button");
      remove.type = "button";
      remove.textContent = "remove";
      if (typeof remove.setAttribute === "function") remove.setAttribute("aria-label", `${remove.textContent} ${host}`);
      remove.addEventListener("click", () => runSiteAction({ id: "remove-site", host: hostname, label: host, origin: entry }));
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
      const dismiss = document.createElement("button");
      dismiss.type = "button";
      dismiss.textContent = "dismiss";
      dismiss.addEventListener("click", () => runSiteAction({ id: "dismiss-truncation", origin, bound: notice.newestId }));
      const site = document.createElement("div");
      site.className = "site-host";
      site.textContent = Hosts.displayOrigin(origin);
      attention.append(site, sentence, dismiss);
      list.append(attention);
    }
  }

  function getStep1State(st) {
    if (!st || typeof st !== "object" || st.ok === false || !st.inst) {
      return {
        heading: `looking for the solstone app on ${Copy.PLACE}\u2026`,
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

  function heldRules(st) {
    const rules = st && st.agreementRules;
    return rules === "firefox" || rules === "safari" ? rules : "chrome";
  }

  function questionShown(st) {
    if (Copy.MOBILE === true) return false;
    const rules = heldRules(st);
    if (!st || st.ok !== true) return rules === "chrome";
    if (rules === "chrome") return st.consentAccepted !== true;
    if (st.firstRunAnswered === true) return false;
    if (Hosts?.everySiteLive?.(st.livePatterns) === true) return false;
    return true;
  }

  function welcomeShown(st) {
    if (Copy.MOBILE === true) return false;
    if (!st || st.ok !== true) return true;
    const rules = heldRules(st);
    if (rules === "chrome") {
      const accepted = st.consentAccepted === true;
      return !accepted;
    }
    return questionShown(st);
  }

  function placeDisclosureCard(inQuestion) {
    const card = $("disclosureCard");
    const settings = $("settingsView");
    const welcome = $("welcomeView");
    if (!card || !settings || !welcome) return;
    const summary = $("disclosureSummary");
    if (inQuestion) {
      if (card.parentNode !== welcome) welcome.append(card);
      card.hidden = false;
      // Nobody has read it yet on a first run.
      if (summary) summary.textContent = "what it takes in";
    } else {
      if (card.parentNode !== settings) settings.append(card);
      if (summary && !Copy.MOBILE) summary.textContent = "read it again";
    }
  }

  // Each answer keeps its words with its own button, so neither reads as the other's.
  function firstRunOption(...parts) {
    const group = document.createElement("div");
    group.className = "first-run-option";
    group.append(...parts);
    return group;
  }

  function renderFirstRunQuestion(st, step1Met) {
    const welcome = $("welcomeView");
    if (!welcome) return;
    let block = findChild(welcome, "firstRunQuestion");
    if (!questionShown(st)) {
      if (block) removeChild(welcome, block);
      return;
    }
    if (!block) {
      block = document.createElement("section");
      block.id = "firstRunQuestion";
      block.className = "card";
      welcome.append(block);
    }
    block.replaceChildren();
    const rules = heldRules(st);
    const heading = document.createElement("h2");
    heading.id = "firstRunHeading";
    heading.textContent = "which sites do you want in your journal?";
    block.append(heading);
    const buttonsLive = rules !== "chrome" || step1Met === true;
    const everyBody = document.createElement("p");
    everyBody.textContent = Copy.everySiteQuestionBody();
    const every = document.createElement("button");
    every.type = "button";
    every.id = "firstRunEverySite";
    every.hidden = !buttonsLive;
    every.textContent = rules === "chrome" ? "agree and share every site" : "share every site";
    if (rules === "chrome") every.dataset.act = "agree";
    every.addEventListener("click", () => runFirstRunEverySite());
    if (Hosts?.everySiteLive?.(st?.livePatterns) === true) {
      // One-at-a-time would be a false promise. Chrome says so before the agreeing click.
      if (rules === "chrome") {
        const already = document.createElement("p");
        already.id = "firstRunAlreadyAllowed";
        already.textContent = Copy.alreadyAllowedBody(st?.brand);
        block.append(firstRunOption(everyBody, already, every));
      } else {
        block.append(firstRunOption(everyBody, every));
      }
      return;
    }
    block.append(firstRunOption(everyBody, every));
    const oneBody = document.createElement("p");
    oneBody.textContent = Copy.oneSiteQuestionBody();
    const one = document.createElement("button");
    one.type = "button";
    one.id = "firstRunOneSite";
    one.hidden = !buttonsLive;
    one.textContent = rules === "chrome" ? "agree and add sites one at a time" : "add sites one at a time";
    if (rules === "chrome") one.dataset.act = "agree";
    one.addEventListener("click", () => runFirstRunOneSite());
    block.append(firstRunOption(oneBody, one));
  }

  function renderWelcome(derived) {
    if ($("pageSubTitle")) $("pageSubTitle").textContent = "in your browser";
    if ($("welcomeView")) {
      $("welcomeView").hidden = false;
      $("welcomeView").dataset.rules = heldRules(state);
    }
    if ($("settingsView")) $("settingsView").hidden = true;

    if (Copy && Copy.WARM_CARD) {
      if ($("warmKinship0")) $("warmKinship0").textContent = Copy.WARM_CARD[0];
      if ($("warmKinship1")) $("warmKinship1").textContent = Copy.WARM_CARD[1];
      if ($("warmKinship2")) $("warmKinship2").textContent = Copy.WARM_CARD[2];
    }

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

    const rules = heldRules(state);
    const chromeAgreement = rules === "chrome";
    if ($("step2Section")) $("step2Section").hidden = !chromeAgreement;
    if ($("step3Section")) $("step3Section").hidden = true;
    if ($("agreeDisclosureBtn")) $("agreeDisclosureBtn").hidden = true;
    if ($("step2Heading")) $("step2Heading").textContent = "what the solstone extension takes in";
    if ($("step3Heading")) $("step3Heading").textContent = "choose your first site";
    if ($("step3Body") && Copy) $("step3Body").textContent = Copy.step3Body(state ? state.brand : "");
    if ($("step2Check")) $("step2Check").hidden = true;
    if ($("step2Completed")) $("step2Completed").hidden = true;
    if ($("step2Content")) $("step2Content").hidden = !chromeAgreement;
    if (chromeAgreement && !step1.met) {
      if ($("step2PendingText")) {
        $("step2PendingText").hidden = false;
        $("step2PendingText").textContent = Copy.STEP2_PENDING;
      }
      if ($("step2DisclosureBody")) $("step2DisclosureBody").hidden = true;
    } else {
      if ($("step2PendingText")) $("step2PendingText").hidden = true;
      if ($("step2DisclosureBody")) $("step2DisclosureBody").hidden = !chromeAgreement;
    }

    renderFirstRunQuestion(state, step1.met);
    placeDisclosureCard(!chromeAgreement);
  }

  function renderSettings(derived) {
    if ($("pageSubTitle")) $("pageSubTitle").textContent = "in your browser";
    const welcome = $("welcomeView");
    if (welcome) {
      welcome.hidden = true;
      const block = findChild(welcome, "firstRunQuestion");
      if (block) removeChild(welcome, block);
    }
    placeDisclosureCard(false);
    if ($("settingsView")) $("settingsView").hidden = false;

    // Status Section
    // On a phone the card is only for what needs the owner; the list says the rest.
    if ($("statusCard")) $("statusCard").hidden = Copy.MOBILE === true && ["no-sites", "on", "idle"].includes(derived.kind);
    if ($("pauseSwitch")) $("pauseSwitch").checked = state?.paused === true;
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
      // The popup's pause button reads resume; settings needs its own, or an
      // owner who comes here to turn things back on finds no way to.
      if (state?.paused) {
        const resume = document.createElement("button");
        resume.type = "button";
        resume.className = "primary";
        resume.textContent = "resume";
        resume.addEventListener("click", async () => {
          clearAnnouncement();
          const result = await cmd({ cmd: "setPaused", paused: false });
          if (result.error) showActionError(result.error);
          await refresh();
        });
        actions.append(resume);
      }
    }

    // Top sections (clearedNotice, upgradeQuestion, upgradeQuiet, stopResult)
    renderTopSections(optionsModel(state));

    // Sites Section
    renderSites();

    if ($("pauseWithApp")) $("pauseWithApp").checked = state?.pauseWithApp !== false;

  }

  let stopResultCode = null;

  function optionsModel(st) {
    st = st || {};
    const H = globalThis.SolstoneHosts;
    const isBroad = !st.fence && (st.broadGrant === true || (Array.isArray(st.livePatterns) && H?.broadLive(st.livePatterns)));
    const sections = [];

    if (st.clearedNotice) {
      sections.push({
        id: "clearedNotice",
        kind: "cleared-notice",
        text: Copy.clearedStorageNotice(),
      });
    }

    if (st.fence && st.fence.sawMore && !st.fence.answered) {
      const leftOutHosts = Array.from(new Set([...(st.excludedHosts || []), ...(st.appLeftOut || [])]));
      const beyond = H?.beyondExample ? H.beyondExample(st.fence, st.livePatterns || [], leftOutHosts) : null;
      if (beyond) {
        const q = Copy?.fenceQuestion ? Copy.fenceQuestion(st.brand, beyond.kind, beyond.host) : null;
        if (q) {
          sections.push({
            id: "upgradeQuestion",
            kind: "upgrade-question",
            shown: beyond.shown,
            body: q.body,
            buttons: [
              {
                id: q.shareId,
                label: q.shareLabel,
                // Taking in more is never the visually preselected answer.
                primary: false,
              },
              {
                id: q.keepId || "keep-my-sites",
                label: q.keepLabel || "keep my sites",
                primary: false,
              },
            ],
            action: {
              id: q.shareId,
              label: q.shareLabel,
              primary: false,
            },
            secondaryAction: {
              id: q.keepId || "keep-my-sites",
              label: q.keepLabel || "keep my sites",
              primary: false,
            },
          });
        }
      }
    } else if (st.fence && st.fence.answered) {
      // Safari can't be asked, so its offer shows only while Safari allows every site.
      const canShare = st.brand !== "safari" || H?.everySiteLive?.(st.livePatterns || []) === true;
      // Say the browser allows more only while it still does: an owner can set it back after keeping their sites.
      const leftOutHosts = Array.from(new Set([...(st.excludedHosts || []), ...(st.appLeftOut || [])]));
      const allowsMore = !H?.beyondExample || H.beyondExample(st.fence, st.livePatterns || [], leftOutHosts) !== null;
      sections.push({
        id: "upgradeQuiet",
        kind: "upgrade-quiet",
        text: Copy.fenceQuiet(st.brand, allowsMore),
        action: canShare ? {
          id: "share-every-site",
          label: Copy.SHARE_EVERY_SITE,
          primary: false,
        } : null,
      });
    }

    if (stopResultCode) {
      const kind = stopResultCode === "still_every_site" ? "stop-still"
        : stopResultCode === "every_site_off_none" ? "stop-none"
        : stopResultCode === "every_site_off_some" ? "stop-some" : null;
      if (kind) {
        sections.push({
          id: "stopResult",
          kind,
          text: Copy?.stopResultCopy ? Copy.stopResultCopy(st.brand, stopResultCode) : "",
        });
      }
    }

    if (isBroad) {
      sections.push({
        id: "access",
        kind: "access",
        brand: st.brand,
        safari: st.brand === "safari",
        steps: st.brand === "safari",
        stopSharing: st.brand !== "safari",
      });
    }

    return sections;
  }

  function renderTopSections(modelSections) {
    let topContainer = $("optionsTopSections");
    if (!topContainer) {
      topContainer = document.createElement("div");
      topContainer.id = "optionsTopSections";
      const settingsView = $("settingsView");
      if (settingsView && settingsView.firstChild) {
        settingsView.insertBefore(topContainer, settingsView.firstChild);
      } else if (settingsView) {
        settingsView.appendChild(topContainer);
      }
    }
    topContainer.replaceChildren();
    for (const sec of modelSections) {
      if (["cleared-notice", "upgrade-question", "upgrade-quiet", "stop-still", "stop-none", "stop-some"].includes(sec.kind)) {
        const div = document.createElement("section");
        div.className = `card ${sec.kind}`;
        div.dataset.kind = sec.kind;
        if (sec.kind === "cleared-notice") {
          const p = document.createElement("p");
          p.textContent = sec.text;
          div.append(p);
        } else if (sec.kind === "upgrade-question") {
          const p = document.createElement("p");
          p.textContent = sec.body;
          const actions = document.createElement("div");
          actions.className = "actions";
          for (const btn of (sec.buttons || [])) {
            const b = document.createElement("button");
            b.type = "button";
            b.id = btn.id;
            b.dataset.shareId = btn.id;
            b.className = btn.primary ? "primary" : "";
            b.textContent = btn.label;
            b.addEventListener("click", async () => {
              if (btn.id === "share-every-site") {
                await runShareEverySite();
                return;
              }
              if (btn.id === "share-them-too") {
                const shown = sec.shown;
                const result = await cmd({ cmd: "shareThemToo", shown });
                const held = result?.result === "share_held" || result?.result === "question_every_site" || result?.result === "question_changed";
                if (!held && (result?.error || result?.ok === false)) {
                  showActionError(result?.error || "storage_error");
                }
                await refresh();
                return;
              }
              if (btn.id === "keep-my-sites") await cmd({ cmd: "keepMySites" });
              await refresh();
            });
            actions.append(b);
          }
          div.append(p, actions);
        } else if (sec.kind === "upgrade-quiet") {
          const p = document.createElement("p");
          p.textContent = sec.text;
          div.append(p);
          if (sec.action) {
            const actions = document.createElement("div");
            actions.className = "actions";
            const b = document.createElement("button");
            b.type = "button";
            b.id = sec.action.id;
            b.dataset.shareId = sec.action.id;
            b.className = sec.action.primary ? "primary" : "";
            b.textContent = sec.action.label;
            b.addEventListener("click", () => runShareEverySite());
            actions.append(b);
            div.append(actions);
            mountVersionOneNote(div, actions);
          }
        } else if (["stop-still", "stop-none", "stop-some"].includes(sec.kind)) {
          const p = document.createElement("p");
          p.textContent = sec.text;
          div.append(p);
        }
        topContainer.append(div);
      }
    }
    if (modelSections.some((sec) => sec.id === "stopResult")) stopResultCode = null;
  }

  // The request starts before this handler awaits, while the click still counts.
  function requestShareEverySite() {
    if (state?.brand === "safari") return null;
    try {
      return chrome.permissions.request({ origins: ["*://*/*"] });
    } catch (_e) {
      return null;
    }
  }

  // Announce after refresh, so the next paint does not wipe the sentence.
  // A request that resolves false is a decline. Safari does not ask.
  async function runShareEverySite() {
    const requested = requestShareEverySite();
    let granted = null;
    if (requested && typeof requested.then === "function") {
      try { granted = await requested; }
      catch (_e) { granted = null; }
    }
    if (granted === false) {
      await refresh();
      announce(Copy.accessCopy(state?.brand).declined);
      return;
    }
    const result = await cmd({ cmd: "shareEverySite" });
    await refresh();
    const held = result?.result === "share_held" || result?.result === "question_every_site";
    if (!held && !result?.error && result?.ok !== false) {
      announce(Copy.accessCopy(state?.brand).nowAllowed, "ok");
    }
  }

  function offersShareEverySite() {
    if (!state?.fence || state.fence.sawMore === true) return false;
    return Hosts?.everySiteLive?.(state.livePatterns || []) !== true;
  }

  function clearDeniedList() {
    if ($("accessDenied")) $("accessDenied").hidden = true;
    if ($("accessDeniedTitle")) $("accessDeniedTitle").textContent = "";
    if ($("accessDeniedList")) $("accessDeniedList").replaceChildren();
    if ($("accessDeniedHelp")) {
      $("accessDeniedHelp").textContent = "";
      $("accessDeniedHelp").hidden = true;
    }
  }

  function renderAccess(isBroad) {
    clearDeniedList();
    const panel = $("accessPanel");
    if (!panel) return;
    dropVersionOneNote($("accessAllow")?.parentNode || panel);
    const offerShare = offersShareEverySite();
    if (state?.fence && !offerShare) {
      panel.hidden = true;
      syncSettingsEverySiteOn(false);
      return;
    }
    panel.hidden = false;
    const words = Copy.accessCopy(state?.brand);
    const safari = state?.brand === "safari";

    if (isBroad) {
      if ($("accessGranted")) $("accessGranted").hidden = true;
      if ($("accessMissing")) $("accessMissing").hidden = false;
      if ($("accessTitle")) $("accessTitle").textContent = "";
      if (safari) {
        if ($("accessBody")) {
          const parts = [Copy.everySiteOnLine(state?.brand), Copy.safariStopLine()];
          if (words.grantedNote) parts.push(words.grantedNote);
          $("accessBody").textContent = parts.join(" ");
        }
        if ($("accessSteps")) {
          $("accessSteps").replaceChildren();
          $("accessSteps").hidden = true;
        }
        if ($("accessReturn")) $("accessReturn").hidden = true;
        if ($("accessCheck")) $("accessCheck").hidden = true;
        if ($("accessChecking")) $("accessChecking").textContent = "";
        if ($("accessAllow")) $("accessAllow").hidden = true;
      } else {
        if ($("accessBody")) $("accessBody").textContent = Copy.everySiteOnLine(state?.brand);
        if ($("accessSteps")) {
          $("accessSteps").replaceChildren();
          $("accessSteps").hidden = true;
        }
        if ($("accessReturn")) $("accessReturn").hidden = true;
        if ($("accessCheck")) $("accessCheck").hidden = true;
        if ($("accessChecking")) $("accessChecking").textContent = "";
        if ($("accessAllow")) {
          $("accessAllow").hidden = false;
          $("accessAllow").textContent = Copy.STOP_SHARING_EVERY_SITE;
          dropVersionOneNote($("accessAllow").parentNode);
        }
      }
    } else {
      if ($("accessGranted")) $("accessGranted").hidden = true;
      if ($("accessMissing")) $("accessMissing").hidden = false;
      // Safari can't be asked for every site, so a button here would do nothing.
      // Its own steps are the way, fence or not; once Safari allows every site,
      // a held owner gets the upgrade question.
      if (safari) {
        if ($("accessTitle")) $("accessTitle").textContent = words.missingTitle;
        if ($("accessBody")) $("accessBody").textContent = words.missingBody;
        const steps = $("accessSteps");
        if (steps) {
          steps.replaceChildren();
          for (const step of words.steps) {
            const item = document.createElement("li");
            item.textContent = step;
            steps.append(item);
          }
          steps.hidden = words.steps.length === 0;
        }
        if ($("accessReturn")) {
          $("accessReturn").textContent = words.returnNote;
          $("accessReturn").hidden = !words.returnNote;
        }
        if ($("accessAllow")) $("accessAllow").hidden = true;
        if ($("accessCheck")) {
          $("accessCheck").hidden = false;
          $("accessCheck").textContent = words.checkLabel;
        }
        if ($("accessChecking")) $("accessChecking").textContent = accessCheck ? words.checking : "";
      } else {
        if ($("accessTitle")) $("accessTitle").textContent = "";
        if ($("accessBody")) $("accessBody").textContent = words.missingBody;
        if ($("accessSteps")) {
          $("accessSteps").replaceChildren();
          $("accessSteps").hidden = true;
        }
        if ($("accessReturn")) $("accessReturn").hidden = true;
        if ($("accessCheck")) $("accessCheck").hidden = true;
        if ($("accessChecking")) $("accessChecking").textContent = "";
        if ($("accessAllow")) {
          $("accessAllow").hidden = false;
          $("accessAllow").textContent = "share every site";
          mountVersionOneNote($("accessAllow").parentNode, $("accessAllow"));
        }
      }
    }
    syncSettingsEverySiteOn(false);
  }

  function renderSites() {
    const H = globalThis.SolstoneHosts;
    const everySite = !state?.fence && H?.everySiteLive?.(state?.livePatterns) === true;

    if ($("modeSelected")) $("modeSelected").hidden = true;
    if ($("modeAll")) $("modeAll").hidden = true;
    if ($("offersBlock")) $("offersBlock").hidden = true;
    if ($("broadInSelectedNote")) $("broadInSelectedNote").hidden = true;
    if ($("regrant")) $("regrant").hidden = true;
    if ($("exactOnly")) $("exactOnly").hidden = true;
    if ($("keptNote")) $("keptNote").hidden = true;

    renderAccess(everySite);
    syncSettingsEverySiteOn(false);

    if ($("listHeading")) {
      $("listHeading").textContent = "your sites";
      $("listHeading").hidden = everySite;
    }
    if ($("siteModeHelp")) {
      $("siteModeHelp").textContent = state?.permissionsUnavailable === true
        ? Copy.actionFailure("permissions_unavailable", state?.brand)
        : Copy.addHelp(state?.brand);
      // With every site on there is nothing to add, so the form and its help step aside.
      $("siteModeHelp").hidden = everySite && state?.permissionsUnavailable !== true;
    }
    fieldLeavesOut = everySite;
    if ($("addForm")) $("addForm").hidden = false;
    if ($("siteInputLabel")) $("siteInputLabel").textContent = fieldLeavesOut ? "leave out a site" : "add a site";
    if ($("addBtn")) $("addBtn").textContent = fieldLeavesOut ? "leave out" : "add this site";
    if ($("newHost")) $("newHost").placeholder = fieldLeavesOut ? "bank.com" : (Copy.MOBILE ? "eff.org" : "mail.google.com");

    let visibleSites = [];
    if (state?.fence) {
      visibleSites = state.fence.entries || [];
    } else if (everySite) {
      visibleSites = [];
    } else if (Array.isArray(state?.livePatterns)) {
      const origins = new Set();
      for (const pattern of state.livePatterns) {
        if (!H.isBroadPattern(pattern)) {
          const row = H.grantRowOrigin?.(pattern);
          if (row) origins.add(row);
        }
      }
      visibleSites = Array.from(origins);
    } else {
      visibleSites = [];
    }

    renderSiteRowsInto("siteList", visibleSites);

    const leftOutDetails = $("leftOutDetails");
    if (leftOutDetails) {
      const localEx = state?.excludedHosts || [];
      const appEx = state?.appLeftOut || [];
      const effectiveList = Array.from(new Set([...localEx, ...appEx]));
      if ($("leftOutNote")) {
        $("leftOutNote").textContent = Copy.leftOutListNote(state?.brand);
        $("leftOutNote").hidden = !everySite && effectiveList.length === 0;
      }
      if (effectiveList.length === 0) {
        leftOutDetails.hidden = true;
      } else {
        leftOutDetails.hidden = false;
        if (everySite) leftOutDetails.open = true;
        if ($("leftOutSummary")) {
          $("leftOutSummary").textContent = Copy.leftOutSummary(effectiveList.length);
        }
        const listDiv = $("leftOutList");
        if (listDiv) {
          listDiv.replaceChildren();
          for (const host of effectiveList) {
            const isLocal = localEx.includes(host);
            const row = document.createElement("div");
            row.className = "site";
            const hostSpan = document.createElement("span");
            hostSpan.className = "site-host";
            hostSpan.textContent = host;
            row.append(hostSpan);

            if (isLocal || state?.leftOutCapable) {
              const btn = document.createElement("button");
              btn.type = "button";
              btn.textContent = "stop leaving out";
              btn.className = "include";
              btn.addEventListener("click", async () => {
                clearAnnouncement();
                const res = await cmd({ cmd: "setLeftOut", host, out: false });
                if (res?.error) showActionError(res.error);
                else announce(Copy.includedAnnouncement(host), "ok");
                await refresh();
              });
              row.append(btn);
            } else {
              const span = document.createElement("span");
              span.className = "muted";
              span.textContent = Copy.appOnlyLeftOut;
              row.append(span);
            }
            listDiv.append(row);
          }
        }
      }
    }
  }

  function paint(nextState, sequence) {
    if (sequence !== paintSequence) return;
    latest = nextState;
    return show();
  }

  function findChild(parent, id) {
    if (!parent || !parent.children) return null;
    for (const child of parent.children) {
      if (child.id === id) return child;
    }
    return null;
  }

  function removeChild(parent, node) {
    if (!parent || !node) return;
    if (typeof node.remove === "function") node.remove();
    if (Array.isArray(parent.children)) {
      parent.children = parent.children.filter((child) => child !== node);
    }
  }

  // The notice sits above the welcome view. Settings keeps its own copy.
  function renderWelcomeClearedNotice() {
    const welcome = $("welcomeView");
    if (!welcome) return;
    const parent = welcome.parentNode;
    const notice = parent ? findChild(parent, "welcomeClearedNotice") : null;
    const show = state?.clearedNotice === true && welcome.hidden !== true;
    if (!show) {
      removeChild(parent, notice);
      return;
    }
    let section = notice;
    if (!section) {
      section = document.createElement("section");
      section.id = "welcomeClearedNotice";
      section.className = "card cleared-notice";
    }
    section.replaceChildren();
    const text = document.createElement("p");
    text.textContent = Copy.clearedStorageNotice();
    const resume = document.createElement("button");
    resume.type = "button";
    resume.textContent = "resume";
    resume.addEventListener("click", async () => {
      clearAnnouncement();
      const result = await cmd({ cmd: "setPaused", paused: false });
      if (result?.error) showActionError(result.error);
      await refresh();
    });
    section.append(text, resume);
    if (parent && typeof parent.insertBefore === "function") {
      parent.insertBefore(section, welcome);
    } else if (parent && Array.isArray(parent.children)) {
      parent.children = parent.children.filter((child) => child !== section);
      const at = parent.children.indexOf(welcome);
      parent.children.splice(at < 0 ? 0 : at, 0, section);
      section.parentNode = parent;
    }
  }

  function paintedState(shown, raw) {
    if (!shown || typeof shown !== "object") return shown;
    if (shown.ok === false || (raw && raw.ok === false)) return shown;
    if (shown.ok === true || (raw && raw.ok === true)) {
      return shown.ok === true ? shown : Object.assign({}, shown, { ok: true });
    }
    if (raw && typeof raw === "object" && raw.ok !== false &&
        (typeof raw.inst === "string" || typeof raw.captureEpoch === "number")) {
      return Object.assign({}, shown, { ok: true });
    }
    return shown;
  }

  function maybeAutoAnswer(st) {
    if (Copy.MOBILE === true) return;
    if (!st || st.ok !== true) return;
    const rules = heldRules(st);
    if (rules !== "firefox" && rules !== "safari") return;
    if (st.firstRunAnswered === true) return;
    if (Hosts?.everySiteLive?.(st.livePatterns) !== true) return;
    if (firstRunAutoSent) return;
    firstRunAutoSent = true;
    cmd({ cmd: "answerFirstRun" }).then(() => refresh());
  }

  function dropVersionOneNote(parent) {
    if (!parent) return;
    const note = findChild(parent, "versionOneShareNote");
    if (note) removeChild(parent, note);
  }

  function mountVersionOneNote(parent, before) {
    if (!parent) return;
    dropVersionOneNote(parent);
    if (state?.versionOneFence !== true || !state.fence || typeof state.fence !== "object") return;
    const note = document.createElement("p");
    note.id = "versionOneShareNote";
    note.hidden = false;
    note.textContent = Copy.VERSION_ONE_SHARE_NOTE;
    if (typeof parent.insertBefore === "function") parent.insertBefore(note, before || null);
    else parent.append(note);
  }

  function syncSettingsEverySiteOn(live) {
    const host = $("sitesMain") || $("settingsView");
    if (!host) return;
    const existing = findChild(host, "settingsEverySiteOn");
    if (live !== true) {
      if (existing) removeChild(host, existing);
      return;
    }
    if (existing) {
      existing.hidden = false;
      return;
    }
    const line = document.createElement("p");
    line.id = "settingsEverySiteOn";
    line.hidden = false;
    line.textContent = Copy.everySiteOnLine(state?.brand);
    host.append(line);
  }

  function appendActionNote(id, text) {
    // While the welcome shows, settings is hidden, so a note there would never be seen.
    const welcome = $("welcomeView");
    const region = welcome && welcome.hidden === false && $("welcomeMessage") ? $("welcomeMessage") : $("actionMessage");
    if (!region) return;
    const note = document.createElement("p");
    note.id = id;
    note.hidden = false;
    note.textContent = text || "";
    region.append(note);
  }

  async function runFirstRunEverySite() {
    if (state?.ok !== true) return;
    const rules = heldRules(state);
    const live = Hosts?.everySiteLive?.(state?.livePatterns) === true;
    if (live) {
      if (rules === "chrome") {
        await cmd({ cmd: "acknowledgeDisclosure" });
        await refresh();
        appendActionNote("firstRunAlreadyAllowed", Copy.alreadyAllowedBody(state?.brand));
        return;
      }
      await cmd({ cmd: "answerFirstRun" });
      await refresh();
      return;
    }
    if (rules === "safari") {
      await cmd({ cmd: "answerFirstRun" });
      await refresh();
      return;
    }
    everySiteRequestPending = true;
    const hadFence = !!(state?.fence && typeof state.fence === "object");
    try {
      let granted = false;
      let failed = false;
      try {
        const pending = chrome.permissions.request({ origins: ["*://*/*"] });
        if (pending && typeof pending.then === "function") granted = (await pending) === true;
        else granted = pending === true;
      } catch (_e) {
        failed = true;
      }
      if (!granted) failed = true;
      let result = null;
      if (rules === "chrome") result = await cmd({ cmd: "acknowledgeDisclosure" });
      else if (!failed) result = await cmd({ cmd: "answerFirstRun" });
      await refresh();
      if (failed) {
        appendActionNote("firstRunDeclined", Copy.accessCopy(state?.brand).declined);
        return;
      }
      if (result?.result === "agreed_fence_kept") {
        announce(Failures.classify("permissions_unavailable", state), "bad");
        return;
      }
      const everyLive = Hosts?.everySiteLive?.(state?.livePatterns) === true;
      const fenceEnded = hadFence && !state?.fence;
      if (fenceEnded || everyLive) {
        appendActionNote("everySiteNowOn", Copy.accessCopy(state?.brand).nowAllowed);
      }
    } finally {
      everySiteRequestPending = false;
    }
  }

  async function runFirstRunOneSite() {
    if (state?.ok !== true) return;
    if (everySiteRequestPending) return;
    const rules = heldRules(state);
    if (Hosts?.everySiteLive?.(state?.livePatterns) === true) {
      if (rules === "chrome") {
        appendActionNote("firstRunAlreadyAllowed", Copy.alreadyAllowedBody(state?.brand));
        return;
      }
      await cmd({ cmd: "answerFirstRun" });
      await refresh();
      return;
    }
    if (rules === "chrome") {
      const result = await cmd({ cmd: "acknowledgeDisclosure" });
      await refresh();
      if (result?.result === "agreed_fence_kept") {
        announce(Failures.classify("permissions_unavailable", state), "bad");
        return;
      }
      if (result?.ok === false) {
        if (result?.error) showActionError(result.error);
        return;
      }
      focus("newHost");
      return;
    }
    await cmd({ cmd: "answerFirstRun" });
    await refresh();
  }

  function show() {
    link = Status.present(link, latest, undefined, Date.now());
    if (linkTimer != null) clearTimeout(linkTimer);
    linkTimer = link.wakeAt == null ? null : setTimeout(() => {
      linkTimer = null;
      show();
    }, Math.max(0, link.wakeAt - Date.now()));
    // Nothing heard yet: the page keeps its first look.
    if (!link.status) return;
    state = paintedState(link.status, latest);
    if ($("ver")) $("ver").textContent = state && state.version ? `v${state.version}` : "";

    const derived = Status.derive(state);

    if ($("optionsMark")) {
      $("optionsMark").src = `brand/mark-${Copy.MOBILE === true ? "healthy" : derived.mark || "healthy"}.svg`;
    }

    if (welcomeShown(state)) {
      renderWelcome(derived);
    } else {
      maybeAutoAnswer(state);
      renderSettings(derived);
    }
    renderWelcomeClearedNotice();

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

  if ($("step1ActionBtn")) {
    $("step1ActionBtn").addEventListener("click", () => {
      if (step1Action) Actions.run(step1Action, sharedActionEffects());
    });
  }

  // Settings Add Form
  if ($("addForm")) {
    $("addForm").addEventListener("submit", async (event) => {
      event.preventDefault();
      if (fieldLeavesOut) await leaveOutFromInput($("newHost"));
      else await addSiteFromInput($("newHost"));
    });
  }

  // Settings Pause With App Checkbox
  // On iPhone and iPad the solstone app has no pause, so there is nothing to choose.
  if (Copy.MOBILE && $("pauseWithAppCard")) $("pauseWithAppCard").hidden = true;
  // A phone's settings are one list: its sites, the pause switch, and what it takes in.
  if (Copy.MOBILE) {
    document.documentElement.classList.add("mobile");
    document.querySelector("#disclosureCard summary").textContent = "what it takes in";
    $("pauseCard").hidden = false;
    $("pauseSwitch").addEventListener("change", async () => {
      await cmd({ cmd: "setPaused", paused: $("pauseSwitch").checked });
      await refresh();
    });
  }
  if ($("pauseWithApp")) {
    $("pauseWithApp").addEventListener("change", async () => {
      await cmd({ cmd: "setConfig", pauseWithApp: $("pauseWithApp").checked });
      await refresh();
    });
  }

  $("modeAllBtn")?.addEventListener("click", async () => {});
  $("modeSelectedBtn")?.addEventListener("click", async () => {});
  $("accessAllow")?.addEventListener("click", async () => {
    clearAnnouncement();
    const H = globalThis.SolstoneHosts;
    const isBroad = !state?.fence && (state?.broadGrant === true || (Array.isArray(state?.livePatterns) && H?.broadLive(state.livePatterns)));
    const everySite = !state?.fence && H?.everySiteLive?.(state?.livePatterns) === true;
    if (isBroad && everySite) {
      const result = await cmd({ cmd: "stopSharingEverySite" });
      if (result?.result) {
        stopResultCode = result.result;
        announce(Copy?.stopResultCopy(state?.brand, result.result), "ok");
      }
    } else {
      await runShareEverySite();
      return;
    }
    await refresh();
  });

  // Safari's grant is made in its own settings window, so this page re-reads the
  // browser whenever the owner comes back to it, and on request.
  async function checkAccess(explicit) {
    if (accessCheck) return;
    // A check that doesn't answer gives up, so check again always works; the
    // status channel still brings the answer whenever the browser gives it.
    accessCheck = Promise.race([cmd({ cmd: "checkEverySite" }),
      new Promise((resolve) => setTimeout(() => resolve({ timedOut: true }), 10000))]);
    renderSites();
    const result = await accessCheck;
    accessCheck = null;
    await refresh();
    if (result?.timedOut) renderSites();
    else if (result?.error) showActionError(result.error);
    else if (explicit && state?.broadGrant !== true) {
      announce(Copy.accessCopy(state?.brand).stillMissing, "bad");
    }
  }
  $("accessCheck")?.addEventListener("click", () => checkAccess(true));
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
  if ($("exactOnlyBtn")) $("exactOnlyBtn").addEventListener("click", async () => {
    $("exactOnlyBtn").hidden = true;
  });
  if ($("regrantBtn")) $("regrantBtn").addEventListener("click", async () => {
    $("regrantBtn").hidden = true;
  });

  let subscriptionEpoch = 0;
  let reconnectTimer = null;
  let statusPort = null;
  let lastStatusAt = Date.now();
  let subscribedAt = 0;
  function subscribeStatus() {
    const generation = ++subscriptionEpoch;
    appliedCaptureEpoch = -1;
    lastStatusAt = Date.now();
    subscribedAt = lastStatusAt;
    try { statusPort?.disconnect?.(); } catch (_e) {}
    statusPort = null;
    // The channel closes when the background restarts. What the page knew is
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
      paint(Status.withdrawn(latest, true), ++paintSequence);
      refresh();
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

  globalThis.SolstoneOptions = { refresh, optionsModel, model: optionsModel };
  refresh();
})();
