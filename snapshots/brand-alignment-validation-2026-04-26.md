# solstone-macos brand alignment validation — 2026-04-26

Scope: comprehensive validation that solstone-macos is in alignment with `extro/cmo/brand/sol/` after parts 1–3 of `req_yezzr7cd` (CPO → VPE) ship. Future re-validation is a re-run of the same scans.

Reference spec: `extro/cmo/brand/sol/index.md`. Founder-approved decisions: orange-on-cream rule (2026-04-25), render-from-SVG rule (2026-04-25), Variation A app icon (2026-04-25).

## summary

| area | result |
|------|--------|
| asset inventory | 10/10 match canonical |
| brand color sweep | 0 residual hand-typed values; all hits inside vendored SVGs or the just-fixed AccentColor.colorset |
| author-controlled UI strings | 0 Title-Case author strings; nothing to lowercase |
| AccentColor light/dark | shipped as `0.690/0.416/0.102` light + `0.910/0.573/0.227` dark with brand-spec comment |
| mark surface inventory | 4 surfaces enumerated; all render from canonical sources |
| CMO Apple-ecosystem plan parts C + E | shipped (this PR) |
| outstanding items | 1 (menubar regular-state geometry mismatch with variant icons) |

## 1. asset inventory

Every file in `assets/` diffed against canonical, using the rename map (`icon-app*.svg` ↔ `sol-app-icon*.svg`):

| local | canonical | result |
|-------|-----------|--------|
| `assets/sol-wordmark.svg` | `sol-wordmark.svg` | match |
| `assets/sol-wordmark-white.svg` | `sol-wordmark-white.svg` | match |
| `assets/sol-ring.svg` | `sol-ring.svg` | match (drift fixed: base-ring `r=8.0/sw=1.2`) |
| `assets/sol-ring-icon.svg` | `sol-ring-icon.svg` | match (newly vendored) |
| `assets/sol-ring-icon-error.svg` | `sol-ring-icon-error.svg` | match |
| `assets/sol-ring-icon-paused.svg` | `sol-ring-icon-paused.svg` | match |
| `assets/sol-ring-icon-half.svg` | `sol-ring-icon-half.svg` | match |
| `assets/icon-app.svg` | `sol-app-icon.svg` | match (local rename) |
| `assets/icon-app-16.svg` | `sol-app-icon-16.svg` | match (local rename) |
| `assets/icon-app-32.svg` | `sol-app-icon-32.svg` | match (local rename) |

Reproduce: see the inventory loop in this PR's commit message; or `make brand-sync` then `git diff --quiet assets/`.

## 2. brand color sweep

Comprehensive scan across `Sources/`, `assets/`, `Tests/`, `scripts/`, plus `Makefile` and `Package.swift`:

```
grep -rin '#[ef][8c]923[a-f]\|#b06a1a\|#f5c740\|0\.910.*0\.573\|0\.690.*0\.416\|0\.961.*0\.780' \
  Sources/ assets/ Tests/ scripts/ Makefile Package.swift
```

All hits classify cleanly:

- **Inside vendored SVGs** (`assets/*.svg`) — expected. Vendored = canonical, not hand-typed.
  - `assets/sol-ring.svg`, `assets/sol-ring-icon.svg`, `assets/sol-ring-icon-error.svg`, `assets/sol-ring-icon-paused.svg`, `assets/sol-ring-icon-half.svg` — `#F5C740` (rays) and `#E8923A` (ring).
  - `assets/sol-wordmark.svg`, `assets/sol-wordmark-white.svg` — `#F5C740` (rays) and `#E8923A` (ring + glyphs).
  - `assets/icon-app.svg`, `assets/icon-app-16.svg`, `assets/icon-app-32.svg` — `#F5C740` (rays), `#B06A1A` (accessible orange ring) per the orange-on-cream rule.
- **Inside the AccentColor.colorset** (`Sources/solstone/Resources/Assets.xcassets/AccentColor.colorset/Contents.json`) — expected, just-fixed in part 1.
  - Light variant: `0.690 / 0.416 / 0.102` (`#B06A1A`, WCAG AA on cream).
  - Dark variant: `0.910 / 0.573 / 0.227` (`#E8923A`).
- **No other hits** in Swift sources, tests, scripts, Makefile, or Package.swift. Zero residual hand-typed brand values.

## 3. author-controlled UI string audit

Casing scan over all SwiftUI string-initializer call sites that produce visible product copy:

