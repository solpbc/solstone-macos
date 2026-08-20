# M2 SPL Tunnel Owner Design

Status: design only. No implementation in this document.

> **Historical — superseded in part.** This records the original M2 design, from when
> SPL lived in a vendored `Sources/SPLTunnel/` target in this repo. That target and its
> `SPLTunnelTests` suite no longer exist: SPL now comes from the shared `spl-swift`
> package, which owns those tests. Two things below no longer describe the system —
> the goal "keep exactly one reconnect loop: `TunnelSession.monitorAndReconnect`" (the
> package splits this into a single-shot `TunnelSession` plus a `TunnelSupervisor` that
> owns the reconnect loop), and the `SPLTunnelTests` test plan. The app-layer
> lifecycle-owner design is otherwise still accurate. Kept as a point-in-time record —
> do not update it to track the package.

## Goals

- Link the existing `SPLTunnel` module into the `solstone` app target.
- Add an app-level lifecycle owner for SPL tunnel availability.
- Keep exactly one reconnect loop: `TunnelSession.monitorAndReconnect`.
- Expose a loopback port for future app upload routing, without changing upload code in M2.
- Add token refresh policy at the app owner layer, with SPLTunnel plumbing for refreshable auth failures.

## Non-Goals

- No upload path changes (`UploadClient`, `UploadCoordinator`, sync services).
- No pairing UI, keychain access groups, App Group, or app-owned keychain write flow.
- No `waitingForHome` or `home_offline` state.
- No live relay/home tests.
- No iOS/UIKit/background task/scene phase concepts.
- No second reconnect/backoff/retry loop outside `TunnelSession`.

## Target Architecture

`TunnelSession` remains the only component that reconnects transport after a connected session drops. The new app-level owner observes state, decides when to ask the session to reconnect now, handles token refresh and dormancy policy, and owns app lifecycle wiring.

The owner stack:

- `AppState` holds the owner for app lifetime.
- `AppDelegate` starts and stops it through `AppState.shared`.
- `TunnelLifecycleOwner` is the app policy object.
- `SPLTunnelTransport` is the macOS transport wrapper that owns `TunnelSession` and `LoopbackProxy`.
- `TunnelSession` owns mux, transport, and its internal reconnect loop.
- `Multiplexer` owns the inbound activity counter.

## Package Change

Update `Package.swift` so executable target `solstone` depends on `.target(name: "SPLTunnel")`.

Current state:

- `solstone` target depends on `SolstoneCore`, `ObjCHelpers`, and Sparkle.
- `sol-mac` already depends on `SPLTunnel`.
- All Swift targets use `.swiftLanguageMode(.v6)`.

This should be a direct dependency addition only. No target split or compatibility shim.

## Ownership Site

Hold the owner in `AppState`.

Reasoning:

- `AppState` is the existing `@MainActor @Observable` lifetime container for app managers.
- `AppDelegate` already uses `AppState.shared` to kick services on launch and tear them down on terminate.
- The owner state may be consumed later by settings/status UI, so it belongs with other observable app state.
- Scene phase is not used by this app for long-lived services and should not be introduced.

Add an `AppState` property, for example:

- `internal let tunnelLifecycleOwner: TunnelLifecycleOwner`

Construct it in both `AppState` initializers:

- Real initializer creates live dependencies.
- Snapshot/test initializer creates inert fakes or a dormant owner, with no keychain/network side effects.

Boot wiring:

- In `AppDelegate.applicationDidFinishLaunching`, inside the existing `if let state = AppState.shared` block, start the owner after current launch service setup. The safe placement is after IPC setup and bundled journal detection scheduling, near the current `Task { await state.startBundledJournalDetectionIfNeeded() }`.
- Use an `AppState` method such as `startTunnelLifecycleOwner()` so `AppDelegate` does not know owner internals.

Teardown wiring:

- In `AppDelegate.applicationWillTerminate`, inside the existing `if let state = AppState.shared` block, call an `AppState` method such as `stopTunnelLifecycleOwner()`.
- It should stop path monitoring, liveness probing, loopback proxy, and the active session.
- This follows the existing `heartbeatService.stop()` pattern.

## Owner Type

Name: `TunnelLifecycleOwner`.

Justification:

