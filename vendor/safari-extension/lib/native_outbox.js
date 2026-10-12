// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

(function () {
  "use strict";

  const DB = globalThis.SolstoneDB;
  const Seg = globalThis.SolstoneSegment;
  const Blocks = globalThis.SolstoneBlocks;
  const activeTransactions = new Set();
  function checkAuthorization() {
    for (const check of activeTransactions) check();
  }
  function guardTransaction(t, authorize) {
    if (typeof authorize !== "function") return true;
    let active = true;
    const finish = () => { active = false; activeTransactions.delete(check); };
    const check = () => {
      if (!active) return true;
      let allowed = false;
      try { allowed = authorize() === true; } catch (_e) {}
      if (allowed) return true;
      const err = new Error("authorization_failed");
      err.code = "authorization_failed";
      t.__error = err;
      try { t.abort(); } catch (_e) {}
      finish();
      return false;
    };
    activeTransactions.add(check);
    t.addEventListener("complete", finish);
    t.addEventListener("abort", finish);
    // Check after all request listeners, while the transaction is abortable.
    t.addEventListener("success", () => { Promise.resolve().then(check); }, true);
    return check();
  }

  function appendLoss(meta, notice) {
    const previous = meta.get("lossNotice");
    previous.onsuccess = () => {
      const old = previous.result;
      meta.put({ ...notice, count: notice.count + (old?.count || 0) }, "lossNotice");
    };
  }

  function getConsts() {
    const C = globalThis.SolstoneNativeBrowserConstants;
    if (!C) throw new Error("missing SolstoneNativeBrowserConstants");
    return C;
  }

  function mintBatchId() {
    const bytes = new Uint8Array(16);
    crypto.getRandomValues(bytes);
    return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
  }

  function byteLengthOf(value) {
    return new TextEncoder().encode(JSON.stringify(value)).byteLength;
  }

  function contextKeyFor(inst, ctx) {
    return `${inst}\n${ctx}`;
  }

  function cursorByteBudget(cursor) {
    return byteLengthOf({ ...cursor, generation: "g".repeat(getConsts().GENERATION_MAX) });
  }

  function producerByteBudget(items, cursors) {
    const byKey = new Map(cursors.map(cursor => [cursor.contextKey, cursor]));
    for (const row of items) {
      const key = contextKeyFor(row.inst, row.ctx);
      if (!byKey.has(key)) byKey.set(key, {
        contextKey: key, inst: row.inst, ctx: row.ctx, generation: "", snapshotRequired: false, blocks: [],
      });
    }
    let total = 0;
    for (const cursor of byKey.values()) total += cursorByteBudget(cursor);
    return total;
  }

  function buildWireBatch(storedItem, transport) {
    const records = storedItem.sendSnapshot ? storedItem.snapshotRecords : storedItem.records;
    return {
      type: "batch",
      destination_generation: transport && Object.hasOwn(transport, "destinationGeneration")
        ? transport.destinationGeneration : storedItem.destinationGeneration,
      inst: storedItem.inst,
      batch_id: storedItem.batchId,
      queued_at_ms: transport && Object.hasOwn(transport, "queuedAtMs")
        ? transport.queuedAtMs : storedItem.queuedAtMs,
      records,
    };
  }

  function validateWireBatch(wireBatch) {
    const codec = globalThis.SolstoneNativeBrowser;
    if (!codec || typeof codec.decode !== "function") {
      throw new Error("missing native-browser codec decode");
    }
    const jsonStr = JSON.stringify(wireBatch);
    const decoded = codec.decode(jsonStr, "extension_to_host");
    if (decoded.status !== "accept") {
      const err = new Error("invalid wire batch: " + (decoded.code || "refuse"));
      err.code = decoded.code;
      throw err;
    }
    return true;
  }

  async function enqueueSkim({ inst, ctx, destinationGeneration, senderUrl, site, title, adapter, blocks, nowMs, authorize, writeObservation } = {}) {
    const consts = getConsts();
    const clonedBlocks = structuredClone(blocks || []);
    const ts = Math.floor(Number(nowMs !== undefined ? nowMs : Date.now()));
    const maxGeneration = "g".repeat(consts.GENERATION_MAX);
    const maxQueuedAtMs = consts.TIMESTAMP_MAX;
    const originUrl = Blocks.originPath(senderUrl || "");

    const truncatedTitle = Blocks.sliceCodePoints ? Blocks.sliceCodePoints(title || "", consts.TITLE_STRING_MAX || 8192) : (title || "");
    const truncatedSite = Blocks.sliceCodePoints ? Blocks.sliceCodePoints(site || "", consts.SITE_STRING_MAX || 512) : (site || "");
    const truncatedAdapter = Blocks.sliceCodePoints ? Blocks.sliceCodePoints(adapter || "", consts.ADAPTER_STRING_MAX || 64) : (adapter || "");

    const snapshotRec = Seg.snapshotLine(truncatedSite, { url: originUrl, title: truncatedTitle, adapter: truncatedAdapter }, clonedBlocks, ts, 0);
    snapshotRec.ctx = ctx;
    snapshotRec.inst = inst;

    const ctxKey = contextKeyFor(inst, ctx);
    const maxStamp = { destinationGeneration: maxGeneration, queuedAtMs: maxQueuedAtMs };
    const candidateWire = (records) => ({
      type: "batch",
      destination_generation: maxGeneration,
      inst,
      batch_id: "00000000000000000000000000000000",
      queued_at_ms: maxQueuedAtMs,
      records,
    });
    const snapshotRecords = [snapshotRec];
    const snapshotWire = candidateWire(snapshotRecords);
    const snapshotBytes = byteLengthOf(snapshotWire);
    if (snapshotBytes > consts.EXTENSION_TO_HOST_MAX) {
      const err = new Error("batch-oversize");
      err.code = "batch-oversize";
      err.disposition = "batch-oversize";
      throw err;
    }
    validateWireBatch(snapshotWire);

    const result = await DB.tx(["outbox", "producer", "meta"], "readwrite", (stores, t) => {
      const outboxStore = stores.outbox;
      const producerStore = stores.producer;
      if (!guardTransaction(t, authorize)) return;

      if (typeof authorize === "function") {
        try {
          const authOk = authorize();
          if (!authOk) {
            const err = new Error("authorization_failed");
            err.code = "authorization_failed";
            t.__error = err;
            t.abort();
            return;
          }
        } catch (authErr) {
          t.__error = authErr;
          t.abort();
          return;
        }
      }

      let cursor = null;
      let allItems = null;
      let allCursors = null;
      let pending = 3;

      function checkReady() {
        if (--pending > 0) return;
        try {
          const sortedItems = (allItems || []).sort((a, b) => (a.seq || 0) - (b.seq || 0));
          let outboxBytes = 0;
          let maxSeq = 0;
          for (const item of sortedItems) {
            outboxBytes += item.bytes || byteLengthOf(item);
            if (item.seq && item.seq > maxSeq) maxSeq = item.seq;
          }
          const producerBytes = producerByteBudget(allItems || [], allCursors || []);
          const totalBytes = outboxBytes + producerBytes;

          let recordsToUse = null;
          const hasValidCursor = cursor && cursor.generation === destinationGeneration && cursor.snapshotRequired !== true && Array.isArray(cursor.blocks);

          if (hasValidCursor) {
            const diff = Seg.diffBlocks(cursor.blocks, clonedBlocks);
            if (diff.added.length === 0 && diff.updated.length === 0 && diff.removed.length === 0) {
              writeObservation?.(stores.meta);
              t.__result = { enqueued: false, disposition: "empty" };
              return;
            }
            const deltas = Seg.deltaLines(truncatedSite, diff, ts, 0);
            for (const d of deltas) {
              d.ctx = ctx;
              d.inst = inst;
            }

            const candidateWireBatch = candidateWire(deltas);

            const deltasCountOk = deltas.length <= consts.DELTA_RECORDS_MAX;
            const deltasBytesOk = byteLengthOf(candidateWireBatch) <= consts.EXTENSION_TO_HOST_MAX;

            if (deltasCountOk && deltasBytesOk) {
              recordsToUse = deltas;
            } else {
              if (snapshotBytes <= consts.EXTENSION_TO_HOST_MAX) {
                recordsToUse = snapshotRecords;
              } else {
                const err = new Error("batch-oversize");
                err.code = "batch-oversize";
                err.disposition = "batch-oversize";
                t.__error = err;
                t.abort();
                return;
              }
            }
          } else {
            if (snapshotBytes <= consts.EXTENSION_TO_HOST_MAX) {
              recordsToUse = snapshotRecords;
            } else {
              const err = new Error("batch-oversize");
              err.code = "batch-oversize";
              err.disposition = "batch-oversize";
              t.__error = err;
              t.abort();
              return;
            }
          }

          const batchId = mintBatchId();
          const nextSeq = maxSeq + 1;
          const storedItem = {
            batchId,
            seq: nextSeq,
            inst,
            ctx,
            destinationGeneration,
            queuedAtMs: ts,
            records: recordsToUse,
            snapshotRecords,
            bytes: 0,
            sendSnapshot: false,
          };

          // Pre-validate BOTH candidate wire batch AND snapshot recovery wire batch
          const wireBatch = buildWireBatch(storedItem, maxStamp);
          validateWireBatch(wireBatch);
          const recoveryBatch = buildWireBatch({ ...storedItem, sendSnapshot: true }, maxStamp);
          validateWireBatch(recoveryBatch);

          let itemBytes = byteLengthOf(storedItem);
          storedItem.bytes = itemBytes;
          while (true) {
            const nextBytes = byteLengthOf(storedItem);
            if (nextBytes === storedItem.bytes) break;
            storedItem.bytes = nextBytes;
          }

          const nextCursor = {
            contextKey: ctxKey,
            inst,
            ctx,
            blocks: clonedBlocks,
            generation: destinationGeneration,
            snapshotRequired: false,
          };

          const priorCursor = cursor || (sortedItems.some(row => contextKeyFor(row.inst, row.ctx) === ctxKey)
            ? { contextKey: ctxKey, inst, ctx, generation: "", snapshotRequired: false, blocks: [] } : null);
          const cursorDelta = cursorByteBudget(nextCursor) - (priorCursor ? cursorByteBudget(priorCursor) : 0);
          if (totalBytes + storedItem.bytes + cursorDelta > consts.OUTBOX_BYTES_MAX) {
            const err = new Error("outbox-full");
            err.code = "outbox-full";
            err.disposition = "outbox-full";
            t.__error = err;
            t.abort();
            return;
          }

          if (typeof authorize === "function") {
            const authOk = authorize();
            if (!authOk) {
              const err = new Error("authorization_failed");
              err.code = "authorization_failed";
              t.__error = err;
              t.abort();
              return;
            }
          }

          writeObservation?.(stores.meta);
          outboxStore.add(storedItem);
          producerStore.put(nextCursor);

          const newTotalBytes = totalBytes + storedItem.bytes + cursorDelta;
          const pressure = { active: newTotalBytes >= consts.OUTBOX_BYTES_MAX };

          t.__result = {
            enqueued: true,
            batchId,
            seq: nextSeq,
            bytes: storedItem.bytes,
            pressure,
          };
        } catch (err) {
          t.__error = err;
          t.abort();
        }
      }

      const cursorReq = producerStore.get(ctxKey);
      cursorReq.onsuccess = () => {
        cursor = cursorReq.result;
        checkReady();
      };
      cursorReq.onerror = () => {
        t.__error = cursorReq.error;
        t.abort();
      };

      const allOutboxReq = outboxStore.getAll();
      allOutboxReq.onsuccess = () => {
        allItems = allOutboxReq.result;
        checkReady();
      };
      allOutboxReq.onerror = () => {
        t.__error = allOutboxReq.error;
        t.abort();
      };

      const allProducersReq = producerStore.getAll();
      allProducersReq.onsuccess = () => {
        allCursors = allProducersReq.result;
        checkReady();
      };
      allProducersReq.onerror = () => {
        t.__error = allProducersReq.error;
        t.abort();
      };
    });
    return result;
  }

  async function getHead() {
    return DB.tx("outbox", "readonly", (outboxStore, t) => {
      const req = outboxStore.getAll();
      req.onsuccess = () => {
        try {
          const items = (req.result || []).sort((a, b) => (a.seq || 0) - (b.seq || 0));
          t.__result = items[0] || null;
        } catch (err) {
          t.__error = err;
          t.abort();
        }
      };
    });
  }

  async function getAll() {
    return DB.tx("outbox", "readonly", (outboxStore, t) => {
      const req = outboxStore.getAll();
      req.onsuccess = () => {
        try {
          const items = (req.result || []).sort((a, b) => (a.seq || 0) - (b.seq || 0));
          t.__result = items;
        } catch (err) {
          t.__error = err;
          t.abort();
        }
      };
    });
  }

  async function removeBatch(batchId) {
    return DB.tx("outbox", "readwrite", (outboxStore) => {
      outboxStore.delete(batchId);
      return true;
    });
  }

  async function markSnapshotRequired(inst, ctx) {
    const ctxKey = contextKeyFor(inst, ctx);
    return DB.tx("producer", "readwrite", (producerStore, t) => {
      const req = producerStore.get(ctxKey);
      req.onsuccess = () => {
        try {
          const cursor = req.result;
          if (cursor) {
            cursor.snapshotRequired = true;
            producerStore.put(cursor);
          }
        } catch (err) {
          t.__error = err;
          t.abort();
        }
      };
    });
  }

  async function markAllSnapshotRequired() {
    return DB.tx("producer", "readwrite", (producerStore, t) => {
      const req = producerStore.getAll();
      req.onsuccess = () => {
        try {
          for (const cursor of req.result || []) {
            cursor.snapshotRequired = true;
            producerStore.put(cursor);
          }
        } catch (err) {
          t.__error = err;
          t.abort();
        }
      };
    });
  }

  async function pruneCursor(inst, ctx) {
    const ctxKey = contextKeyFor(inst, ctx);
    return DB.tx("producer", "readwrite", (producerStore) => {
      producerStore.delete(ctxKey);
      return true;
    });
  }

  async function applyRejectedReceipt(batchId, receipt) {
    if (["stale_generation", "expired_unaccepted"].includes(receipt.reason)) {
      return { removed: 0, promotedBatchId: null };
    }
    return DB.tx(["outbox", "producer", "meta"], "readwrite", (stores, t) => {
      const outboxStore = stores.outbox;
      const producerStore = stores.producer;
      const metaStore = stores.meta;

      const itemReq = outboxStore.get(batchId);
      itemReq.onsuccess = () => {
        try {
          const item = itemReq.result;
          if (!item) {
            t.__result = { removed: 0, promotedBatchId: null };
            return;
          }

          const ctxKey = contextKeyFor(item.inst, item.ctx);
          const cursorReq = producerStore.get(ctxKey);

          cursorReq.onsuccess = () => {
            try {
              const cursor = cursorReq.result;
              if (cursor) {
                cursor.snapshotRequired = true;
                producerStore.put(cursor);
              }

              if (receipt.reason === "snapshot_required") {
                item.sendSnapshot = true;
                outboxStore.put(item);
                t.__result = { removed: 0, promotedBatchId: null };
                return;
              }

              const consts = getConsts();
              const permanentReasons = consts.RECEIPT_CLASSES?.permanent || [];
              if (permanentReasons.includes(receipt.reason)) {
                outboxStore.delete(batchId);

                const lossSeqReq = metaStore.get("lossSeq");
                lossSeqReq.onsuccess = () => {
                  try {
                    const currentSeq = Number(lossSeqReq.result || 0);
                    const nextLossSeq = currentSeq + 1;
                    metaStore.put(nextLossSeq, "lossSeq");
                    appendLoss(metaStore, { seq: nextLossSeq, reason: receipt.reason, count: 1 });

                    const allReq = outboxStore.getAll();
                    allReq.onsuccess = () => {
                      try {
                        const remaining = (allReq.result || [])
                          .filter((x) => x.inst === item.inst && x.ctx === item.ctx && (x.seq || 0) > (item.seq || 0))
                          .sort((a, b) => (a.seq || 0) - (b.seq || 0));

                        let promotedBatchId = null;
                        if (remaining.length > 0) {
                          const descendant = remaining[0];
                          promotedBatchId = descendant.batchId;
                          descendant.sendSnapshot = true;
                          outboxStore.put(descendant);
                        }
                        t.__result = { removed: 1, promotedBatchId, seq: nextLossSeq };
                      } catch (err) {
                        t.__error = err;
                        t.abort();
                      }
                    };
                  } catch (err) {
                    t.__error = err;
                    t.abort();
                  }
                };
              } else {
                t.__result = { removed: 0, promotedBatchId: null };
              }
            } catch (err) {
              t.__error = err;
              t.abort();
            }
          };
        } catch (err) {
          t.__error = err;
          t.abort();
        }
      };
    });
  }

  async function promoteHeldForGeneration(newGeneration, authorize) {
    return DB.tx(["outbox", "producer", "meta"], "readwrite", (stores, t) => {
      if (!guardTransaction(t, authorize)) return;
      const outboxStore = stores.outbox;
      const producerStore = stores.producer;
      const allRowsReq = outboxStore.getAll();
      const allCursorsReq = producerStore.getAll();
      let allRows = null;
      let allCursors = null;
      let pending = 2;

      function promoteWhenReady() {
        if (--pending > 0) return;
        try {
          const cursorByKey = new Map((allCursors || []).map(cursor => [cursor.contextKey, cursor]));
          const rowsByKey = new Map();
          for (const row of allRows || []) {
            const key = contextKeyFor(row.inst, row.ctx);
            if (!rowsByKey.has(key)) rowsByKey.set(key, []);
            rowsByKey.get(key).push(row);
          }
          for (const rows of rowsByKey.values()) rows.sort((a, b) => (a.seq || 0) - (b.seq || 0));

          const affected = new Set();
          for (const cursor of allCursors || []) {
            if (cursor.generation !== newGeneration) affected.add(cursor.contextKey);
          }
          for (const [key, rows] of rowsByKey) {
            const head = rows[0];
            const needsBaseline = head && !head.sendSnapshot && head.records?.some(record => record.t === "delta");
            if (!cursorByKey.has(key) && (needsBaseline || rows.some(row => row.destinationGeneration !== newGeneration))) affected.add(key);
          }

          for (const key of affected) {
            const cursor = cursorByKey.get(key);
            if (cursor) {
              cursor.snapshotRequired = true;
              cursor.generation = newGeneration;
              producerStore.put(cursor);
            } else {
              const row = rowsByKey.get(key)?.[0];
              if (!row) continue;
              producerStore.put({
                contextKey: key,
                inst: row.inst,
                ctx: row.ctx,
                generation: newGeneration,
                snapshotRequired: true,
                blocks: [],
              });
            }

            const oldest = rowsByKey.get(key)?.[0];
            if (oldest && oldest.sendSnapshot !== true &&
                Array.isArray(oldest.records) && oldest.records.some(record => record.t === "delta")) {
              oldest.sendSnapshot = true;
              outboxStore.put(oldest);
            }
          }
          t.__result = { count: 0 };
        } catch (err) {
          t.__error = err;
          t.abort();
        }
      }

      allRowsReq.onsuccess = () => { allRows = allRowsReq.result || []; promoteWhenReady(); };
      allRowsReq.onerror = () => { t.__error = allRowsReq.error; t.abort(); };
      allCursorsReq.onsuccess = () => { allCursors = allCursorsReq.result || []; promoteWhenReady(); };
      allCursorsReq.onerror = () => { t.__error = allCursorsReq.error; t.abort(); };
    });
  }

  async function dismissLoss(seq) {
    return DB.tx("meta", "readwrite", (metaStore, t) => {
      const noticeReq = metaStore.get("lossNotice");
      noticeReq.onsuccess = () => {
        try {
          const notice = noticeReq.result;
          if (notice && notice.seq === seq) {
            metaStore.delete("lossNotice");
            t.__result = true;
          } else {
            t.__result = false;
          }
        } catch (err) {
          t.__error = err;
          t.abort();
        }
      };
    });
  }

  async function getCapacityStatus() {
    const consts = getConsts();
    return DB.tx(["outbox", "producer"], "readonly", (stores, t) => {
      const outboxStore = stores.outbox;
      const producerStore = stores.producer;

      const allOutboxReq = outboxStore.getAll();
      const allProducersReq = producerStore.getAll();

      let allItems = null;
      let allCursors = null;
      let pending = 2;

      function checkDone() {
        if (--pending > 0) return;
        try {
          let outboxBytes = 0;
          for (const item of (allItems || [])) {
            outboxBytes += item.bytes || byteLengthOf(item);
          }
          const producerBytes = producerByteBudget(allItems || [], allCursors || []);
          const totalBytes = outboxBytes + producerBytes;
          t.__result = {
            totalBytes,
            pressure: { active: totalBytes >= consts.OUTBOX_BYTES_MAX },
          };
        } catch (err) {
          t.__error = err;
          t.abort();
        }
      }

      allOutboxReq.onsuccess = () => {
        allItems = allOutboxReq.result;
        checkDone();
      };
      allOutboxReq.onerror = () => {
        t.__error = allOutboxReq.error;
        t.abort();
      };

      allProducersReq.onsuccess = () => {
        allCursors = allProducersReq.result;
        checkDone();
      };
      allProducersReq.onerror = () => {
        t.__error = allProducersReq.error;
        t.abort();
      };
    });
  }

  globalThis.SolstoneNativeOutbox = {
    checkAuthorization,
    enqueueSkim,
    getHead,
    getAll,
    removeBatch,
    markSnapshotRequired,
    markAllSnapshotRequired,
    pruneCursor,
    applyRejectedReceipt,
    promoteHeldForGeneration,
    dismissLoss,
    getCapacityStatus,
    buildWireBatch,
    validateWireBatch,
    byteLengthOf,
  };
})();
