# Changelog

All notable changes to solstone will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- the permissions screen reads your real microphone setting instead of saying it couldn't check. a microphone sol has never asked about now offers to ask, and one that is off or restricted says which. reported by Dave Smith.
- a microphone you have already allowed no longer makes "check my setup" report that some setup checks are unavailable. reported by Dave Smith.
- change your microphone setting while sol is running and the menu bar icon and the permissions screen now agree about it, instead of one saying allowed while the other still asks for it.

## [1.4.9] - 2026-07-25

### Added
- opening your journal from sol's menu or a notification now shows it in a window inside sol instead of your browser. the window uses your current journal connection and shows when it is waiting, loading, ready, or needs a retry.

### Fixed
- clicking a notification while your journal is unavailable now opens the journal window and waits for the connection instead of doing nothing.
- connection errors that might be temporary no longer make sol forget your journal pairing.


## [1.4.8] - 2026-07-24

### Fixed
- your private link reconnects after your mac locks, sleeps, wakes, or comes back from a network blackhole. reported by Dave Smith.
- your private link now prefers the direct home-network path before trying the relay. reported by Dave Smith.
- your private link can still reach your journal when a VPN is up and the home-network address only works through it. reported by Dave Smith.
- sol now picks back up on its own after your mac sleeps and wakes. before, it could stay paused until you restarted it.

## [1.4.7] - 2026-07-16

### Added
- "create your journal on this mac" now gets the journal app for you in-app, over the same signed and verified path sol already uses for journal migration, then connects once your journal is ready.
- if a journal from an earlier install is found on this mac, sol names it and offers to install the journal app to bring it back online, adopting it in place at its original location.
- when sol is on but no journal is set up yet, the menu bar icon shows an attention badge so first-run setup is easy to spot.
- settings has a new "check my setup" panel: it reports, in plain language, whether sol, the journal app, your journal link, permissions, and the command-line tools are each in place, with a fix action where one exists — one screenshot now tells support the whole story.

### Fixed
- sol now finds its way back to your journal on its own after your network changes, like moving between Wi-Fi and ethernet or a VPN going up or down. previously sol's private-link connection could look connected while nothing new actually reached your journal, and only restarting sol would fix it. sol was still taking in your day alongside you the whole time, so this was easy to miss.
- after re-checking your journal link, sol keeps its ongoing health check running; before, that check could stop for good, so a private link that quietly went unhealthy might not be noticed or recover until sol was restarted.
- when sol runs from anywhere outside Applications, it now says so honestly and offers to move itself there, so macOS can remember its screen recording permission.
- sol now notices when your journal already holds part of your day and stops sending it again. before, sol could quietly keep re-sending things your journal had already received, using bandwidth and energy it did not need to. nothing was lost, and sol still keeps its own copy until your journal confirms it has one.

## [1.4.6] - 2026-07-11

### Changed
- sol's journal handoff can now be validated against the exact upcoming journal build before release, using the same signed acquisition and trust path as production.

### Fixed
- if macOS opens sol from a temporary location, sol now offers to move itself to Applications and reopen from there so screen recording permission can stick.


## [1.4.5] - 2026-07-05

### Fixed
- the "your journal" panel now shows connected as soon as your journal answers sol's regular check-ins — previously it waited for the first finished recording to upload, which could take several minutes (or indefinitely on a locked screen) while everything was healthy.


## [1.4.4] - 2026-07-05

### Fixed
- the "your journal" panel now reads connection health from real heartbeats when your journal is linked directly (on this mac or by address) — it previously watched the private-link tunnel, which never applies to a direct link, so the panel could say "connecting…" forever while everything was healthy.


## [1.4.3] - 2026-07-05

### Fixed
- during the migration handoff, sol no longer gives up when the journal app is still starting up — it now waits patiently while your journal gets ready, instead of stopping at the first unanswered check.


## [1.4.2] - 2026-07-05

### Fixed
- the migration handoff now allows the journal app the time it needs to prepare its runtime on first launch (the previous two-minute wait could give up while a slower mac was still setting up — a retry always recovered, but now it completes in one pass).


## [1.4.1] - 2026-07-05

### Fixed
- the migration banner's start button is reachable by assistive technologies again (the banner container was hiding its controls from the accessibility tree).