- It describes the app role precisely: lifecycle ownership and policy.
- It avoids importing the iOS `TunnelManager` mental model, where reconnect/backoff machinery lives in the manager.
- It makes the non-negotiable boundary easier to review.

Location:

- `Sources/solstone/TunnelLifecycleOwner.swift`

Attributes:

- `@MainActor`
- `@Observable`

Observable state:

- `disconnected`
- `connecting`
- `connected(localPort: Int, via: TunnelConnectionRoute)`
- `error(TunnelLifecycleError)`

Supporting types:

- `TunnelConnectionRoute`: `.lan`, `.relay`
- `TunnelHealth`: `.unknown`, `.healthy`, `.degraded`
- `localPort: Int?` computed accessor, non-nil only when connected

State transition policy:

- Start dormant: `disconnected`.
- After a readable, usable pairing: `connecting`.
- After transport and loopback are ready: `connected(localPort:via:)`.
- Terminal policy failures: `error`, for example revoked pairing or exhausted loopback bind retry.
- Retryable session failures emitted by `TunnelSession` do not start owner retry loops. The owner may reflect `connecting` while the session loop continues.
- Liveness degradation updates `TunnelHealth`; sustained probe failure asks the session to reconnect via `requestReconnect()`.

No `waitingForHome` state in M2.

## Reconnect-Now Contract

Add an idempotent `requestReconnect()` API to `TunnelSession`.

Required behavior:

- Never starts a reconnect loop.
- Never throws.
- Is no-op safe when `reconnectTask == nil`.
- Feeds the existing `monitorAndReconnect` loop.
- Wakes both wait points:
  - connected wait: currently `await pump?.value`
  - backoff wait: currently `Task.sleep(for: delay)`
- Coalesces simultaneous triggers.
- Preserves `relayOnlyNextReconnect`.

### Session State Additions

Add one reconnect wake signal owned by `TunnelSession`, for example an `AsyncStream<Void>` plus continuation.

Add a coalescing flag:

- `reconnectRequestPending`

`requestReconnect()` does this on the actor:

- If `reconnectTask == nil`, return.
- If `reconnectRequestPending` is already true, return.
- Set `reconnectRequestPending = true`.
- Yield one event on the reconnect signal.

The signal is consumed only by `monitorAndReconnect`.

### Connected Wait Restructure

Replace the single pump wait with a helper that waits for either:

- the captured `inboundPumpTask` to complete, or
- a reconnect signal to arrive.

The helper should race waiters, not start another reconnect path. If the reconnect signal wins, `monitorAndReconnect` continues to the existing teardown and reconnect sequence. If the pump completes first, internal transport death continues exactly as today.

Cancellation semantics:

- The helper should cancel the losing waiter when one side wins.
- Cancelling the waiter for `pump.value` must not cancel the pump itself.
- If `reconnectTask` is cancelled, the helper exits so the outer `while !Task.isCancelled` can stop.

Important existing behavior preserved:

- `tearDownCurrent(reason: .transportFailure)` already cancels `inboundPumpTask`, closes `innerTLS`, tears down mux streams, and clears connection mode. Internal transport death still flows through this path.

### Backoff Wait Restructure

Replace the single `Task.sleep(for: delay)` after a failed reconnect attempt with a wait for either:

- backoff sleep completion, or
- reconnect signal arrival.

If sleep completes normally:

- increment `attempt` as today.

If reconnect signal arrives:

- reset `attempt = 1`;
- retry immediately through the same loop.

This makes "reconnect now" cut short backoff without creating a second backoff schedule.

### Coalescing Lifecycle

The coalescing flag is set by `requestReconnect()` and cleared when the next reconnect cycle begins.

Definition of reconnect cycle begins:

- Immediately before the loop computes candidates and calls `connectOnce`.

Result:

- Probe failure, path change, and transport close arriving in one tick produce at most one pending signal and one in-flight reconnect cycle.
- If another request arrives after a reconnect cycle has already begun, it may become a later pending request, but it still cannot create a parallel reconnect task.

### Relay-Only Hint Preservation

Do not clear or overwrite `relayOnlyNextReconnect` in `requestReconnect()`.

`handleDirectKeepaliveLost()` sets:

- `relayOnlyNextReconnect = true`
- clears trusted direct endpoint
- publishes `.failed(.directKeepaliveMissed)`
- calls `tearDownCurrent(reason: .transportFailure)`

