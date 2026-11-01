// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

(function () {
  "use strict";
  const isIOS = () => typeof navigator !== "undefined" && (/iPhone|iPad|iPod/.test(navigator.userAgent) ||
    (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1));
  const mac = globalThis.SolstoneSafariPort;
  if (!isIOS()) return;
  // Safari on iPhone and iPad has no app-to-extension dispatch, so each exchange is a
  // request the extension's native handler answers. The handler is part of the
  // solstone app and works from the store the app shares with it, whether or not
  // the app is running.
  function connect(runtime, hostName) {
    const id = crypto.randomUUID();
    const messages = [], disconnects = [];
    let open = true, chain = Promise.resolve(), queued = 0;
    let timer;
    function close() {
      if (!open) return;
      open = false;
      clearInterval(timer);
      for (const listener of disconnects) listener();
    }
    function send(frame) {
      if (!frame && queued > 0) return;
      queued++;
      chain = chain.then(async () => {
        if (!open) return;
        const reply = await runtime.sendNativeMessage(hostName, { v: 1, c: id, ...(frame ? { f: frame } : {}) });
        if (!open || reply?.c !== id || reply.v !== 1) { close(); return; }
        const parsed = mac.framesFor(reply, id);
        for (const frame of parsed?.frames || []) {
          if (!open) return;
          for (const listener of messages) listener(frame);
        }
        if (parsed?.closed) close();
      }).catch(close).finally(() => { queued--; });
    }
    // Safari may unload the nonpersistent background at any time. This timer
    // renews authority only while Safari gives this page execution time.
    timer = setInterval(() => send(), 2000);
    return {
      id,
      onMessage: { addListener(fn) { messages.push(fn); } },
      onDisconnect: { addListener(fn) { disconnects.push(fn); } },
      postMessage(value) { if (!open) throw new Error("disconnected"); send(JSON.stringify(value)); },
      disconnect() { open = false; clearInterval(timer); },
    };
  }
  globalThis.SolstoneSafariPort = { ...mac, connect, ios: true };
})();