## [1.4.0] - 2026-07-05

### Changed
- sol is now just the app for this device. the journal — the memory sol keeps — has its own app, with its own updates.
- if sol was keeping your journal on this mac, a guided handoff sets up the journal app and hands your journal to it. nothing moves: same journal, same permissions, same pairing. segments are kept on this mac until your journal is back.
- settings show "your journal" — which journal this sol keeps to, its mark, and the connection — in place of the old service tab.
- on first run, sol looks before it asks: a journal on this mac links in one guided step, ending with your journal's mark.

### Removed
- sol no longer carries the journal runtime in the bundle — the download shrinks from about 450 MB to a few MB.


## [1.3.31] - 2026-07-04

### Changed
- the app's wording is refreshed throughout. the menu bar app is now sol, the memory it keeps is your journal, and sol's status reads as plain on / off / paused. permission and setup prompts, and the status spoken aloud for accessibility, are reworded to match.
- updated the bundled solstone journal to 0.6.24 →

### Fixed
- if solstone runs into trouble taking things in or syncing, it now shows that instead of quietly staying on, and a day counts as synced only once its uploads have finished. when solstone can't confirm it's observing along with you, it now says so plainly.
- if you remove a microphone partway through, the audio it already took in still reaches your journal, where before that mic's audio could be left out. when solstone can't finish putting together a stretch of what it took in, it now shows you a banner instead of failing quietly.
- when solstone's live connection to your journal drops, it now notices within a couple of seconds and reconnects. previously it could look connected for up to a minute and a half before recovering.
- chat now reconnects on its own if its live connection goes stale, instead of getting stuck and going quiet.

## [1.3.30] - 2026-07-03

### Changed
- your pairing to your journal now carries over across app updates without a keychain prompt. previously, each update could ask for keychain permission again before solstone could reach your saved pairing.
- while an update downloads in the background, solstone now shows real progress, instead of a screen that could look stuck.
updated the bundled solstone journal to 0.6.22 →

### Fixed
- an update downloading in the background no longer stops solstone from observing along with you. previously it could go quiet until you reopened the app; now it keeps observing through the download and only pauses as the update installs.
- solstone now quits promptly. previously, if it was finishing saving the latest stretch of what it observed with you, closing the app could take up to half a minute.
- if solstone can't read your saved pairing when it starts, it now shows a clear error and a retry button. previously that could leave it looking like it was simply not paired, with no sign that anything had gone wrong.

### Removed
- the sol-mac command-line tool is no longer part of solstone. pairing, connecting to your journal, and setup checks now all live in the app itself, in settings and the menu.

## [1.3.29] - 2026-07-02

### Changed
- updated the bundled solstone journal to 0.6.21 →

## [1.3.28] - 2026-07-01

### Changed
- updated the bundled solstone journal to 0.6.19 →


## [1.3.27] - 2026-06-30

### Added
- after you pair this Mac to your journal, it now shows your journal's mark, a small two-word, two-icon identity, and asks you to confirm it matches the one your journal shows before this Mac connects. if it doesn't match, this Mac disconnects right away and keeps nothing.

### Changed
- pairing this Mac to your journal when the two aren't on the same network is now more reliable. it works through a one-time pairing window your journal opens, and if you start a pairing link before your journal has opened that window, this Mac now tells you the pairing window is closed instead of failing without a reason.
- disconnecting this Mac from your journal is now a quiet, separate action with a short inline confirm, rather than a prominent button.

updated the bundled solstone journal to 0.6.18 →

## [1.3.26] - 2026-06-29

### Added
- this Mac can now reach your journal even when the two aren't on the same network. pair this Mac to your journal once with a pairing link, and from then on it sends what it observes to your journal over a relay sol pbc operates while you're away, and directly over your local network when you're home. it stays off until you pair this way, so nothing changes unless you set it up. the connection row shows whether this Mac is paired and whether it's connected right now, so a saved pairing never looks like a live connection.
- this Mac also sends your journal a small health note alongside its regular check-in, so you can tell at a glance that it's running and keeping up. the note is diagnostics only, its name, version, how long it's been running, and whether it's caught up. none of what it observes with you, no screen or audio, is included.

updated the bundled solstone journal to 0.6.17 →