The next `reconnectCandidates(from:)` call must continue to consume the relay-only hint exactly once. A coincident owner `requestReconnect()` must not discard that hint.

### sol-mac DialTest Impact

`sol-mac dial-test` never calls `requestReconnect()`. It constructs a `TunnelSession`, calls `connect(endpoints:)`, opens one stream, requests `/app/network/api/status`, prints the response, and disconnects.

Therefore:

- Reconnect-now is unused by DialTest.
- The initial `connect(endpoints:)` behavior remains the same.
- The existing self-heal loop still starts after a successful connect, but DialTest disconnects at the end as before.

## Auth Failure and Token Refresh

Add SPLTunnel plumbing:

- `SessionError.tokenExpired`
- `DialError.relayTokenExpired`

Port WebSocket close-code detection from the iOS reference:

- `RelayWSTransport` records close code from `URLSessionWebSocketDelegate.urlSession(_:webSocketTask:didCloseWith:reason:)`.
- `RelayWSTransport` also checks `URLSessionWebSocketTask.closeCode`.
- Close code `4401` maps to `DialError.relayTokenExpired`.
- `send(_:)` and `receive()` check the recorded close code when a WebSocket operation throws and raise `relayTokenExpired` instead of generic send/receive failure.
- Opening can also complete with `relayTokenExpired` if the close callback arrives before open completes.

Thread through SPLTunnel:

- `RaceCoordinator.sessionError(from:)` maps `DialError.relayTokenExpired` to `SessionError.tokenExpired`.
- `TunnelSession.connectOnce` catches and publishes/throws `SessionError.tokenExpired`.
- Per the recommendation below, also map `DialError.relayUnauthorized` to `SessionError.tokenExpired`, so the owner refreshes first for handshake auth failures.

### Recommendation: Handshake 401 vs 4401

Recommendation: option (a), map both handshake auth failure and 4401 close to `SessionError.tokenExpired`.

Details:

- Current macOS maps HTTP 401/403 handshake failure to `DialError.relayUnauthorized`.
- iOS maps HTTP 401 to revoked and 4401 to token expired.
- M2 section 6 says the refresher is the single arbiter of terminal versus refreshable auth failure.
- Therefore the owner should see relay auth failure as refresh-needed first, not terminal revoked.

Practical mapping:

- `DialError.relayTokenExpired` -> `SessionError.tokenExpired`
- `DialError.relayUnauthorized` -> `SessionError.tokenExpired`
- `DeviceTokenRefresher.definitiveAuthFailure` is the only owner path that retires pairing as revoked.

This means HTTP 403 also goes through refresh-first because current `DialClient` groups 401 and 403 as `relayUnauthorized`. That is acceptable for section 6 because `DeviceTokenRefresher` maps 403 to `.definitiveAuthFailure`, so terminal handling still happens, just after the refresh arbiter speaks.

### sol-mac DialTest Impact of Recommendation

`SPLCommand.DialTest` does not observe `stateUpdates`. It calls `try await tunnel.connect(...)` directly. On failure it:

- disconnects;
- writes structured stderr with code `dial_failed`;
- uses `error.localizedDescription`;
- exits with the same local validation exit.

If handshake auth failure maps to `.tokenExpired` instead of `.revoked`, DialTest behavior remains the same at the command/control level:

- same catch block;
- same stderr code;
- same exit code;
- no refresh attempt;
- no pairing deletion.

Only the diagnostic identity of the thrown `SessionError` changes. Because DialTest uses `localizedDescription`, this is at most a diagnostic label/message change, not a flow change. The unused helper `waitForConnected(_:)` would throw `.tokenExpired` instead of `.revoked` if it were used in the future.

## Owner Token Refresh Flow

The owner, not `TunnelSession`, owns pairing refresh and persistence.

Dependencies:

- `loadPairing`: default `SPLKeychain.load`
- `savePairing`: default `SPLKeychain.save`
- `deletePairing`: default `SPLKeychain.delete`
- `DeviceTokenRefresher`

### Proactive Refresh

At connect:

1. Load pairing.
2. Apply dormancy gate.
3. If relay enrollment is `.enrolled`, call `DeviceTokenRefresher.refreshIfNeeded(pairing:now:)`.
4. Handle result:
   - `.refreshed(updated)`: persist updated pairing and connect with it.
   - `.notNeeded(current)`: connect with current.
   - `.transientFailure(current)`: connect with current; if token is actually stale and relay rejects, reactive flow handles it.
   - `.definitiveAuthFailure`: terminal revoked; retire pairing.

### Reactive Refresh

The owner observes `session.stateUpdates`.

On `.failed(.tokenExpired)`:

1. Coalesce auth-refresh work so only one refresh task is active.
2. Stop the current transport/session. This cancels the old `TunnelSession` loop.
3. Load the latest pairing.
4. Call `DeviceTokenRefresher.refreshNow(pairing:)`.
5. Route result:
   - `.refreshed(updated)`: save updated pairing, construct a fresh `TunnelSession(pairing: updated)` through the transport wrapper, and connect.
   - `.transientFailure(current)`: treat as unreachable; keep pairing; let normal session reconnect cadence handle retry where possible.
   - `.notNeeded(current)`: terminal revoked because the token-expired signal could not be resolved by refresh.
   - `.definitiveAuthFailure`: terminal revoked; retire pairing.

Why a fresh session is needed after refresh:

- `TunnelSession.init(pairing:)` captures the pairing.
- Relay candidates embed the device token.
- A re-dial with a new token needs a new pairing and likely a fresh session/transport.
- The owner must disconnect the old session before constructing the new one, so there is still only one active session reconnect loop.

Pairing retirement:

- Only `.definitiveAuthFailure` and reactive `.notNeeded` retire pairing.
- Refreshable token expiry never deletes pairing.

## Transport Wrapper

Name: `SPLTunnelTransport`.

Location:

- `Sources/solstone/SPLTunnelTransport.swift`

Role:

- Owns `TunnelSessioning` and `LoopbackProxy`.
- Starts session connect with candidates.
- Starts loopback after session mux is ready.
- Surfaces bound local port and connection route.
- Forwards `requestReconnect()` to the active session.
- Exposes `inboundActivitySnapshot()`.

It must not implement reconnect/backoff.

Connection route:

- `ConnectionMode.plDirect` -> `.lan`
- `ConnectionMode.plViaSpl` or nil -> `.relay`

Loopback startup:

- `LoopbackProxy.start()` binds `127.0.0.1:any`.
- The returned port becomes owner `localPort`.

## Protocol Seams

### `TunnelSessioning`

Location: `Sources/SPLTunnel/Tunnel/TunnelSession.swift`

Reason:

- `LoopbackProxy` should accept a protocol so tests and app wrappers can inject sessions.
- This is a core SPLTunnel seam, not app policy.

Methods/properties:

- `nonisolated var stateUpdates: AsyncStream<TunnelState> { get }`
- `nonisolated var connectionModeUpdates: AsyncStream<ConnectionMode?> { get }`
- `var connectionMode: ConnectionMode? { get async }`
- `connect(endpoints:) async throws -> ConnectedVia`
- `disconnect() async`
- `openStream() async throws -> MuxStream`
- `requestReconnect() async`
- `inboundActivitySnapshot() async -> UInt64`

Conformer:

- `TunnelSession`

Consumer updates:

- `LoopbackProxy` stores `any TunnelSessioning` instead of concrete `TunnelSession`.
- `sol-mac DialTest` can keep using concrete `TunnelSession`.

### `TunnelTransporting`

Location: `Sources/solstone/TunnelLifecycleOwner.swift` or a small adjacent file in `Sources/solstone/`.

Reason:

- This is app owner policy and test seam, not tunnel protocol.

Methods/properties:

- `var connectionMode: ConnectionMode? { get async }`
- `connect(pairing:candidates:) async throws -> TunnelTransportConnection`
- `disconnect() async`
- `requestReconnect() async`
- `inboundActivitySnapshot() async -> UInt64`
- state/mode observation hooks, either as streams or callback registration, so the owner can republish on the main actor

Conformer:

- `SPLTunnelTransport`

Test fake:

- `FakeTunnelTransport`

### `PathMonitoringSource`

Location: `Sources/solstone/PathMonitor.swift`

Methods:

- `start(onPathChange:)`
- `stop()`

Conformer:

- `NWPathMonitoringSource`

Test fake:

