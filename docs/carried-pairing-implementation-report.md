# Carried pairing implementation record

This report records the carried-pairing implementation on checkout `d1e43cd70920f0bcd4621dfa699b22abeeadaa0c`. It contains source inventory, focused test evidence, artifact provenance, and remaining caller-owned proofs. No commit was created.

## Implementation map

- `SPLPairingKeychain.swift` selects `~/Library/Keychains/login.keychain-db` explicitly for the destination item. Reads distinguish `errSecItemNotFound` from errors. Writes update or add with an explicit `SecAccess`, read back the exact stored bytes, and retain the legacy item on any destination failure. The access object is restricted to the calling app; the running code is checked against its stable Developer ID designated requirement before creating it. The old Data Protection item is deleted only after exact destination verification.
- The local marker, carried candidate, decision, invalidation, and cleanup tombstone live in nonsynchronizing, device-only Data Protection items. The portable baseline is a separate synchronizing Data Protection item; it records journal identity, credential fingerprint/revision, the expected local marker, and source/destination provenance. It contains no private key or CSR. Candidate private key and CSR bytes remain in the device-only keychain record.
- Recovery is phase-driven. A prepared marker without a completed baseline resumes the same-device move. Only a completed baseline and matching local marker admit ordinary traffic. A completed baseline with a missing or mismatched local marker creates a device-local candidate and requires rekey. An unreadable marker or destination blocks. A missing destination with no legacy credential returns the existing not-linked state. Once the portable baseline exists, stale Data Protection credentials never become a fallback. A durable cleanup tombstone retains source and destination provenance plus the source credential digest until cleanup succeeds.
- `PairingCredentialStore` serializes these records and checks durable credential fingerprint, revision, and operation ID. `PairingCoordinator` persists invalidation before explicit retirement, switch, unpair, and mark cancellation/rejection; a persistence error leaves the old pairing intact and sends no retirement. Lost retirement and cleanup failures remain recoverable. The lifecycle owner's revoked-pairing path also records invalidation before deleting a credential already refused by the journal.
- `TunnelLifecycleOwner` persists the exact operation ID, CSR, and key before migration network mutation. Its temporary control transport uses the old credential only for migration state/rekey and is disconnected without install, loopback publication, or ordinary post-jobs. It validates the reply, commits the fresh credential and matching baseline, stores the pending decision, then reconnects with the new credential. Current durable identity checks fence late replies and continuations, including same-journal credential replacement.
- `AppState` supplies durable-ready admission to upload and browser egress and rebinds mark confirmation and `LastJournalDelivery` only across a validated same-journal lineage. Browser intake continues to take custody while migration is blocked; the planner holds POST, receipt reconciliation, and release until admission returns. Capture, `PauseManager` persistence/restoration, and `BrowserOwnerSurface` pause/resume behavior are unchanged.
- Pending same/new-device choices are persisted before PUT. Same-device has no default action. Unknown outcomes reconcile the exact operation before another submission; mismatched terminal state leaves the row pending. Fresh-pair replacement is a separate durable one-shot offer, recorded before display and displayed after ordinary mark confirmation. Its current-device list excludes self, preserves distinct CIDs with equal labels, starts unselected, and re-fetches the exact target before native confirmation. Dismissal submits nothing.
- Protocol 3 decoding accepts `segment` and `stream` only as a valid nonempty pair, permits duplicate original keys only across distinct streams, keeps collision aliases unique, and decodes day listing values from `files` only. Receipt reconciliation uses original physical coordinates, complete file/name/size/hash and custody/generation bindings; aliases are lookup hints only. Ambiguity does not release bytes. Alias reassignment is persisted when the physical evidence is sufficient. An unmatched nonempty listing proceeds to POST through the admitted route.

The two copied contract families keep separate roots: `vendor/contracts/device-migration/` and `vendor/contracts/client-ingest-contract/`. Their provenance is stored outside the copied bytes in `vendor/contracts/provenance/carried-pairing-artifacts.json`. Existing `client-ingest/adoption.json` and `native-browser` contract identities were not modified.

## Immutable artifact provenance

Each file below was read with `git show 1e432dba3ecdfa43789c25f97077fdc3e71fab59:<source-path>` from the read-only source clone. Source output and installed copy were independently hashed with SHA-256; they match byte-for-byte.

| Source path | Installed path | Supplied expected SHA-256 | Pinned source SHA-256 | Installed SHA-256 | Bytes equal | Expected matches source |
|---|---|---|---|---|---|---|
| `contracts/device-migration/v1.schema.json` | `vendor/contracts/device-migration/v1.schema.json` | `5ea0ce5bf0bc5f07233f05dda3334ccea3bf173363fcd4fd4cdcd9479130a373` | `5ea0ce5bf0bc5f07233f05dda3334ccea3bf173363fcd4fd4cdcd9479130a373` | `5ea0ce5bf0bc5f07233f05dda3334ccea3bf173363fcd4fd4cdcd9479130a373` | yes | yes |
| `contracts/device-migration/v1.vectors.json` | `vendor/contracts/device-migration/v1.vectors.json` | `3ba1bb508a0cd5756626c6246fbff77573c54538db60c8e7f938e38b306ef9c` (63 hex characters) | `3ba1bb508a0cd5756626c6246bfbff77573c54538db60c8e7f938e38b306ef9c` | `3ba1bb508a0cd5756626c6246bfbff77573c54538db60c8e7f938e38b306ef9c` | yes | no; expected omits one `b` after `6246` |
| `docs/openapi/client-ingest-contract/manifest.json` | `vendor/contracts/client-ingest-contract/manifest.json` | `86d4358916a0303c29a8e61c6d1e48ef1939d0b5a2f042ae617958b9d0c1a5a8` | `86d4358916a0303c29a8e61c6d1e48ef1939d0b5a2f042ae617958b9d0c1a5a8` | `86d4358916a0303c29a8e61c6d1e48ef1939d0b5a2f042ae617958b9d0c1a5a8` | yes | yes |
| `docs/openapi/client-ingest-contract/projection.openapi.json` | `vendor/contracts/client-ingest-contract/projection.openapi.json` | `db75a94ab97e83c56603e44d9313db86a94a2d9c4a920deaf090fe0f3358b8b0` | `db75a94ab97e83c56603e44d9313db86a94a2d9c4a920deaf090fe0f3358b8b0` | `db75a94ab97e83c56603e44d9313db86a94a2d9c4a920deaf090fe0f3358b8b0` | yes | yes |
| `docs/openapi/client-ingest-contract/vectors.json` | `vendor/contracts/client-ingest-contract/vectors.json` | `7c61c1238184e1440110801478daf714aba05b2472338db98c12cd508b303d0f` | `7c61c1238184e1440110801478daf714aba05b2472338bd98c12cd508b303d0f` | `7c61c1238184e1440110801478daf714aba05b2472338bd98c12cd508b303d0f` | yes | no; the `db`/`bd` pair is transposed |
| `docs/openapi/client-ingest-contract/fixtures/wire-behavior.json` | `vendor/contracts/client-ingest-contract/fixtures/wire-behavior.json` | `035e59297af21da998984910b4aa6a850d7e2e1225c79019045381bf3e17e708` | `035e59297af21da998984910b4aa6a850d7e2e1225c79019045381bf3e17e708` | `035e59297af21da998984910b4aa6a850d7e2e1225c79019045381bf3e17e708` | yes | yes |

The two mismatching supplied digests are retained exactly above; neither was used to alter pinned source bytes. The source repository was not modified. Package/library versions, protocol versions, release/tag state, entitlements, provisioning-profile wiring, and access groups are unchanged.

## Production-only caller inventory

Every query below was run against production `Sources` only; tests are excluded. Match lists retain the exact source lines so later edits can be compared directly.

### Credential storage, load/save/delete

Query:

```text
rg -n --glob '*.swift' '(SPLPairingKeychain\.store|PairingCredentialStore\(|credentialStore\.(load|save|delete)|keychainStore\.(load|save|delete)|PairingStoring|deletePairing|delete\(after:)' Sources/solstone Sources/JournalMarkKit
```

Matches and dispositions:

- `SPLPairingKeychain.swift:23,38` — production backend factory and pinned login-keychain store.
- `PairingCoordinator.swift:105,122,258,374,412,465,472,488,492,506,542,559,589,611,632,655,670,686,707,725,850,864,930,963` — coordinator construction, credential load, durable decision/offer writes, replacement save, and cleanup. Credential deletion is only `delete(after:)` at 258 and 374, after the durable invalidation/remote-retirement path.
- `PairingCredentialStore.swift:14,24,67` — `PairingStoring` interface and serialized owner.
- `TunnelLifecycleOwner.swift:320,341,412,974,1025,1043,1087,1108,1113,1130,1147,1148,2080` — lifecycle store construction, migration candidate/reply/commit, and revoked-credential cleanup through the invalidation-aware store.
- `AppState.swift:1205,1358,1359,1639,1684,1790,2229` — production construction, injected snapshot construction, credential load, and browser credential restoration.
- `deletePairing` has no production matches. No caller bypasses `PairingCredentialStore` with a raw pairing deletion.

### Marker, baseline, candidate, decision, offer, and invalidation state

Query:

```text
rg -n --glob '*.swift' '(localMarker|initialMovePrepared|completedPortableBaseline|preparedCredential|legacyCleanupPending|replacementOfferShown|replacementOfferID|\.candidate|\.decision|\.invalidation)' Sources/solstone/CarriedPairingState.swift Sources/solstone/SPLPairingKeychain.swift Sources/solstone/PairingCredentialStore.swift Sources/solstone/PairingCoordinator.swift Sources/solstone/TunnelLifecycleOwner.swift Sources/solstone/SettingsView.swift
```

Matches and dispositions:

- `CarriedPairingState.swift:87,88,89,90,92,95,96,98,102` — durable record and baseline/candidate/decision/invalidation types.
- `SPLPairingKeychain.swift:55,57,59,60,63,67,87,89,95,112,113,127,130,131,133,134,135,139,142,143,144,154,169,172,182,187,189,190,191,193,196,202,240,241,242,245,255,260,265,275,277,278,281,284,287,288,289,291,297,298,327,541` — prepared move, baseline matching, source cleanup, marker/record/baseline keychain writes, and tombstone verification.
- `PairingCredentialStore.swift:144,145,146,157,158,167,168,173,175,185,186,189,195,256,261,281,298,307,308,309,310,313,328,329,330,331,334,352,353,354,357,358,359,360,362,363,364,496,497,498,499,500,517,518,519,520,521,528` — record ownership, durable admission, current fingerprint/revision CAS, and invalidation cleanup.
- `PairingCoordinator.swift:277,279,310,324,326,460,461,470,487,490,508,509,510,544,545,546,561,562,563,591,592,593,613,614,621,630,673,674,675,676,704,706,774,835,837,841,842,844,857,859,861,862,960,961,962` — invalidation recovery, deferred migration decision, one-shot offer, exact target picker, and terminal decision state. `PairingCoordinator.swift:1082` is a `PairURL` candidate list, not migration state.
- `TunnelLifecycleOwner.swift:573,1006,1013,1018,1019,1020,1024,1028,1042,1086,1111,1112,1132,1136,1137,1151,1152,1153,1925,2054` — lifecycle-owned migration/rekey state. Line 2054 reads durable invalidation before a revoked self-retirement continuation; `TunnelLifecycleOwner.swift:1925` is a transport endpoint candidate list, not migration state.
- `SettingsView.swift:2142,2143,2151,2152` — pending decision status rendering. `SettingsView.swift:3151` is a SwiftUI picker candidate name, not migration state.

### Confirmation reads and writes

Query:

```text
rg -n --glob '*.swift' '(journalMarkConfirmationStore\.(confirm|clear|load|confirmedJournal)|isJournalMarkConfirmed|clearJournalMarkConfirmation|recordJournalMarkConfirmed|clearConfirmedMark|JournalMarkConfirmationStore)' Sources/solstone Sources/JournalMarkKit
```