## [1.3.25] - 2026-06-28

### Changed
- updated the bundled solstone journal to 0.6.16 →

## [1.3.24] - 2026-06-27

### Changed
- updated the bundled solstone journal to 0.6.15 →

### Fixed
- changing or unplugging an audio device while solstone was paused could freeze the app, and the only way out was a force quit. that's resolved, along with a rarer case where solstone could quit unexpectedly around a device change or when it stopped.
- solstone now stops cleanly when your screen locks or your Mac goes to sleep. previously, in some narrow timing cases, it could stay active for a brief moment after the screen locked instead of pausing. that timing gap is closed.

## [1.3.23] - 2026-06-26

### Changed
- the app icon is now the unified sol wordmark, the single mark sol pbc uses across every platform. it sits on the same cream squircle in your Dock.
- updated the bundled solstone journal to 0.6.14 →

## [1.3.22] - 2026-06-24

### Changed
- solstone's icon now sits naturally among the other apps in your Dock, with the same mark. nothing else about the icon changed.
- updated the bundled solstone journal to 0.6.13 →

### Fixed
- the health check in Settings could report "setup needed" on a healthy install before it had actually run. it now reads the same path the rest of the app uses, so a healthy install reads as healthy.
- a blank entry could appear in the menubar menu. it's gone, with no change to what the menu does.

## [1.3.21] - 2026-06-23

### Changed
- updated the bundled solstone journal to 0.6.12 →

## [1.3.20] - 2026-06-23

### Changed
- the "check for updates" controls in Settings now reflect what's actually possible: they're available when a check could do something, and they step back when one is already running, a download is staged and waiting, or your update settings aren't ready. the "last checked" line also reads as a live clock, saying "just now" for the first minute. nothing about how updates install changed, just how honestly the pane reads.
- updated the bundled solstone journal to 0.6.11 →