- `FakePathMonitoringSource`

### Probe and Clock Seams

Keep these as injected closures or tiny protocols on `TunnelLifecycleOwner`:

- `probe(localPort:) async -> ProbeResult`
- `sleep(for:) async`
- `now() -> Date` or `ContinuousClock.Instant`

Tests use fakes; no live network.

## Inbound Activity Counter

Add to `Multiplexer`:

- `private var inboundActivityCounter: UInt64 = 0`
- `public func inboundActivitySnapshot() -> UInt64`

Increment placement:

- At the top of `dispatch(_:)`, immediately after the method begins and before flag decoding.
- Counts each successfully decoded inbound frame from `FrameDecoder.next()`.
- Includes control frames and stream frames.

Expose through `TunnelSession`:

- `inboundActivitySnapshot() async -> UInt64`
- returns `0` when no multiplexer is installed.

This matches the iOS reference placement and gives the owner a false-negative suppression signal for liveness probes.

## Path Monitor Policy

Location:

- `Sources/solstone/PathMonitor.swift`

Model:

- `NetworkPathStatus`: satisfied, interface bucket, expensive, constrained.
- `PathInterfaceBucket`: `.wifi`, `.wired`, `.cellular`, `.other`.
- Meaningful signature: `(bucket, isSatisfied)`.

Behavior:

- Wrap `NWPathMonitor`.
- Debounce path changes by 200 ms.
- Ignore duplicate meaningful signatures.
- While connected, if the interface bucket changes and the new path is satisfied, call `requestReconnect()`.
- If path becomes unsatisfied, do not start owner retry. The session loop continues to own reconnect cadence.
- While dormant/disconnected, update path status only; do not connect solely because path changed.

Reasoning:

- Interface changes can leave an otherwise live transport pinned to a stale route.
- A single `requestReconnect()` asks the existing session loop to redial immediately.
- 200 ms debounce avoids churn during transient NWPath updates.

## Liveness Probe Policy

Probe URL:

- `http://127.0.0.1:<port>/app/network/api/status`

Evidence:

- `sol-mac dial-test` requests this path.
- `MockHome` serves it.
- Convey network blueprint mounts `/app/network/api/status`.

Concrete policy:

- Interval: 30 seconds.
- Per-probe HTTP timeout: 3 seconds.
- Degraded after 2 consecutive failed probes.
- Reconnect request after 3 consecutive failed probes.
- Add small jitter, for example 0.8x to 1.2x, to avoid fixed wake cadence.

Suppression:

- Before a probe, read `inboundActivitySnapshot()`.
- If the probe fails, read it again.
- If the counter increased, reset consecutive probe failures and do not mark degraded.

Reasoning:

- A menu-bar background app should not churn on one missed local HTTP request.
- Three failed 30-second probes means roughly 90 seconds of no successful status probe and no compensating inbound traffic.
- Inbound activity proves the mux is alive even if the HTTP status request failed.

On sustained failure:

- Call `transport.requestReconnect()`.
- Do not disconnect directly from the owner.
- Do not start an owner retry loop.

## Activation and Dormancy Gate

The owner is dormant when there is no usable pairing.

Startup gate:

1. `SPLKeychain.load()`
2. If it returns nil: `disconnected`, no error, no retry.
3. If it throws `SPLKeychainError`: `disconnected`, no error, no retry.
4. If pairing has no usable candidates: `disconnected`, no error, no retry.

Usable candidates:

- Relay is usable only when `RelayEnrollment.enrolled` has a nonblank device token and a valid relay endpoint URL.
- LAN is usable when at least one local endpoint has nonblank host and port in `1...65535`.
- `RelayEnrollment.unavailable` with no usable LAN is dormant.
- `RelayEnrollment.unavailable` with usable LAN may connect LAN-only.

The owner can reuse `TransportEndpoint.candidates(for:)` and apply a small local validation filter for the LAN usability gate. It should not duplicate dial behavior beyond deciding dormancy.

Dormant is not an error. This keeps first launch and unpaired installs quiet.

## Loopback Bind Failure Retry

`LoopbackProxy.start()` can throw `LoopbackProxyError.listenerFailed` or `listenerMissingPort`.

This is the one bounded retry owned by the app layer because it is local listener startup, not tunnel transport reconnect.

Policy:

- Retry loopback bind up to 3 total attempts.
- Backoff delays: 100 ms, then 300 ms before final attempt.
- Recreate or restart the proxy cleanly between attempts.
- If exhausted:
  - disconnect the session;
  - set owner state to `error(.loopbackUnavailable)`;
  - stop probe/path tasks for that connection;
  - do not keep retrying forever.

Reasoning:

- Binding `127.0.0.1:any` should nearly always succeed.
- A short bounded retry handles transient Network framework/listener races.
- Exhaustion is a real local failure and should not wedge the app.

## Offline Home / 503 Handling

No `waitingForHome` state in M2.

If a fake transport/session emits an offline or 503-equivalent retryable failure, map it to retryable unreachable/transport failure at the session layer. The owner should not create a retry task or countdown. It observes the failure, keeps nonterminal state, and lets `TunnelSession.monitorAndReconnect` continue with its normal backoff.

This avoids an error storm and preserves the single reconnect cadence.

## AppState and AppDelegate Integration

`AppState` changes:

- Add owner property.
- Add `startTunnelLifecycleOwner()` and `stopTunnelLifecycleOwner()` methods.
- Real init wires live dependencies.
- Snapshot/test init wires inert fakes.
- Deinit cancels owner observation tasks if possible through sync cancellation APIs; async shutdown remains in explicit stop.

`AppDelegate.applicationDidFinishLaunching`:

- In the existing `if let state = AppState.shared` block, after launch service setup, call `state.startTunnelLifecycleOwner()` or schedule a main-actor task for it.

`AppDelegate.applicationWillTerminate`:

- In the existing `if let state = AppState.shared` block, call `state.stopTunnelLifecycleOwner()` near the existing heartbeat shutdown call.

No scene phase hooks.

## Implementation Sequence

1. Add SPLTunnel protocol seams:
   - `TunnelSessioning`
   - `requestReconnect()`
   - `inboundActivitySnapshot()`
   - `LoopbackProxy` accepts `any TunnelSessioning`

2. Add reconnect-now internals in `TunnelSession`:
   - reconnect signal
   - coalescing flag
   - connected wait race
   - backoff wait race
   - attempt reset on requested reconnect
   - preserve relay-only hint

3. Add auth plumbing:
   - `SessionError.tokenExpired`
   - `DialError.relayTokenExpired`
   - WebSocket 4401 close-code recording
   - RaceCoordinator/TunnelSession mapping
   - recommended mapping of `relayUnauthorized` to `tokenExpired`

4. Add inbound activity counter:
   - `Multiplexer`
   - `TunnelSession` pass-through

5. Link `SPLTunnel` into `solstone` target.

6. Add solstone seams and concrete wrappers:
   - `TunnelTransporting`
   - `SPLTunnelTransport`
   - `PathMonitor`
   - probe dependencies

7. Add `TunnelLifecycleOwner`:
   - state machine
   - dormancy gate
   - proactive refresh
   - reactive refresh/session swap
   - path monitor handling
   - liveness probe
   - loopback retry policy

8. Wire `AppState` and `AppDelegate`.

9. Add tests.

## Test Plan

### SPLTunnelTests

`Multiplexer`:

- Counter starts at zero.
- Counter increments once per decoded inbound frame.
- Counter increments for control frames and stream frames.
- Snapshot remains actor-safe under feed/open interactions.

`RelayWSTransport` / `DialClient`:

- WebSocket close code 4401 during receive maps to `DialError.relayTokenExpired`.
- WebSocket close code 4401 during send maps to `DialError.relayTokenExpired`.
- Close code recorded by delegate is honored even if `task.closeCode` is not updated yet.
- Existing HTTP 401/403/404/500 tests are updated for the chosen mapping.

`RaceCoordinator`:

- `DialError.relayTokenExpired` maps to `SessionError.tokenExpired`.
- `DialError.relayUnauthorized` maps to `SessionError.tokenExpired` if option (a) is accepted.
- Revocation aggregation behavior remains intentional for any still-terminal auth case.

`TunnelSession.requestReconnect()`:

- No-op when disconnected or before reconnect loop starts.
- Connected wait wakes on request and reconnects through existing loop.
- Backoff wait wakes on request and resets attempt to 1.
- Multiple simultaneous requests produce one reconnect cycle.
- Internal pump completion still reconnects without explicit request.
- Keepalive miss still sets relay-only fallback and the next reconnect uses relay-only candidates when available.
- `sol-mac DialTest` path can still connect/open/read/disconnect without using requestReconnect.

Fakes:

- `FakeByteTransport` or existing echo servers.
- `FakeTunnelSession` only if protocol seam requires targeted requestReconnect tests; otherwise use in-tree TLS echo servers.
- Actor-backed state recorder and `waitUntil`, matching existing Swift Testing idiom.

### solstoneTests

`TunnelLifecycleOwner` with fake transport:

- Dormant when keychain load returns nil.
- Dormant when keychain load throws.
- Dormant when relay unavailable and no usable LAN.
- LAN-only connect allowed when relay unavailable and usable LAN exists.
- State transitions: disconnected -> connecting -> connected(localPort, via).
- Connection mode `.plDirect` maps to `.lan`; `.plViaSpl` maps to `.relay`.
- Retryable session failure does not start an owner retry loop.
- Offline/503 fake signal flows through as retryable and no `waitingForHome` state appears.

Token refresh:

- Proactive `.refreshed` saves updated pairing and connects with updated token.
- Proactive `.notNeeded` connects with current pairing.
- Proactive `.transientFailure` keeps current pairing and does not delete.
- Proactive `.definitiveAuthFailure` retires pairing and enters terminal revoked error.
- Reactive `.failed(.tokenExpired)` plus `.refreshed` disconnects old session, saves pairing, creates fresh session, and reconnects.
- Reactive `.transientFailure` treats as unreachable and does not delete.
- Reactive `.notNeeded` and `.definitiveAuthFailure` retire pairing.
- Concurrent token-expired states coalesce to one refresh.

Path monitor:

- Debounces rapid path changes.
- Duplicate meaningful signature does not request reconnect.
- Satisfied interface bucket change while connected calls `requestReconnect()` once.
- Unsatisfied path does not create owner retry.

Probe:

- Successful probe keeps health healthy.
- One failed probe does not mark degraded.
- Two failed probes mark degraded.
- Three failed probes call `requestReconnect()`.
- Failed probe suppressed when inbound counter increases across the probe window.
- Probe task stops on disconnect/terminate.

Loopback retry:

- First bind failure then success yields connected state.
- Three bind failures set loopback error and disconnect session.
- Retry is bounded and does not schedule future retries.

AppState/AppDelegate:

- `AppState` real init constructs owner without starting network work before launch hook.
- Snapshot/test `AppState` does not touch keychain/network.
- Start/stop methods delegate to owner.

Fakes:

- `FakeTunnelTransport`
- `FakeTunnelSession`
- `FakePathMonitoringSource`
- `FakeProbeClient` or probe closure
- Fake keychain load/save/delete closures
- Fake `DeviceTokenRefresher` result provider
- Controllable sleep/clock closure

Use Swift Testing style already present:

- `@Suite`
- `@Test`
- `#expect`
- `#require`
- actor recorders
- polling `waitUntil`

## Risks and Review Points

- Mapping HTTP 401/403 to `tokenExpired` changes the diagnostic identity of relay auth failures. I recommend it because section 6 makes the refresher the terminal authority.
- `SessionError` currently has no `LocalizedError`; `sol-mac DialTest` uses `localizedDescription`, so diagnostics may remain generic unless separately improved. Do not change CLI messaging in M2 unless explicitly approved.
- A refreshed pairing requires a fresh `TunnelSession`; the owner must disconnect the old session before creating the new one to avoid two active reconnect loops.
- `requestReconnect()` must not cancel `reconnectTask` or call `connect()` internally.
- Path and probe triggers must call `requestReconnect()` only; they must not disconnect/reconnect directly.
- Loopback retry is intentionally bounded and local. Expanding it into a long-running retry would violate the owner-thinness goal.

## Open Questions

- Final gate decision: accept recommendation (a), mapping both handshake auth failure and 4401 to `SessionError.tokenExpired`, or keep handshake auth as terminal revoked.
- Whether to expose owner state in UI in M2. This design keeps it observable but does not add UI.
- Whether to add custom `LocalizedError` for `SessionError` later. Not needed for M2 and could alter CLI output beyond the auth mapping decision.