Matches and dispositions:

- `JournalMarkConfirmationDriver.swift:90,99,112,121` — destructive cancel/reject clear only after the supplied unpair operation returns success.
- `PairingCoordinator.swift:80,114,138,300,335,379,946` — clear hook wiring and confirmation clearing after successful removal or a genuinely new-journal pairing; same-journal certificate rotation preserves confirmation.
- `SettingsView.swift:661,1349,1351,1470,1858,2663,2677` — confirmation reads, refresh, and successful unpair clearing. `2663` is the explicit relink flow's transient displayed-mark reset; it does not clear durable confirmation.
- `LocalJournalLinkFlow.swift:265` — same transient relink display reset.
- `JournalMarkConfirmationStore.swift:21,50` — durable UserDefaults store and memory fake.
- `AppState.swift:941,1080,1113,1118,1119,1134,1158,1169,1171,1234,1235,1239,1245,1246,1247,1258,1278,1302,1328,1398,1400,1402,1691,1741,1742,1802,1804,1806,1848` — mark answer persistence, same-journal lineage reuse, gate calculation, transient mark reset, and store injection.
- `JournalMarkConfirmationDriver+AppState.swift:8,18,101,102,112,113` — normal answer recording and cancel/reject wrappers.
- `JournalWindow.swift:95` — presentation read.

### Pairing invalidation, retirement, deletion, and recovery

Query:

```text
rg -n --glob '*.swift' '(beginInvalidation|updateInvalidation|clearInvalidation|credentialStore\.delete|delete\(after:|retireOwnCredential|retirePairingAndFailRevoked|retryRevokedPairingRetirement|pairingCoordinator\.unpair)' Sources/solstone Sources/JournalMarkKit
```

Matches and dispositions:

- `PairingCoordinator.swift:201,229,255,258,261,262,285,286,333,334,348,359,370,374,376,377,390,394,435,439,951` — direct same-journal replacement and confirmed switch begin durable invalidation before retirement; unpair/recovery delete only after operation ownership and retirement are confirmed; cleanup clears only the matching operation/fingerprint/revision. `348` is stale invalidation cleanup guarded by the durable identity comparison.
- `PairingCredentialStore.swift:269,303,317,338` — serialized invalidation start/update/clear operations.
- `TunnelLifecycleOwner.swift:593,595,1227,1423,1634,1826,1833,2040,2064,2079,2080,2082,2083` — retry and automatic revoked path. It persists invalidation before deletion and retains it on cleanup failure.
- `AppState.swift:835,836,1405,1809` — retry routing and production/snapshot retirement injection.
- `SettingsView.swift:2457,2618,2675` — revoked recovery actions and Settings unpair; removal state is shown only after successful cleanup.
- `JournalMarkConfirmationDriver+AppState.swift:97,108` — cancel/reject delegate to the invalidation-aware coordinator.

### Lifecycle, transport, client-self, relay, and ordinary admission

Query:

```text
rg -n --glob '*.swift' '(credentialStore\.admission|connectFromStoredPairing|requestCoalescedReconnect|replaceLiveTransport|install\(|connectOnceForEstablishment|makeTransport\(|carriedPairingControl\.(rekey|migrationState)|clientSelfSequencer\.enqueue|relayAccessSequencer\.enqueue|state = \.connected)' Sources/solstone/TunnelLifecycleOwner.swift Sources/solstone/AppState.swift Sources/solstone/UploadCoordinator.swift
```

Matches and dispositions:

- `TunnelLifecycleOwner.swift:137,494,495,581,612,646,651,657,712,734,822,830,836,851,897,900,909,934,945,953,958,961,975,979,1056,1065,1073,1159,1176,1241,1286,1303,1326,1376,1491,1496,1502,1613,1672,1962,1965` — cold start/retry/reconnect/replacement/install recheck durable admission. The separate `makeTransport()` at 1056 is the restricted migration control transport. Migration GET/POST are at 1065/1073. Ordinary client-self and relay enqueue at 651/657 and 1496/1502 are scheduled only after durable-ready checks. Connection state publication at 934/1613/1672 is rechecked by `handleStateTransition`; the browser route is published only when connected and ready.
- `AppState.swift:2166` — supplies the durable admission closure to browser egress.

Ordinary publisher/admission query:

```text
rg -n --glob '*.swift' '(currentPairedIngestIdentity\(|ordinaryAdmission\(|syncOnStartup\(|triggerSync\(|forceFullSync\(|clientSelfSequencer\.enqueue\(|relayAccessSequencer\.enqueue\(|scheduleDelivery\(|connectFromStoredPairing\(|connectOnceForEstablishment\(|replaceLiveTransport\(|install\()' Sources/solstone/AppState.swift Sources/solstone/UploadCoordinator.swift Sources/solstone/TunnelLifecycleOwner.swift
```

Matches and dispositions:

- `UploadCoordinator.swift:260,272,305,330,349,355,360,373,491,555` — configured identity changes, ordinary readiness, startup, manual/automatic trigger, force sync, connection probe, contextual progress result, and retry. All ordinary sends enter the readiness gate.
- `AppState.swift:551,554,1172,1177,1248,1257,1311,1512,1515,1517,1555,1588,1686,1885,1890,1964,2113,2191` — connection identity changes and config/startup/segment/reconnect/resume callbacks update or invoke the gated coordinator. Browser schedule nudges cannot bypass the planner admission predicate.
- `TunnelLifecycleOwner.swift:651,657,712,734,822,830,897,900,945,958,961,979,1159,1241,1286,1376,1496,1502` — ordinary connection and post-job publishers share the durable-ready gate described above.

### Browser intake, route, listing, receipt, and release

Query:

```text
rg -n --glob '*.swift' '(setCarriedPairingAdmissionOpen\(|scheduleDelivery\(|planAndUpload\(|uploadStaged\(|segmentsDay\(|releaseProven\(|listingMatch\(|publishDeliveryAck\(|publishBrowserRoute\(|BrowserIntakeRouteCapability\(|ingestBaseURL\(|accept\(decoded:)' Sources/solstone/BrowserIntakeOwner.swift Sources/solstone/BrowserUploadPlanner.swift Sources/solstone/BrowserIngestAck.swift Sources/solstone/AppState.swift Sources/solstone/TunnelLifecycleOwner.swift
```

Matches and dispositions:

- `BrowserIntakeOwner.swift:255,276,286,288,300,303,310,321,426,530,539,573,593,635` — current route-driven delivery nudges, admission configuration, and decoded local acceptance. Intake retains custody while egress is closed; nudges enter the planner.
- `BrowserUploadPlanner.swift:23,109,126,218,222,232,234,276,308,313,330` — upload interface, admission configuration/check, planning, listing and listing match, receipt publication, alias update, listing custody release, staged POST, POST receipt publication, and fresh ordinary POST custody release. Fresh and listing releases both use the admission-serialized commit; collision POST receipts remain held for coordinate reconciliation.
- `BrowserIngestAck.swift` — no match in this query; acknowledgment decoding is consumed through the planner's receipt path.
- `AppState.swift:554,1076,1087,1181,1906,2214` — delivery nudges and home/ingest resolvers. The resolvers fail closed and the planner independently rechecks admission.
- `TunnelLifecycleOwner.swift:134,142,624` — route capability construction/publication and lifecycle state publication; fencing publishes no ordinary route.

### Settings actions, mark wrappers, local relink, and same-machine pairing

Settings query:

```text
rg -n --glob '*.swift' '(submitPairingLink\(|confirmSwitch\(|cancelSwitch\(|pairingCoordinator\.unpair\(|chooseCarriedPairing\(|keepBothDevices\(|confirmReplacement\(|dismissReplacementPicker\(|openReplacementPicker\(|selectReplacementTarget\()' Sources/solstone/SettingsView.swift Sources/solstone/AppState.swift Sources/solstone/PairingCoordinator.swift
```

Matches and dispositions:

- `SettingsView.swift:1360,1368,2035,2068,2074,2107,2111,2265,2288,2297,2310,2314,2321,2576,2591,2658,2668,2675,2930` — pairing link submission, switch, cancel, explicit same/new migration choice, offer dismissal, exact-CID picker selection/confirmation, keep-both, and unpair. Choice rows have no default same-device action. Dismissal does not submit. Unpair clears presentation only after success.
- `PairingCoordinator.swift:162,210,234,503,525,533,539,555,608` — corresponding owner methods.
- `AppState.swift:932` — automatic same-machine pair link submits through `PairingCoordinator`.

Mark wrapper query:

```text
rg -n --glob '*.swift' '(cancelPairing\(|reject\(|unpair\(|clearConfirmedMark|clearJournalMarkConfirmation|continueAnyway|func cancel\()' Sources/JournalMarkKit/JournalMarkConfirmationDriver.swift Sources/solstone/JournalMarkConfirmationDriver+AppState.swift Sources/solstone/SettingsView.swift Sources/solstone/PairingCoordinator.swift Sources/solstone/AppState.swift
```

Matches and dispositions:

- `JournalMarkConfirmationDriver.swift:66,82,89,90,98,99,111,112,120,121` — cancel, continue, cancel-pairing, and reject. Destructive wrappers clear mark only after successful coordinator unpair.
- `JournalMarkConfirmationDriver+AppState.swift:16,21,99,100,101,102,105,110,111,112,113,116` — app-state answer and durable unpair wrappers.
- `SettingsView.swift:634,640,649,2663,2675,2677` — continue, cancel, reject, transient relink mark reset, and success-guarded Settings unpair.
- `PairingCoordinator.swift:80,114,138,239,300,335,379,946` — hook ownership, unpair, recovery, and new-journal/same-journal confirmation behavior.
- `AppState.swift:1245,1302,1398,1400,1402,1802,1804,1806` — durable answer clear, transient displayed mark clear, and production/snapshot wiring.

Same-machine and local relink query:

```text
rg -n --glob '*.swift' '(performSameMachineHomePairing\(|SameMachineHomePairingResult|SameMachinePairStartClient|submitPairingLink:|clearConfirmedMark\()' Sources/solstone/LocalJournalLinkFlow.swift Sources/solstone/SameMachineHomePairing.swift Sources/solstone/AppState.swift Sources/solstone/SettingsView.swift
```

Matches and dispositions:

- `SameMachineHomePairing.swift:45,179,186,196,197` — same-machine pair-start client, result, and coordinator-driven ceremony submission.
- `LocalJournalLinkFlow.swift:265` — transient displayed-mark reset for explicit relink; durable confirmation is controlled by the later pairing result.
- `AppState.swift:147,927,931,1302,1339,1585,1637,1682` — migration result, automatic adoption, pair-start clients, and transient mark reset owner.
- `SettingsView.swift:263,2663,2677,2925,2929` — local discovery, explicit relink, successful unpair reset, and same-machine ceremony submit.

Browser intake compile-mode query:

```text
rg -n 'SOLSTONE_BROWSER_INTAKE_PREVIEW|bundle-adhoc|SolstoneSPLKeychainPlane' Sources Makefile Tests Package.swift
```

`Package.swift:97,128,234` selects the existing preview compile mode. Browser route/intake/planner code and its app-state wiring remain behind the existing compile guards. `bundle-adhoc` remains a local signing target; it no longer writes `SolstoneSPLKeychainPlane` into `Info.plist`, and that marker has no remaining source, test, or documentation matches. `docs/local-test-build.md` now states that ad-hoc/self-signed bundles cannot use the production pairing credential backend.

## Focused test evidence

All test commands were run with `hop check --allow-capture`; no full CI gate, build-only gate, real app-state permission poller, OS keychain, network, socket, process, or clock integration test was run.