```
grep -rn 'Text("[A-Z]'                Sources/ --include="*.swift"
grep -rn 'Button("[A-Z]'              Sources/ --include="*.swift"
grep -rn 'Label("[A-Z]'               Sources/ --include="*.swift"
grep -rn 'navigationTitle("[A-Z]'     Sources/ --include="*.swift"
grep -rn 'Toggle("[A-Z]'              Sources/ --include="*.swift"
grep -rn 'Picker("[A-Z]'              Sources/ --include="*.swift"
grep -rn 'Stepper("[A-Z]'             Sources/ --include="*.swift"
grep -rn 'Section("[A-Z]'             Sources/ --include="*.swift"
grep -rn 'TextField("[A-Z]'           Sources/ --include="*.swift"
grep -rn 'Menu("[A-Z]'                Sources/ --include="*.swift"
grep -rn 'DisclosureGroup("[A-Z]'     Sources/ --include="*.swift"
grep -rn 'GroupBox("[A-Z]'            Sources/ --include="*.swift"
grep -rn 'LabeledContent("[A-Z]'      Sources/ --include="*.swift"
grep -rn 'help("[A-Z]'                Sources/ --include="*.swift"
grep -rn 'alert("[A-Z]'               Sources/ --include="*.swift"
grep -rn '\.tint\|\.borderedProminent\|accentColor' Sources/ --include="*.swift"
```

Zero hits across the board. solstone-macos's hand-discipline holds. **No casing lint is being added** — the surface is small enough that grep on touch is sufficient. Revisit if drift returns.

Confirmed lowercase elsewhere:
- `Info.plist` → `CFBundleName` and `CFBundleDisplayName` are both `solstone`.
- `Info.plist` → `NSHumanReadableCopyright` is `© 2026 sol pbc. all rights reserved.`
- `SolstoneCaptureApp.swift` → `Window("solstone observer settings", ...)` and `Window("about solstone observer", ...)` are lowercase.
- `AboutView.swift` → all `Text(...)` strings (`"solstone observer"`, `"version \(version)"`, `"by sol pbc"`, the covenant line, etc.) are lowercase.

Out-of-scope per spec (do not touch):
- `StorageManager.swift:28` → `appSupport.appendingPathComponent("Solstone/captures", ...)` — OS-required Application Support directory name. Touching it breaks installed users.
- HIG cancel/destructive labels, third-party proper nouns, and protocol/URL literals are exception categories per `extro/cmo/brand/sol/index.md`.

## 4. AccentColor verification

Pre-fix: single-variant `0.910 / 0.573 / 0.227` (`#E8923A`) — fails WCAG 3:1 against light system surfaces (per the orange-on-cream rule, contrast vs `#FEFCF8` is 2.07:1, vs `#FFFFFF` is 2.13:1).

Post-fix:
- light → `red 0.690, green 0.416, blue 0.102, alpha 1.000` (`#B06A1A`, `solOrangeAccessible`, WCAG AA on cream).
- dark → `red 0.910, green 0.573, blue 0.227, alpha 1.000` (`#E8923A`, `solOrange`, clears on dark surfaces).
- top-level `comment` field added: `extro/cmo/brand/sol/index.md — solOrangeAccessible (light, WCAG-AA-on-cream) & solOrange (dark)`.

Verification method: structural-only inspection of `Sources/solstone/Resources/Assets.xcassets/AccentColor.colorset/Contents.json`. **No current macOS Swift code references `accentColor`, `.tint`, or `.borderedProminent`** (`grep -rn '\.tint\|\.borderedProminent\|accentColor' Sources --include="*.swift"` → zero hits), so the fix is structural — locking the brand-spec contract before something starts using it. No screenshot diff necessary today; the values match `Sources/Assets.xcassets/AccentColor.colorset/Contents.json` in solstone-swift `8eeab99` byte-for-byte (modulo trivial key-order normalization Xcode applies on save).

## 5. wordmark / mark surface inventory

| surface | code path | source asset |
|---------|-----------|--------------|
| About window logo | `AboutView.swift:19` → `bundleImage("sol-wordmark")` | `Sources/solstone/Resources/sol-wordmark.png` (rendered from `assets/sol-wordmark.svg` via `make icons`) |
| Menubar regular-state icon | `SolstoneCaptureApp.swift:222,229` → `bundleImage("sol-ring-template", isTemplate: true)` | `Sources/solstone/Resources/sol-ring-template.png` (rendered from `assets/sol-ring.svg` via `make icons`) |
| Menubar error-state icon | `SolstoneCaptureApp.swift:215,229` → `bundleImage("sol-ring-icon-error-template", isTemplate: true)` | `Sources/solstone/Resources/sol-ring-icon-error-template.png` (rendered from `assets/sol-ring-icon-error.svg`) |
| Menubar paused-state icon | `SolstoneCaptureApp.swift:218,229` → `bundleImage("sol-ring-icon-paused-template", isTemplate: true)` | `Sources/solstone/Resources/sol-ring-icon-paused-template.png` (rendered from `assets/sol-ring-icon-paused.svg`) |
| Menubar half-state icon | `SolstoneCaptureApp.swift:224,229` → `bundleImage("sol-ring-icon-half-template", isTemplate: true)` | `Sources/solstone/Resources/sol-ring-icon-half-template.png` (rendered from `assets/sol-ring-icon-half.svg`) |
| Settings icon-state preview rows | `SettingsView.swift:1155,1160,1165,1170` → `bundleImage("sol-ring-template" / "sol-ring-icon-half-template" / "sol-ring-icon-paused-template" / "sol-ring-icon-error-template", isTemplate: true)` | same as above |
| Dock + Finder app icon | `Sources/solstone/Resources/AppIcon.icns` | rendered from `assets/icon-app.svg` + per-size `assets/icon-app-16.svg` / `assets/icon-app-32.svg` via `make icons` (per-size SVG selection — never downsample) |

