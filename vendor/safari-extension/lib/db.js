// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

(function () {
  "use strict";

  const DB_NAME = "solstone-browser-native";
  const DB_VERSION = 2;
  let memo = null;

  function open() {
    if (memo) return memo;
    memo = new Promise((resolve, reject) => {
      const req = indexedDB.open(DB_NAME, DB_VERSION);
      req.onupgradeneeded = () => {
        const db = req.result;
        if (!db.objectStoreNames.contains("meta")) {
          db.createObjectStore("meta");
        }
        if (!db.objectStoreNames.contains("outbox")) {
          db.createObjectStore("outbox", { keyPath: "batchId" });
        }
        if (!db.objectStoreNames.contains("producer")) {
          db.createObjectStore("producer", { keyPath: "contextKey" });
        }
      };
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => {
        memo = null;
        reject(req.error);
      };
      req.onblocked = () => {
        memo = null;
        reject(new Error("IndexedDB open blocked"));
      };
    });
    return memo;
  }

  async function tx(stores, mode, fn) {
    const db = await open();
    const storeList = Array.isArray(stores) ? stores : [stores];
    return new Promise((resolve, reject) => {
      const t = db.transaction(storeList, mode);
      let syncResult;
      t.oncomplete = () => resolve(t.__result !== undefined ? t.__result : syncResult);
      t.onerror = () => reject(t.__error || t.error || new Error("IndexedDB transaction error"));
      t.onabort = () => reject(t.__error || t.error || new Error("IndexedDB transaction aborted"));
      try {
        const osMap = {};
        for (const name of storeList) {
          osMap[name] = t.objectStore(name);
        }
        syncResult = fn(storeList.length === 1 ? osMap[storeList[0]] : osMap, t);
      } catch (e) {
        try {
          t.abort();
        } catch (_err) {
          /* ignore */
        }
        reject(e);
      }
    });
  }

  async function get(store, key) {
    const db = await open();
    return new Promise((resolve, reject) => {
      const t = db.transaction(store, "readonly");
      const req = t.objectStore(store).get(key);
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error);
    });
  }

  async function getAll(store) {
    const db = await open();
    return new Promise((resolve, reject) => {
      const t = db.transaction(store, "readonly");
      const req = t.objectStore(store).getAll();
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error);
    });
  }

  async function put(store, val, key) {
    return tx(store, "readwrite", (os) => {
      if (key === undefined) os.put(val);
      else os.put(val, key);
      return val;
    });
  }

  async function add(store, val, key) {
    return tx(store, "readwrite", (os) => {
      if (key === undefined) os.add(val);
      else os.add(val, key);
      return val;
    });
  }

  async function del(store, key) {
    return tx(store, "readwrite", (os) => {
      os.delete(key);
    });
  }

  async function clear(store) {
    return tx(store, "readwrite", (os) => {
      os.clear();
    });
  }

  function resetMemo() {
    memo = null;
  }

  globalThis.SolstoneDB = {
    DB_NAME,
    DB_VERSION,
    open,
    get,
    getAll,
    put,
    add,
    del,
    clear,
    tx,
    resetMemo,
  };
})();
