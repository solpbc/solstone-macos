# Accessibility Identifiers

This document defines the engineering contract for Solstone's accessibility identifiers and values. The source of truth for exact identifier strings is `Sources/solstone/AXID.swift`; do not duplicate the registry in docs or view code.

## Identifier Grammar

Enumerable identifiers use:

```text
<surface>.<section>.<element>[.<key>][.state]
```

Allowed surfaces are `menubar`, `settings`, `installer`, `updates`, and `about`. Each dot-separated segment must match `[a-z][a-zA-Z0-9-]*`, and AXID tests enforce the full expression:

```text
^(menubar|settings|installer|updates|about)(\.[a-z][a-zA-Z0-9-]*)+$
```

View code must reference `AXID` constants or functions. It must not pass inline string literals to `.accessibilityIdentifier(...)` or `.accessibilityValue(...)`.

## Value Tokens

`.accessibilityValue(...)` is the polling channel for state. Values are always `String` values. Closed state enums use `.axToken`, numeric/progress states use raw integer strings, and stable text or boolean state uses `String` variables. Do not use `accessibilityCustomContent`.

State tokens match:

```text
^[a-z][a-z_]*$
```

| State source | Tokens |
| --- | --- |
| `RowStatus` | `pending`, `running`, `ok`, `failed` |
| `InstallerCardState` | `detecting`, `absent`, `installing`, `installed_placeholder`, `done`, `installed_current`, `installed_unknown`, `failed`, `upgrade_failed`, `externally_managed` |
| `AutoTestState` | `verifying`, `success`, `failure` |
| `DoctorStatus` | `ok`, `warn`, `fail`, `skip`, `unknown` |
| `UploadCoordinator.Status` | `not_synced`, `syncing`, `synced`, `uploading`, `retrying`, `offline` |
| `ConnectionTestState` | `idle`, `testing`, `success`, `failure` |
| `UpdateState` | `idle`, `checking`, `update_available`, `downloading`, `extracting`, `ready_to_install`, `installing`, `up_to_date`, `error` |
| `SettingsView.SidebarBadgeState` | `attention`, `done`, `none` |
| Permission state | `granted`, `denied`, `waiting` |
| Menubar icon state | `recording`, `offline`, `paused`, `error` |
| Menubar status row state | `permissions`, `error`, `pipeline_dead`, `pipeline_restarting`, `pipeline_missing`, `local_only`, `offline`, `paused`, `observing`, `stopped` |

Numeric values publish raw integer strings. Examples include upload checked/total/pending counts, next-segment seconds, update download/extract percentages, and model download percentage. The harness owns formatting.

## Runtime Keys

Some identifiers include runtime keys verbatim as their final segment:

- Microphone CoreAudio UIDs.
- Privacy excluded app names.
- Privacy title patterns.

These runtime identifiers are exempt from the enumerable grammar because UIDs and operator-entered values may contain dots, colons, uppercase letters, spaces, or punctuation. AXID tests only check prefix stability and injectivity for these functions.

Runtime uniqueness assumptions:

- Microphone UIDs are unique per CoreAudio device identity.
- Excluded app entries and title patterns are unique through the settings UI's case-insensitive add path.
- Doctor check names are stable and unique at runtime. `AXID.Installer.doctorCheck(_:)` slugs names by lowercasing, replacing runs of non-alphanumeric characters with `-`, and trimming leading/trailing `-`.

## Companion Elements

When a state or number has no always-rendered host, add a zero-size AX companion inside a stable enclosing view:

```swift
Color.clear
    .frame(width: 0, height: 0)
    .accessibilityElement()
    .accessibilityIdentifier(...)
    .accessibilityValue(value)
```

Use an existing always-rendered `Text`, `LabeledContent`, or composite row instead when that host is cleaner. For composites, apply grouping first, then identifier and value on the grouped container.

Containers whose children must remain independently queryable stay ungrouped. This includes installer step rows, doctor checklist rows, microphone device rows, and privacy list entries.

## Validation

Static test coverage:

- `swift test --filter AXID` checks grammar, uniqueness, tokens, runtime-key behavior, and the literal-grep guard.
- `swift test --filter WireUp` checks source references to `AXID` in each surface. These tests prove source wire-up presence only; they do not prove live AX-tree attachment.
- `swift test --filter SnapshotTests` checks that grouping and zero-size companions do not collapse rendered content.

Device-phase validation should dump the live accessibility tree for the settings window, installer card, updates tab, about window, and menu bar extra after launch. Confirm identifiers and values are present for the current visible state and after driving state transitions such as permission waiting, connection testing, upload syncing, update progress, and menu icon status.

SwiftUI's `.menuBarExtraStyle(.menu)` may not propagate every menu identifier consistently. Wire the menubar idiomatically and validate on device. If propagation blocks the harness later, candidate follow-ups are an AppKit `NSMenu` bridge or a `.menuBarExtraStyle(.window)` UX change.