| Final focused command | Result |
|---|---|
| `hop check --allow-capture -n 180 -- swift test --filter 'SPLPairingKeychainTests|PairingCredentialStoreTests|PairingCoordinatorTests|SameMachineHomeMigrationTests|SettingsViewTests|PairingOverlayTests'` | Exit 0; 80 tests, 6 suites passed. |
| `hop check --allow-capture -n 180 -- swift test --filter 'TunnelLifecycleOwnerTests|JournalMarkConfirmationDriverTests|JournalMarkConfirmationGateTests|JournalWindowMarkGateTests|UploadCoordinatorTests|SyncServiceTests|JournalClientSelfTests|JournalRelayAccessTests|JournalSelfRetirementTests|TunnelConnectedSyncTests|LastJournalDeliveryStoreTests|CarriedPairingControlTests|CarriedPairingCertificateValidationTests'` | Exit 0; 320 tests, 13 suites passed. |
| `hop check --allow-capture -n 180 -- swift test --filter 'BrowserIntakeTests|BrowserPairingPersistenceTests|BrowserSpoolLifecycleTests|IngestProtocolV3DecoderTests'` | Exit 0; 88 tests, 5 suites passed. |
| `hop check --allow-capture -n 45 -- swift test --filter 'CarriedPairingCertificateValidationTests.rekeyPairingRequiresCertificateKeyFingerprintInstanceAndCA|CarriedPairingControlTests.rekeyEnvelopeBindsOperationProtocolStateAndCurrentCID'` | Exit 0; 2 tests, 2 suites passed after mutation restores. |
| `hop check --allow-capture -n 40 -- swift test --filter TunnelLifecycleOwnerTests.candidatePersistenceFailureStopsBeforeMigrationNetworkMutation` | Exit 0; 1 test, 1 suite passed after attempted mutation restore. |

SwiftPM reports existing unhandled packaging inputs (`entitlements-adhoc-debug.plist`, `entitlements-app.plist`, and `embedded.provisionprofile`) while planning test builds; these are not target resources and were not changed. The source also retains existing unused-result/`try` warnings in browser lifecycle tests. The required file-keychain `SecKeychainOpen` and `SecAccessCreate` APIs are deprecated by the SDK; the focused keychain suite compiles and passes.

## Final audit mutation proof completion

The previous implementation report correctly marked its short mutation summaries unverified because they lacked restoration evidence. This follow-up reran those gates through `hop check --allow-capture -n 50 -- swift test --filter <test>`. For every row below, the red command exited 1 with the listed assertion, the source was restored from its exact pre-mutation byte snapshot (byte comparison true and before/after SHA-256 equal), and the same focused command after restore exited 0. Full command output was captured for the focused runs. These are memory-backed owner/decoder tests; they do not claim live keychain, network, or hardware behavior.

| Gate and guarding test | Temporary mutation and actual red result | Restore and green result |
|---|---|---|
| Durable invalidation blocks admission — `PairingCredentialStoreTests.staleSameJournalInvalidationCannotDeleteReplacementCredential` | Changed the invalidation admission result from `.blocked` to `.ready`; red exit 1: replacement admission was `.ready`, expected `.blocked`. | `PairingCredentialStore.swift` byte-identical to snapshot; SHA-256 `92b8b6c8db127b2bd5220a05b5c7d6f7c346b5dfc1c23508736f3ecd8fe39008`; same test green exit 0. |
| Candidate ownership binds operation ID — `PairingCredentialStoreTests.candidateOwnershipIncludesCredentialRevisionAndOperationID` | Bypassed the candidate operation-ID comparison; red exit 1: `owns(oldRevision, operationID: "operation-b")` returned true. | `PairingCredentialStore.swift` byte-identical to snapshot; SHA-256 `92b8b6c8db127b2bd5220a05b5c7d6f7c346b5dfc1c23508736f3ecd8fe39008`; same test green exit 0. |
| Candidate ownership binds current credential revision — same test | Bypassed `current == fingerprint`; red exit 1: the old operation remained owned after credential replacement. | `PairingCredentialStore.swift` byte-identical to snapshot; SHA-256 `92b8b6c8db127b2bd5220a05b5c7d6f7c346b5dfc1c23508736f3ecd8fe39008`; same test green exit 0. |
| Durable invalidation precedes retirement — `PairingCoordinatorTests.invalidationPersistenceFailurePreservesPairingAndSendsNoRetirement` | Temporarily made the failed-invalidation branch call remote retirement; red exit 1: retire count was 1, expected 0. | `PairingCoordinator.swift` byte-identical to snapshot; SHA-256 `d7fac5cd131794e0139902a12fe6c31ab8b1b68de0a936873a414520a6371329`; same test green exit 0. |
| Mark cancel honors failed unpair — `JournalMarkConfirmationDriverTests.cancelPairingKeepsConfirmationWhenDurableInvalidationFails` | Removed the unpair-result guard; red exit 1: cancel returned success, cleared confirmation, and dismissed. | `JournalMarkConfirmationDriver.swift` byte-identical to snapshot; SHA-256 `dd3c1678ff99b7c004301b5b0e45805dcf9d8622140f3a6660e3f25bfd587a41`; same test green exit 0. |
| Mark reject honors failed unpair — `JournalMarkConfirmationDriverTests.rejectKeepsConfirmationAndSkipsMismatchWhenDurableInvalidationFails` | Removed the unpair-result guard; red exit 1: reject returned success, cleared confirmation, called mismatch, and dismissed. | `JournalMarkConfirmationDriver.swift` byte-identical to snapshot; SHA-256 `dd3c1678ff99b7c004301b5b0e45805dcf9d8622140f3a6660e3f25bfd587a41`; same test green exit 0. |
| Browser POST requires admission — `BrowserSpoolLifecycleTests.carriedPairingAdmissionBlocksQueuedBrowserPostAndRetainsBytes` | Made planner admission always open; red exit 1: one POST ran instead of zero, periods became delivered, and payloads were removed. | `BrowserUploadPlanner.swift` byte-identical to snapshot; SHA-256 `b7291ace1290994c4d4d766a3c3b1286469ad25243a6599a4ac9aaa2d51a8ab2`; same test green exit 0. |
| Browser receipt requires exactly one physical candidate — `BrowserSpoolLifecycleTests.equalByteCollisionTwinsRemainAmbiguousAndUnmatchedListingPosts` | Relaxed the listing candidate count from exactly one to nonempty; red exit 1: ambiguous twin custody was released and expected retry/state assertions failed. | `BrowserUploadPlanner.swift` byte-identical to snapshot; SHA-256 `b7291ace1290994c4d4d766a3c3b1286469ad25243a6599a4ac9aaa2d51a8ab2`; same test green exit 0. |
| Protocol-3 segment and stream coordinates are paired — `IngestProtocolV3DecoderTests.segmentsDayRejectsFalseTotalsDuplicateKeysAndMalformedCoordinates` | Bypassed the pair check; red exit 1: a segment-only listing fixture decoded successfully instead of throwing. | `IngestProtocolV3.swift` byte-identical to snapshot; SHA-256 `dffcd310258af33ef9a04a0833817deef53c83ea315f2bd21052a7d76089668b`; same test green exit 0. |
| Alias reassignment persists across restart — `BrowserSpoolLifecycleTests.physicalAliasReassignmentPersistsAcrossRestart` | Skipped publishing the updated receipt; red exit 1: updated alias/coordinates were absent both before and after reopen, and payload stayed held. | `BrowserUploadPlanner.swift` byte-identical to snapshot; SHA-256 `b7291ace1290994c4d4d766a3c3b1286469ad25243a6599a4ac9aaa2d51a8ab2`; same test green exit 0. |
| Terminal decision must match expected state — `PairingCoordinatorTests.terminalDecisionMismatchKeepsTheDurableChoicePending` | Bypassed the reply-state comparison; red exit 1: decision state and durable/presented choice were cleared instead of remaining unknown/pending. | `PairingCoordinator.swift` byte-identical to snapshot; SHA-256 `d7fac5cd131794e0139902a12fe6c31ab8b1b68de0a936873a414520a6371329`; same test green exit 0. |
| Carried choice persists before PUT — `PairingCoordinatorTests.carriedChoiceIsDeferredAndUnknownSubmissionPersistsBeforeRetryReconciliation` | Skipped the durable choice write; red exit 1: no `decide` request was sent, the choice was absent, and state remained `deciding`. | `PairingCoordinator.swift` byte-identical to snapshot; SHA-256 `d7fac5cd131794e0139902a12fe6c31ab8b1b68de0a936873a414520a6371329`; same test green exit 0. |
| Unknown choice reconciles before retry — same test | Skipped the status reconciliation branch; red exit 1: events were `["decide", "decide"]`, expected `["decide", "state", "decide"]`. | `PairingCoordinator.swift` byte-identical to snapshot; SHA-256 `d7fac5cd131794e0139902a12fe6c31ab8b1b68de0a936873a414520a6371329`; same test green exit 0. |
| Replacement offer is one-shot — `PairingCoordinatorTests.freshPairReplacementOfferIsDeferredAndDismissalSubmitsNothing` | Bypassed the persisted shown-state check; red exit 1: the offer became visible again after dismissal. | `PairingCoordinator.swift` byte-identical to snapshot; SHA-256 `d7fac5cd131794e0139902a12fe6c31ab8b1b68de0a936873a414520a6371329`; same test green exit 0. |
| Upload readiness requires ordinary admission — `UploadCoordinatorTests.carriedPairingAdmissionBlocksUploadStartupAndConnectionProbe` | Removed `ordinaryAdmission()` from readiness; red exit 1: readiness became true and an unexpected `/app/devices/ingest` request was sent. | `UploadCoordinator.swift` byte-identical to snapshot; SHA-256 `055e34db69998b461033adf3f192f5fb95f8fa41dc5489ba61437ab500394777`; same test green exit 0. |
| Rekey envelope binds protocol, operation, state, previous CID, and current CID — `CarriedPairingControlTests.rekeyEnvelopeBindsOperationProtocolStateAndCurrentCID` | Made the complete envelope predicate return true; red exit 1: all five invalid-envelope expectations failed. | `CarriedPairingControl.swift` byte-identical to snapshot; SHA-256 `eb8734855447e0f45634dfdb6b6a3facec957fafa9da6b14beb64b743f56cc55`; same test green exit 0. |
| Rekey leaf public key matches candidate key — `CarriedPairingCertificateValidationTests.rekeyPairingRequiresCertificateKeyFingerprintInstanceAndCA` | Bypassed public-key equality; red exit 1: the unrelated key fixture returned a pairing instead of throwing. | `CarriedPairingControl.swift` byte-identical to snapshot; SHA-256 `eb8734855447e0f45634dfdb6b6a3facec957fafa9da6b14beb64b743f56cc55`; same test green exit 0. |
| Rekey leaf fingerprint matches reply — same test | Bypassed leaf-fingerprint equality; red exit 1: the wrong-fingerprint fixture returned a pairing instead of throwing. | `CarriedPairingControl.swift` byte-identical to snapshot; SHA-256 `eb8734855447e0f45634dfdb6b6a3facec957fafa9da6b14beb64b743f56cc55`; same test green exit 0. |
| CA subject key matches journal instance — same test | Bypassed the SPKI/instance comparison; red exit 1: the wrong-instance fixture returned a pairing instead of throwing. | `CarriedPairingControl.swift` byte-identical to snapshot; SHA-256 `eb8734855447e0f45634dfdb6b6a3facec957fafa9da6b14beb64b743f56cc55`; same test green exit 0. |
| Rekey chain validates against supplied CA — same test | Bypassed `SecTrustEvaluateWithError`; red exit 1: the unrelated-CA fixture returned a pairing instead of throwing. | `CarriedPairingControl.swift` byte-identical to snapshot; SHA-256 `eb8734855447e0f45634dfdb6b6a3facec957fafa9da6b14beb64b743f56cc55`; same test green exit 0. |
| Fresh 409 replay keeps stable decision UUID — `PairingCoordinatorTests.freshReplacementConflictReplaysTheSameDurableDecisionAndExactTarget` | Changed only the replay UUID; red exit 1: the terminal replay no longer resolved, so the pending decision remained. | `PairingCoordinator.swift` byte-identical to snapshot; SHA-256 `d7fac5cd131794e0139902a12fe6c31ab8b1b68de0a936873a414520a6371329`; same test green exit 0. |
| Fresh 409 replay keeps exact target body — same test | Changed only replay `replacesCID` to nil; red exit 1: the response no longer validated and the pending decision remained. | `PairingCoordinator.swift` byte-identical to snapshot; SHA-256 `d7fac5cd131794e0139902a12fe6c31ab8b1b68de0a936873a414520a6371329`; same test green exit 0. |

