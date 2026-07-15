# Check My Setup Status Group Design Record

Status: design only. No production code changes in this record.

## Ground Rules

- The Status pane gets a new honest `GroupBox("check my setup")` immediately after `healthSummaryCard`.
- The group is driven by value snapshots, pure classifiers, and injected probes. No I/O inside presentation builders.
- No second `AppState`; consume the existing `@Bindable appState` in `SettingsView` and existing seams such as `RunningJournalController`.
- Fail closed. Unknown probe failure is `unavailable`, not `ready` and not a fabricated denial.
- The scoped prompt's section 6 copy is authoritative. That exact copy was not present in the visible research context; constant names are specified here, but exact values must be filled from section 6 before implementation.

## A. Setup-Snapshot Value Model

Per-check state:

- `ready`: durable or observed fact is good.
- `needsAttention`: required check is conclusively missing or not granted.
- `notRequired`: row is informational because this topology does not require the local artifact.
- `checking`: cheap probe has not completed yet.
- `unavailable`: required check could not be classified because a probe or API failed in a non-conclusive way.

Group verdict:

- `ready`: every required voting row is `ready`; non-required rows may exist.
- `needsAttention(count: Int)`: no required row is `unavailable`, and `count` required rows are `needsAttention`.
- `someUnavailable`: at least one required row is `unavailable`.

Pure builder signature:

- `buildSetupSnapshot(input: SetupSnapshotInput) -> SetupSnapshotPresentation`
- `SetupSnapshotInput` is a value type. `SetupSnapshotPresentation` contains `rows: [SetupCheckRowPresentation]` and `verdict: SetupGroupVerdictPresentation`.
- The builder performs no filesystem, LaunchServices, keychain, UserDefaults, ScreenCaptureKit, AVFoundation, network, or process I/O.

Input fields and sources:

- `placementOutcome`: from an injected cheap placement probe. Source should reuse the existing placement repair/check area, not open-code bundle path logic in the builder.
- `journalAppInstalledOutcome`: from `RunningJournalController.installedURL()` through the existing `LiveRunningJournalController` seam.
- `serviceIsDone`: from `AppState.serviceIsDone`.
- `solWrapperExecutableOutcome`: injected filesystem/executable probe for the `sol` wrapper.
- `journalWrapperExecutableOutcome`: injected filesystem/executable probe for the `journal` wrapper.
- `screenPermissionOutcome`: pure `PermissionOutcome`, derived outside the snapshot builder.
- `microphonePermissionOutcome`: pure `PermissionOutcome`, derived outside the snapshot builder.
- `topology`: from the pure topology classifier in section B.
- `lastSyncOutcome`: from the durable last-sync store in section D.
- `now`: injected only if presentation needs relative time for the non-voting last-sync row.

Rows:

- App placement row: required for all topologies. Uses `placementOutcome`.
- Journal link row: required for all topologies. Uses `serviceIsDone`; before a journal choice this row is `needsAttention`.
- Screen recording row: required for all topologies. Uses `screenPermissionOutcome`.
- Microphone row: required for all topologies. Uses `microphonePermissionOutcome`.
- Journal app row: required only for `local`; for `remote` and `undecided`, emits `notRequired` with "not needed on this Mac" semantics and does not vote.
- `sol` wrapper row: required only for `local`; for `remote` and `undecided`, emits `notRequired` and does not vote.
- `journal` wrapper row: required only for `local`; for `remote` and `undecided`, emits `notRequired` and does not vote.
- Last sync row: always non-voting. Shows last successful contact, never synced, couldn't check, or not applicable. It never affects verdict.

Verdict rollup:

- Consider only required voting rows.
- If any required row is `unavailable`, verdict is `someUnavailable`.
- Else if any required row is `needsAttention`, verdict is `needsAttention(count:)`, where `count` is the number of required rows with `needsAttention`.
- Else verdict is `ready`.
- Mixed unavailable and missing keeps `someUnavailable`, but all known missing rows and their actions still render.
- `checking` does not count as ready. While any required row is `checking` and no required row is unavailable or missing, verdict should present as `someUnavailable` or an explicit checking surface if section 6 defines one. Without a separate group checking verdict, fail closed as `someUnavailable`.
- `notRequired` rows never vote.
- Last-sync never votes.

