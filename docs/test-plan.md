# mac test plan

This plan covers the solstone app on mac: build, installation, permissions,
screen and audio intake, the journal connection, and updates. The journal app
has its own package and tests in
[solstone-journal/platforms/macos](https://github.com/solpbc/solstone-journal/tree/main/platforms/macos).

## what “macos supported” means

The minimum is **macOS 15.0**, matching `Package.swift`, the app's
`LSMinimumSystemVersion`, and the native build target. macOS 14 is outside the
supported floor. Both Apple silicon and Intel are build targets; a build for
one architecture is not a live test of the other.

Supported means the release meets the checks below on its named test systems,
the package targets the stated minimum, and any known limitation is recorded
with the result. It does not mean every Mac, audio device, dock, or OS minor
version has been tested. Record the OS version and build, architecture, app
version, source commit, package digest, and test inputs with every live result.
An unrun check is unrun, and an inaccessible test system is inconclusive.

The current physical test systems cover macOS 26 and 27. A macOS 15 virtual
machine can establish installation and software compatibility; it cannot
establish real microphone, dock, lid-close or Bluetooth behavior. Those hardware
combinations are outside this plan's required qualification. Do not describe a
virtual-machine result as a physical-Mac result.

## before a change lands

Run `make ci` on the final code tree, plus the affected tests while developing.
It runs Swift and script tests through the repository's serialized runner.
It uses an isolated test keychain and writes the full log to `scratch/ci.log`.
Run it directly so its exit status remains the result of the check.

| Area | Regression coverage in `make ci` |
| --- | --- |
| Permissions and desired sources | `CaptureCoordinatorEvidenceTests`, `CaptureCoordinatorTests`, `SettingsRestartContractTests` |
| Multiple displays, display loss and recovery | `CaptureManagerDisplayRecoveryTests`, `CaptureManagerCommitTests`, screenshot-capturer and exclusion-planner tests |
| Pause, lock, sleep and resume | `PauseManagerTests`, `CaptureLifecycleManagerRecoveryTests`, `CaptureManagerStateTests` |
| Audio boundaries and device changes | `AudioAppendAfterFinishTests`, `AudioFinalizeExceptionTests`, `AudioSourceReadinessTests`, `MicrophoneSelectionTests`, `AudioTimelineTests` |
| Pending material and journal receipts | Sync-service, upload-coordinator and ingest-acknowledgment tests |
| Settings and menu state | `StatusHealthSummaryTests`, `MenuContentTests`, `SettingsSceneRootTests`, settings and AX-contract tests |
| Updates and deferred installation | `UpdateKitTests`, appcast and preflight script tests |

These tests establish owned logic with controlled inputs. They do not establish
that macOS granted access, a real display produced frames, a real microphone
produced sound, or a signed update installed correctly.

## end-to-end qualification

Use disposable test journals and dedicated test Macs. Do not use an owner's
Mac or journal. Keep synthetic screen and audio inputs distinctive enough that
reading the resulting files can identify their source.

1. **Build.** Record the source commit and a green `make ci`. Build the signed
   distribution app using the release Make targets. Check the bundle version,
   both executable architectures, minimum OS, signature and entitlements. A
   local ad-hoc app can exercise UI and intake, but cannot establish saved
   pairing; see [local test builds](local-test-build.md).
2. **Install.** On the test Mac, install the exact disk image being qualified.
   Check its digest and the installed bundle version. Launch from Applications
   and check that one instance runs. Verify the app is usable after closing
   and reopening Settings. A clean installation and an update are separate
   cases.
3. **Permissions.** From a clean test state, turn on each source and follow its
   permission action. Check granted, denied and restricted states where the OS
   can supply them. Check the screen permission by reading a new frame and the
   microphone permission by decoding new audio. A displayed grant alone is not
   proof. Revoke screen access while intake runs and check that the failure is
   visible. Check macOS's explicit Stop Sharing action separately from a fault.
4. **Screen intake.** Put different synthetic patterns on two physical or
   virtual displays. Read decoded frames from each per-display video; check
   dimensions and content, rather than file presence alone. Attach, detach and
   reconnect a display with Settings open and after closing it. The app must
   stay responsive and show any requested screen that is not coming through.
   Keep a missing-screen warning visible while microphone audio or another
   display remains healthy. Check recovery with new frames.
5. **Audio intake.** Use a test tone and the selected test microphone. Decode
   the resulting tracks before and after a segment boundary, pause/resume,
   sleep/wake and a selected-device change. Check timing and pitch, not merely
   a nonempty container. Check an empty device list with and without permission;
   the recovery action must match the observed state. Keep device-specific
   limits in the result.
6. **Pause shortcut.** Start with the shortcut off. Assign a chord, switch to
   another app, pause and resume, and check the menu icon and actual new media.
   Holding the keys must toggle once. A system-reserved or already-registered
   chord must show a conflict. Recording or cancelling a chord must not change
   pause. Relaunch preserves an owner-held pause. Resuming an owner hold must
   not override a lock, sleep or protected-video pause. Verify the registration
   path does not request Accessibility or Input Monitoring.
7. **Journal delivery.** Link a disposable journal and confirm its mark. Run
   screen and audio intake through a finished segment, then read that segment
   in the destination journal. Pause sync and interrupt the connection: local
   waiting must remain visible and pending material must survive relaunch.
   Reconnect and confirm journal receipt before expecting default local
   cleanup. Check the separate option that keeps confirmed debugging copies.
   Pausing intake and pausing sync have different effects.
8. **Updates.** Use the signed disk image and controlled update feed. Exercise
   a fresh install and an update from the previous supported app, including a
   deferred install and relaunch. Read the installed version back and check
   that pairing, settings and an owner-held pause survive. Check feed failure
   without claiming an update completed. Run the native release profiles for
   fresh use, upgrade and private-link delivery on the exact release bytes.

`make integration-native` supplies an additional opt-in door/proxy/transport
check against an isolated native journal. It requires the two explicit runtime
and fixture inputs documented in the README. It complements these checks;
it is outside `make ci` and does not substitute for signed installation.

## result and release decision

Keep a result table with each check marked pass, fail, unrun or inconclusive,
and link the receipts. For each known mac-only crasher, record its broad trigger,
affected build, fix and reproduction result, or an explicit open engineering
owner. Review open project issues, defect records, lab crash reports
and recent gate logs; qualify new support reports through the support process
without copying personal content into engineering evidence. Search results and
crash-report files are candidates, not a count of current defects.

A release has no unresolved known mac-only crasher, passes its native release
profiles, and names any accepted coverage limit. A green unit gate alone does
not make that claim. A change landing on main is separate from publication.
