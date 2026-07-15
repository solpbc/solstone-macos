# Changelog

All notable changes to journal will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