## B. Pure Topology Classifier

Signature:

- `classifySetupTopology(serviceMode: ServiceMode?, serverURL: String?, isTunnelManaged: Bool) -> SetupTopology`
- Output cases: `local`, `remote`, `undecided`.

Truth table:

| serviceMode | serverURL | isTunnelManaged | result |
| --- | --- | --- | --- |
| `.bundled` | any | any | `local` |
| `.external` or nil | loopback-host URL | false | `local` |
| `.external` or nil | any | true | `remote` |
| `.external` or nil | non-loopback URL | false | `remote` |
| `.external` or nil | nil/empty | false | `undecided` |

Ordering matters:

- Bundled wins first.
- Tunnel-managed wins over runtime loopback URLs, because the loopback is only the local proxy for a remote tunnel-managed journal.
- Direct external loopback without tunnel is local.

Host semantics:

- Use host parsing, not substring matching.
- Loopback means `localhost`, IPv4 `127.0.0.0/8`, or IPv6 `::1`.
- Reuse or extend `Sources/SolstoneCore/LoopbackHost.swift:5-15`. Current helper covers `localhost` and `127.0.0.1` at the bundled port; implementation must add true loopback-host semantics there or in a sibling helper, then route `BundledJournalEndpoint.isBundledServiceURL` through it. Do not duplicate parser logic in `SettingsView`.

Topology-specific voting:

- `local`: journal app and both wrapper rows are required.
- `remote`: journal app and wrapper rows say "not needed on this Mac" and do not vote.
- `undecided`: journal app and wrapper rows are informational/non-voting; journal-link row needs attention until a journal choice exists.

## C. Permission-Outcome Type

Outcome enum:

- `checking`
- `granted`
- `notGranted`
- `unavailable`

Pure derivation inputs:

- `initialPermissionCheckComplete`
- `screenRecordingGranted`
- `microphoneGranted`
- `hasPromptedScreenRecording`
- `screenPreflightSucceeded`
- `screenShareableContentCheckFailedAfterPositivePreflight`
- `microphoneAuthorizationCause`: `notDetermined`, `denied`, `restricted`, `unknown`

Rules:

- Before `initialPermissionCheckComplete`, both permissions are `checking`.
- If the corresponding granted bool is true, outcome is `granted`.
- Screen recording is `notGranted` when the initial check has completed and preflight is false, including the state where the user has not granted yet.
- Screen recording is `unavailable` when `CGPreflightScreenCaptureAccess()` is true but `SCShareableContent` still fails. This is the current CDHash/reinstall class; never collapse it into denial.
- Microphone is `notGranted` for AVFoundation `.notDetermined`, `.denied`, or `.restricted` after initial check.
- Microphone is `unavailable` only when the authorization status cannot be classified.
- Probe/API failure is `unavailable`, not `notGranted`.

Minimal new PermissionChecker signals:

- Add a layered screen diagnostic method that returns enough information to distinguish positive-preflight SCK failure from conclusive not-granted. It should wrap the existing `CGPreflightScreenCaptureAccess` + `PermissionChecker.checkScreenRecording()` sequence and be callable by SettingsView probes, not by the 5.0s poll unless separately chosen later.
- Add a microphone authorization-cause accessor that wraps `AVCaptureDevice.authorizationStatus(for: .audio)` and maps to the small cause enum.
- Do not alter `CaptureCoordinator` polling or auto-start. The 5.0s timer remains at `CaptureCoordinator.swift:185-197`; auto-start remains at `CaptureCoordinator.swift:249-258`.
- `AVCaptureDevice.requestAccess` stays user-driven at the existing `PermissionChecker.requestMicrophone()` call site.