### Fixed
- after a solstone update, on-device screen analysis (how sol makes sense of what's on your screen, right on your Mac) could stop working until the next restart. it now keeps running cleanly across updates.

## [1.3.19] - 2026-06-22

### Changed
- some wording is clearer and more consistent across the app and the sol command line: "device" in place of "machine," a tidier line for the journal on this Mac, and clearer help text for the private network command. nothing about how solstone works changed, just how it reads.
- updated the bundled solstone journal to 0.6.10 →

### Fixed
- if you had an update download in the background, settings and the menu could still say "up to date" even though the new version was already downloaded and staged, ready to install when you quit. those now honestly reflect a downloaded-and-staged update, so what you see matches what's actually waiting.

## [1.3.18] - 2026-06-19

### Changed
- the menubar status now tells you the honest truth about whether what you're observing is reaching your journal right now. before, the sun icon could look full even when observing was paused, local-only, or stopped. now a full sun means your journal is receiving, a half sun means it isn't, and there's a clear starting state and an error state. the status text in Settings and the Help legend match this too, and the tray status now sits cleanly next to its pause and resume control.
- Help and Settings → Status now show the solstone app version on its own, so it's no longer mixed up with your journal's version.
- updated the bundled solstone journal to 0.6.9 →

### Fixed
- quitting, restarting, and updating solstone are now clean and reliable, including right after an update has been prepared. a normal quit is also no longer mistaken for a crash, so solstone won't relaunch itself when you meant to close it.
## [1.3.17] - 2026-06-18

### Changed
- updated the bundled solstone journal to 0.6.8 →

## [1.3.16] - 2026-06-18

### Added
- solstone now restarts on its own if it ever stops unexpectedly, so observing keeps going without you having to reopen it. the "start at login" toggle also governs this, so turning it on covers both launching at login and restarting after an unexpected stop.

### Changed
- updated the bundled solstone journal to 0.6.7 →
- some iphone continuity microphones (wired and wireless) and aggregate audio devices are no longer observed by default, so fewer microphones are on out of the box. you can turn any of them back on in Settings whenever you like.
- first-time setup now shows a "verifying macOS security integrity" step and is more reliable. it waits for your journal to be fully ready before connecting, and retries a slow first connection instead of failing.

### Fixed
- solstone no longer hangs on startup when an iphone continuity microphone is connected.
- solstone no longer quits when your Mac goes to sleep or locks while audio is being taken in. if it ever happened, just that moment's audio is set aside and observing keeps running.
- solstone no longer quits when you unplug or replug a display, or when a monitor sleeps or wakes. some Macs ran into this on a display change; this resolves it.
- if every display disconnects, or a monitor sleeps while your Mac stays awake, observing now resumes on its own once a display comes back. before, it could stay stopped until you reopened solstone, even overnight.
- after your Mac sleeps and wakes or locks and unlocks, observing now reliably resumes. some sessions could get stuck paused and stay that way until a manual restart; this resolves it.
- the journal card in Settings no longer stays on "upgrade in progress" after a routine update finishes. it now reflects your journal's real running state.
- old bundled journal versions are now cleaned up after an update, instead of leaving hundreds of megabytes behind on disk.

## [1.3.15] - 2026-06-15

### Changed
- updated the bundled solstone journal to 0.6.4 →
- Settings now reads more clearly for bundled and self-managed journals,
  with lifecycle controls tucked under troubleshooting and a last-activity
  line for the bundled journal.
- chat notifications now use the journal's current callosum connection path,
  with the observer key still sent in the authorization header.

### Fixed
- the Updates tab no longer gets stuck on checking when an automatic check is
  already running in the background.

## [1.3.14] - 2026-06-12

### Added
- you can now stop and start the journal yourself from Settings, so observing pauses and resumes when you choose.

### Changed
- updated the bundled solstone journal to 0.5.4 →
- the journal now runs as part of solstone itself instead of a separate background process. quitting solstone now stops the journal too, and the menu, doctor, and Settings show its real status as it changes.
- when an app update is ready, the journal stops cleanly before the new version takes over, so an update never leaves it half-applied.

### Fixed
- the "notify me when sol starts a chat" setting and your system notification permission are now separate, so the setting reflects what you chose rather than the permission state. notifications are on by default.

## [1.3.13] - 2026-06-05

### Changed
- updated the bundled solstone journal to 0.5.2 →

### Fixed
- when an update is available, the Updates tab now reliably offers the download, even if the latest check hasn't come back yet. choosing it re-checks and starts the install for you.

## [1.3.12] - 2026-06-05

### Changed
- updated the bundled solstone journal to 0.5.1 →

### Fixed
- if an app update starts while solstone is active, the current segment is finished before the installer takes over, so the update does not leave it midstream.

## [1.3.11] - 2026-06-03

### Fixed
- the menu and Settings now use the same journal status, so a healthy journal is not shown as stopped in one place and synced in another.
- if the bundled journal needs attention, the menu opens Settings instead of trying to restart from the dropdown. restart now lives in the journal settings pane, where the status reason is visible.
- the app now says journal throughout the menu, Settings, install status, and accessibility labels. the old technical wording is gone.

## [1.3.10] - 2026-06-03

### Changed
- the journal settings stay fully visible and usable in every installer state. if you manage your own journal, you can still see bundled install and failure status while another mode is selected, and switching journal modes no longer cancels an install that's already running.
- app updates and installs no longer get in each other's way. while solstone is installing, automatic update checks hold off so the two don't collide, but you can still check for updates yourself anytime; if an update is waiting, it picks up once the install finishes.

### Fixed
- during a fresh install or an app-run upgrade, solstone now waits for your journal to be fully ready before connecting your observers, so setup no longer moves ahead before the journal can accept them. if an upgrade does hit a snag after the new version is already in place, the status card now reflects what actually happened and points you to the right next step instead of restarting the whole upgrade.
## [1.3.9] - 2026-06-02

### Changed
- updated the bundled solstone journal to 0.4.10 →
- when you stop or pause solstone, or your Mac sleeps or locks, and the last segment's audio can't be read yet, solstone now keeps that segment and tells you, instead of finishing it with screen only. nothing is quietly set aside.

### Fixed
- if a segment finished with its screen but without its audio, even though good audio was sitting on your Mac, that's resolved. a timing issue could finish the segment that was in progress right then before its audio had finished saving; the way solstone finishes and recovers segments was reworked so the in-progress segment is never finished early and its audio is kept with it. this goes deeper than the 1.3.8 reconciliation, closing the same gap at its source. everything stays on your machine, as always.
- for a journal you manage yourself, including one you run from source, the bundled journal now stays up to date through upgrades. some self-managed setups had the journal fall a release behind because the app didn't recognize its own shortcut; it does now.

## [1.3.8] - 2026-06-02

### Changed
- updated the bundled solstone journal to 0.4.9 →
- upgrades now stage and verify the new bundled journal before switching the app over. if staging fails, your current install keeps running instead of being torn down first.
- settings now recognizes journals you manage yourself, including one you run from source. it shows their version without trying to reinstall them or move them to the default journal.

### Fixed
- upgrades run by the app keep using the journal path already configured on your Mac, so a journal outside the default folder stays connected through the upgrade.
- segments no longer finish without audio when valid audio files are still on disk. solstone reconciles those files before the segment is marked complete.
- install and upgrade failure cards now put the summary first, keep retry nearby, and leave the details available for support.

## [1.3.7] - 2026-05-31

### Fixed
- upgrading over an older install no longer stops because the `sol` or `journal` shortcut in your shell points somewhere stale. setup now repairs the shortcuts it owns and keeps going.
- sol's background thinking can ask your journal for identity, routines, health, and talent context again. those approved journal tools were being turned away before sol could use them; now they work without widening what sol is allowed to run.
- fresh bundled installs resolve cleanly when the app installs solstone. the bundled journal now uses matching telemetry packages for sol's thinking runtime, so setup no longer lands on an incompatible dependency mix.
- upgrades can continue when launchd reports a transient service-start error after the bundled journal has actually started and become healthy.

## [1.3.6] - 2026-05-31

### Added
- you can now re-run sol's thinking on any day right from the page. "process now" picks up where it left off; "redo from scratch" starts the day over.

### Changed
- the on-device option is now a single "Local (on-device)" choice, and on your Mac it runs entirely on your machine, including sol's thinking. nothing leaves your machine, with no cloud fallback.
- your journal now tells you plainly whether it's caught up. the stats and health pages show an honest "is my journal caught up?" answer, plus a "days that need a hand" list for any day sol can't finish on its own, like one with corrupted media or a step that keeps failing. catch-up runs on its own in the background and never leaves older days behind.

### Fixed
- your journal no longer shows finished work as still pending. days that hit an earlier error but later completed were being counted as outstanding, so the backlog looked larger than it was. the count now reflects what's actually still incomplete.


## [1.3.5] - 2026-05-30

### Added
- you can now reach your journal from your phone or laptop even when they're away from your home machine. a single connections page shows how you connect, your network access, and your paired devices. pair a new one with a fresh code, give each device a name, and remove any device with one tap.
- the local model that runs entirely on your machine can now take in images as well as text. nothing new leaves your machine.

### Changed
- the local model now stays ready in the background instead of starting on demand, so sol doesn't wait on it; fresh installs start it reliably the first time, and downloading a model shows real progress.
- update status is now a first-class signal. the Updates row in Settings and the menu flag when an update is waiting or a check didn't go through, and clear once you're current.

### Fixed
- the health panel in Settings now shows each individual check, so you can see exactly which permission or service needs attention. if you saw a single "doctor failed" warning on 1.3.4, you'll now see the specific check instead, with the rest still passing.
- your journal now shows when a moment has been transcribed but not yet thought through, instead of looking finished, and catches those moments up on its own.

## [1.3.4] - 2026-05-27

### Changed
- the bundled solstone is updated.

### Fixed
- your segment audio now stays with its segment. on 1.3.3, if a recording finished in a way solstone couldn't fully process, the segment could reach your journal with its screen but without its audio, even when a good recording was sitting on your machine. now those recordings are kept safe on disk and the segment is marked for another pass instead of going up incomplete.
- the upgrade-failed notice no longer lingers once you're current. if an earlier upgrade ran into trouble, the notice could stay up after the problem was resolved, and an outdated install could stop retrying the upgrade on launch. solstone now re-runs the upgrade when it's behind and clears the notice once you're on the latest.

## [1.3.3] - 2026-05-27

### Added
- a new newsletters page in the sidebar. read the facet newsletters sol writes for you from their own surface, with copy and PDF download.

### Changed
- the bundled solstone is updated. the activity participation tab now renders as a structured list, with attendees and mentioned grouped separately, per-entry provenance, and a "less certain" tag on lower-confidence entries. previously it rendered as a raw JSON block.
- the chat surface gets a small refresh: sol's thinking summary now appears alongside the response when the AI provider returns one, a liveness placeholder shows while sol is working, errors offer a retry, and labels for what sol is doing read in plain language.

### Fixed
- the weekly reflection page now fills in. on busier journals, sol was stopping before it got to the writing, so the page rendered empty. that's resolved.
- a name that only appeared in a transcript, without other corroboration, no longer surfaces as a meeting attendee on the activity participation tab. it shows up under "mentioned" instead.
- some of sol's background work running through google could fail silently on the default configuration. a request-budget calculation was landing one over the supported maximum, rejecting every call; the calculation is corrected.
- sidebar labels for apps like "transcripts," "activities," and "settings" no longer truncate when the sidebar is expanded.

## [1.3.2] - 2026-05-26

### Fixed
- solstone now recovers automatically when segment rotation stalls after pause/resume, so your journal keeps receiving uploads without needing to quit and relaunch. previously, on rare occasions, the app could appear to be recording while no new segments reached your journal until the app was restarted.

### Changed
- the journal setup tab now shows an attention badge when the bundled solstone install is outdated, and the upgrade action is highlighted so it is easier to find.

### Removed
- legacy self-signed dev-loop targets — `make bundle`, `make bundle-universal`, `make install-app`, `make open`, `make cert`, `make allow`, and the `SIGN_IDENTITY ?= solstone dev` default. these predated the Apple Developer Program enrollment (2026-04-20); the canonical build is now `make bundle-dist` which signs under Developer ID Application with hardened runtime and bundles uv + python. `make run` now launches `solstone.app` from the source tree (was `/Applications/solstone.app`).

## [1.3.1] - 2026-05-24

### Fixed
- per-display segment videos now contain that display's actual pixels. earlier builds always wrote the primary display's pixels into every per-display file, so anyone running solstone on a multi-display Mac was recording the wrong screen until now.

## [1.3.0] - 2026-05-22

### Added
- you can now run sol's on-screen analysis entirely on your own Apple Silicon Mac. choose the on-device option in settings, and the part of sol that makes sense of what's on your screen runs locally, with nothing about those frames going to a cloud provider. it's opt-in, vision-only for now, and needs a Mac with at least 16 GB of memory. a one-time model download happens the first time you turn it on.
- the menu bar now tells you when the journal needs attention and gives you a recovery path from the app.
- you can now power sol with your Anthropic or OpenAI account without installing anything separately. enable the provider in settings and paste your key, and solstone installs what it needs on its own.

### Changed
- the timeline view is rebuilt. it fits any window width, shows where each entry came from with a link to that day, and refreshes in place as new days roll up.
- long todo lists load faster. solstone now shows a focused first screen with a "show more" control, instead of rendering the entire list up front.
- pairing a phone is more reliable, and the paused state in the menu now reads "paused - 8 min left" so you can see at a glance when sol resumes.

### Fixed
- videos and audio in your journal that wouldn't play now play correctly, with a clearer message on the rare file that still can't.
- when transcription hit a dense stretch of speech it could fail outright; it now recovers on its own, and segments that did fail are surfaced instead of disappearing silently.
- pages occasionally got stuck loading on a cold start, and the paused and error menu-bar icons had lost their sun in 1.2.1. both are resolved, alongside internal stability improvements.

## [1.2.1] - 2026-05-18

### Changed
- the bundled solstone is updated. results are more consistent across AI providers, and your provider-tier defaults move to each provider's current model. nothing about how you use solstone changes.

### Fixed
- a name from your own contacts could be written into your journal as if it had appeared on your screen, when sol had little else to go on for a frame. that no longer happens.
- on a rare frame, sol could write a long run of repeated text into your journal. that output is now bounded before it's saved, and normal entries are unaffected.
- when sol fell back to its backup AI provider for a screen or document, the image wasn't reaching the provider, so the journal entry was a guess instead of grounded in what was on screen. the image now reaches every provider.
- updating solstone on a Mac that already had it installed could fail partway through. some upgrades over an existing install hit this — this resolves it, and updating now completes cleanly.


## [1.2.0] - 2026-05-17

### Added
- a plain-language data-flow page now ships with solstone. it lays out what's sent to your AI provider for each task, what stays on your machine, and the Article 8 covenant for what is never sent. linked from setup, the install guide, and the readme.
- first-run setup now walks through how to power sol: a hosted key to start, your own provider account (a developer key, not a consumer chat plan), and where local-only is headed.

### Changed
- installing solstone now happens inside settings → journal, not a separate window. pick the bundled solstone or connect to your own, see each step as it runs with a details view, and a single badge points you to whatever still needs attention. when it finishes, an "open journal dashboard" button opens it on your terms instead of a browser opening on its own.
- the menubar and settings wording now follows one model: your observers experience your day along with you, and everything goes to your journal, where sol keeps it. clearer language for what each part does. nothing about how solstone works changed.
- bundled solstone updated. fresh setup is clearer, the starting nav rail comes ready instead of blank, timezones resolve correctly on Macs, and help points to support.solstone.app.

## [1.1.3] - 2026-05-14

### Added
- Failure card now surfaces a **show-details** disclosure with the captured subprocess log (uv stderr, sol setup rendered transcript, or observer-create output) — monospaced, selectable, copyable. Diagnosing a failed install no longer requires Console.app.

### Changed
- Bundled solstone backend pinned to **0.3.2**, which makes `sol doctor` PATH-independent. Fresh-Mac installs no longer need a launchctl-PATH workaround.
- `uv tool install` now passes `--refresh` so freshly published solstone versions install reliably from the first attempt (no stale PyPI index cache).

### Fixed
- Subprocess environment inheritance: `Foundation.Process.environment = nil` did not deliver the .app's PATH to subprocesses in practice. The installer now passes `ProcessInfo.processInfo.environment` explicitly. This was the root cause of `npx_on_path` / `journal_sync` / `port_5015_free` doctor failures in earlier installer builds.

## [1.1.2] - 2026-05-04

### Added
- Updates tab anchored with current version + last-checked line, and surfaces auto-update preferences.
- Polished DMG window layout via create-dmg (brand background, window bounds, icon positions).

### Changed
- Settings switched from `TabView` to `NavigationSplitView` for a native-feeling sidebar.
- Menu-bar icons now ship as vector PDF templates — crisp at any density.
- `SettingsView` seeds its selected tab from init for snapshot stability; snapshot frame widened.

### Fixed
- Menu-bar icons load from the nested SwiftPM `Resources/` subdirectory.
- `UpdatesTabView` no longer shows a duplicate transient block while checking.

## [1.1.1] - 2026-04-29

### Fixed
- `sol-mac` maps a stale-socket connect failure to `app_not_running` cleanly.

## [1.1.0] - 2026-04-28

### Added
- In-app update support with an Updates tab and menu-bar "check for updates".
- Sparkle-based signed update feed integration.
- `sol-mac` IPC over a unix domain socket, including the locked `Codable` wire schema in `SolstoneCore`, the app-side `NWListener` service, and the hidden `_internal-ping` round-trip command.
- `StatusInfo.screenRecordingGranted` and `StatusInfo.microphoneGranted` (additive optional fields) so `sol-mac diagnose` and `sol-mac status` surface real TCC grants over IPC instead of "unknown".

### Changed
- Distribution builds are now packaged as signed, notarized DMGs suitable for direct install outside the App Store.
- `AppState.reloadConfigFromDisk()` is now the cross-process fast path for config reloads.

### Fixed
- Release builds now use the production Sparkle signing key.
- Signing checks are idempotent across fresh SSH sessions by resetting the session keychain search list.

## [1.0.0] - 2026-04-22

### Added
- Initial release of Solstone Capture.
- Continuous multi-display screen capture at 1 FPS.
- System audio plus per-microphone recording with dynamic mic join/leave.
- 5-minute segment rotation, pause with auto-resume, observer sync/retry, startup recovery, and privacy window exclusion.

### Changed
- H.264 recording for browser compatibility.
- Day-based local cache retention instead of size-based cleanup.

### Fixed
- Fresh-install start-at-login registration.
- Clearer local-network permission handling for journals reachable over LAN or Tailscale.
- Reliable settings-window Dock behavior and reopen handling.
- Install flow split into `make cert` plus human-run `make allow`.
