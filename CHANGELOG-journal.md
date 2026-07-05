# Changelog

All notable changes to journal will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-07-05

### Added
- journal is now its own macOS app for the keeper side of the owner model. it lives with and tends the owner's journal while observers send their experience there.
- the first standalone journal.app release includes the local runtime material needed to install and verify the journal command line without mutating the app bundle.
- journal ships its own signed update feed, changelog, disk image, and release path separate from sol.

### Changed
- journal setup and update plumbing now belongs to journal.app instead of riding inside sol.app.