## D. Durable Last-Sync Store

Persistence:

- Use `UserDefaults.standard`, consistent with `AppConfig` and `SyncService.syncedDays`.
- Production suite/domain is the standard defaults domain for bundle id `app.solstone.observer`.
- Proposed key: `settings.status.setup.lastSuccessfulJournalContact`.

Protocol seam:

- `LastSuccessfulJournalContactStoring`
- Operations: read payload, write payload, clear payload.
- Production implementation wraps `UserDefaults`.
- Tests use an isolated suite, following `IsolatedUserDefaults` in `Tests/solstoneTests/UpdateAppTestSupport.swift`.

Stored payload:

- `date: Date`
- `fingerprint: String`
- Payload contains no raw secret. Hash any secret-bearing fingerprint input before storage.

Canonical fingerprint:

- `journalConnectionFingerprint(config: AppConfig, topology: SetupTopology, tunnelPairing: StoredPairing?) -> JournalConnectionFingerprint?`
- Tunnel: hash canonical tuple `topology=tunnel`, `StoredPairing.instanceID`, `StoredPairing.fingerprint`.
- Direct external: hash canonical tuple `topology=direct`, normalized `serverURL`, `serverKey`.
- Bundled: hash canonical tuple `topology=bundled`, `journalPath`. Include a sentinel for nil `journalPath` so nil does not collide with empty string. Do not include local loopback URL because it is not identity.
- Unconfigured/undecided: returns nil.

Write point:

- Hook `UploadCoordinator.handleProgressEvent(.journalContactSucceeded)` at `UploadCoordinator.swift:287-291`.
- Stamp `nowProvider()` and the current canonical fingerprint through an injected store.
- `.uploadSucceeded` remains a bundled-ingest fact at `UploadCoordinator.swift:274-277`; it is not the durable "journal contact" write point because skipped uploads and empty syncs still need honest contact.

Read/restore:

- On `UploadCoordinator` or `AppState` construction, read the store through the injected seam.
- Accept timestamp only if stored fingerprint matches current canonical fingerprint.
- Mismatch means `noSyncYet`.
- Store read/decode failure means `couldNotCheck`.
- Never-synced should be represented durably: absence of a valid payload for the current fingerprint maps to `noSyncYet`, not an ambiguous process-local nil.

Clear points:

- Primary guarantee: fingerprint mismatch. A stale timestamp can never present after unpair, switch, or relink because the current identity is absent or different.
- Explicit clears still improve UX and reduce stale storage. Clear before presenting a new identity at updateConfig funnels that do change identity:
  - direct connect in `SettingsView.saveService`
  - local link in `persistLocalObserverRegistration`
  - tunnel registration in `performTunnelObserverRegistration`
  - external defaults reload before `updateConfig(fresh)`
  - journal handoff flip if bundled identity changes to external.
- Pairing keychain paths do not route through `updateConfig`: `PairingCoordinator.unpair`, `confirmSwitch`, and `activate`.
- Recommendation: also inject a clear callback into `PairingCoordinator` and call it after successful `deletePairing` and successful `savePairing`. The fingerprint gate is sufficient for correctness, but explicit clear is warranted because it removes stale state immediately and documents the identity mutation at the keychain layer. Keep it one callback, default no-op for tests/snapshots.
- Last-sync is neutral information and never votes on setup health.

## E. Top-Verdict Merge

Goal:

- A healthy operational sync can never leave an unqualified "all good" above a missing or unavailable required setup fact.

Minimal seam:

- Add an optional `setupVerdict` or `setupSeverity` parameter to `StatusHealthSummary.make`.
- Keep the setup snapshot builder separate. `SettingsView.statusHealthSummary` computes setup presentation first, then passes only the verdict severity into `StatusHealthSummary.make`.
- Do not make `StatusHealthSummary` know row-level setup details.

Severity mapping:

- `ready` -> `.good`
- `needsAttention(count:)` -> `.attention`
- `someUnavailable` -> `.attention`

