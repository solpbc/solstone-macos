# Changelog

All notable changes to journal will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.12 (build 14)] - 2026-07-22

### Changed
- updated the bundled journal to [1.0.12](https://solstone.app/releases#v1.0.12) →


## [1.0.11] - 2026-07-22

### Changed

- updated the bundled journal to [0.9.1](https://solstone.app/releases#v0.9.1) →

## [1.0.10] - 2026-07-19

### Changed

- updated the bundled journal to [0.9.0](https://solstone.app/releases#v0.9.0) →


## [1.0.9] - 2026-07-17

### Changed

- when the journal app finds a background journal service, it now shuts that service down and removes it, but only once it can prove the service is running the same journal the app was set up for. if the service points at a different journal, or the journal app can't tell, it stops and tells you what it found instead of taking over: nothing is uninstalled, stopped, or started while that's unclear. running a journal from the command line, with no journal app, works as it did before.
- updated the bundled journal runtime to 0.8.9.

### Fixed

- once the journal app adopts your journal, it's the only thing running it. before, a background journal service could be running that same journal at the same time, and the two competed for the same files and the same port, so your journal could look healthy while behaving oddly. if you ran into that, this resolves it.
- the journal app now calls your journal ready only when the journal it started is the one answering. before, it trusted whatever answered on the port, which could be a different copy entirely.
- if you have your own `sol` or `journal` command, setup no longer replaces it with its own version. your command keeps working across app updates: the journal app refreshes only the commands it created, and leaves anything else exactly as it found it.

## [1.0.8] - 2026-07-16

### Added

- first run can now adopt an existing journal that sol found on this mac: the location arrives pre-filled, and setup accepts the existing journal in place.

### Changed

- updated the bundled journal runtime to 0.8.8.

## [1.0.7] - 2026-07-15

### Changed

- updated the bundled journal runtime to 0.8.7.

## [1.0.6] - 2026-07-14

### Changed
- updated the bundled journal runtime to 0.8.6.


## [1.0.5] - 2026-07-12

### Changed
- the bundled journal runtime now installs solstone 0.8.4, which adds batch review of duplicate-merge suggestions, renders sol's chat replies with formatting, checks your journal by default when you ask about your own history, shows live progress while local thinking installs, keeps your transcript text out of internal error reports, and handles local thinking and transcription limits more honestly.

## [1.0.4] - 2026-07-10

### Changed
- the bundled journal runtime now installs solstone 0.8.3.

## [1.0.3] - 2026-07-07

### Changed
- the bundled journal runtime now installs solstone 0.8.2, which keeps the screen and combined-transcript tabs from going blank on unexpected content, makes local thinking on your own machine steadier, files calendar moments as their own category, and stops the home page repeating the same thing to do twice.

## [1.0.2] - 2026-07-07

### Changed
- the bundled journal runtime now installs solstone 0.8.1, including exact-match journal search, the unified journal app frame, local media/social/ambient-sound hints, and local helper-model checks in settings.

### Fixed
- `sol call health summary` now works from a sol-only runtime install without importing journal-only readiness code.

## [1.0.1] - 2026-07-05

### Added
- (describe new journal-visible additions)

### Changed
- (describe journal behavior changes)

### Fixed
- (describe journal bug fixes)


## [Unreleased]

## [1.0.0] - 2026-07-05

### Added
- the journal has its own app now. your journal — the memory sol keeps — is a visible, deliberately installed thing: a dock app with a native window for its name, its mark, and its run state.
- creating a journal is a short ritual: name it, choose where it lives, then meet your journal's mark — lock it in, and the app's own icon becomes it.
- the devices pane shows every device that keeps to this journal, opens a pairing window for a new one, and can rename or revoke.
- the journal app updates itself, separately from sol.

### Changed
- if sol was keeping your journal on this mac, the journal app adopts it in place — same journal, nothing moves.
