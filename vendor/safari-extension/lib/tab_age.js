// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

(function () {
  "use strict";

  const memoryMap = new Map();
  // Epoch milliseconds survive background recreation; performance.now() does not.
  // A separate key leaves old relative timestamps behind instead of inventing ages.
  const STORAGE_KEY = "tabFirstSeenEpochMs";

  async function getStoredMap() {
    if (typeof chrome !== "undefined" && chrome.storage?.session?.get) {
      try {
        const res = await chrome.storage.session.get(STORAGE_KEY);
        if (res && res[STORAGE_KEY] && typeof res[STORAGE_KEY] === "object") {
          return { ...res[STORAGE_KEY] };
        }
      } catch (_e) {}
    }
    return {};
  }

  async function setStoredMap(map) {
    if (typeof chrome !== "undefined" && chrome.storage?.session?.set) {
      try {
        await chrome.storage.session.set({ [STORAGE_KEY]: map });
      } catch (_e) {}
    }
  }

  async function start(tabs, nowMs) {
    try {
      const sessionMap = await getStoredMap();
      for (const [k, v] of Object.entries(sessionMap)) {
        if (!memoryMap.has(k) && typeof v === "number" && Number.isFinite(v)) {
          memoryMap.set(k, v);
        }
      }

      if (Array.isArray(tabs)) {
        let changed = false;
        for (const tab of tabs) {
          if (!tab || tab.incognito === true || !Number.isInteger(tab.id)) continue;
          const key = String(tab.id);
          if (!memoryMap.has(key)) {
            memoryMap.set(key, nowMs);
            sessionMap[key] = nowMs;
            changed = true;
          }
        }
        if (changed) {
          await setStoredMap(sessionMap);
        }
      }
    } catch (_e) {}
  }

  async function noteCreated(tab, nowMs) {
    if (!tab || tab.incognito === true || !Number.isInteger(tab.id)) return;
    const key = String(tab.id);
    if (memoryMap.has(key)) return;

    try {
      const sessionMap = await getStoredMap();
      if (typeof sessionMap[key] === "number" && Number.isFinite(sessionMap[key])) {
        memoryMap.set(key, sessionMap[key]);
        return;
      }
      memoryMap.set(key, nowMs);
      sessionMap[key] = nowMs;
      await setStoredMap(sessionMap);
    } catch (_e) {
      memoryMap.set(key, nowMs);
    }
  }

  async function forget(tabId) {
    if (!Number.isInteger(tabId)) return;
    const key = String(tabId);
    memoryMap.delete(key);
    try {
      const sessionMap = await getStoredMap();
      if (Object.prototype.hasOwnProperty.call(sessionMap, key)) {
        delete sessionMap[key];
        await setStoredMap(sessionMap);
      }
    } catch (_e) {}
  }

  async function ageMs(tabId, nowMs) {
    if (!Number.isInteger(tabId) || typeof nowMs !== "number" || !Number.isFinite(nowMs)) {
      return undefined;
    }
    const key = String(tabId);
    if (memoryMap.has(key)) {
      return Math.max(0, nowMs - memoryMap.get(key));
    }

    try {
      const sessionMap = await getStoredMap();
      if (typeof sessionMap[key] === "number" && Number.isFinite(sessionMap[key])) {
        const stored = sessionMap[key];
        memoryMap.set(key, stored);
        return Math.max(0, nowMs - stored);
      }
      // Real miss: seed nowMs and return 0
      memoryMap.set(key, nowMs);
      sessionMap[key] = nowMs;
      await setStoredMap(sessionMap);
      return 0;
    } catch (_e) {
      memoryMap.set(key, nowMs);
      return 0;
    }
  }

  globalThis.SolstoneTabAge = {
    start,
    noteCreated,
    forget,
    ageMs,
  };
})();