Justification:

- Existing `.warn` is used for transient/offline/catching-up states.
- Missing setup facts and unclassifiable required checks require owner action or at least cannot honestly be green. Use `.attention`.
- If product wants a less severe color for `needsAttention`, that must be a copy/design decision; the engineering default is fail closed.

Merge rule:

- If setup severity is `.attention`, returned summary severity is at least `.attention`.
- Summary title/subtitle should use section 6 setup-verdict copy when setup is not ready, even if sync is operationally `.synced`.
- If setup is ready, preserve existing `StatusHealthSummary` behavior.

Rehoming removed journal info:

- App version moves to a compact footer row below the setup group or to the existing app/help surfaces, with `AXID.Settings.Status.appVersionState` rehomed if it remains in Status.
- Route to journal settings becomes an action in the setup group verdict or journal-link row, using `selectedTab = .service`; `manageJournal` AXID should either be rehomed there or renamed to the new action identifier.

## F. AX Additions

New `AXID.Settings.Status.*` identifiers:

- `setupVerdictState`: `settings.status.setup.verdict.state`
- `setupJournalLinkState`: `settings.status.setup.journalLink.state`
- `setupJournalLinkAction`: `settings.status.setup.journalLink.action`
- `setupAppPlacementState`: `settings.status.setup.appPlacement.state`
- `setupAppPlacementAction`: `settings.status.setup.appPlacement.action`
- `setupScreenRecordingState`: `settings.status.setup.screenRecording.state`
- `setupScreenRecordingAction`: `settings.status.setup.screenRecording.action`
- `setupMicrophoneState`: `settings.status.setup.microphone.state`
- `setupMicrophoneAction`: `settings.status.setup.microphone.action`
- `setupJournalAppState`: `settings.status.setup.journalApp.state`
- `setupJournalAppAction`: `settings.status.setup.journalApp.action`
- `setupSolWrapperState`: `settings.status.setup.solWrapper.state`
- `setupSolWrapperAction`: `settings.status.setup.solWrapper.action`
- `setupJournalWrapperState`: `settings.status.setup.journalWrapper.state`
- `setupJournalWrapperAction`: `settings.status.setup.journalWrapper.action`
- `setupLastSyncState`: `settings.status.setup.lastSync.state`
- `setupManageJournal`: `settings.status.setup.manageJournal`
- `setupAppVersionState`: `settings.status.setup.appVersion.state`

New token enums:

- `SetupCheckRowAXState`: `ready`, `needs_attention`, `not_required`, `checking`, `unavailable`
- `SetupGroupVerdictAXState`: `ready`, `needs_attention`, `some_unavailable`
- `PermissionOutcomeAXState`: `checking`, `granted`, `not_granted`, `unavailable`
- If `PermissionOutcomeAXState` maps one-to-one to `SetupCheckRowAXState` at render time, do not expose both. Prefer one shared row state unless tests need the permission-specific vocabulary.

AXContract additions:

- Add every static ID above to `AXContract.staticIDs`.
- Add vocabularies for `SetupCheckRowAXState` and `SetupGroupVerdictAXState`.
- Add state bindings:
  - verdict -> `SetupGroupVerdictAXState`
  - each row state -> `SetupCheckRowAXState`
  - last sync -> freeform or enum if the presentation is closed; prefer freeform only if it includes timestamps.
  - app version -> freeform

Removals/rehomes:

- Delete the old Status journal group source references.
- Rehome or remove `AXID.Settings.Status.manageJournal`; `SettingsWireUpTests.swift:80-95` currently asserts it.
- Rehome or remove `AXID.Settings.Status.appVersionState`; it is in AXContract but not directly asserted by SettingsWireUp today.
- Preserve `lastSyncedState` in the service sync section or update tests if it moves. Do not orphan `uploadJournalState`, `pauseSync`, `lastErrorState`, or `resyncAll`, which are still service-sync controls.
- Regenerate with `make ax-contract`; drift is gated by `AXContractTests`.