The completed-baseline marker, candidate-save-before-control, serialized browser release, synchronous route revocation, stale progress, late mark answer, required nullable fields, and unknown rekey envelope-key proofs remain recorded in the focused proof tables below. The earlier candidate-persistence mutation that was blocked by a second ownership check is not counted; the later direct save-bypass proof is the valid evidence. Security file-keychain behavior remains untested against a real OS keychain by instruction.

## Caller-owned proofs still outstanding

- Visual review of the Settings/pairing surfaces, including the supplied exact copy and native target confirmation.
- Signed-storage review on a properly Developer ID-signed app: verify the selected login keychain, effective app designated-requirement ACL, readback equality, destination error behavior, conflict handling, and cleanup after a source-delete failure. Unit tests intentionally do not open the user's keychain.
- Two-device and backup/restore exercises: same-hardware recovery, new-device adoption, marker mismatch rekey, cloud baseline propagation, late response, and cleanup after restart against the actual service and signed app.
- Final-tree caller gate requested by the session owner: `hop check --ship-gate --allow-capture -- make ci`. It was not run here.
- No claim is made that these focused memory-backed tests prove live tunnel, login-keychain ACL, server protocol, visual, or hardware behavior.

Apple documents that `kSecAttrAccess` is the file-keychain `SecAccess` ACL mechanism ([`kSecAttrAccess`](https://developer.apple.com/documentation/security/ksecattraccess)) and that a nil trusted-app list limits sensitive operations to the calling app ([`SecAccessCreate`](https://developer.apple.com/documentation/security/secaccesscreate%28_%3A_%3A_%3A%29)). Apple describes file-keychain app ACL identity as a designated requirement in its [keychain ACL guidance](https://developer.apple.com/forums/thread/115425). These APIs are legacy/deprecated, but the task fixes the file-based user login-keychain destination.

## Audit follow-up

### Corrected behavior

- Durable invalidation first synchronously revokes `TunnelLifecycleOwner`'s ordinary route, clears browser route authority, advances the lifecycle attempt guard, and changes the lifecycle state. Only after that linearization point does the callback suspend to revoke/cancel upload work and finish transport teardown. Restricted retirement/control uses its isolated temporary transport.
- `SyncService` tags every ordinary progress event with the captured upload context and epoch. `UploadCoordinator.handleProgressEnvelope` applies one centralized freshness check before dispatching any event variant, including status-only events such as `offline`, `syncStarted`, `syncProgress`, `awaitingTunnel`, and `segmentUnprovable`. Sync post-await checks and the lock-held acknowledgment/removal gate preserve unconfirmed files when invalidation wins.
- Browser listing reconciliation now has a final synchronous commit inside `PairingCredentialStore.withOrdinaryBrowserAdmission`. That store lock serializes receipt-coordinate persistence and `releaseProven` against durable invalidation; no await occurs inside the critical section. The browser intake store lock is acquired only after the credential-store lock, and the transaction does not acquire the planner admission lock. If invalidation wins, the ack remains unconfirmed and the payload/recovery backup remain held; if the transaction wins, release linearizes before invalidation.
- `JournalWindowSceneRoot` observes current durable admission and lifecycle route revocation. `JournalWindowSession.routeAuthorityDidChange` clears the route and loaded WebView immediately; open/reload paths check authority before and after base resolution. App-state home-base, ingest, and mark gates consult current durable readiness.
- Mark answers use an attempt's captured credential revision for fetch and commit. The final commit also requires current durable admission and no invalidation, so an answer from before same-journal credential replacement cannot confirm the mark or mutate the replacement offer.
- Carried choices reject invalidated records before submission and after awaits. Fresh replacement choices persist a stable decision UUID and exact body/target before PUT; a 409 causes exact same-ID/body replay, and an unresolved response leaves the original choice pending. Migration response decoders reject unknown object keys per the pinned schema.

### Final production-only caller inventory

These queries were rerun against production `Sources`; tests are excluded. The listed results are every match for each query, grouped by owning file. They supplement the initial storage, browser, protocol-3, lifecycle, Settings, LocalJournalLinkFlow, and SameMachineHomePairing inventory above.

**Sync custody, revocation, and result publication query:**

```text
rg -n --glob '*.swift' '(revokeOrdinaryTraffic|ordinarySyncIsCurrent|withOrdinarySyncAdmission|uploadStaged|persistAcknowledgment|removeConfirmedSegment|LastJournalDeliveryPayload|lastContactStore\.write)' Sources/solstone/SyncService.swift Sources/solstone/UploadCoordinator.swift Sources/solstone/PairingCredentialStore.swift
```

- `PairingCredentialStore.swift:212,235` — current pairing revision/admission check and the lock-held synchronous gate used for acknowledgment and custody mutations.
- `UploadCoordinator.swift:290,292,449,495,501` — revocation entry point and SyncService propagation; last-contact write and last-delivery payload creation follow current contextual event checks.
- `SyncService.swift:144,190,232,268,275,277,281,289,294,306` — injected acknowledgment writer/store, sync epoch revocation, current-context checks, and trigger admission.
- `SyncService.swift:386,414,454,471,614,677` — settled-remnant, acknowledged-segment, and segment-removed cleanup callers; destructive acknowledgment cleanup at 471 uses the serialized gate.
- `SyncService.swift:974,1009,1010` — staged upload response, followed by atomic acknowledgment persistence only while the captured pairing revision remains admitted.
- `SyncService.swift:1364,1492,1511,1528,1539,1552,1607,1618,1635,1646,1659,1718,1731,1745,1760,1771,1784` — confirmed-segment removal, preservation, file deletion, directory removal, and quarantine. Each write/removal/rename is performed through the same gate; suspension points are followed by a current-context check.

**Ordinary publishers and transport admission query:**

```text
rg -n --glob '*.swift' '(currentPairedIngestIdentity\(|ordinaryAdmission\(|syncOnStartup\(|triggerSync\(|forceFullSync\(|clientSelfSequencer\.enqueue\(|relayAccessSequencer\.enqueue\(|scheduleDelivery\(|connectFromStoredPairing\(|connectOnceForEstablishment\(|replaceLiveTransport\(|install\()' Sources/solstone/AppState.swift Sources/solstone/UploadCoordinator.swift Sources/solstone/TunnelLifecycleOwner.swift
```

- `UploadCoordinator.swift:260,272,305,330,349,355,360,373,491,555` — configured identity changes, ordinary readiness, startup, manual/automatic trigger, force sync, connection probe, current progress result, and retry. All ordinary sends enter the readiness gate.
- `AppState.swift:551,554,1172,1177,1248,1257,1311,1512,1515,1517,1555,1588,1686,1885,1890,1964,2113,2191` — identity updates, browser delivery nudges, capture/config/resume triggers, and startup. These are triggers only; the shared upload or browser egress gate decides whether traffic can leave.
- `TunnelLifecycleOwner.swift:651,657,712,734,822,830,897,900,945,958,961,979,1159,1241,1286,1376,1496,1502` — client-self/relay jobs, transport replacement/install, stored-pairing startup/retry, and one-shot establishment. Durable readiness is rechecked before ordinary installation and post-jobs; migration-control GET/PUT remains separate.

**Browser intake and egress query:**

```text
rg -n --glob '*.swift' '(setCarriedPairingAdmissionOpen\(|scheduleDelivery\(|planAndUpload\(|uploadStaged\(|segmentsDay\(|releaseProven\(|listingMatch\(|publishDeliveryAck\(|publishBrowserRoute\(|BrowserIntakeRouteCapability\(|ingestBaseURL\(|accept\(decoded:)' Sources/solstone/BrowserIntakeOwner.swift Sources/solstone/BrowserUploadPlanner.swift Sources/solstone/BrowserIngestAck.swift Sources/solstone/AppState.swift Sources/solstone/TunnelLifecycleOwner.swift
```

- `BrowserIntakeOwner.swift:255,276,286,288,300,303,310,321,426,530,539,573,593,635` — current route-driven delivery nudges, admission configuration, and decoded local acceptance. Intake retains custody while egress is closed; nudges enter the planner.
- `BrowserUploadPlanner.swift:23,109,126,218,222,232,234,276,308,313,330` — upload interface, admission configuration/check, planning, listing and listing match, receipt publication, alias update, listing custody release, staged POST, POST receipt publication, and fresh ordinary POST custody release. Fresh and listing releases both use the admission-serialized commit; collision POST receipts remain held for coordinate reconciliation.
- `BrowserIngestAck.swift` — no match in this query; acknowledgment decoding is consumed through the planner's receipt path.
- `AppState.swift:554,1076,1087,1181,1906,2214` — delivery nudges and home/ingest resolvers. The resolvers fail closed and the planner independently rechecks admission.
- `TunnelLifecycleOwner.swift:134,142,624` — route capability construction/publication and lifecycle state publication; fencing publishes no ordinary route.

**Loopback and already-open window route query:**

```text
rg -n --glob '*.swift' '(ordinaryRouteRevoked|revokeRoute\(|routeAuthority|homeBase\(|ingestBaseURL\(|resolveHomeBase\()' Sources/solstone/AppState.swift Sources/solstone/TunnelLifecycleOwner.swift Sources/solstone/JournalWindow.swift Sources/solstone/JournalWindowComposition.swift
```

- `TunnelLifecycleOwner.swift:118,553,933` — route-revoked state, invalidation fence, and reset only on successful ordinary install.
- `AppState.swift:1043,1046,1054,1076,1087,1109,1135,1212,1224,1266,1275` — shared home-base/ingest resolvers, readiness predicates, mark attempt, and resolved-window base. Loopback requires current durable admission and non-revoked route state.
- `JournalWindow.swift:102,121,123,186,202,263` — root observes current durable admission and owner revocation, passes route state to the window, and sends changes to the session.
- `JournalWindowComposition.swift:219,461,502,509,514,515,518,519,520,535,536,539,540,541,550,551,552` — immediate route clearing, authority checks before and after base resolution in open/reload, and revocation on the observed state change.

**Mark fetch, answer, and commit query:**

```text
rg -n --glob '*.swift' '(beginJournalMarkConfirmationAttempt|currentJournalMarkAttemptRevision|recordJournalMarkConfirmed|markAnswerIsCurrent|confirm\(appState|continueAnyway\(appState|fetchMark:|startJournalMark)' Sources/solstone/AppState.swift Sources/solstone/JournalMarkConfirmationDriver+AppState.swift Sources/solstone/SettingsView.swift Sources/JournalMarkKit/JournalMarkConfirmationDriver.swift
```

- `PairingCredentialStore.swift:224` — the exact current credential revision must still be admitted and uninvaldated before a mark answer can commit.
- `AppState.swift:941,1158,1194,1209,1218,1235` — migration-confirmation entry point, answer persistence with expected revision, durable store read, and attempt-token ownership.
- `JournalMarkConfirmationDriver+AppState.swift:6,8,10,16,18,19,33,39,46,53,64,68,88,93,94,104,105,139,145,146,161,174,181,187` — start/fetch revalidation and confirm/continue/cancel/reject wrappers. Destructive wrappers call coordinator unpair; an answer is not accepted after revision or invalidation changes.
- `JournalMarkConfirmationDriver.swift:130,145,153` — shared asynchronous fetch flow; app-specific closures validate current durable ownership at the read and completion boundaries.
- `SettingsView.swift:413,428,629,634,657,669` — Settings refresh, answer controls, and fetch-attempt revision capture.

**Pairing retirement and destructive wrappers query:**

```text
rg -n --glob '*.swift' '(JournalSelfRetirement\(\)|retireInvalidatedPairing\(|retireOwnCredential|beginInvalidation\(|\.unpair\(\)|confirmSwitch\()' Sources/solstone/PairingCoordinator.swift Sources/solstone/TunnelLifecycleOwner.swift Sources/solstone/SettingsView.swift Sources/solstone/JournalMarkConfirmationDriver+AppState.swift
```

- `PairingCoordinator.swift:82,115,139,201,210,229,255,359,390,394,435` — retirement injection, same-journal refresh/switch/unpair and recovery. Explicit retirement follows successful durable invalidation; delete/replace proceeds only for the same operation and credential revision.
- `TunnelLifecycleOwner.swift:570,584,2064` — invalidation-scoped retirement recovery, direct `JournalSelfRetirement` on its isolated control transport, and automatic revoked-pairing invalidation.
- `SettingsView.swift:2068,2675` — Settings switch/unpair actions use coordinator-owned retirement.
- `JournalMarkConfirmationDriver+AppState.swift:105,116` — mark cancel/reject use coordinator unpair, and clear/dismiss only after success.

**Settings/pairing semantic actions query:**

```text
rg -n --glob '*.swift' '(submitPairingLink\(|confirmSwitch\(|cancelSwitch\(|pairingCoordinator\.unpair\(|chooseCarriedPairing\(|keepBothDevices\(|confirmReplacement\(|dismissReplacementPicker\(|openReplacementPicker\(|selectReplacementTarget\()' Sources/solstone/SettingsView.swift Sources/solstone/AppState.swift Sources/solstone/PairingCoordinator.swift
```

- `AppState.swift:932` — automatic same-machine link submission.
- `PairingCoordinator.swift:162,210,234,503,525,533,539,555,608` — shared link, switch, pending-choice, one-shot offer, picker, keep-both, and replacement owner operations.
- `SettingsView.swift:1360,1368,2035,2068,2074,2107,2111,2265,2288,2297,2310,2314,2321,2576,2591,2658,2668,2675,2930` — button/sheet actions. Dismiss paths do not submit; replacement requires a current selected CID and native confirmation.

**Protocol reply and conflict query:**

```text
rg -n --glob '*.swift' '(rejectUnknownKeys\(|statusCode == 409|reconcileConflictedDecision\(|CarriedPairingMigrationReply|CarriedPairingDecisionReply)' Sources/solstone/CarriedPairingControl.swift Sources/solstone/PairingCoordinator.swift
```

- `CarriedPairingControl.swift:32,97,113,136,156,232,233,263,264,269,271,318` — strict migration/decision reply decoding, typed client calls, and HTTP 409 conflict result.
- `PairingCoordinator.swift:787,794` — conflict dispatch and exact-operation state reconciliation before terminal refusal or completion.

No raw production pairing deletion bypass was added. `PauseManager`, `CaptureCoordinator`, and `BrowserOwnerSurface` pause/resume ownership were not changed.

### Follow-up focused checks

All commands below used `hop check --allow-capture`. The first post-fix owner run exposed the existing four-variant `postResolveContextChangeFailsClosed` fixture: it timed out waiting for the config-change event and failed its event assertion in each variant. The resolver guard now emits that event with its captured context; the late-event handler rejects it for stale UI state. The final two-owner run below is green.

| Final command | Result |
|---|---|
| `hop check --allow-capture -n 300 -- swift test --filter 'SyncServiceTests|UploadCoordinatorTests'` | Exit 0; 133 tests in 2 suites passed. This final run includes the four resolver variants and twelve post-response variants. |
| `hop check --allow-capture -n 120 -- swift test --filter 'SyncServiceTests.postResolveContextChangeFailsClosed|SyncServiceTests.postResponseContextChangeFailsClosed|SyncServiceTests.durableInvalidationAfterUploadResponseLeavesBytesUnacknowledgedAndUndelivered|SyncServiceTests.ordinaryRevocationEpochStopsHeldUploadBeforeAcknowledgment|UploadCoordinatorTests.revokedOrdinaryTrafficRejectsLateDeliveryEvent'` | Exit 0; 5 selected tests in 2 suites passed, including all parameter cases. |
| `hop check --allow-capture -n 100 -- swift test --filter 'TunnelLifecycleOwnerTests.durableInvalidationFenceDisconnectsTheInstalledOrdinaryRoute|JournalWindowCompositionTests.revokedOrdinaryRouteRemovesAnAlreadyLoadedWebView|JournalMarkConfirmationGateTests.invalidatedPairingHasNoMarkRouteOrValidAnswer|JournalMarkConfirmationDriverTests.cancelPairingKeepsConfirmationWhenDurableInvalidationFails|JournalMarkConfirmationDriverTests.rejectKeepsConfirmationAndSkipsMismatchWhenDurableInvalidationFails'` | Exit 0; 5 tests in 4 suites passed. |
| `hop check --allow-capture -n 30 -- swift test --filter JournalWindowCompositionTests.revokedOrdinaryRouteRemovesAnAlreadyLoadedWebView` | Exit 0; 1 session-level composed test passed after wiring already-open window revocation. |
| `hop check --allow-capture -n 120 -- swift test --filter 'PairingCoordinatorTests.durableInvalidationBlocksADeferredCarriedChoiceBeforeSubmission|PairingCoordinatorTests.persistedChoiceCannotSubmitOrReconcileAfterDurableInvalidation|PairingCoordinatorTests.decisionConflictReconcilesExactOperationBeforeCompleting|PairingCoordinatorTests.lateCarriedDecisionCannotChangePresentationAfterUnpairAndSameJournalReplacement|PairingCoordinatorTests.lateCarriedDecisionCannotChangePresentationAfterConfirmedSwitch|PairingCoordinatorTests.invalidationPersistenceFailurePreservesPairingAndSendsNoRetirement|PairingCredentialStoreTests.markAnswerRequiresCurrentCredentialAndNoDurableInvalidation'` | Exit 0; 7 tests in 2 suites passed. |
| `hop check --allow-capture -n 80 -- swift test --filter 'CarriedPairingControlTests.migrationAndDecisionRepliesRejectUnknownResponseKeys|CarriedPairingControlTests.http409IsAnOutcomeConflictThatRequiresReconciliation'` | Exit 0; 2 tests in 1 suite passed. |
| `hop check --allow-capture -- git diff --check` | Exit 0; no whitespace errors. |

### Second-audit mutation proofs with restore evidence

These gates were rerun in the final follow-up because the prior audit report lacked auditable restoration evidence. Each mutation below changed only the named guard, then restored the exact byte snapshot (`restored_bytes_equal=true` and unchanged SHA-256) before rerunning the same focused test. Commands used `hop check --allow-capture -n 50 -- swift test --filter <test>`, except both JournalWindow mutations and fresh replacement 409 replay, which used `-n 60`. Red and green output tails are retained under `/var/tmp/carried-pairing-final-followup/`.

| Gate/test | Exact temporary mutation and actual red result | Restore and green result |
|---|---|---|
| Delayed sync admission — `SyncServiceTests.durableInvalidationAfterUploadResponseLeavesBytesUnacknowledgedAndUndelivered` | In `PairingCredentialStore.swift`, bypassed `record.invalidation` in durable admission. Exit 1: the segment file was removed and `delivery.read()` returned `.found(...)` rather than `.absent`. | Exact snapshot restored; `PairingCredentialStore.swift` SHA-256 `92b8b6c8db127b2bd5220a05b5c7d6f7c346b5dfc1c23508736f3ecd8fe39008`; same test green exit 0. |
| Active sync epoch — `SyncServiceTests.ordinaryRevocationEpochStopsHeldUploadBeforeAcknowledgment` | Replaced `ordinaryTrafficEpoch &+= 1` with `ordinaryTrafficEpoch &+= 0`. Exit 1: assertion at `SyncServiceTests.swift:2438` found the audio segment missing after the held response. | Exact snapshot restored; `SyncService.swift` SHA-256 `5c62f673d67ea8ae368870744a2b3746ec1416553f80bb0f8fcd74867b8f2153`; same test green exit 0. |
| Installed loopback fence — `TunnelLifecycleOwnerTests.durableInvalidationFenceDisconnectsTheInstalledOrdinaryRoute` | In `TunnelLifecycleOwner.beginOrdinaryTrafficFence`, forced the ordinary state to remain `.connected(localPort: 18281, via: .relay)`. Exit 1: `localPort` remained 18281, state remained connected, and browser route capability remained published. | Exact snapshot restored; `TunnelLifecycleOwner.swift` SHA-256 `dcb00bb5764d4ccacbc76d951b2d44715317d1cc942bc72b270f676860589851`; same test green exit 0. |
| Open WebView state revocation — `JournalWindowCompositionTests.revokedOrdinaryRouteRemovesAnAlreadyLoadedWebView` | In `JournalWindowComposition.revokeRoute()`, changed the held state to loading. Exit 1: state was `.loading` instead of `.held`, and `showsWebView` remained true. | Exact snapshot restored; `JournalWindowComposition.swift` SHA-256 `006e2cc33ae70238f19787a050ead92e20c1de9b5c8628bd020dee167265b0b1`; same test green exit 0. |
| Open-window authority notification — same JournalWindow test | Made `JournalWindowSession.routeAuthorityDidChange()` a no-op. Exit 1: five assertions showed state remained loaded, the WebView remained shown, the base and load command remained, and generation did not advance. | Exact snapshot restored; same SHA-256 `006e2cc33ae70238f19787a050ead92e20c1de9b5c8628bd020dee167265b0b1`; same test green exit 0. |
| Mark answer durable admission — `JournalMarkConfirmationGateTests.invalidatedPairingHasNoMarkRouteOrValidAnswer` | Changed the store's answer admission predicate to return true. Exit 1: `markAnswerIsCurrent(revision)` returned true during durable invalidation. | Exact snapshot restored; `PairingCredentialStore.swift` SHA-256 `92b8b6c8db127b2bd5220a05b5c7d6f7c346b5dfc1c23508736f3ecd8fe39008`; same test green exit 0. |
| Deferred choice invalidation — `PairingCoordinatorTests.persistedChoiceCannotSubmitOrReconcileAfterDurableInvalidation` | Bypassed invalidation in `migrationDecisionIsCurrent`. Exit 1: observed control events were `["state", "decide"]`, not empty. | Exact snapshot restored; `PairingCoordinator.swift` SHA-256 `d7fac5cd131794e0139902a12fe6c31ab8b1b68de0a936873a414520a6371329`; same test green exit 0. |
| 409 conflict classification — `CarriedPairingControlTests.http409IsAnOutcomeConflictThatRequiresReconciliation` | Classified HTTP 409 as refused. Exit 1: actual `.refused`, expected `.conflict`. | Exact snapshot restored; `CarriedPairingControl.swift` SHA-256 `eb8734855447e0f45634dfdb6b6a3facec957fafa9da6b14beb64b743f56cc55`; same test green exit 0. |
| Strict reply fields — `CarriedPairingControlTests.migrationAndDecisionRepliesRejectUnknownResponseKeys` | Bypassed `rejectUnknownKeys`. Exit 1: both migration and decision replies with extra fields decoded instead of throwing. | Exact snapshot restored; same `CarriedPairingControl.swift` SHA-256 `eb8734855447e0f45634dfdb6b6a3facec957fafa9da6b14beb64b743f56cc55`; same test green exit 0. |
| Fresh replacement 409 replay — `PairingCoordinatorTests.freshReplacementConflictReplaysTheSameDurableDecisionAndExactTarget` | Replaced the call to `replayConflictedFreshDecision` with an immediate `decision_unknown` return. Exit 1: assertion at `PairingCoordinatorTests.swift:869` observed one decision submission instead of two; the mutated test then hit its unchecked snapshot index and the Swift test helper exited with signal 5. | Exact snapshot restored; `PairingCoordinator.swift` SHA-256 `d7fac5cd131794e0139902a12fe6c31ab8b1b68de0a936873a414520a6371329`; same test green exit 0. |

### Remaining caller-owned proofs

The caller-owned visual review, Developer ID signed-keychain/ACL behavior, backup and two-device migration exercises, and final ship gate remain as listed above. No full ship gate, signing, real keychain, hardware, or external-project change was performed in this follow-up.

## Second-audit implementation follow-up

### Additional fixes

- Browser receipt reconciliation now commits updated listing coordinates and `releaseProven` inside the credential store's synchronous `withOrdinaryBrowserAdmission` transaction. Its lock checks the current pairing generation, identity digest, and durable `.ready` admission while holding the same lock used by invalidation. There is no suspension inside the transaction. The final store lock order is credential store then browser intake store; the planner admission lock is released before entry. Invalidation winning first leaves the browser payload and recovery backup held; the transaction winning first linearizes the release before invalidation.
- The invalidation callback invokes `TunnelLifecycleOwner.beginOrdinaryTrafficFence` synchronously before the first suspension. That immediately sets route revocation, clears browser route capability, invalidates lifecycle attempts, and disconnects the exposed loopback state. Only then does the callback await upload cancellation and teardown. An already-open window observes the revoked state, clears route authority, and drops its loaded WebView.
- Every `SyncService` event is emitted as an envelope with the run's captured `JournalUploadContext` and epoch. `UploadCoordinator.handleProgressEnvelope` rejects all events centrally unless the envelope epoch, current pairing/journal context, and ordinary admission still match. This includes previously untagged status, retry, and recorder events.
- Fresh replacement decisions persist one stable UUID and exact target/body before submission. A 409 replays that same decision; it never creates a replacement decision ID or changes the choice. A still-unknown response leaves the exact decision pending and prevents conflicting choice submission.
- Mark confirmation commit checks the expected credential revision against both the active attempt and current durable store state. The same-journal replacement race test verifies that the old response cannot confirm the mark or mutate the replacement offer.
- Candidate persistence fault coverage now injects a store write that commits then throws. The owner does not dispatch control traffic because its mandatory save call throws before the network boundary. This is the targeted candidate-save gate proof, separate from the earlier mutation that another `owns` check independently blocked.

### Final-tree inventory refresh

The following exact production-only queries were rerun after this follow-up. All search roots are production `Sources`; no test files are included. Match locations below are the complete output for each query. The earlier inventory sections retain the broader migration/storage and Settings/browser caller dispositions; this refresh records the new synchronization, route, event, mark, and decision seams and the final line locations for the caller paths.

For clarity, the initial inventory tables above preserve the locations captured before this follow-up. The following final-tree refresh supersedes their line numbers for the queries listed here.

**Credential load/save/delete query (final-tree locations):**

```text
rg -n --glob '*.swift' '(SPLPairingKeychain\.store|PairingCredentialStore\(|credentialStore\.(load|save|delete)|keychainStore\.(load|save|delete)|PairingStoring|deletePairing|delete\(after:)' Sources/solstone Sources/JournalMarkKit
```

- `SPLPairingKeychain.swift:23,38` — backend factory and login-keychain implementation.
- `PairingCredentialStore.swift:14,24,67` — protocol, serialized store owner, and initializer.
- `PairingCoordinator.swift:105,122,258,374,412,465,472,488,492,506,542,559,589,611,632,655,670,686,707,725,886,900,966,999` — coordinator construction, loads/writes, invalidation-owned deletion, decision/offer state, and replacement save. Deletion matches occur at 258 and 374 and remain downstream of durable invalidation.
- `TunnelLifecycleOwner.swift:320,341,412,988,1039,1057,1101,1122,1127,1144,1161,1162,2094` — store construction, candidate/reply/commit persistence, and invalidation-owned revoked-credential cleanup.
- `AppState.swift:1220,1373,1374,1655,1700,1806,2252` — durable read/production initialization, injected memory-store initializers, and browser credential restoration.
- The query has no `deletePairing` matches. No raw deletion API bypasses the serialized credential owner.

**Marker/baseline/candidate/decision/offer/invalidation query (final-tree locations):**

```text
rg -n --glob '*.swift' '(localMarker|initialMovePrepared|completedPortableBaseline|preparedCredential|legacyCleanupPending|replacementOfferShown|replacementOfferID|\.candidate|\.decision|\.invalidation)' Sources/solstone/CarriedPairingState.swift Sources/solstone/SPLPairingKeychain.swift Sources/solstone/PairingCredentialStore.swift Sources/solstone/PairingCoordinator.swift Sources/solstone/TunnelLifecycleOwner.swift Sources/solstone/SettingsView.swift
```

- `CarriedPairingState.swift:87,88,89,90,92,95,96,98,102` — durable state shape.
- `SPLPairingKeychain.swift:55,57,59,60,63,67,87,89,95,112,113,127,130,131,133,134,135,139,142,143,144,154,169,172,182,187,189,190,191,193,196,202,240,241,242,245,255,260,265,275,277,278,281,284,287,288,289,291,297,298,327,541` — initial move phases, local marker/baseline persistence, cleanup tombstone, and migration/adoption distinction.
- `PairingCredentialStore.swift:144,145,146,157,158,167,168,173,175,185,186,189,195,277,282,302,319,328,329,330,331,334,349,350,351,352,355,373,374,375,378,379,380,381,383,384,385,517,518,519,520,521,538,539,540,541,542,549` — ready/admission derivation, current ownership, invalidation lifecycle, and matching cleanup predicates.
- `PairingCoordinator.swift:277,279,310,324,326,460,461,470,487,490,508,509,510,544,545,546,561,562,563,591,592,593,613,614,621,630,673,674,675,676,704,706,774,851,871,873,877,878,880,893,895,897,898,996,997,998` — invalidation recovery, choice/offer/picker mutations and current-state revalidation. `1118` is unrelated pair-link endpoint candidates.
- `TunnelLifecycleOwner.swift:587,1020,1027,1032,1033,1034,1038,1042,1056,1100,1125,1126,1146,1150,1151,1165,1166,1167,2068` — rekey candidate ownership/commit and durable revoked-retirement guard. `1939` is unrelated transport endpoint candidates.
- `SettingsView.swift:2142,2143,2151,2152` — pending/unknown decision UI. `3151` is the UI device-name picker list, not durable migration state.

**Durable confirmation query (final-tree locations):**

```text
rg -n --glob '*.swift' '(journalMarkConfirmationStore\.(confirm|clear|load|confirmedJournal)|isJournalMarkConfirmed|clearJournalMarkConfirmation|recordJournalMarkConfirmed|clearConfirmedMark|JournalMarkConfirmationStore)' Sources/solstone Sources/JournalMarkKit
```

- `JournalMarkConfirmationDriver.swift:90,99,112,121` — clear only after unpair succeeds.
- `PairingCoordinator.swift:80,114,138,300,335,379,982` — hook, success-path clearing, and same/new journal handling.
- `SettingsView.swift:661,1349,1351,1470,1858,2663,2677` and `LocalJournalLinkFlow.swift:265` — read/presentation and transient relink display reset; durable confirmation clear only follows successful unpair/new-journal semantics.
- `JournalMarkConfirmationStore.swift:21,50` — durable UserDefaults owner and memory fake.
- `AppState.swift:941,1080,1113,1118,1119,1134,1158,1173,1175,1249,1250,1254,1260,1261,1262,1273,1293,1317,1343,1413,1415,1417,1707,1757,1758,1818,1820,1822,1864` — confirmation read/write, current admission gate, clear wiring, and test/production store construction.
- `JournalMarkConfirmationDriver+AppState.swift:8,18,101,102,112,113` and `JournalWindow.swift:95` — app wrappers and UI read.

**Browser custody commit and release:**

```text
rg -n --glob '*.swift' '(withOrdinaryBrowserAdmission|setCarriedPairingAdmissionCommit|beforeCustodyCommit|publishDeliveryAck\(|releaseProven\(|listingMatch\(|getSegmentsDay\()' Sources/solstone/PairingCredentialStore.swift Sources/solstone/BrowserUploadPlanner.swift Sources/solstone/BrowserIntakeOwner.swift Sources/solstone/AppState.swift Sources/solstone/BrowserIntakeStore.swift
```

- `PairingCredentialStore.swift:254` — `withOrdinaryBrowserAdmission` owns the final lock-held ready/generation/identity check.
- `BrowserUploadPlanner.swift:11,89,113,118,218,220,222,227,232,234,308,313,330` — browser list transport; final commit seam; ack-coordinate update and listing release inside that seam; ordinary POST ack publication and fresh POST release; physical listing matcher.
- `BrowserIntakeOwner.swift:291,292` — forwards the final commit closure to planner.
- `AppState.swift:2184,2185` — production injects the store-owned admission transaction.
- `BrowserIntakeStore.swift:2273,2305` — serialized ack write and payload release implementations.

**Invalidation callback, synchronous route revocation, and asynchronous cleanup:**

```text
rg -n --glob '*.swift' '(fenceOrdinaryTraffic\(|beginOrdinaryTrafficFence\(|completeOrdinaryTrafficFence\(|revokeOtherOrdinaryWork|revokeOrdinaryTraffic\()' Sources/solstone/AppState.swift Sources/solstone/TunnelLifecycleOwner.swift Sources/solstone/UploadCoordinator.swift Sources/solstone/PairingCoordinator.swift
```

- `AppState.swift:1427,1429` — callback enters owner fence and then awaits upload revocation.
- `TunnelLifecycleOwner.swift:552,554,556,557,558,563,578` — fence calls synchronous begin before either await, then async completion; begin revokes the ordinary route and complete disconnects/cancels sequencers.
- `UploadCoordinator.swift:291,293` — ordinary sync revocation closes the UI/progress gate and advances the SyncService epoch.
- `PairingCoordinator.swift:354,416,421` — pairing invalidation and admission recovery invoke the shared fence.

**All SyncService progress publication and central freshness handling:**

```text
rg -n --glob '*.swift' '(ProgressEnvelope|progressEnvelopeStream|emitProgress\(|handleProgressEnvelope|minimumProgressEpoch|progressContinuation\.yield)' Sources/solstone/SyncService.swift Sources/solstone/UploadCoordinator.swift
```

- `SyncService.swift:37,182,183,252,253,290,291,292` — envelope type, stream setup, and single emitter that tags events with the captured run context/epoch while preserving the existing raw stream.
- `SyncService.swift:376,526,539,563,564,577,588,590,596,598,615,640,657,682,690,756,767,777,787,796,800,811,818,827,834,840,846,853,962,999,1001,1045,1055,1078,1106` — all ordinary event variants flow through `emitProgress`; none directly bypass the envelope stream.
- `UploadCoordinator.swift:134,293,410,413,419,420` — epoch state, stream consumer, and centralized guard before event dispatch.

**Sync acknowledgment, delivery, and file-custody checks:**

```text
rg -n --glob '*.swift' '(ordinarySyncIsCurrent|withOrdinarySyncAdmission|persistAcknowledgment|removeConfirmedSegment|LastJournalDeliveryPayload|lastContactStore\.write|revokeOrdinaryTraffic)' Sources/solstone/SyncService.swift Sources/solstone/UploadCoordinator.swift Sources/solstone/PairingCredentialStore.swift
```

- `PairingCredentialStore.swift:212,235` — current pairing context predicate and synchronous invalidation-serialized mutation gate.
- `UploadCoordinator.swift:291,293,456,502,508` — revoke, current-context last-contact publication, and successful delivery persistence after event freshness check.
- `SyncService.swift:150,200,242,282,299,305,313,330,416,444,484,501,644,707,1039,1040,1394,1522,1541,1558,1569,1582,1637,1648,1665,1676,1689,1748,1761,1775,1790,1801,1814` — acknowledgment persistence and every file/directory remove, preservation, or quarantine path are called through the captured-context admission gate; network awaits are followed by current context/epoch checks.

**Mark answer read and commit ownership:**

```text
rg -n --glob '*.swift' '(markAnswerRevisionMatches|recordJournalMarkConfirmed|beginJournalMarkConfirmationAttempt|isCurrentJournalMarkAttempt|markAnswerIsCurrent|fetchMark:|startJournalMark)' Sources/solstone/AppState.swift Sources/solstone/JournalMarkConfirmationDriver+AppState.swift Sources/solstone/PairingCredentialStore.swift Sources/JournalMarkKit/JournalMarkConfirmationDriver.swift
```

- `PairingCredentialStore.swift:224` — rejects mark answer when expected revision or current durable admission is stale.
- `AppState.swift:941,1158,1164,1193,1209,1224,1237,1250` — migration-confirmation entry, commit guard, revision matcher, attempt capture/current check, and subsequent confirmation presentation.
- `JournalMarkConfirmationDriver+AppState.swift:8,18,33,39,46,53,64,68,89,94,139,145,147,152,161,174,181,187` — app wrappers capture/recheck revision before fetch and answer completion.
- `JournalMarkConfirmationDriver.swift:130,145,153` — shared fetch-and-answer sequence invokes those owner closures.

**Fresh replacement conflict/replay and carried-decision freshness:**

```text
rg -n --glob '*.swift' '(replayConflictedFreshDecision|reconcileConflictedDecision|persistAndSubmitFreshChoice|decisionID|decision_unknown|CarriedPairingControlError\.conflict)' Sources/solstone/PairingCoordinator.swift
```

- `PairingCoordinator.swift:547,548,578,579,621,679,680,688,693,704,715,737,743,750,759,765,774,779,786,788,790,794,798,806,815,824,830,838,851,856,862,871,873,877,878,880` — replacement persists and uses its stable decision ID/exact target, routes 409 to exact same-body replay for fresh choices or exact operation status for carried choices, and retains pending unknown decisions. Fresh terminal reply must match operation, CID, state, and expected replaced CID; current-record checks also reject invalidation.

**Candidate persistence boundary and durable ownership recheck:**

```text
rg -n --glob '*.swift' '(saveCarriedPairingRecord\(|owns\(.*operationID)' Sources/solstone/TunnelLifecycleOwner.swift Sources/solstone/PairingCredentialStore.swift
```

- `PairingCredentialStore.swift:19,95,99,107,120,271,320,335,356,387` — serialized protocol, durable record writes, and current operation ownership.
- `TunnelLifecycleOwner.swift:591,1039,1057,1063,1084,1093,1101,1117,1161,1162` — candidate is persisted before migration state/rekey dispatch; every awaited control result is followed by current credential/operation ownership validation before mutation.

**Final inventory reruns for retirement, transport, browser, Settings, wrappers, and relink:**

The exact queries and complete match locations were rerun using the query blocks already recorded in “Pairing invalidation, retirement, deletion, and recovery,” “Lifecycle, transport, client-self, relay, and ordinary admission,” “Browser intake, route, listing, receipt, and release,” and “Settings actions, mark wrappers, local relink, and same-machine pairing.” The final added or moved matches are:

- Invalidation/retirement query: `PairingCoordinator.swift:201,229,255,258,261,262,285,286,333,334,348,359,370,374,376,377,390,394,435,439,987`; `PairingCredentialStore.swift:290,324,338,359`; `TunnelLifecycleOwner.swift:607,609,1241,1437,1648,1840,1847,2054,2078,2093,2094,2096,2097`; `AppState.swift:835,836,1420,1825`; `SettingsView.swift:2457,2618,2675`; `JournalMarkConfirmationDriver+AppState.swift:105,116`. `PairingCoordinator` owns explicit pre-retirement invalidation; lifecycle's direct retirement only follows durable invalidation for journal-revoked credentials; Settings and mark wrappers use the coordinator.
- Transport/admission query: `AppState.swift:2182`; `TunnelLifecycleOwner.swift:137,494,495,595,626,660,665,671,726,748,836,844,850,865,911,914,923,948,959,967,972,975,989,993,1070,1079,1087,1173,1190,1255,1300,1317,1340,1390,1505,1510,1516,1627,1686,1976,1979`. Ordinary install, state publication, post-jobs, startup/reconnect, and replacement are admission checked; lines 1070/1079/1087 are the isolated carried-key migration control connection and its GET/POST. Connected state callbacks are additionally rejected by `handleStateTransition` at 626 if durable admission is no longer ready.
- Browser intake query: `BrowserUploadPlanner.swift:23,109,126,218,222,232,234,276,308,313,330`; `BrowserIntakeOwner.swift:255,276,286,288,300,303,310,321,426,530,539,573,593,635`; `TunnelLifecycleOwner.swift:134,142,624`; `AppState.swift:554,1076,1087,1181,1906,2214`. Intake accepts and retains while planner egress, list reconciliation, POST, and release require current route/admission; both ordinary POST and listing receipt release are covered by the credential-store transaction above.
- Settings action query: `AppState.swift:932`; `PairingCoordinator.swift:162,210,234,503,525,533,539,555,608`; `SettingsView.swift:1360,1368,2035,2068,2074,2107,2111,2265,2288,2297,2310,2314,2321,2576,2591,2658,2668,2675,2930`. The same-device choice has no default selection; replacement target submission is only from the explicit native confirmation action.
- Mark cancel/reject query: `JournalMarkConfirmationDriver.swift:66,82,89,90,98,99,111,112,120,121`; `JournalMarkConfirmationDriver+AppState.swift:16,21,99,100,101,102,105,110,111,112,113,116`; `SettingsView.swift:634,640,649,2663,2675,2677`; `PairingCoordinator.swift:80,114,138,239,300,335,379,982`; `AppState.swift:1260,1261,1262,1317,1413,1415,1417,1818,1820,1822`. Driver wrappers await successful unpair before clearing/dismissing; explicit Settings mark reset is transient local relink behavior.
- Same-machine/local relink query: `SameMachineHomePairing.swift:45,179,186,196,197`; `LocalJournalLinkFlow.swift:265`; `AppState.swift:147,927,931,1317,1354,1601,1653,1698`; `SettingsView.swift:263,2663,2677,2925,2929`. Automatic and Settings ceremonies submit the exact pair link through `PairingCoordinator`; local relink clears displayed mark state before a fresh confirmation flow.

### Follow-up test and mutation evidence

Final focused follow-up command, run after all mutations were restored:

```text
hop check --allow-capture -n 180 -- swift test --filter 'BrowserSpoolLifecycleTests.durableInvalidationBetweenBrowserListingAndCustodyCommitRetainsPendingBytes|TunnelLifecycleOwnerTests.ordinaryRouteIsRevokedBeforeInvalidationWaitsForUploadCancellation|UploadCoordinatorTests.queuedUntaggedProgressFromRevokedRunIsDiscardedAfterSamePairingResumes|PairingCoordinatorTests.freshReplacementConflictReplaysTheSameDurableDecisionAndExactTarget|PairingCoordinatorTests.unresolvedFreshReplacementConflictKeepsTheExactDecisionPending|JournalMarkConfirmationGateTests.lateMarkAnswerAfterSameJournalCredentialReplacementCannotConfirmOrShowOffer|TunnelLifecycleOwnerTests.candidatePersistenceErrorNeverDispatchesWhenTheWriteMayHaveCommitted'
```

Exit 0; all 7 selected tests passed in 5 suites. `git diff --check` is recorded after this report update below.

```text
hop check --allow-capture -n 120 -- swift test --filter 'SyncServiceTests.ordinaryRevocationEpochStopsHeldUploadBeforeAcknowledgment|SyncServiceTests.durableInvalidationAfterUploadResponseLeavesBytesUnacknowledgedAndUndelivered'
```

Exit 0; both delayed-response/custody tests passed in the `SyncService` suite.

```text
hop check --allow-capture -n 80 -- swift test --filter JournalWindowCompositionTests.revokedOrdinaryRouteRemovesAnAlreadyLoadedWebView
```

Exit 0; the already-open WebView revocation test passed.

`hop check --allow-capture -- git diff --check` exited 0 after the report update.

| New gate | Temporary mutation and actual red | Restore and green evidence |
|---|---|---|
| Browser final custody commit is serialized with durable admission — `BrowserSpoolLifecycleTests.durableInvalidationBetweenBrowserListingAndCustodyCommitRetainsPendingBytes` | Replaced the `.ready` predicate inside `withOrdinaryBrowserAdmission` with unconditional admission. The focused test exited 1: the period became `delivered` instead of remaining `finalized`, and the payload had been removed (file-not-found error 260). | Restored the durable predicate; same test exited 0 and is in the 7-test final command. |
| Route is synchronously revoked before cancellation can suspend — `TunnelLifecycleOwnerTests.ordinaryRouteIsRevokedBeforeInvalidationWaitsForUploadCancellation` | Moved `await revokeOtherOrdinaryWork()` before `beginOrdinaryTrafficFence`. The focused test exited 1 with four failures: route not revoked, `localPort` still 18282, state still connected, and browser route still published while cancellation was held. | Restored begin-before-await order; same test exited 0 and is in the 7-test final command. |
| All progress events use centralized freshness — `UploadCoordinatorTests.queuedUntaggedProgressFromRevokedRunIsDiscardedAfterSamePairingResumes` | Removed the envelope epoch comparison. The focused test exited 1: stale `.offline` replaced `.notSynced` and changed `lastError`/health state after invalidation and same-pairing resumption. | Restored the epoch and context guard; same test exited 0 and is in the 7-test final command. |
| Late mark answer revision is rejected — `JournalMarkConfirmationGateTests.lateMarkAnswerAfterSameJournalCredentialReplacementCannotConfirmOrShowOffer` | Weakened `markAnswerRevisionMatches` to check only the active attempt. The focused test exited 1: the old answer committed, confirmation was stored, and the replacement offer record changed. | Restored both expected/current revision comparisons; same test exited 0. |
| Candidate save must succeed before migration dispatch — `TunnelLifecycleOwnerTests.candidatePersistenceErrorNeverDispatchesWhenTheWriteMayHaveCommitted` | Mutated the candidate `saveCarriedPairingRecord` call from throwing `try` to `try?`. Injected store wrote the candidate and then threw. The focused test exited 1: migration-state request count became 1 instead of 0 and candidate request snapshot was nonempty. This directly bypassed the candidate-save gate; no independent ownership gate stopped dispatch. | Restored throwing save; same test exited 0, including in the final 7-test command. |

Fresh 409 tests `PairingCoordinatorTests.freshReplacementConflictReplaysTheSameDurableDecisionAndExactTarget` and `PairingCoordinatorTests.unresolvedFreshReplacementConflictKeepsTheExactDecisionPending` both passed in the final focused follow-up command. The first also has the isolated bypass red/restore/green proof above. It proves same persisted UUID/choice/CID on replay; the second preserves the exact decision pending when unresolved. Existing broader 80/320/88 and 133-test sync/upload suites were not rerun in this follow-up.

The six artifact source blobs were re-read from `git show 1e432dba3ecdfa43789c25f97077fdc3e71fab59:<path>` and each copied file independently rehashed during this follow-up. Five supplied 64-character digests match source and copy. The supplied device migration vectors digest is exactly `3ba1bb508a0cd5756626c6246fbff77573c54538db60c8e7f938e38b306ef9c` (63 hex); source and copy are byte-identical at actual SHA-256 `3ba1bb508a0cd5756626c6246bfbff77573c54538db60c8e7f938e38b306ef9c`. Neither source repository nor vendored bytes were modified.

## Third-audit follow-up

### Changes

- `BrowserUploadPlanner` now commits a validated ordinary `.ok`/`.duplicate` POST receipt and payload release inside the existing `BrowserAdmissionCommit`; collision responses persist a receipt but retain payload until physical coordinates arrive. Listing reconciliation accepts coordinate-free items only for the exact ordinary canonical key, without `original_key`, with valid held file custody and exactly one matching local pending period. Coordinate-bearing candidates still require a complete pair and one matching local candidate; multiple listing or local candidates retain custody.
- `SPLPairingKeychain.loadCarriedPairingRecord()` now clears the record's cached marker when a completed portable baseline exists but the separate device-only marker item is absent. `SPLPairingKeychain.load()` only recovers a completed baseline or retries its cleanup tombstone when the independently loaded local marker matches the baseline. Mismatching/absent markers return the login-keychain credential for the existing migration-required path and do not retry cleanup. Unreadable marker reads still throw. `localMarkerMatches` is shared by the backend and credential admission owner. A carried rekey that commits on a device whose marker does not match the old baseline writes a new local marker before completing the new baseline.
- Migration-state and decision response decoders require every schema-required nullable key to be present, while accepting explicit `null`. Rekey response decoding now rejects unknown envelope keys as required by the pinned schema.
- The exact production browser query and current matches above were rerun for this report update. `BrowserUploadPlanner.deliver` validates the staged POST response, then uses `carriedPairingAdmissionCommit` for durable ack plus ordinary custody release; collision responses remain ack-only until a coordinate-bearing listing resolves. `listingMatch` uses the exact canonical key only as a lookup hint for ordinary coordinate-free entries and refuses ambiguous local or server candidates.

### Final focused checks

All commands below ran through `hop check --allow-capture`. No broad suite, full CI, real OS keychain, hardware, signing, or external repository write was run.

| Command | Result |
|---|---|
| `hop check --allow-capture -n 70 -- swift test --filter 'BrowserSpoolLifecycleTests.uniqueFreshPostCustodyReleasesPayloadAndRetryConverges|BrowserSpoolLifecycleTests.uniqueCoordinateFreeListingReconcilesCustodyAfterLocalReleaseFailure|BrowserSpoolLifecycleTests.ackReconciliationRequiresCanonicalKeyAndEveryBindingField|BrowserSpoolLifecycleTests.ackParentSyncFailureRetriesDurabilityWithoutReupload|BrowserSpoolLifecycleTests.capturedAckSurvivesCredentialReplacementButStopCancelsUpload|BrowserSpoolLifecycleTests.durableInvalidationBetweenBrowserListingAndCustodyCommitRetainsPendingBytes|BrowserSpoolLifecycleTests.equalByteCollisionTwinsRemainAmbiguousAndUnmatchedListingPosts|BrowserSpoolLifecycleTests.physicalAliasReassignmentPersistsAcrossRestart'` | Exit 0; 8 selected tests passed in 1 suite. |
| `hop check --allow-capture -n 65 -- swift test --filter 'SPLPairingKeychainTests|PairingCredentialStoreTests.completedBaselineAndMatchingMarkerAdmitInterruptedCompletion|PairingCredentialStoreTests.completedBaselineDoesNotAdoptWhenActualMarkerIsAbsentOrMismatched|PairingCredentialStoreTests.unreadableDeviceMarkerStateBlocksAdmission|PairingCredentialStoreTests.markerWithoutBaselineNeverAdmitsAndPreparedMoveRequiresRecovery|TunnelLifecycleOwnerTests.interruptedCompletedBaselineWithAbsentOrMismatchedMarkerCreatesFreshCandidate|TunnelLifecycleOwnerTests.candidatePersistenceErrorNeverDispatchesWhenTheWriteMayHaveCommitted'` | Exit 0; 8 selected tests passed in 3 suites, including both absent/mismatch argument cases. |
| `hop check --allow-capture -n 65 -- swift test --filter 'CarriedPairingControlTests.migrationStateRequiresNullableFieldsAndAllowsFreshPairTerminalState|CarriedPairingControlTests.decisionReplyRequiresExplicitNullableFieldsAndValidatedCurrentCID|CarriedPairingControlTests.migrationAndDecisionRepliesRejectUnknownResponseKeys|CarriedPairingControlTests.rekeyResponseRejectsUnexpectedEnvelopeKeys|CarriedPairingControlTests.rekeyEnvelopeBindsOperationProtocolStateAndCurrentCID'` | Exit 0; 5 tests passed in 1 suite. |
| `hop check --allow-capture -n 40 -- swift test --filter TunnelLifecycleOwnerTests.candidatePersistenceErrorNeverDispatchesWhenTheWriteMayHaveCommitted` | Exit 0; the candidate-save boundary fixture passed after the mutation restore. |
| `hop check --allow-capture -- git diff --check` | Exit 0; no whitespace errors after this report update. |

### Current red/restore/green mutation proofs

Each row below was independently snapshotted under `/var/tmp/carried-pairing-followup`, mutated at one guard, tested through `hop check`, restored from the snapshot, and checked with `cmp -s` plus SHA-256 before the green rerun. The hashes below are the post-restore hashes; all `cmp -s` commands exited 0.

| Gate, source mutation, and guarding test | Actual red result | Restore and green evidence |
|---|---|---|
| Ordinary fresh browser custody release. In `Sources/solstone/BrowserUploadPlanner.swift`, flipped the release condition from `response.status != .collision` to `.collision`. Guarded by `BrowserSpoolLifecycleTests.uniqueFreshPostCustodyReleasesPayloadAndRetryConverges`. | Exit 1. Assertions failed: period did not reach `delivered`; payload still existed; retry count was 2 rather than 1. | Restored from snapshot; `cmp -s` exit 0; SHA-256 `b7291ace1290994c4d4d766a3c3b1286469ad25243a6599a4ac9aaa2d51a8ab2`. Same test rerun exit 0. |
| Completed-baseline marker check. In `Sources/solstone/SPLPairingKeychain.swift`, changed `localMarkerMatches` to always return true; this is the shared predicate used by keychain recovery and `PairingCredentialStore.admission`. Guarded by `PairingCredentialStoreTests.completedBaselineDoesNotAdoptWhenActualMarkerIsAbsentOrMismatched`. | Exit 1. Both absent and mismatched marker cases returned `.ready` instead of `.migrationRequired`. | Restored from snapshot; `cmp -s` exit 0; SHA-256 `fe41dc2691e473769b5c0bbb4bee8d66fd20cff2f729540177b78facc6d499a3`. Same test rerun exit 0. |
| Required nullable response keys. In `Sources/solstone/CarriedPairingControl.swift`, changed the missing-key check in `decodeRequiredNullable` to return `nil`. Guarded by `CarriedPairingControlTests.migrationStateRequiresNullableFieldsAndAllowsFreshPairTerminalState`. | Exit 1. Three missing-key fixtures decoded successfully instead of throwing. | Restored from snapshot; `cmp -s` exit 0; SHA-256 `eb8734855447e0f45634dfdb6b6a3facec957fafa9da6b14beb64b743f56cc55`. Same test rerun exit 0. |
| Unknown rekey envelope key. In `Sources/solstone/CarriedPairingControl.swift`, removed the `rejectUnknownKeys` call from `CarriedPairingRekeyResponse.init(from:)`. Guarded by `CarriedPairingControlTests.rekeyResponseRejectsUnexpectedEnvelopeKeys`. | Exit 1. The object with an extra `unexpected` key decoded into `CarriedPairingRekeyResponse`. | Restored from snapshot; `cmp -s` exit 0; SHA-256 `eb8734855447e0f45634dfdb6b6a3facec957fafa9da6b14beb64b743f56cc55`. Same test rerun exit 0. |
| Candidate save must succeed before control dispatch. In `Sources/solstone/TunnelLifecycleOwner.swift`, changed the candidate `saveCarriedPairingRecord` call from `try` to `try?`. Guarded by `TunnelLifecycleOwnerTests.candidatePersistenceErrorNeverDispatchesWhenTheWriteMayHaveCommitted`, whose memory store commits then throws. | Exit 1. `migrationStateCount` was 1 instead of 0 and the candidate request snapshot was nonempty. | Restored from snapshot; `cmp -s` exit 0; SHA-256 `dcb00bb5764d4ccacbc76d951b2d44715317d1cc942bc72b270f676860589851`. Same test rerun exit 0. |

### Artifact recheck

The pinned source commit object exists in the read-only source repository. For each row, `git show 1e432dba3ecdfa43789c25f97077fdc3e71fab59:<path>` was written to a scratch file under `/var/tmp`, compared byte-for-byte to the installed copy (`cmp` exit 0), and independently hashed. The copied files are unchanged.

| Source and installed path | Supplied expected SHA-256 | Pinned source SHA-256 | Installed SHA-256 | Bytes equal | Expected matches source |
|---|---|---|---|---|---|
| `contracts/device-migration/v1.schema.json` → `vendor/contracts/device-migration/v1.schema.json` | `5ea0ce5bf0bc5f07233f05dda3334ccea3bf173363fcd4fd4cdcd9479130a373` | `5ea0ce5bf0bc5f07233f05dda3334ccea3bf173363fcd4fd4cdcd9479130a373` | `5ea0ce5bf0bc5f07233f05dda3334ccea3bf173363fcd4fd4cdcd9479130a373` | yes | yes |
| `contracts/device-migration/v1.vectors.json` → `vendor/contracts/device-migration/v1.vectors.json` | `3ba1bb508a0cd5756626c6246fbff77573c54538db60c8e7f938e38b306ef9c` (63 characters) | `3ba1bb508a0cd5756626c6246bfbff77573c54538db60c8e7f938e38b306ef9c` | `3ba1bb508a0cd5756626c6246bfbff77573c54538db60c8e7f938e38b306ef9c` | yes | no; expected omits one `b` after `6246` |
| `docs/openapi/client-ingest-contract/manifest.json` → `vendor/contracts/client-ingest-contract/manifest.json` | `86d4358916a0303c29a8e61c6d1e48ef1939d0b5a2f042ae617958b9d0c1a5a8` | `86d4358916a0303c29a8e61c6d1e48ef1939d0b5a2f042ae617958b9d0c1a5a8` | `86d4358916a0303c29a8e61c6d1e48ef1939d0b5a2f042ae617958b9d0c1a5a8` | yes | yes |
| `docs/openapi/client-ingest-contract/projection.openapi.json` → `vendor/contracts/client-ingest-contract/projection.openapi.json` | `db75a94ab97e83c56603e44d9313db86a94a2d9c4a920deaf090fe0f3358b8b0` | `db75a94ab97e83c56603e44d9313db86a94a2d9c4a920deaf090fe0f3358b8b0` | `db75a94ab97e83c56603e44d9313db86a94a2d9c4a920deaf090fe0f3358b8b0` | yes | yes |
| `docs/openapi/client-ingest-contract/vectors.json` → `vendor/contracts/client-ingest-contract/vectors.json` | `7c61c1238184e1440110801478daf714aba05b2472338db98c12cd508b303d0f` | `7c61c1238184e1440110801478daf714aba05b2472338bd98c12cd508b303d0f` | `7c61c1238184e1440110801478daf714aba05b2472338bd98c12cd508b303d0f` | yes | no; the `db`/`bd` pair is transposed |
| `docs/openapi/client-ingest-contract/fixtures/wire-behavior.json` → `vendor/contracts/client-ingest-contract/fixtures/wire-behavior.json` | `035e59297af21da998984910b4aa6a850d7e2e1225c79019045381bf3e17e708` | `035e59297af21da998984910b4aa6a850d7e2e1225c79019045381bf3e17e708` | `035e59297af21da998984910b4aa6a850d7e2e1225c79019045381bf3e17e708` | yes | yes |

The previously unverified in-memory durable-state/refusal gates now have individual red/restore/green rows above; candidate persistence has the direct save-bypass proof in the earlier focused proof table. No real OS keychain, signing, or hardware proof is claimed. Caller-owned visual review, signed-keychain/ACL proof, two-device and backup/restore proof, and final `hop check --ship-gate --allow-capture -- make ci` remain outstanding. No package/version, protocol, entitlement/profile, pause/capture behavior, external repository, signing, or commit state was changed.
