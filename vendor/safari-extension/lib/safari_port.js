// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc
//
// safari_port.js — gives Safari the one native port the controller expects.
// Safari routes connectNative to the app's extension handler one message at a
// time, and the app answers through dispatched messages that reach every open
// port. Each connection carries its own id: outgoing frames travel as
// { c, f } and only frames addressed to this connection are delivered.

(function () {
  "use strict";

  function isSafari(runtime) {
    try {
      return String(runtime.getURL("")).startsWith("safari-web-extension://");
    } catch (_e) {
      return false;
    }
  }

  function mintConnectionId() {
    const bytes = new Uint8Array(16);
    crypto.getRandomValues(bytes);
    return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
  }

  // Safari wraps dispatched messages as { name, userInfo }; the handler's own
  // replies arrive bare. Both carry { c, f, closed }.
  function framesFor(message, id) {
    if (!message || typeof message !== "object") return null;
    const body = message.userInfo && typeof message.userInfo === "object" ? message.userInfo : message;
    if (body.c !== id) return null;
    const frames = Array.isArray(body.f) ? body.f : typeof body.f === "string" ? [body.f] : [];
    return { frames: frames.filter((frame) => typeof frame === "string"), closed: body.closed === true };
  }

  function connect(runtime, hostName, mintId = mintConnectionId) {
    const native = runtime.connectNative(hostName);
    const id = mintId();
    const messageListeners = [];
    const disconnectListeners = [];
    let open = true;

    function close() {
      if (!open) return;
      open = false;
      for (const listener of disconnectListeners) {
        try { listener(); } catch (_e) { /* listener faults stay local */ }
      }
    }

    native.onMessage.addListener((message) => {
      if (!open) return;
      const parsed = framesFor(message, id);
      if (!parsed) return;
      for (const frame of parsed.frames) {
        if (!open) return;
        for (const listener of messageListeners) listener(frame);
      }
      if (parsed.closed) close();
    });
    native.onDisconnect.addListener(() => close());

    return {
      id,
      onMessage: { addListener(listener) { messageListeners.push(listener); } },
      onDisconnect: { addListener(listener) { disconnectListeners.push(listener); } },
      postMessage(message) {
        if (!open) throw new Error("disconnected");
        native.postMessage({ c: id, f: JSON.stringify(message) });
      },
      // Like Chrome, a local disconnect does not notify this port's own listeners.
      disconnect() {
        if (!open) return;
        open = false;
        try { native.postMessage({ c: id, close: true }); } catch (_e) { /* already gone */ }
        try { native.disconnect(); } catch (_e) { /* already gone */ }
      },
    };
  }

  globalThis.SolstoneSafariPort = { isSafari, connect, framesFor };
})();