## G. Refresh Triggers

Probe storage:

- Add one `@State` value on `SettingsView`, e.g. `setupProbeSnapshot`.
- It stores only cheap probe outcomes and timestamps/identity read results needed by the pure builder.
- The builder consumes `appState` facts plus `setupProbeSnapshot`; it never probes.

Triggers:

- `statusTab.onAppear` at `SettingsView.swift:447`: run cheap filesystem/LaunchServices/defaults probes once.
- `selectedTab` change into `.status`: trigger the same refresh. This covers returning from Journal and Permissions tabs.
- Permission booleans:
  - `appState.initialPermissionCheckComplete`
  - `appState.screenRecordingGranted`
  - `appState.microphoneGranted`
- Relevant config fields:
  - `appState.config.serverURL`
  - `appState.config.serverKey`
  - `appState.config.serviceMode`
  - `appState.config.journalPath`
  - `appState.tunnelLifecycleOwner.isTunnelManaged`
- Last-sync store write: after `.journalContactSucceeded`, update coordinator observable state so the Status pane redraws without polling.

No background timer:

- No new recurring timer, no task loop, no periodic LaunchServices/file probes.
- Expensive probes are excluded. Wrapper checks are `FileManager.isExecutableFile`; installed app check uses the existing `RunningJournalController.installedURL` seam.

## H. Group Structure And Copy

Structure:

- Native `GroupBox("check my setup")`.
- Place immediately after `healthSummaryCard` and before the existing `GroupBox("sol")`.
- Use `LabeledContent` rows for stable labels and values.
- Use SF Symbols plus text for every state; never color alone.
- Use semantic system colors only.
- Actions are buttons with 44pt-equivalent hit targets. Use existing navigation actions where possible.

Actions by row:

- Journal link: navigate to `.service`.
- App placement: run or open existing placement repair flow if available; otherwise open Applications guidance surface.
- Screen recording: navigate to `.permissions` or invoke existing screen-recording enable flow from Permissions tab only if user action is explicit.
- Microphone: navigate to `.permissions`; request access remains at existing user-driven site.
- Journal app: use `RunningJournalController` seam or navigate to journal service flow; do not open-code workspace.
- Wrapper rows: navigate to journal/setup surface that can repair wrappers; no shell mutation from Status unless an existing explicit repair API exists.
- Last sync: no action unless section 6 defines one.

UICopy constants to add:

- `SETTINGS_SETUP_GROUP_TITLE`
- `SETTINGS_SETUP_VERDICT_READY`
- `SETTINGS_SETUP_VERDICT_NEEDS_ATTENTION`
- `SETTINGS_SETUP_VERDICT_SOME_UNAVAILABLE`
- `SETTINGS_SETUP_ROW_READY`
- `SETTINGS_SETUP_ROW_NEEDS_ATTENTION`
- `SETTINGS_SETUP_ROW_NOT_REQUIRED`
- `SETTINGS_SETUP_ROW_CHECKING`
- `SETTINGS_SETUP_ROW_UNAVAILABLE`
- `SETTINGS_SETUP_ROW_JOURNAL_LINK_LABEL`
- `SETTINGS_SETUP_ROW_APP_PLACEMENT_LABEL`
- `SETTINGS_SETUP_ROW_SCREEN_RECORDING_LABEL`
- `SETTINGS_SETUP_ROW_MICROPHONE_LABEL`
- `SETTINGS_SETUP_ROW_JOURNAL_APP_LABEL`
- `SETTINGS_SETUP_ROW_SOL_WRAPPER_LABEL`
- `SETTINGS_SETUP_ROW_JOURNAL_WRAPPER_LABEL`
- `SETTINGS_SETUP_ROW_LAST_SYNC_LABEL`
- `SETTINGS_SETUP_ACTION_OPEN_JOURNAL_SETTINGS`
- `SETTINGS_SETUP_ACTION_OPEN_PERMISSIONS`
- `SETTINGS_SETUP_ACTION_FIX_APP_LOCATION`
- `SETTINGS_SETUP_ACTION_REPAIR_WRAPPERS`
- `SETTINGS_SETUP_LAST_SYNC_NEVER`
- `SETTINGS_SETUP_LAST_SYNC_COULD_NOT_CHECK`
- `SETTINGS_PERMISSIONS_SCREEN_RECORDING_RESET_HINT`
- `SETTINGS_PERMISSIONS_MIC_CAUSE_NOT_DETERMINED`
- `SETTINGS_PERMISSIONS_MIC_CAUSE_DENIED`
- `SETTINGS_PERMISSIONS_MIC_CAUSE_RESTRICTED`