The "by sol pbc" line in `AboutView.swift:36` renders as type, not as the pbc-wordmark mark — already aligned with the iOS rule (treat company credit as text, reserve mark for product surfaces).

PNG outputs in `Sources/solstone/Resources/` were last regenerated 2026-04-25 (commit `4f1d544`). The next `make icons` run on a Mac will re-render them from the post-sync canonical SVGs — see Outstanding items § for one consequence.

## 6. CMO Apple-ecosystem brand plan — parts C + E status

Reference: `extro/cmo/workspace/apple-ecosystem-brand-plan.md`.

| part | status | evidence |
|------|--------|----------|
| Part C — `CLAUDE.md`/`AGENTS.md` brand section | shipped (this PR) | `CLAUDE.md` § Brand — lowercase rule, exception categories, brand-sync workflow, AccentColor split, render-from-SVG rule, data covenants. `AGENTS.md` is a symlink → `CLAUDE.md`. |
| Part E — `make brand-sync` + re-vendored SVGs | shipped (this PR) | `Makefile` § brand-sync target; `assets/sol-ring.svg` drift fixed; `assets/sol-ring-icon.svg` newly vendored. |

The plan doc itself doesn't track state. This validation report is the audit trail.

## 7. outstanding items

**Menubar regular-state geometry mismatch with variant icons (advisory).** After this PR, the menubar regular-state ring renders from canonical `sol-ring.svg` (base geometry: `r=8.0`, `stroke-width=1.2`), while the error/paused/half variants continue to render from `sol-ring-icon-*.svg` (icon geometry: `r=6.5`, `stroke-width=1.7`). This means at 18px in the menubar, the regular state will be visually lighter than the variant states — the ring stroke will appear thinner and the inner annulus larger.

The local `assets/sol-ring.svg` had previously been hand-edited to icon geometry (`r=6.5/sw=1.7`), which masked this inconsistency by making the regular state match the variants. Brand-sync corrects the drift but exposes the underlying mismatch.

The CPO request flagged this implicitly: "`sol-ring-icon.svg` is missing locally (extro has it, macOS doesn't — used by the heavier-stroke menubar template; vendor it even if no current macOS surface references it…)". The natural fix is to switch `Sources/solstone/Resources/sol-ring-template.png` to render from `assets/sol-ring-icon.svg` (matching the variants' icon-geometry stroke weight at small sizes). That is a one-line `Makefile` change in the `icons` target plus a `make icons` re-render — but it is out of scope for this lode and should be filed as a follow-up to confirm visual intent (the brand spec lists `sol-ring.svg` as the menubar template canonical, so this needs CMO sign-off before flipping).

**No PNG regeneration in this PR.** `rsvg-convert` and `iconutil` aren't available in the Linux-side session that produced this PR, and the macOS Makefile's `icons` target is Mac-only. The committed PNGs in `Sources/solstone/Resources/` (last regen `4f1d544`, 2026-04-25) reflect pre-sync sources. Next time someone runs `make icons` on a Mac, the regular-state menubar PNG will pick up the canonical base-ring geometry — visible to users on the next bundle/install. If we resolve the menubar mismatch above first, that follow-up PR can also commit the regenerated PNGs in one move.

**No casing lint adopted.** Per the request constraint, casing lint (à la solstone-swift's `assert_casing.sh`) is not added because zero residual drift exists. solstone-macos is small enough that hand-discipline holds. Revisit if drift returns or if the surface grows materially.

## reproduction

To re-run this validation in the future:

```sh
# 1. asset inventory (10 files diffed against canonical)
make brand-sync
git diff --quiet assets/ || echo "drift present"

# 2. brand color sweep
grep -rin '#[ef][8c]923[a-f]\|#b06a1a\|#f5c740\|0\.910.*0\.573\|0\.690.*0\.416\|0\.961.*0\.780' \
  Sources/ assets/ Tests/ scripts/ Makefile Package.swift

# 3. casing audit
for pat in 'Text(' 'Button(' 'Label(' 'navigationTitle(' 'Toggle(' 'Picker(' \
           'Stepper(' 'Section(' 'TextField(' 'Menu(' 'DisclosureGroup(' \
           'GroupBox(' 'LabeledContent(' 'help(' 'alert('; do
  grep -rn "${pat}\"[A-Z]" Sources/ --include="*.swift"
done

# 4. AccentColor verify
cat Sources/solstone/Resources/Assets.xcassets/AccentColor.colorset/Contents.json
```

All four return clean (no diff, no hex outside vendored SVGs + AccentColor.colorset, no Title-Case author strings, both light + dark variants present with the brand-spec comment).
