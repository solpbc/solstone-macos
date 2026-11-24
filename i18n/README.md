# Native string catalog

English is authored in [catalog/source/en-US.ftl](catalog/source/en-US.ftl). Each message has a translator sidecar in catalog/meta. Keep stable identities and history; retire an identity when its argument contract changes.

[compiler.json](compiler.json) pins the compiler and locale registry from solstone-journal. Build that revision's tools/i18n package with its locked Cargo dependencies. On a Mac, regenerate with:

    make catalog I18N_COMPILER=/absolute/path/to/i18n-catalog

The compiler emits Apple String Catalogs. scripts/i18n.py partitions their keys using [targets.json](targets.json), generates typed Swift calls, and invokes Xcode's xcstringstool. The resulting strings and stringsdict resources live in each target's Localization directory. They are committed so SwiftPM consumers can build without running this repository's Makefile.

Each target uses its own Bundle.module. SwiftUI, AppKit, notifications and accessibility receive the translated String. Foundation chooses among packaged languages, including the macOS per-app language setting. The app declares its supported languages in the generated Info.plist values. Only en-US is packaged today.

The generated InfoPlist tables supply the displayed app and native Safari extension names, and the app’s permission usage descriptions. Consent text requires review before translation. The app's bundle identifier, executable name, file paths and automation identifiers remain program data.

Add a translation only after its language is admitted in the pinned registry. Update the registry pin, catalog and generated resources together; no application lookup code is needed. Do not add an independently authored Xcode catalog or extracted English defaults.

make ci checks the catalog, compiler pin and generated files against the committed byte lock. A generated-output-only edit fails. Regeneration updates the lock. This is a generated-resource consistency check; it does not scan source code for English.

About protocol records and external application-title matchers retain their wire/input formats. Presentation has separate catalog calls. Sparkle owns its own interface translations; UpdateKit's copy belongs here. Browser-extension resources and journal web content keep their own catalogs.

## Draft locales

Draft locales registered in the pinned locale registry (`development` released, `production` withheld; including `es-419`, `de`, `it` and `te`) keep their draft translations in `catalog/translations/<locale>.ftl` (or sharded files under `catalog/translations/<locale>/`), and production builds exclude them. Unapproved legal and statutory messages stay absent from draft translation files and fall back to English in development builds. When editing English prose, run `i18n-catalog lock` to refresh `source-lock.json`, copy each changed `source` hash into its sidecar `source_revision`, and do not pass `--acknowledge <locale>` for any draft locale: leaving prior acknowledgments untouched marks edited draft entries stale until a translator updates them.

When regenerating production resources on a host without `xcrun` (for example after adding a draft translation that does not change emitted `.xcstrings` bytes), `scripts/i18n.py` verifies that the emitted `.xcstrings` files and existing compiled resources match `i18n/generated-lock.json` before updating the lock; any change to `.xcstrings` bytes requires macOS with `xcrun`.