Copy lock:

- Exact values must be copied from scoped section 6 before implementation.
- Follow lowercase-first UI copy.
- Avoid owner-visible banned verbs from `AGENTS.md`: `watch`, `capture`, `record`, `monitor`, `track`, `collect`.

## Removal Plan For `GroupBox("journal")`

Delete from `SettingsView.statusTab`:

- `GroupBox("journal")` at `SettingsView.swift:2344-2371`.
- `Text(syncTargetText)` and `syncTargetText` if it becomes unused.
- Status-pane `uploadStatusView` occurrence in that group. Keep `uploadStatusView` itself for service sync panels.
- Bundled `"your journal needs a new link"` line; replace with setup verdict/journal-link row copy.
- External `"last synced ..."` line; replace with durable setup last-sync row.
- `"app version \(AppVersion.short)"`; rehome to setup footer/app-version row or existing app/help surface.
- `"manage journal ->"`; rehome as setup group or journal-link row action navigating to `.service`.

Keep elsewhere:

- `externalJournalSyncSection` with `uploadJournalState`, `pauseSync`, `lastSyncedState`, `lastErrorState`, `resyncAll`.
- `externalJournalStorageSection`.
- `healthSummaryCard`.

AX/test follow-through:

- Update `SettingsWireUpTests` expected status references so `manageJournal` and any removed identifiers do not remain orphaned.
- If `appVersionState` is moved, keep the contract and wire-up. If removed from Status, remove from `AXID`, `AXContract`, and regenerated JSON.

## Test Plan

New pure unit tests:

- `SetupTopologyClassifierTests`: full truth table, loopback host semantics, tunnel-managed beats loopback runtime URL.
- `SetupSnapshotBuilderTests`: row-state mapping, required vs not-required topology behavior, journal-link before choice, last-sync non-voting.
- `SetupVerdictRollupTests`: ready, N missing, unavailable, mixed unavailable+missing, checking fail-closed, not-required non-voting.
- `PermissionOutcomeTests`: checking before initial pass, granted after success, conclusive screen not-granted, positive-preflight SCK failure unavailable, mic notDetermined/denied/restricted, unknown unavailable.
- `LastSuccessfulJournalContactStoreTests`: read/write/clear, decode failure, fingerprint match/mismatch, absence => noSyncYet.
- `JournalConnectionFingerprintTests`: tunnel, direct, bundled, unconfigured nil, no raw serverKey persisted.

Updated existing tests:

- `UploadCoordinatorTests`: `.journalContactSucceeded` writes durable timestamp using `nowProvider` and current fingerprint; mismatch does not restore.
- `PairingCoordinatorTests`: unpair and confirm switch call explicit clear callback.
- `TunnelObserverRegistrationTests`: identity-changing registration clears before `updateConfig`; same-key no-op does not clear unnecessarily.
- `JournalClientBehaviorTests`: local link clears old last-sync and stores new identity after registration.
- `SettingsRestartContractTests`: external defaults reload path clears durable sync before `updateConfig(fresh)`.
- `StatusHealthSummaryTests`: setup severity overrides "all good"; ready preserves existing behavior.
- `AXIDTests` and `AXContractTests`: new vocabularies and state bindings.
- `SettingsWireUpTests`: new setup AX IDs and removed/rehome journal IDs.
- `UICopyTests` / `SettingsViewUICopyWireUpTests`: all new `UICopy` constants use locked section 6 strings and are referenced.
- `SnapshotTests`: Status pane renders group across ready, needs-attention, unavailable, local vs remote, and long text.

Validation commands:

- `hop check -- swift test --filter Setup`
- `hop check -- swift test --filter PermissionOutcome`
- `hop check -- swift test --filter LastSuccessfulJournalContact`
- `hop check -- swift test --filter UploadCoordinator`
- `hop check -- swift test --filter PairingCoordinator`
- `hop check -- swift test --filter AX`
- `hop check -- swift test --filter WireUp`
- `hop check -- make ax-contract`
- `hop check -- make test`

## Implementation Sequence

1. Add pure types and builders: topology classifier, permission outcome mapper, snapshot rows/verdict, fingerprint function.
2. Add durable last-sync store protocol, production UserDefaults store, and test fake.
3. Inject store/fingerprint seam into `UploadCoordinator` and hook `.journalContactSucceeded`.
4. Add explicit clear hooks at updateConfig identity funnels and PairingCoordinator keychain identity mutation points.
5. Add minimal PermissionChecker diagnostic accessors without changing poll/auto-start.
6. Add SettingsView `@State` probe snapshot and refresh triggers.
7. Render setup group and remove old journal group, rehoming app version and manage-journal action.
8. Add AX IDs/tokens/contracts and regenerate.
9. Add UICopy constants with exact section 6 strings.
10. Run targeted tests, then full `make test`.

## Open Ambiguities

- Scoped section 6 exact copy was not present in the visible session context. Implementation must not proceed on copy constants until the exact strings are supplied or recovered.
- The app-placement probe/action surface is not fully specified by prep. Prefer reusing existing `AppPlacementRepair` flow, but the exact owner-visible action depends on current UX.
- Wrapper repair behavior from Status is not specified. The safe default is informational row plus route to Journal settings; do not mutate shell wrappers from Status without an existing explicit repair API.
- Bundled fingerprint uses `serviceMode=bundled + journalPath` per direction. If `journalPath` is nil in a real legacy bundled config, the fingerprint should still be canonical and mismatch-safe, but the row will likely need attention.

## As-Built Reconciliation

Commit `3f5f98b` implemented a consolidated setup surface rather than separate
wrapper rows. The actual Status AX IDs are:

- `setupVerdictState`: `settings.status.setup.verdict.state`
- `setupSolAppState`: `settings.status.setup.solApp.state`
- `setupSolAppAction`: `settings.status.setup.solApp.action`
- `setupJournalAppState`: `settings.status.setup.journalApp.state`
- `setupJournalAppAction`: `settings.status.setup.journalApp.action`
- `setupJournalLinkState`: `settings.status.setup.journalLink.state`
- `setupJournalLinkAction`: `settings.status.setup.journalLink.action`
- `setupCommandLineToolsState`: `settings.status.setup.commandLineTools.state`
- `setupCommandLineToolsAction`: `settings.status.setup.commandLineTools.action`
- `setupScreenRecordingState`: `settings.status.setup.screenRecording.state`
- `setupScreenRecordingAction`: `settings.status.setup.screenRecording.action`
- `setupMicrophoneState`: `settings.status.setup.microphone.state`
- `setupMicrophoneAction`: `settings.status.setup.microphone.action`
- `setupLastSyncState`: `settings.status.setup.lastSync.state`
- `setupManageJournal`: `settings.status.setup.manageJournal`
- `setupAppVersionState`: `settings.status.setup.app.version.state`

The contract exposes one shared row-state vocabulary,
`SetupCheckRowAXState`, plus `SetupGroupVerdictAXState`. There is no separate
`PermissionOutcomeAXState` in the emitted AX contract. The old Status
`manageJournal` route and app-version state were rehomed into the setup group
as `setupManageJournal` and `setupAppVersionState`.
