.PHONY: build release release-universal release-universal-journal run clean test ax-contract integration-test snapshot install setup reset reset-full icons check-icons-deps check-dev-deps ci \
        signing-check notary-restore unlock-signing bundle-dist bundle-dist-journal dmg dmg-journal dmg-both notarize notarize-journal notarize-both staple staple-journal staple-both verify-notarization verify-notarization-journal verify-notarization-both release-dmg release-dmg-journal release-dmg-both \
        vendor-uv vendor-python vendor-wheelhouse generate-bundle-config check-versions supply-chain-check release-dmg-smoke release-dmg-smoke-journal release-dmg-smoke-both journal-materialize-smoke brand-sync \
        release-preflight bump-release bump-release-journal journal-app-dev run-journal publish-preflight publish-appcast publish-appcast-staging publish-appcast-journal publish-appcast-journal-staging github-release github-release-journal

# Default goal when running bare `make` — build the project. brand-sync is
# opt-in (run it manually when the brand spec updates).
.DEFAULT_GOAL := build

# Brand asset source — REQUIRED by `make brand-sync` (no default). Point it at
# your sol brand asset directory: BRAND_DIR=/path/to/brand make brand-sync
BRAND_DIR ?=

# ---------------------------------------------------------------------------
# Distribution signing (Apple Developer ID + notarization)
#
# Activated 2026-04-20 when the sol pbc Apple Developer Program went live
# (team 7QCG8V4M6H). Certs live in a dedicated sol-signing keychain on the
# release host, isolated from the login keychain. Notarytool uses an ASC
# API key (no app-specific password).
# ---------------------------------------------------------------------------
DEVELOPER_ID_APP       ?= Developer ID Application: sol pbc (7QCG8V4M6H)
DEVELOPER_ID_INSTALLER ?= Developer ID Installer: sol pbc (7QCG8V4M6H)
NOTARY_PROFILE         ?= sol-pbc-notary
SIGNING_KEYCHAIN       ?= $(HOME)/Library/Keychains/sol-signing.keychain-db
SIGNING_KC_PASS_FILE   ?= $(HOME)/.config/sol-pbc/signing/keychain-password
# ASC API key + identifiers used by `make notary-restore` to rebuild the
# notarytool keychain profile when it evicts (the profile lives inside
# sol-signing.keychain-db and is reconstructable from these three inputs).
# Mirrors cso/vault/credentials/apple-asc-api-key.{p8,json} in the extro repo.
ASC_API_KEY_FILE       ?= $(HOME)/.config/sol-pbc/signing/apple-asc-api-key.p8
ASC_API_KEY_ID         ?= SNP7CMKMZ5
ASC_API_ISSUER         ?= 0fe42f6d-2c46-4f09-a9c2-152b20b3ea19
DIST_VERSION           := $(shell python3 -c "import plistlib; print(plistlib.load(open('Sources/solstone/Info.plist','rb'))['CFBundleShortVersionString'])" 2>/dev/null || echo 0.0.0)
DIST_BUILD             := $(shell python3 -c "import plistlib; print(plistlib.load(open('Sources/solstone/Info.plist','rb'))['CFBundleVersion'])" 2>/dev/null || echo 0)
DMG_NAME               ?= sol-$(DIST_VERSION).dmg
JOURNAL_DIST_VERSION   := $(shell python3 -c "import plistlib; print(plistlib.load(open('Sources/journal/Info.plist','rb'))['CFBundleShortVersionString'])" 2>/dev/null || echo 0.0.0)
JOURNAL_DIST_BUILD     := $(shell python3 -c "import plistlib; print(plistlib.load(open('Sources/journal/Info.plist','rb'))['CFBundleVersion'])" 2>/dev/null || echo 0)
JOURNAL_DMG_NAME       ?= journal-$(JOURNAL_DIST_VERSION).dmg
BOTH_DMG_NAME          ?= sol-journal-$(DIST_VERSION).dmg
DMG_VOLNAME            ?= sol
DMG_APP                ?= solstone.app
DMG_ICON               ?= solstone.app
SPARKLE_ARTIFACT_DIR   ?= .build/artifacts/sparkle/Sparkle
SPARKLE_FRAMEWORK      ?= $(SPARKLE_ARTIFACT_DIR)/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework
ENTITLEMENTS_PLIST     := Sources/solstone/entitlements.plist
# App-only entitlements (adds the DP-keychain keychain-access-groups). Helpers like the
# bundled python3.13 keep the base ENTITLEMENTS_PLIST — a profile-less helper signed with
# the restricted keychain entitlements is SIGKILLed by amfi (exit 137).
APP_ENTITLEMENTS_PLIST := Sources/solstone/entitlements-app.plist

# uv vendoring
UV_VERSION ?= 0.11.13
UV_TARBALL_NAME := uv-aarch64-apple-darwin.tar.gz
UV_RELEASE_URL_BASE ?= https://releases.astral.sh/github/uv/releases/download/$(UV_VERSION)
UV_RELEASE_URL := $(UV_RELEASE_URL_BASE)/$(UV_TARBALL_NAME)
UV_VENDOR_DIR := vendor
UV_SHA256_FILE := $(UV_VENDOR_DIR)/uv-aarch64-apple-darwin.sha256
UV_VENDOR_BINARY := $(UV_VENDOR_DIR)/uv

# version pins for installer (consumed by BundleConfig)
SOLSTONE_PIN_VERSION ?= 0.8.2
SOLSTONE_MIN_VERSION ?= 0.8.2

# python-build-standalone vendoring
PYTHON_BUILD_STANDALONE_VERSION ?= 20260510
PYTHON_VERSION ?= 3.13.13
PYTHON_TARBALL_NAME := cpython-$(PYTHON_VERSION)+$(PYTHON_BUILD_STANDALONE_VERSION)-aarch64-apple-darwin-install_only.tar.gz
PYTHON_RELEASE_URL_BASE ?= https://github.com/astral-sh/python-build-standalone/releases/download/$(PYTHON_BUILD_STANDALONE_VERSION)
PYTHON_RELEASE_URL := $(PYTHON_RELEASE_URL_BASE)/$(PYTHON_TARBALL_NAME)
PYTHON_VENDOR_DIR := vendor/python
PYTHON_VENDOR_SHA_FILE := vendor/python-aarch64-apple-darwin.sha256

# bundled backend wheelhouse
SOLSTONE_SRC_DIR ?= ../solstone
SOLSTONE_REF ?= v0.8.2
WHEELHOUSE_DIR := vendor/solstone-wheelhouse
WHEELHOUSE_MANIFEST := $(WHEELHOUSE_DIR)/MANIFEST.sha256
WHEELHOUSE_PLATFORM_TAG ?= macosx_15_0_arm64
WHEELHOUSE_ABI ?= cp313
WHEELHOUSE_PYTHON_TAG ?= 3.13

check-versions:
	@[ -n "$(SOLSTONE_PIN_VERSION)" ] || { echo "error: solstone pin version must not be empty"; exit 1; }
	@printf '0.2.1\n%s\n' "$(SOLSTONE_MIN_VERSION)" | sort -V -C || { echo "error: solstone minimum version must be >= 0.2.1 (got $(SOLSTONE_MIN_VERSION))"; exit 1; }

vendor-uv:
	@mkdir -p "$(UV_VENDOR_DIR)"
	@if [ -f "$(UV_VENDOR_BINARY)" ] && [ -f "$(UV_VENDOR_DIR)/$(UV_TARBALL_NAME)" ] && \
	    (cd "$(UV_VENDOR_DIR)" && shasum -a 256 -c "$(notdir $(UV_SHA256_FILE))" >/dev/null 2>&1); then \
	    echo "vendor: uv $(UV_VERSION) already present and sha matches"; \
	else \
	    echo "vendor: fetching uv $(UV_VERSION) from $(UV_RELEASE_URL)"; \
	    rm -rf "$(UV_VENDOR_DIR)/uv-aarch64-apple-darwin" "$(UV_VENDOR_BINARY)" "$(UV_VENDOR_DIR)/$(UV_TARBALL_NAME)"; \
	    curl --fail --location --retry 3 --retry-delay 2 --output "$(UV_VENDOR_DIR)/$(UV_TARBALL_NAME)" "$(UV_RELEASE_URL)"; \
	    (cd "$(UV_VENDOR_DIR)" && shasum -a 256 -c "$(notdir $(UV_SHA256_FILE))") || { echo "error: uv tarball sha256 mismatch"; exit 1; }; \
	    tar -xzf "$(UV_VENDOR_DIR)/$(UV_TARBALL_NAME)" -C "$(UV_VENDOR_DIR)"; \
	    mv "$(UV_VENDOR_DIR)/uv-aarch64-apple-darwin/uv" "$(UV_VENDOR_BINARY)"; \
	    chmod +x "$(UV_VENDOR_BINARY)"; \
	    echo "vendor: uv $(UV_VERSION) extracted to $(UV_VENDOR_BINARY)"; \
	fi

vendor-python:
	@mkdir -p "$(UV_VENDOR_DIR)"
	@if [ -x "$(PYTHON_VENDOR_DIR)/bin/python3.13" ] && [ -f "$(UV_VENDOR_DIR)/$(PYTHON_TARBALL_NAME)" ] && \
	    (cd "$(UV_VENDOR_DIR)" && shasum -a 256 -c "$(notdir $(PYTHON_VENDOR_SHA_FILE))" >/dev/null 2>&1); then \
	    echo "vendor: python-build-standalone $(PYTHON_VERSION)+$(PYTHON_BUILD_STANDALONE_VERSION) already present and sha matches"; \
	else \
	    echo "vendor: fetching python-build-standalone $(PYTHON_VERSION)+$(PYTHON_BUILD_STANDALONE_VERSION) from $(PYTHON_RELEASE_URL)"; \
	    rm -rf "$(PYTHON_VENDOR_DIR)" "$(UV_VENDOR_DIR)/$(PYTHON_TARBALL_NAME)"; \
	    curl --fail --location --retry 3 --retry-delay 2 --output "$(UV_VENDOR_DIR)/$(PYTHON_TARBALL_NAME)" "$(PYTHON_RELEASE_URL)"; \
	    (cd "$(UV_VENDOR_DIR)" && shasum -a 256 -c "$(notdir $(PYTHON_VENDOR_SHA_FILE))") || { echo "error: python-build-standalone tarball sha256 mismatch; re-pin intentionally before updating $(PYTHON_VENDOR_SHA_FILE)"; exit 1; }; \
	    tar -xzf "$(UV_VENDOR_DIR)/$(PYTHON_TARBALL_NAME)" -C "$(UV_VENDOR_DIR)"; \
	    [ -d "$(PYTHON_VENDOR_DIR)" ] || { echo "error: python-build-standalone did not extract to $(PYTHON_VENDOR_DIR)"; exit 1; }; \
	    [ -x "$(PYTHON_VENDOR_DIR)/bin/python3.13" ] || { echo "error: bundled python missing executable"; exit 1; }; \
	    [ -f "$(PYTHON_VENDOR_DIR)/lib/libpython3.13.dylib" ] || { echo "error: bundled python missing libpython3.13.dylib"; exit 1; }; \
	    [ -d "$(PYTHON_VENDOR_DIR)/lib/python3.13/lib-dynload" ] || { echo "error: bundled python missing lib-dynload"; exit 1; }; \
	    "$(PYTHON_VENDOR_DIR)/bin/python3.13" --version 2>&1 | grep -F "Python $(PYTHON_VERSION)" >/dev/null || { echo "error: bundled python reported wrong version"; exit 1; }; \
	    echo "vendor: python-build-standalone $(PYTHON_VERSION)+$(PYTHON_BUILD_STANDALONE_VERSION) extracted to $(PYTHON_VENDOR_DIR)"; \
	fi

vendor-wheelhouse: check-versions vendor-uv vendor-python
	@# wheel-macos signs+notarizes the helper inside the wheel; requires the sol-signing keychain unlocked and the sol-pbc-notary profile (bundle-dist orders unlock-signing/signing-check first).
	@set -e; \
	    if [ "$$(uname -s)" != "Darwin" ] || [ "$$(uname -m)" != "arm64" ]; then \
	        echo "error: vendor-wheelhouse must run on a macOS arm64 host (pip evaluates dependency markers against the running host; mlx requires darwin+arm64)"; \
	        exit 1; \
	    fi; \
	    if [ ! -d "$(SOLSTONE_SRC_DIR)/.git" ]; then \
	        echo "error: SOLSTONE_SRC_DIR '$(SOLSTONE_SRC_DIR)' is not a git repo; set SOLSTONE_SRC_DIR=/path/to/solstone"; \
	        exit 1; \
	    fi; \
	    git -C "$(SOLSTONE_SRC_DIR)" rev-parse --verify "$(SOLSTONE_REF)" >/dev/null 2>&1 || { echo "vendor: SOLSTONE_REF '$(SOLSTONE_REF)' not in $(SOLSTONE_SRC_DIR) yet; fetching tags from origin..."; git -C "$(SOLSTONE_SRC_DIR)" fetch --quiet --tags origin >/dev/null 2>&1 || true; }; \
	    git -C "$(SOLSTONE_SRC_DIR)" rev-parse --verify "$(SOLSTONE_REF)" >/dev/null 2>&1 || { echo "error: SOLSTONE_REF '$(SOLSTONE_REF)' not found in $(SOLSTONE_SRC_DIR) (even after a tag fetch from origin)"; exit 1; }; \
	    if python3 scripts/wheelhouse_helper.py verify-wheelhouse "$(WHEELHOUSE_DIR)" "$(SOLSTONE_PIN_VERSION)" >/dev/null 2>&1; then \
	        echo "vendor: solstone wheelhouse $(SOLSTONE_PIN_VERSION) already present and verified"; \
	        exit 0; \
	    fi; \
	    EXPORT_DIR="$$(mktemp -d -t solstone-export)"; \
	    BUILD_DIR="$$(mktemp -d -t solstone-wheelhouse)"; \
	    trap 'rm -rf "$$EXPORT_DIR" "$$BUILD_DIR"' EXIT; \
	    echo "vendor: building solstone wheelhouse from $(SOLSTONE_SRC_DIR) at $(SOLSTONE_REF)"; \
	    ARCHIVE_TAR="$$BUILD_DIR/solstone-src.tar"; \
	    git -C "$(SOLSTONE_SRC_DIR)" archive "$(SOLSTONE_REF)" > "$$ARCHIVE_TAR" || { echo "error: failed to archive $(SOLSTONE_SRC_DIR) at $(SOLSTONE_REF)"; exit 1; }; \
	    tar -x -f "$$ARCHIVE_TAR" -C "$$EXPORT_DIR" || { echo "error: failed to extract solstone archive"; exit 1; }; \
	    $(MAKE) -C "$$EXPORT_DIR" UV="$(abspath $(UV_VENDOR_BINARY))" wheel-macos || { echo "error: wheel-macos build failed for $(SOLSTONE_SRC_DIR) at $(SOLSTONE_REF)"; exit 1; }; \
	    BUILT_COUNT="$$(find "$$EXPORT_DIR/dist" -maxdepth 1 -type f -name 'solstone-$(SOLSTONE_PIN_VERSION)-*.whl' | wc -l | tr -d ' ')"; \
	    [ "$$BUILT_COUNT" = "1" ] || { echo "error: expected exactly one built solstone wheel in $$EXPORT_DIR/dist, found $$BUILT_COUNT"; exit 1; }; \
	    BUILT_WHEEL="$$(find "$$EXPORT_DIR/dist" -maxdepth 1 -type f -name 'solstone-$(SOLSTONE_PIN_VERSION)-*.whl' | head -n 1)"; \
	    BUILT_VERSION="$$(python3 scripts/wheelhouse_helper.py wheel-version "$$BUILT_WHEEL")"; \
	    [ "$$BUILT_VERSION" = "$(SOLSTONE_PIN_VERSION)" ] || { echo "error: sibling backend version $$BUILT_VERSION != pinned $(SOLSTONE_PIN_VERSION) — re-pin or update sibling"; exit 1; }; \
	    rm -rf "$(WHEELHOUSE_DIR)"; \
	    mkdir -p "$(WHEELHOUSE_DIR)"; \
	    mv "$$BUILT_WHEEL" "$(WHEELHOUSE_DIR)/"; \
	    REQS="$$BUILD_DIR/requirements.txt"; \
	    (cd "$$EXPORT_DIR" && "$(abspath $(UV_VENDOR_BINARY))" export --frozen --no-dev --package solstone-journal --no-emit-workspace --no-editable --python "$(abspath $(PYTHON_VENDOR_DIR))/bin/python3.13" -o "$$REQS") || { echo "error: uv export failed"; exit 1; }; \
	    "$(PYTHON_VENDOR_DIR)/bin/python3.13" -m pip download -r "$$REQS" --only-binary=:all: --dest "$(WHEELHOUSE_DIR)" --platform "$(WHEELHOUSE_PLATFORM_TAG)" --python-version "$(WHEELHOUSE_PYTHON_TAG)" --implementation cp --abi "$(WHEELHOUSE_ABI)" || { echo "error: pip wheel download failed"; exit 1; }; \
	    LEAF_BUILD_DIR="$$BUILD_DIR/leaf"; \
	    mkdir -p "$$LEAF_BUILD_DIR"; \
	    (cd "$$EXPORT_DIR" && "$(abspath $(UV_VENDOR_BINARY))" build --package solstone-journal --wheel --out-dir "$$LEAF_BUILD_DIR") || { echo "error: solstone-journal wheel build failed"; exit 1; }; \
	    LEAF_WHEEL="$$(find "$$LEAF_BUILD_DIR" -maxdepth 1 -type f -name 'solstone_journal-$(SOLSTONE_PIN_VERSION)-*.whl' | head -n 1)"; \
	    [ -n "$$LEAF_WHEEL" ] || { echo "error: solstone-journal wheel not produced for $(SOLSTONE_PIN_VERSION)"; exit 1; }; \
	    mv "$$LEAF_WHEEL" "$(WHEELHOUSE_DIR)/"; \
	    MODELS_BUILD_DIR="$$BUILD_DIR/models"; \
	    mkdir -p "$$MODELS_BUILD_DIR"; \
	    (cd "$$EXPORT_DIR" && "$(abspath $(UV_VENDOR_BINARY))" build --package solstone-journal-models --wheel --out-dir "$$MODELS_BUILD_DIR") || { echo "error: solstone journal models wheel build failed"; exit 1; }; \
	    MODELS_WHEEL="$$(find "$$MODELS_BUILD_DIR" -maxdepth 1 -type f -name 'solstone_journal_models-*.whl' | head -n 1)"; \
	    [ -n "$$MODELS_WHEEL" ] || { echo "error: solstone journal models wheel not produced"; exit 1; }; \
	    mv "$$MODELS_WHEEL" "$(WHEELHOUSE_DIR)/"; \
	    PINNED_COUNT="$$(find "$(WHEELHOUSE_DIR)" -maxdepth 1 -type f -name 'solstone-$(SOLSTONE_PIN_VERSION)-*.whl' | wc -l | tr -d ' ')"; \
	    [ "$$PINNED_COUNT" = "1" ] || { echo "error: expected exactly one solstone-$(SOLSTONE_PIN_VERSION)-*.whl in $(WHEELHOUSE_DIR)"; exit 1; }; \
	    LEAF_COUNT="$$(find "$(WHEELHOUSE_DIR)" -maxdepth 1 -type f -name 'solstone_journal-$(SOLSTONE_PIN_VERSION)-*.whl' | wc -l | tr -d ' ')"; \
	    [ "$$LEAF_COUNT" = "1" ] || { echo "error: expected exactly one solstone_journal-$(SOLSTONE_PIN_VERSION)-*.whl in $(WHEELHOUSE_DIR)"; exit 1; }; \
	    MODELS_COUNT="$$(find "$(WHEELHOUSE_DIR)" -maxdepth 1 -type f -name 'solstone_journal_models-*.whl' | wc -l | tr -d ' ')"; \
	    [ "$$MODELS_COUNT" = "1" ] || { echo "error: expected exactly one solstone_journal_models-*.whl in $(WHEELHOUSE_DIR)"; exit 1; }; \
	    WHEEL_COUNT="$$(find "$(WHEELHOUSE_DIR)" -maxdepth 1 -type f -name '*.whl' | wc -l | tr -d ' ')"; \
	    [ "$$WHEEL_COUNT" -gt 1 ] || { echo "error: dependency wheel download produced no dependency wheels"; exit 1; }; \
	    NON_WHEELS="$$(find "$(WHEELHOUSE_DIR)" -maxdepth 1 -type f ! -name '*.whl' -print)"; \
	    [ -z "$$NON_WHEELS" ] || { echo "error: wheelhouse contains non-wheel payload files"; echo "$$NON_WHEELS"; exit 1; }; \
	    RUNTIME_DIRS="$$(find "$(WHEELHOUSE_DIR)" -mindepth 1 -type d \( -name '__pycache__' -o -name '.venv' -o -name 'venv' -o -name 'cache' -o -name 'model' -o -name 'models' \) -print)"; \
	    [ -z "$$RUNTIME_DIRS" ] || { echo "error: wheelhouse contains runtime/cache/model dirs"; echo "$$RUNTIME_DIRS"; exit 1; }; \
	    (cd "$(WHEELHOUSE_DIR)" && shasum -a 256 *.whl > "$(notdir $(WHEELHOUSE_MANIFEST))"); \
	    python3 scripts/wheelhouse_helper.py verify-wheelhouse "$(WHEELHOUSE_DIR)" "$(SOLSTONE_PIN_VERSION)" || { echo "error: wheelhouse verification failed"; exit 1; }; \
	    echo "vendor: solstone wheelhouse $(SOLSTONE_PIN_VERSION) built at $(WHEELHOUSE_DIR)"

generate-bundle-config: check-versions
	@SHA="$$(awk '{print $$1; exit}' "$(UV_SHA256_FILE)")"; \
	    [ -n "$$SHA" ] || { echo "error: could not read sha from $(UV_SHA256_FILE)"; exit 1; }; \
	    { \
	        printf '%s\n' '/// machine-generated by `make generate-bundle-config`; do not edit.'; \
	        printf '%s\n' 'public enum BundleConfig {'; \
	        printf '    public static let solstonePinVersion = "%s"\n' "$(SOLSTONE_PIN_VERSION)"; \
	        printf '    public static let solstoneMinVersion = "%s"\n' "$(SOLSTONE_MIN_VERSION)"; \
	        printf '    public static let bundledUVVersion = "%s"\n' "$(UV_VERSION)"; \
	        printf '    public static let bundledPythonBuild = "%s"\n' "$(PYTHON_BUILD_STANDALONE_VERSION)"; \
	        printf '%s\n' '}'; \
	    } > Sources/JournalRuntime/BundleConfig.swift
	@echo "generated: Sources/JournalRuntime/BundleConfig.swift"

# Re-vendor brand SVGs from the canonical source. CI verifies the committed
# output (it does not run brand-sync) — run this locally when the brand spec
# updates, then commit the diff.
brand-sync:
	@test -n "$(BRAND_DIR)" || { echo "brand: BRAND_DIR is required — point it at your sol brand asset directory (BRAND_DIR=/path/to/brand make brand-sync)"; exit 1; }
	@test -d "$(BRAND_DIR)" || { echo "brand: BRAND_DIR=$(BRAND_DIR) not found"; exit 1; }
	cp "$(BRAND_DIR)/sol-wordmark.svg"          assets/sol-wordmark.svg
	cp "$(BRAND_DIR)/sol-wordmark-white.svg"    assets/sol-wordmark-white.svg
	cp "$(BRAND_DIR)/sol-ring.svg"              assets/sol-ring.svg
	cp "$(BRAND_DIR)/sol-ring-icon.svg"         assets/sol-ring-icon.svg
	cp "$(BRAND_DIR)/sol-ring-icon-error.svg"   assets/sol-ring-icon-error.svg
	cp "$(BRAND_DIR)/sol-ring-icon-paused.svg"  assets/sol-ring-icon-paused.svg
	cp "$(BRAND_DIR)/sol-ring-icon-half.svg"    assets/sol-ring-icon-half.svg
	# macOS app icon uses the macOS-convention squircle source (inset rounded-rect
	# plate on a transparent canvas — macOS does NOT auto-mask icons). iOS keeps the
	# full-bleed cream master in solstone-swift (iOS auto-masks). Do NOT point this
	# back at the full-bleed cream master — that ships the lone non-native square in
	# the Dock. The unified wordmark direction (locked 2026-06-25) is ONE mark at all
	# sizes — no per-size hand-tuned 16/32 variants; `make icons` renders icon-app.svg
	# at every iconset size. See records/decisions/260625-cmo-sol-app-icon-unified-wordmark.md.
	cp "$(BRAND_DIR)/app-icon/sol-app-icon-macos.svg" assets/icon-app.svg
	@echo "brand: synced from $(BRAND_DIR)"

# Build debug version
build:
	swift build

# Build release version
release:
	swift build -c release

# Build universal binary (arm64 + x86_64)
release-universal:
	swift build -c release --arch arm64 --arch x86_64 --product solstone
	swift build -c release --arch arm64 --arch x86_64 --product solstone-watchdog

release-universal-journal:
	swift build -c release --arch arm64 --arch x86_64 --product journal
	swift build -c release --arch arm64 --arch x86_64 --product solstone-watchdog

# Run the built app from the source tree and stream all logs to a timestamped
# file in scratch/. Run `make bundle-dist` first to produce solstone.app.
# Keeps capturing across app restarts. Ctrl+C to stop.
run:
	@test -d solstone.app || { echo "error: solstone.app not found — run 'make bundle-dist' first"; exit 1; }
	@mkdir -p scratch; \
	LOG=scratch/$$(date +%Y%m%d_%H%M%S).log; \
	echo "Streaming logs → $$LOG  (Ctrl+C to stop)"; \
	/usr/bin/log stream --predicate 'subsystem == "app.solstone.observer"' --level debug > "$$LOG" 2>&1 & \
	STREAM_PID=$$!; \
	open solstone.app; \
	trap "kill $$STREAM_PID 2>/dev/null; echo; echo 'Log saved: $$LOG'" INT TERM; \
	wait $$STREAM_PID

# Clean all build artifacts
clean:
	swift package clean
	rm -rf .build
	rm -rf solstone.app

# Run tests
test:
	swift test

ax-contract:
	AX_CONTRACT_REGEN=1 swift test --filter AXContract

ci:
	@./scripts/run-ci.sh

integration-test:
	SPL_INTEGRATION=1 swift test --filter 'SPLTunnelTests.IntegrationTests'

# Render view snapshots
snapshot:
	swift test --filter Snapshot

check-dev-deps:
	@xcodebuild -version > /dev/null 2>&1 || \
		{ echo "error: Xcode is required for local builds"; \
		  echo "       install the full Xcode app from the Mac App Store, then run it once"; \
		  exit 1; }

# =======================================================================
# Distribution pipeline: Developer ID signed + notarized DMG
#
# Use `make release-dmg`, `make release-dmg-journal`, or `make release-dmg-both`
# to produce signed, notarized, stapled DMGs ready to hand out for ad-hoc install.
# `make bundle-dist` signs solstone.app without the journal runtime plane; `make
# bundle-dist-journal` signs journal.app with bundled uv, Python, and wheelhouse
# runtime material.
# All signing runs headless over SSH using the sol-signing keychain (see
# header).
# =======================================================================

# Read-only check that Developer ID certs + notary profile are ready.
# If the notary profile has evicted (recurring failure mode), auto-heal
# from the local ASC API key. Cert checks remain hard-fail because cert
# loss is a different class of problem and warrants founder attention.
signing-check:
	@security find-identity -v -p codesigning | grep -q '"$(DEVELOPER_ID_APP)"' || \
		{ echo "error: '$(DEVELOPER_ID_APP)' not found in any keychain on the search list"; \
		  echo "       ensure $(SIGNING_KEYCHAIN) is in 'security list-keychains -d user'"; \
		  exit 1; }
	@security find-identity -v | grep -q '"$(DEVELOPER_ID_INSTALLER)"' || \
		{ echo "error: '$(DEVELOPER_ID_INSTALLER)' not found"; exit 1; }
	@xcrun notarytool history --keychain-profile "$(NOTARY_PROFILE)" --keychain "$(SIGNING_KEYCHAIN)" > /dev/null 2>&1 || \
		{ echo "notarytool profile '$(NOTARY_PROFILE)' missing — auto-restoring from $(ASC_API_KEY_FILE)…"; \
		  $(MAKE) -s notary-restore; }
	@echo "✓ Developer ID certs + notary profile ready"

# Rebuild the notarytool keychain profile from the local ASC API key.
# Idempotent — safe to re-run. Use when `signing-check` fails on the
# notary profile (most common failure mode: profile evicts after OS
# updates, keychain rotation, or other tool churn). The .p8 + key-id +
# issuer-id are the source of truth; the profile is reconstructable
# from them.
notary-restore: unlock-signing
	@test -f "$(ASC_API_KEY_FILE)" || \
		{ echo "error: ASC API key missing at $(ASC_API_KEY_FILE)"; \
		  echo "       copy from extro vault: scp cso/vault/credentials/apple-asc-api-key.p8 pro5e.local:$(ASC_API_KEY_FILE) && ssh pro5e.local chmod 600 $(ASC_API_KEY_FILE)"; \
		  exit 1; }
	@xcrun notarytool store-credentials "$(NOTARY_PROFILE)" \
		--key "$(ASC_API_KEY_FILE)" \
		--key-id "$(ASC_API_KEY_ID)" \
		--issuer "$(ASC_API_ISSUER)" \
		--keychain "$(SIGNING_KEYCHAIN)" >/dev/null
	@echo "✓ notarytool profile '$(NOTARY_PROFILE)' restored in $(SIGNING_KEYCHAIN)"

# Pre-flight gate before kicking off `make release-dmg`. Catches the
# 2026-05-12 ghost-fix scenario where in-session swift edits were live on
# disk during the cold smoke but never committed — a rebuild would have
# shipped without them. Verifies: working tree clean, on a branch tracking
# origin, no stale signing/build processes that might hold a keychain
# prompt open, signing-check (which auto-heals notary profile).
release-preflight: signing-check
	@if ! git diff --quiet || ! git diff --cached --quiet; then \
		echo "error: working tree has uncommitted changes — commit or stash before release"; \
		git status --short; \
		exit 1; \
	fi
	@STALE="$$(ps aux | grep -E 'tmux-run|notarytool|sign-and|wheel-macos|codesign' | grep -v grep | grep -v 'release-preflight' || true)"; \
		[ -z "$$STALE" ] || { \
			echo "error: stale signing/build processes — one may be holding a keychain prompt:"; \
			echo "$$STALE"; \
			echo "       investigate with tmux capture-pane, then 'pkill -9 -f <pattern>'"; \
			exit 1; \
		}
	@BRANCH="$$(git rev-parse --abbrev-ref HEAD)"; \
		[ "$$BRANCH" = "main" ] || { echo "warn: releasing from non-main branch '$$BRANCH'"; }
	@AHEAD="$$(git rev-list --count @{u}..HEAD 2>/dev/null || echo 0)"; \
		[ "$$AHEAD" = "0" ] || { echo "warn: $$AHEAD local commit(s) ahead of upstream — push before release"; }
	@echo "✓ release pre-flight clean: tree clean, no stale processes, signing ready"

# Bump sol.app's user-visible version and root changelog only. Journal runtime
# pins move through bump-release-journal so sol releases do not touch
# BundleConfig or backend material.
#
# Usage: make bump-release VERSION=1.1.4 BUILD=6
#   VERSION  required, semver — sets CFBundleShortVersionString
#   BUILD    required, integer — sets CFBundleVersion (must be > current)
#
# Side effects: sol Info.plist updated via plutil and CHANGELOG.md scaffold
# prepended for the new version (date defaults to today). Does NOT commit.
bump-release:
	@test -n "$(VERSION)" || { echo "error: VERSION=... required (e.g. VERSION=1.1.4)"; exit 1; }
	@test -n "$(BUILD)"   || { echo "error: BUILD=... required (e.g. BUILD=6)"; exit 1; }
	@test -z "$(SOLSTONE)" || { echo "error: SOLSTONE= belongs to bump-release-journal"; exit 1; }
	@CURRENT_BUILD="$(DIST_BUILD)"; \
		python3 -c "import sys; sys.exit(0 if int('$(BUILD)') > int('$$CURRENT_BUILD') else 1)" || \
		{ echo "error: BUILD=$(BUILD) must be strictly greater than current $$CURRENT_BUILD (Sparkle uses CFBundleVersion for 'is newer?')"; exit 1; }
	@/usr/bin/plutil -replace CFBundleShortVersionString -string "$(VERSION)" Sources/solstone/Info.plist
	@/usr/bin/plutil -replace CFBundleVersion -string "$(BUILD)" Sources/solstone/Info.plist
	@echo "✓ Info.plist: CFBundleShortVersionString=$(VERSION), CFBundleVersion=$(BUILD)"
	@if grep -q "^## \[$(VERSION)\]" CHANGELOG.md; then \
		echo "note: CHANGELOG.md already has an entry for $(VERSION); leaving it alone"; \
	else \
		TODAY="$$(date +%Y-%m-%d)"; \
		awk -v v="$(VERSION)" -v d="$$TODAY" 'NR==1 {print; next} /^## \[/ && !inserted {print "## [" v "] - " d "\n\n### Added\n- (describe new user-visible additions)\n\n### Changed\n- (describe behavior changes)\n\n### Fixed\n- (describe bug fixes)\n\n"; inserted=1} {print}' CHANGELOG.md > CHANGELOG.md.tmp && mv CHANGELOG.md.tmp CHANGELOG.md; \
		echo "✓ CHANGELOG.md: scaffolded entry for [$(VERSION)] — $$TODAY (FILL IN BEFORE COMMIT)"; \
	fi
	@echo ""
	@echo "next steps:"
	@echo "  1. edit CHANGELOG.md — replace scaffold bullets with real release notes"
	@echo "  2. git diff to review"
	@echo "  3. git add Sources/solstone/Info.plist Makefile CHANGELOG.md"
	@echo "  4. git commit -m 'release: bump to $(VERSION) (build $(BUILD))'"
	@echo "  5. git push origin main"
	@echo "  6. make release-preflight && make release-dmg"

bump-release-journal:
	@test -n "$(VERSION)" || { echo "error: VERSION=... required (e.g. VERSION=1.0.1)"; exit 1; }
	@test -n "$(BUILD)"   || { echo "error: BUILD=... required (e.g. BUILD=2)"; exit 1; }
	@test -n "$(SOLSTONE)" || { echo "error: SOLSTONE=... required for journal runtime pin"; exit 1; }
	@CURRENT_BUILD="$(JOURNAL_DIST_BUILD)"; \
		python3 -c "import sys; sys.exit(0 if int('$(BUILD)') > int('$$CURRENT_BUILD') else 1)" || \
		{ echo "error: BUILD=$(BUILD) must be strictly greater than current journal build $$CURRENT_BUILD"; exit 1; }
	@/usr/bin/plutil -replace CFBundleShortVersionString -string "$(VERSION)" Sources/journal/Info.plist
	@/usr/bin/plutil -replace CFBundleVersion -string "$(BUILD)" Sources/journal/Info.plist
	@echo "✓ journal Info.plist: CFBundleShortVersionString=$(VERSION), CFBundleVersion=$(BUILD)"
	@sed -i '' "s/^SOLSTONE_PIN_VERSION ?= .*/SOLSTONE_PIN_VERSION ?= $(SOLSTONE)/" Makefile
	@sed -i '' "s/^SOLSTONE_MIN_VERSION ?= .*/SOLSTONE_MIN_VERSION ?= $(SOLSTONE)/" Makefile
	@sed -i '' "s/^SOLSTONE_REF ?= .*/SOLSTONE_REF ?= v$(SOLSTONE)/" Makefile
	@echo "✓ Makefile pins: SOLSTONE_PIN_VERSION = $(SOLSTONE), SOLSTONE_REF = v$(SOLSTONE)"
	@$(MAKE) -s SOLSTONE_PIN_VERSION="$(SOLSTONE)" SOLSTONE_MIN_VERSION="$(SOLSTONE)" generate-bundle-config
	@if grep -q "^## \[$(VERSION)\]" CHANGELOG-journal.md; then \
		echo "note: CHANGELOG-journal.md already has an entry for $(VERSION); leaving it alone"; \
	else \
		TODAY="$$(date +%Y-%m-%d)"; \
		awk -v v="$(VERSION)" -v d="$$TODAY" 'NR==1 {print; next} /^## \[/ && !inserted {print "## [" v "] - " d "\n\n### Added\n- (describe new journal-visible additions)\n\n### Changed\n- (describe journal behavior changes)\n\n### Fixed\n- (describe journal bug fixes)\n\n"; inserted=1} {print}' CHANGELOG-journal.md > CHANGELOG-journal.md.tmp && mv CHANGELOG-journal.md.tmp CHANGELOG-journal.md; \
		echo "✓ CHANGELOG-journal.md: scaffolded entry for [$(VERSION)] — $$TODAY (FILL IN BEFORE COMMIT)"; \
	fi
	@echo ""
	@echo "next steps:"
	@echo "  1. edit CHANGELOG-journal.md — replace scaffold bullets with real release notes"
	@echo "  2. git diff to review"
	@echo "  3. git add Sources/journal/Info.plist Makefile Sources/JournalRuntime/BundleConfig.swift CHANGELOG-journal.md"
	@echo "  4. git commit -m 'release: bump journal to $(VERSION) (build $(BUILD))'"
	@echo "  5. git push origin main"
	@echo "  6. make release-preflight && make release-dmg-journal"

# Unlock the sol-signing keychain and add it to the session search list.
# Fresh SSH sessions don't always inherit the user-domain search list, so
# setting it here makes `make signing-check` work from any session (not just
# the persistent hopper:build tmux window).
unlock-signing:
	@security list-keychains -s "$(SIGNING_KEYCHAIN)" "$(HOME)/Library/Keychains/login.keychain-db" >/dev/null
	@if [ -f "$(SIGNING_KC_PASS_FILE)" ]; then \
		security unlock-keychain -p "$$(cat $(SIGNING_KC_PASS_FILE))" "$(SIGNING_KEYCHAIN)"; \
	else \
		echo "warn: $(SIGNING_KC_PASS_FILE) missing — signing keychain may be locked"; \
	fi

# Build a universal .app bundle signed with Developer ID Application + hardened runtime.
# Separate from `bundle-universal` so distribution signing is additive, not destructive —
# existing self-signed bundle target stays for local dev.
bundle-dist: unlock-signing signing-check release-universal
	@echo "Creating distribution app bundle..."
	@rm -rf solstone.app
	@mkdir -p solstone.app/Contents/MacOS solstone.app/Contents/Resources solstone.app/Contents/Frameworks
	@cp .build/apple/Products/Release/solstone solstone.app/Contents/MacOS/
	@cp .build/apple/Products/Release/solstone-watchdog solstone.app/Contents/MacOS/
	@cp Sources/solstone/Info.plist solstone.app/Contents/
	@# Embedded Developer ID provisioning profile authorizes the keychain-access-groups
	@# entitlement (Data Protection keychain for the SPL pairing bundle). Must be in place
	@# before the app is signed so it is sealed into the signature.
	@cp Sources/solstone/embedded.provisionprofile solstone.app/Contents/embedded.provisionprofile
	@cp Sources/solstone/Resources/AppIcon.icns solstone.app/Contents/Resources/
	@mkdir -p solstone.app/Contents/Library/LaunchAgents
	@cp Sources/solstone/app.solstone.observer.watchdog.plist solstone.app/Contents/Library/LaunchAgents/
	@cp -r .build/apple/Products/Release/solstone_solstone.bundle solstone.app/Contents/Resources/
	@cp -r .build/apple/Products/Release/solstone_JournalMarkKit.bundle solstone.app/Contents/Resources/
	@cp -R "$(SPARKLE_FRAMEWORK)" solstone.app/Contents/Frameworks/
	@install_name_tool -add_rpath "@executable_path/../Frameworks" solstone.app/Contents/MacOS/solstone
	@codesign --force --options runtime --timestamp \
		--sign "$(DEVELOPER_ID_APP)" --keychain "$(SIGNING_KEYCHAIN)" \
		solstone.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc
	@codesign --force --options runtime --timestamp \
		--sign "$(DEVELOPER_ID_APP)" --keychain "$(SIGNING_KEYCHAIN)" \
		solstone.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc
	@codesign --force --options runtime --timestamp \
		--sign "$(DEVELOPER_ID_APP)" --keychain "$(SIGNING_KEYCHAIN)" \
		solstone.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate
	@codesign --force --options runtime --timestamp \
		--sign "$(DEVELOPER_ID_APP)" --keychain "$(SIGNING_KEYCHAIN)" \
		solstone.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app
	@codesign --force --options runtime --timestamp \
		--sign "$(DEVELOPER_ID_APP)" --keychain "$(SIGNING_KEYCHAIN)" \
		solstone.app/Contents/Frameworks/Sparkle.framework
	@codesign --force --options runtime --timestamp \
		--sign "$(DEVELOPER_ID_APP)" --keychain "$(SIGNING_KEYCHAIN)" \
		solstone.app/Contents/Resources/solstone_solstone.bundle
	@codesign --force --options runtime --timestamp \
		--sign "$(DEVELOPER_ID_APP)" --keychain "$(SIGNING_KEYCHAIN)" \
		solstone.app/Contents/Resources/solstone_JournalMarkKit.bundle
	@codesign --force --options runtime --timestamp \
		--identifier app.solstone.observer.watchdog \
		--sign "$(DEVELOPER_ID_APP)" --keychain "$(SIGNING_KEYCHAIN)" \
		solstone.app/Contents/MacOS/solstone-watchdog
	@codesign --force --options runtime --timestamp \
		--sign "$(DEVELOPER_ID_APP)" --keychain "$(SIGNING_KEYCHAIN)" \
		--entitlements "$(APP_ENTITLEMENTS_PLIST)" \
		solstone.app
	@VERIFY_OUT="$$(mktemp -t solstone-codesign-verify)"; \
		if codesign --verify --strict --deep --verbose=2 solstone.app >"$$VERIFY_OUT" 2>&1; then \
			rm -f "$$VERIFY_OUT"; \
		elif grep -Eq '(__pycache__|\.pyc)' "$$VERIFY_OUT"; then \
			cat "$$VERIFY_OUT"; \
			echo "codesign verify failed on python bytecode; removing __pycache__ and re-sealing"; \
			rm -rf solstone.app/Contents/Resources/python/lib/python3.13/encodings/__pycache__; \
			codesign --force --options runtime --timestamp \
				--sign "$(DEVELOPER_ID_APP)" --keychain "$(SIGNING_KEYCHAIN)" \
				--entitlements "$(APP_ENTITLEMENTS_PLIST)" \
				solstone.app; \
			codesign --verify --strict --deep --verbose=2 solstone.app; \
			rm -f "$$VERIFY_OUT"; \
		else \
			cat "$$VERIFY_OUT"; \
			rm -f "$$VERIFY_OUT"; \
			exit 1; \
		fi
	@test -f solstone.app/Contents/embedded.provisionprofile || { echo "error: embedded.provisionprofile missing from bundle"; exit 1; }
	@codesign -d --entitlements - --xml solstone.app 2>/dev/null | plutil -p - 2>/dev/null | grep -q '7QCG8V4M6H.app.solstone.observer.spl' || { echo "error: keychain-access-group entitlement missing from signed app (DP keychain would -34018)"; exit 1; }
	@BAD="$$(find solstone.app -path '*uv*' -o -path '*/python' -o -path '*python3.13*' -o -path '*wheelhouse*' 2>/dev/null | head -1)"; \
		[ -z "$$BAD" ] || { echo "error: solstone.app must not ship the journal runtime plane (found: $$BAD)"; exit 1; }
	@echo "✓ Signed: solstone.app (keychain-access-group + embedded profile verified)"

journal-app-dev:
	@echo "Building journal dev app..."
	@swift build -c release --product journal
	@swift build -c release --product solstone-watchdog
	@BUILD_DIR="$$(swift build -c release --show-bin-path)"; \
		echo "Assembling journal.app from $$BUILD_DIR"; \
		rm -rf journal.app; \
		mkdir -p journal.app/Contents/MacOS journal.app/Contents/Resources journal.app/Contents/Frameworks journal.app/Contents/Library/LaunchAgents; \
		cp "$$BUILD_DIR/journal" journal.app/Contents/MacOS/; \
		cp "$$BUILD_DIR/solstone-watchdog" journal.app/Contents/MacOS/; \
		cp Sources/journal/Info.plist journal.app/Contents/; \
		cp Sources/journal/Resources/AppIcon.icns journal.app/Contents/Resources/; \
		cp Sources/journal/app.solstone.journal.watchdog.plist journal.app/Contents/Library/LaunchAgents/; \
		test -d "$$BUILD_DIR/solstone_JournalMarkKit.bundle" || { echo "error: solstone_JournalMarkKit.bundle missing from $$BUILD_DIR"; exit 1; }; \
		cp -R "$$BUILD_DIR/solstone_JournalMarkKit.bundle" journal.app/Contents/Resources/; \
		if [ -d "$$BUILD_DIR/solstone_journal.bundle" ]; then \
			cp -R "$$BUILD_DIR/solstone_journal.bundle" journal.app/Contents/Resources/; \
		fi; \
		if [ -d "$(SPARKLE_FRAMEWORK)" ]; then \
			cp -R "$(SPARKLE_FRAMEWORK)" journal.app/Contents/Frameworks/; \
		elif [ -d "$$BUILD_DIR/Sparkle.framework" ]; then \
			cp -R "$$BUILD_DIR/Sparkle.framework" journal.app/Contents/Frameworks/; \
		else \
			echo "error: Sparkle.framework not found at $(SPARKLE_FRAMEWORK) or $$BUILD_DIR/Sparkle.framework"; \
			exit 1; \
		fi; \
		RPATH_LOG="$$(mktemp -t journal-rpath)"; \
		if install_name_tool -add_rpath "@executable_path/../Frameworks" journal.app/Contents/MacOS/journal 2>"$$RPATH_LOG"; then \
			rm -f "$$RPATH_LOG"; \
		elif grep -Eq 'would duplicate path|already exists' "$$RPATH_LOG"; then \
			rm -f "$$RPATH_LOG"; \
		else \
			cat "$$RPATH_LOG"; \
			rm -f "$$RPATH_LOG"; \
			exit 1; \
		fi; \
		echo "✓ Assembled: journal.app"; \
		find journal.app/Contents -maxdepth 3 \( -path '*/Versions' -o -path '*/_CodeSignature' \) -prune -o \( -type f -o -type d \) -print | sort

bundle-dist-journal: unlock-signing signing-check vendor-uv vendor-python vendor-wheelhouse generate-bundle-config release-universal-journal
	@echo "Creating journal distribution app bundle..."
	@rm -rf journal.app
	@mkdir -p journal.app/Contents/MacOS journal.app/Contents/Resources journal.app/Contents/Frameworks journal.app/Contents/Library/LaunchAgents
	@cp .build/apple/Products/Release/journal journal.app/Contents/MacOS/
	@cp .build/apple/Products/Release/solstone-watchdog journal.app/Contents/MacOS/
	@cp Sources/journal/Info.plist journal.app/Contents/
	@cp Sources/journal/Resources/AppIcon.icns journal.app/Contents/Resources/
	@cp Sources/journal/app.solstone.journal.watchdog.plist journal.app/Contents/Library/LaunchAgents/
	@test -d .build/apple/Products/Release/solstone_JournalMarkKit.bundle || { echo "error: solstone_JournalMarkKit.bundle missing from .build/apple/Products/Release"; exit 1; }
	@test -d .build/apple/Products/Release/solstone_journal.bundle || { echo "error: solstone_journal.bundle missing from .build/apple/Products/Release"; exit 1; }
	@cp -r .build/apple/Products/Release/solstone_JournalMarkKit.bundle journal.app/Contents/Resources/
	@cp -r .build/apple/Products/Release/solstone_journal.bundle journal.app/Contents/Resources/
	@cp -R "$(SPARKLE_FRAMEWORK)" journal.app/Contents/Frameworks/
	@RPATH_LOG="$$(mktemp -t journal-rpath)"; \
		if install_name_tool -add_rpath "@executable_path/../Frameworks" journal.app/Contents/MacOS/journal 2>"$$RPATH_LOG"; then \
			rm -f "$$RPATH_LOG"; \
		elif grep -Eq 'would duplicate path|already exists' "$$RPATH_LOG"; then \
			rm -f "$$RPATH_LOG"; \
		else \
			cat "$$RPATH_LOG"; \
			rm -f "$$RPATH_LOG"; \
			exit 1; \
		fi
	@cp $(UV_VENDOR_BINARY) journal.app/Contents/Resources/uv
	@chmod +x journal.app/Contents/Resources/uv
	@rm -rf journal.app/Contents/Resources/python
	@cp -R "$(PYTHON_VENDOR_DIR)" journal.app/Contents/Resources/python
	@test -x journal.app/Contents/Resources/python/bin/python3.13 || { echo "error: bundled journal python missing executable"; exit 1; }
	@rm -rf journal.app/Contents/Resources/wheelhouse
	@cp -R "$(WHEELHOUSE_DIR)" journal.app/Contents/Resources/wheelhouse
	@(cd journal.app/Contents/Resources/wheelhouse && shasum -a 256 -c MANIFEST.sha256) || { echo "error: bundled journal wheelhouse sha256 manifest verification failed"; exit 1; }
	@codesign --force --options runtime --timestamp \
		--sign "$(DEVELOPER_ID_APP)" --keychain "$(SIGNING_KEYCHAIN)" \
		journal.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc
	@codesign --force --options runtime --timestamp \
		--sign "$(DEVELOPER_ID_APP)" --keychain "$(SIGNING_KEYCHAIN)" \
		journal.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc
	@codesign --force --options runtime --timestamp \
		--sign "$(DEVELOPER_ID_APP)" --keychain "$(SIGNING_KEYCHAIN)" \
		journal.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate
	@codesign --force --options runtime --timestamp \
		--sign "$(DEVELOPER_ID_APP)" --keychain "$(SIGNING_KEYCHAIN)" \
		journal.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app
	@codesign --force --options runtime --timestamp \
		--sign "$(DEVELOPER_ID_APP)" --keychain "$(SIGNING_KEYCHAIN)" \
		journal.app/Contents/Frameworks/Sparkle.framework
	@codesign --force --options runtime --timestamp \
		--sign "$(DEVELOPER_ID_APP)" --keychain "$(SIGNING_KEYCHAIN)" \
		journal.app/Contents/Resources/solstone_JournalMarkKit.bundle
	@codesign --force --options runtime --timestamp \
		--sign "$(DEVELOPER_ID_APP)" --keychain "$(SIGNING_KEYCHAIN)" \
		journal.app/Contents/Resources/solstone_journal.bundle
	@codesign --force --options runtime --timestamp \
		--identifier app.solstone.journal.watchdog \
		--sign "$(DEVELOPER_ID_APP)" --keychain "$(SIGNING_KEYCHAIN)" \
		journal.app/Contents/MacOS/solstone-watchdog
	@codesign --force --options runtime --timestamp \
		--sign "$(DEVELOPER_ID_APP)" --keychain "$(SIGNING_KEYCHAIN)" \
		journal.app/Contents/Resources/uv
	@codesign --verify --strict --verbose=2 journal.app/Contents/Resources/uv
	@codesign -dvvv journal.app/Contents/Resources/uv 2>&1 | grep -q 'TeamIdentifier=7QCG8V4M6H' || { echo "error: journal uv missing team id 7QCG8V4M6H"; exit 1; }
	@codesign -dvvv journal.app/Contents/Resources/uv 2>&1 | grep -q 'flags=0x10000(runtime)' || { echo "error: journal uv missing hardened runtime flag"; exit 1; }
	@find journal.app/Contents/Resources/python -type f -name '*.so' -print0 | xargs -0 -I{} codesign --force --options runtime --timestamp \
		--identifier app.solstone.journal.python \
		--sign "$(DEVELOPER_ID_APP)" --keychain "$(SIGNING_KEYCHAIN)" \
		"{}"
	@find journal.app/Contents/Resources/python -type f -name '*.dylib' -print0 | xargs -0 -I{} codesign --force --options runtime --timestamp \
		--identifier app.solstone.journal.python \
		--sign "$(DEVELOPER_ID_APP)" --keychain "$(SIGNING_KEYCHAIN)" \
		"{}"
	@codesign --force --options runtime --timestamp \
		--identifier app.solstone.journal.python \
		--sign "$(DEVELOPER_ID_APP)" --keychain "$(SIGNING_KEYCHAIN)" \
		--entitlements Sources/journal/entitlements.plist \
		journal.app/Contents/Resources/python/bin/python3.13
	@find journal.app/Contents/Resources/python -type f \( -name '*.so' -o -name '*.dylib' \) -print0 | xargs -0 -I{} codesign --verify --strict --verbose=2 "{}"
	@codesign --verify --strict --verbose=2 journal.app/Contents/Resources/python/bin/python3.13
	@codesign -dvvv journal.app/Contents/Resources/python/bin/python3.13 2>&1 | grep -Fq 'Identifier=app.solstone.journal.python' || { echo "error: journal bundled python identifier mismatch"; exit 1; }
	@codesign -dvvv journal.app/Contents/Resources/python/bin/python3.13 2>&1 | grep -Fq 'TeamIdentifier=7QCG8V4M6H' || { echo "error: journal bundled python missing team id 7QCG8V4M6H"; exit 1; }
	@codesign -dvvv journal.app/Contents/Resources/python/bin/python3.13 2>&1 | grep -Fq 'flags=0x10000(runtime)' || { echo "error: journal bundled python missing hardened runtime flag"; exit 1; }
	@PYOUT="$$(journal.app/Contents/Resources/python/bin/python3.13 --version 2>&1)"; \
		echo "journal python --version output: $$PYOUT"; \
		echo "$$PYOUT" | grep -Fq "Python $(PYTHON_VERSION)" || { echo "error: journal bundled python reported wrong version (expected $(PYTHON_VERSION))"; exit 1; }
	@python3 scripts/sign_wheelhouse_native.py journal.app/Contents/Resources/wheelhouse \
		--identity "$(DEVELOPER_ID_APP)" \
		--keychain "$(SIGNING_KEYCHAIN)" \
		--identifier app.solstone.journal.wheelhouse
	@(cd journal.app/Contents/Resources/wheelhouse && shasum -a 256 -c MANIFEST.sha256) || { echo "error: bundled signed journal wheelhouse sha256 manifest verification failed"; exit 1; }
	@python3 scripts/assert_wheelhouse_native_identifier.py journal.app/Contents/Resources/wheelhouse app.solstone.journal.wheelhouse
	@codesign --force --options runtime --timestamp \
		--sign "$(DEVELOPER_ID_APP)" --keychain "$(SIGNING_KEYCHAIN)" \
		--entitlements Sources/journal/entitlements.plist \
		journal.app
	@VERIFY_OUT="$$(mktemp -t journal-codesign-verify)"; \
		if codesign --verify --strict --deep --verbose=2 journal.app >"$$VERIFY_OUT" 2>&1; then \
			rm -f "$$VERIFY_OUT"; \
		elif grep -Eq '(__pycache__|\.pyc)' "$$VERIFY_OUT"; then \
			cat "$$VERIFY_OUT"; \
			echo "codesign verify failed on python bytecode; removing __pycache__ and re-sealing"; \
			rm -rf journal.app/Contents/Resources/python/lib/python3.13/encodings/__pycache__; \
			codesign --force --options runtime --timestamp \
				--sign "$(DEVELOPER_ID_APP)" --keychain "$(SIGNING_KEYCHAIN)" \
				--entitlements Sources/journal/entitlements.plist \
				journal.app; \
			codesign --verify --strict --deep --verbose=2 journal.app; \
			rm -f "$$VERIFY_OUT"; \
		else \
			cat "$$VERIFY_OUT"; \
			rm -f "$$VERIFY_OUT"; \
			exit 1; \
		fi
	@test ! -f journal.app/Contents/embedded.provisionprofile || { echo "error: journal.app must not embed a provisioning profile"; exit 1; }
	@! codesign -d --entitlements - --xml journal.app 2>/dev/null | plutil -p - 2>/dev/null | grep -q 'keychain-access-groups' || { echo "error: journal.app must not carry keychain-access-groups"; exit 1; }
	@codesign -dvvv journal.app/Contents/MacOS/solstone-watchdog 2>&1 | grep -Fq 'Identifier=app.solstone.journal.watchdog' || { echo "error: journal watchdog identifier mismatch"; exit 1; }
	@codesign -dvvv journal.app/Contents/Resources/python/bin/python3.13 2>&1 | grep -Fq 'Identifier=app.solstone.journal.python' || { echo "error: journal python identifier mismatch"; exit 1; }
	@echo "✓ Signed: journal.app (journal identifiers, no profile/keychain-group verified)"

run-journal: journal-app-dev
	@open journal.app
	@/usr/bin/log stream --predicate 'subsystem == "app.solstone.journal" OR subsystem == "app.solstone.journal.watchdog"' --level debug

# Create and sign DMGs using create-dmg. Worker targets are standalone: build
# bundles first, then run dmg/notarize/staple/verify explicitly. Recursive
# orchestrators intentionally build each app bundle once; `make -n release-dmg*`
# does not fully expand sub-makes, so dry-run each segment when auditing.
#
# create-dmg builds an unsigned DMG; we codesign with --timestamp after
# (notarization needs the secure timestamp, and create-dmg doesn't pass
# extra codesign flags through).
#
# Requires: brew install create-dmg
dmg:
	@test -d "$(DMG_APP)" || { echo "error: $(DMG_APP) not found — run make bundle-dist* first"; exit 1; }
	@rm -f $(DMG_NAME)
	@create-dmg \
	  --volname "$(DMG_VOLNAME)" \
	  --background assets/dmg-background@2x.png \
	  --window-pos 200 200 \
	  --window-size 640 400 \
	  --icon-size 128 \
	  --icon "$(DMG_ICON)" 180 200 \
	  --app-drop-link 460 200 \
	  --hide-extension "$(DMG_ICON)" \
	  --no-internet-enable \
	  $(DMG_NAME) $(DMG_APP)
	@codesign --force --timestamp --sign "$(DEVELOPER_ID_APP)" --keychain "$(SIGNING_KEYCHAIN)" $(DMG_NAME)
	@echo "✓ Built: $(DMG_NAME)"

dmg-journal:
	@$(MAKE) dmg DMG_NAME=$(JOURNAL_DMG_NAME) DMG_APP=journal.app DMG_VOLNAME=journal DMG_ICON=journal.app

dmg-both:
	@test -d solstone.app || { echo "error: solstone.app not found — run make bundle-dist first"; exit 1; }
	@test -d journal.app || { echo "error: journal.app not found — run make bundle-dist-journal first"; exit 1; }
	@STAGING="$$(mktemp -d -t sol-journal-dmg)"; \
		trap 'rm -rf "$$STAGING"' EXIT; \
		cp -R solstone.app "$$STAGING/"; \
		cp -R journal.app "$$STAGING/"; \
		rm -f $(BOTH_DMG_NAME); \
		create-dmg \
		  --volname "sol + journal" \
		  --background assets/dmg-background@2x.png \
		  --window-pos 200 200 \
		  --window-size 840 400 \
		  --icon-size 128 \
		  --icon "solstone.app" 150 200 \
		  --icon "journal.app" 360 200 \
		  --app-drop-link 650 200 \
		  --hide-extension "solstone.app" \
		  --hide-extension "journal.app" \
		  --no-internet-enable \
		  $(BOTH_DMG_NAME) "$$STAGING"
	@codesign --force --timestamp --sign "$(DEVELOPER_ID_APP)" --keychain "$(SIGNING_KEYCHAIN)" $(BOTH_DMG_NAME)
	@echo "✓ Built: $(BOTH_DMG_NAME)"

# Submit for notarization and block until Apple responds.
notarize:
	@test -f "$(DMG_NAME)" || { echo "error: $(DMG_NAME) not found — run make dmg* first"; exit 1; }
	@echo "Submitting $(DMG_NAME) for notarization (typically 1-5 min)…"
	@xcrun notarytool submit $(DMG_NAME) \
		--keychain-profile "$(NOTARY_PROFILE)" --keychain "$(SIGNING_KEYCHAIN)" \
		--wait

notarize-journal:
	@$(MAKE) notarize DMG_NAME=$(JOURNAL_DMG_NAME)

notarize-both:
	@$(MAKE) notarize DMG_NAME=$(BOTH_DMG_NAME)

# Attach the notarization ticket to the DMG so Gatekeeper works offline.
staple:
	@test -f "$(DMG_NAME)" || { echo "error: $(DMG_NAME) not found — run make notarize* first"; exit 1; }
	@xcrun stapler staple $(DMG_NAME)

staple-journal:
	@$(MAKE) staple DMG_NAME=$(JOURNAL_DMG_NAME)

staple-both:
	@$(MAKE) staple DMG_NAME=$(BOTH_DMG_NAME)

# Confirm the DMG will pass Gatekeeper on a fresh Mac.
verify-notarization:
	@test -f "$(DMG_NAME)" || { echo "error: $(DMG_NAME) not found — run make staple first"; exit 1; }
	@test -d solstone.app || { echo "error: solstone.app not found — run make bundle-dist first"; exit 1; }
	@spctl --assess --type open --context context:primary-signature -v $(DMG_NAME) || \
		{ echo "spctl verification failed"; exit 1; }
	@xcrun stapler validate $(DMG_NAME)
	@codesign --verify --strict --verbose=2 solstone.app/Contents/MacOS/solstone-watchdog || \
		{ echo "watchdog signature invalid"; exit 1; }
	@codesign -dvvv solstone.app/Contents/MacOS/solstone-watchdog 2>&1 | grep -q 'TeamIdentifier=7QCG8V4M6H' || \
		{ echo "watchdog missing Team ID 7QCG8V4M6H"; exit 1; }
	@codesign -dvvv solstone.app/Contents/MacOS/solstone-watchdog 2>&1 | grep -q 'flags=0x10000(runtime)' || \
		{ echo "watchdog missing hardened runtime flag"; exit 1; }
	@codesign -dvvv solstone.app/Contents/MacOS/solstone-watchdog 2>&1 | grep -q 'Identifier=app.solstone.observer.watchdog' || \
		{ echo "watchdog identifier mismatch (expected app.solstone.observer.watchdog)"; exit 1; }
	@lipo -archs solstone.app/Contents/MacOS/solstone-watchdog | grep -q 'arm64' || \
		{ echo "watchdog missing arm64 slice"; exit 1; }
	@lipo -archs solstone.app/Contents/MacOS/solstone-watchdog | grep -q 'x86_64' || \
		{ echo "watchdog missing x86_64 slice"; exit 1; }
	@BAD="$$(find solstone.app -path '*uv*' -o -path '*/python' -o -path '*python3.13*' -o -path '*wheelhouse*' 2>/dev/null | head -1)"; \
		[ -z "$$BAD" ] || { echo "error: solstone.app must not ship the journal runtime plane (found: $$BAD)"; exit 1; }
	@echo "✓ $(DMG_NAME) notarized + stapled"

verify-notarization-journal:
	@test -f "$(JOURNAL_DMG_NAME)" || { echo "error: $(JOURNAL_DMG_NAME) not found — run make staple-journal first"; exit 1; }
	@test -d journal.app || { echo "error: journal.app not found — run make bundle-dist-journal first"; exit 1; }
	@spctl --assess --type open --context context:primary-signature -v $(JOURNAL_DMG_NAME) || \
		{ echo "journal spctl verification failed"; exit 1; }
	@xcrun stapler validate $(JOURNAL_DMG_NAME)
	@codesign --verify --strict --verbose=2 journal.app/Contents/MacOS/solstone-watchdog || { echo "journal watchdog signature invalid"; exit 1; }
	@codesign -dvvv journal.app/Contents/MacOS/solstone-watchdog 2>&1 | grep -q 'TeamIdentifier=7QCG8V4M6H' || { echo "journal watchdog missing Team ID 7QCG8V4M6H"; exit 1; }
	@codesign -dvvv journal.app/Contents/MacOS/solstone-watchdog 2>&1 | grep -q 'flags=0x10000(runtime)' || { echo "journal watchdog missing hardened runtime flag"; exit 1; }
	@codesign -dvvv journal.app/Contents/MacOS/solstone-watchdog 2>&1 | grep -q 'Identifier=app.solstone.journal.watchdog' || { echo "journal watchdog identifier mismatch"; exit 1; }
	@lipo -archs journal.app/Contents/MacOS/solstone-watchdog | grep -q 'arm64' || { echo "journal watchdog missing arm64 slice"; exit 1; }
	@lipo -archs journal.app/Contents/MacOS/solstone-watchdog | grep -q 'x86_64' || { echo "journal watchdog missing x86_64 slice"; exit 1; }
	@test -x journal.app/Contents/Resources/uv || { echo "error: journal bundled uv missing"; exit 1; }
	@codesign --verify --strict --verbose=2 journal.app/Contents/Resources/uv
	@codesign -dvvv journal.app/Contents/Resources/uv 2>&1 | grep -q 'TeamIdentifier=7QCG8V4M6H' || { echo "error: journal uv missing team id"; exit 1; }
	@codesign -dvvv journal.app/Contents/Resources/uv 2>&1 | grep -q 'flags=0x10000(runtime)' || { echo "error: journal uv missing hardened runtime flag"; exit 1; }
	@test -x journal.app/Contents/Resources/python/bin/python3.13 || { echo "error: journal bundled python missing"; exit 1; }
	@find journal.app/Contents/Resources/python -type f \( -name '*.so' -o -name '*.dylib' \) -print0 | xargs -0 -I{} codesign --verify --strict --verbose=2 "{}"
	@codesign --verify --strict --verbose=2 journal.app/Contents/Resources/python/bin/python3.13
	@codesign -dvvv journal.app/Contents/Resources/python/bin/python3.13 2>&1 | grep -Fq 'Identifier=app.solstone.journal.python' || { echo "error: journal bundled python identifier mismatch"; exit 1; }
	@codesign -dvvv journal.app/Contents/Resources/python/bin/python3.13 2>&1 | grep -Fq 'TeamIdentifier=7QCG8V4M6H' || { echo "error: journal bundled python missing team id"; exit 1; }
	@codesign -dvvv journal.app/Contents/Resources/python/bin/python3.13 2>&1 | grep -Fq 'flags=0x10000(runtime)' || { echo "error: journal bundled python missing hardened runtime flag"; exit 1; }
	@journal.app/Contents/Resources/python/bin/python3.13 --version 2>&1 | grep -Fq "Python $(PYTHON_VERSION)" || { echo "error: journal bundled python reported wrong version"; exit 1; }
	@test -f journal.app/Contents/Resources/wheelhouse/MANIFEST.sha256 || { echo "error: journal bundled wheelhouse manifest missing"; exit 1; }
	@(cd journal.app/Contents/Resources/wheelhouse && shasum -a 256 -c MANIFEST.sha256) || { echo "error: journal bundled wheelhouse sha256 manifest verification failed"; exit 1; }
	@echo "✓ $(JOURNAL_DMG_NAME) notarized + stapled"

verify-notarization-both:
	@test -f "$(BOTH_DMG_NAME)" || { echo "error: $(BOTH_DMG_NAME) not found — run make staple-both first"; exit 1; }
	@test -d solstone.app || { echo "error: solstone.app not found — run make bundle-dist first"; exit 1; }
	@test -d journal.app || { echo "error: journal.app not found — run make bundle-dist-journal first"; exit 1; }
	@spctl --assess --type open --context context:primary-signature -v $(BOTH_DMG_NAME) || \
		{ echo "both-DMG spctl verification failed"; exit 1; }
	@xcrun stapler validate $(BOTH_DMG_NAME)
	@BAD="$$(find solstone.app -path '*uv*' -o -path '*/python' -o -path '*python3.13*' -o -path '*wheelhouse*' 2>/dev/null | head -1)"; \
		[ -z "$$BAD" ] || { echo "error: solstone.app must not ship the journal runtime plane (found: $$BAD)"; exit 1; }
	@test -x journal.app/Contents/Resources/uv || { echo "error: both-DMG journal bundled uv missing"; exit 1; }
	@codesign --verify --strict --verbose=2 journal.app/Contents/Resources/uv
	@codesign -dvvv journal.app/Contents/Resources/uv 2>&1 | grep -q 'TeamIdentifier=7QCG8V4M6H' || { echo "error: both-DMG journal uv missing team id"; exit 1; }
	@codesign -dvvv journal.app/Contents/Resources/uv 2>&1 | grep -q 'flags=0x10000(runtime)' || { echo "error: both-DMG journal uv missing hardened runtime flag"; exit 1; }
	@test -x journal.app/Contents/Resources/python/bin/python3.13 || { echo "error: both-DMG journal bundled python missing"; exit 1; }
	@find journal.app/Contents/Resources/python -type f \( -name '*.so' -o -name '*.dylib' \) -print0 | xargs -0 -I{} codesign --verify --strict --verbose=2 "{}"
	@codesign --verify --strict --verbose=2 journal.app/Contents/Resources/python/bin/python3.13
	@codesign -dvvv journal.app/Contents/Resources/python/bin/python3.13 2>&1 | grep -Fq 'Identifier=app.solstone.journal.python' || { echo "error: both-DMG journal bundled python identifier mismatch"; exit 1; }
	@codesign -dvvv journal.app/Contents/Resources/python/bin/python3.13 2>&1 | grep -Fq 'TeamIdentifier=7QCG8V4M6H' || { echo "error: both-DMG journal bundled python missing team id"; exit 1; }
	@codesign -dvvv journal.app/Contents/Resources/python/bin/python3.13 2>&1 | grep -Fq 'flags=0x10000(runtime)' || { echo "error: both-DMG journal bundled python missing hardened runtime flag"; exit 1; }
	@journal.app/Contents/Resources/python/bin/python3.13 --version 2>&1 | grep -Fq "Python $(PYTHON_VERSION)" || { echo "error: both-DMG journal bundled python reported wrong version"; exit 1; }
	@test -f journal.app/Contents/Resources/wheelhouse/MANIFEST.sha256 || { echo "error: both-DMG journal wheelhouse manifest missing"; exit 1; }
	@(cd journal.app/Contents/Resources/wheelhouse && shasum -a 256 -c MANIFEST.sha256) || { echo "error: both-DMG journal bundled wheelhouse sha256 manifest verification failed"; exit 1; }
	@echo "✓ $(BOTH_DMG_NAME) notarized + stapled"

# One-shot orchestrators. They intentionally call standalone worker targets in
# sequence so bundling/signing happens once before DMG notarization.
release-dmg:
	@$(MAKE) bundle-dist
	@$(MAKE) dmg
	@$(MAKE) notarize
	@$(MAKE) staple
	@$(MAKE) verify-notarization
	@echo ""
	@echo "✅ Distribution DMG ready: $(DMG_NAME)"
	@echo "   Signed:  $(DEVELOPER_ID_APP)"
	@echo "   Notary:  $(NOTARY_PROFILE)"
	@echo "   Size:    $$(du -h $(DMG_NAME) | cut -f1)"

release-dmg-journal:
	@$(MAKE) bundle-dist-journal
	@$(MAKE) dmg-journal
	@$(MAKE) notarize-journal
	@$(MAKE) staple-journal
	@$(MAKE) verify-notarization-journal
	@echo ""
	@echo "✅ Journal distribution DMG ready: $(JOURNAL_DMG_NAME)"
	@echo "   Signed:  $(DEVELOPER_ID_APP)"
	@echo "   Notary:  $(NOTARY_PROFILE)"
	@echo "   Size:    $$(du -h $(JOURNAL_DMG_NAME) | cut -f1)"

release-dmg-both:
	@$(MAKE) bundle-dist
	@$(MAKE) bundle-dist-journal
	@$(MAKE) dmg
	@$(MAKE) dmg-journal
	@$(MAKE) notarize
	@$(MAKE) notarize-journal
	@xcrun stapler staple solstone.app
	@xcrun stapler staple journal.app
	@$(MAKE) dmg-both
	@$(MAKE) notarize-both
	@$(MAKE) staple-both
	@$(MAKE) staple
	@$(MAKE) staple-journal
	@$(MAKE) verify-notarization
	@$(MAKE) verify-notarization-journal
	@$(MAKE) verify-notarization-both
	@echo ""
	@echo "✅ Distribution DMGs ready:"
	@echo "   sol:     $(DMG_NAME)"
	@echo "   journal: $(JOURNAL_DMG_NAME)"
	@echo "   both:    $(BOTH_DMG_NAME)"

supply-chain-check: vendor-uv vendor-python generate-bundle-config
	@echo "── supply chain checklist ──"
	@echo "uv version: $(UV_VERSION)"
	@echo "uv release url: $(UV_RELEASE_URL)"
	@echo "uv sha256: $$(awk '{print $$1; exit}' "$(UV_SHA256_FILE)")"
	@echo "python-build-standalone release: $(PYTHON_BUILD_STANDALONE_VERSION)"
	@echo "python version: $(PYTHON_VERSION)"
	@echo "python release url: $(PYTHON_RELEASE_URL)"
	@echo "python sha256: $$(awk '{print $$1; exit}' "$(PYTHON_VENDOR_SHA_FILE)")"
	@echo "── BundleConfig.swift ──"
	@cat Sources/JournalRuntime/BundleConfig.swift
	@echo "── bundled-uv codesign ──"
	@if [ -f journal.app/Contents/Resources/uv ]; then \
	    codesign -dvvv journal.app/Contents/Resources/uv 2>&1 || true; \
	else \
	    echo "(not signed yet — run make bundle-dist-journal to produce signed bundled uv)"; \
	fi
	@echo "── bundled-python codesign ──"
	@if [ -f journal.app/Contents/Resources/python/bin/python3.13 ]; then \
	    codesign -dvvv journal.app/Contents/Resources/python/bin/python3.13 2>&1 || true; \
	else \
	    echo "(not signed yet — run make bundle-dist-journal to produce signed bundled python)"; \
	fi
	@echo "── bundled backend wheelhouse ──"
	@python3 scripts/wheelhouse_helper.py verify-wheelhouse "$(WHEELHOUSE_DIR)" "$(SOLSTONE_PIN_VERSION)"
	@echo "── THIRD_PARTY_NOTICES.md ──"
	@test -f THIRD_PARTY_NOTICES.md || { echo "error: THIRD_PARTY_NOTICES.md missing"; exit 1; }
	@grep -qiE '^##[[:space:]]+uv' THIRD_PARTY_NOTICES.md || { echo "error: THIRD_PARTY_NOTICES.md missing uv entry"; exit 1; }
	@grep -qiE '^##[[:space:]]+python-build-standalone' THIRD_PARTY_NOTICES.md || { echo "error: THIRD_PARTY_NOTICES.md missing python-build-standalone entry"; exit 1; }
	@echo "supply-chain checklist: ok"

release-dmg-smoke:
	@test -f "$(DMG_NAME)" || { echo "error: $(DMG_NAME) not found — run make release-dmg first"; exit 1; }
	@MOUNT="$$(mktemp -d -t solstone-smoke)"; \
	    trap "hdiutil detach \"$$MOUNT\" -quiet -force >/dev/null 2>&1 || true; rm -rf \"$$MOUNT\"" EXIT; \
	    hdiutil attach "$(DMG_NAME)" -mountpoint "$$MOUNT" -nobrowse -quiet || { echo "error: hdiutil attach failed"; exit 1; }; \
	    codesign --verify --strict --deep --verbose=2 "$$MOUNT/solstone.app" || { echo "error: dmg .app codesign verify failed"; exit 1; }; \
	    BAD="$$(find "$$MOUNT/solstone.app" -path '*uv*' -o -path '*/python' -o -path '*python3.13*' -o -path '*wheelhouse*' 2>/dev/null | head -1)"; \
	    [ -z "$$BAD" ] || { echo "error: mounted solstone.app must not ship the journal runtime plane (found: $$BAD)"; exit 1; }; \
	    echo "release-dmg-smoke: ok"

release-dmg-smoke-journal:
	@test -f "$(JOURNAL_DMG_NAME)" || { echo "error: $(JOURNAL_DMG_NAME) not found — run make release-dmg-journal first"; exit 1; }
	@MOUNT="$$(mktemp -d -t journal-smoke)"; \
	    trap "hdiutil detach \"$$MOUNT\" -quiet -force >/dev/null 2>&1 || true; rm -rf \"$$MOUNT\"" EXIT; \
	    hdiutil attach "$(JOURNAL_DMG_NAME)" -mountpoint "$$MOUNT" -nobrowse -quiet || { echo "error: journal hdiutil attach failed"; exit 1; }; \
	    codesign --verify --strict --deep --verbose=2 "$$MOUNT/journal.app" || { echo "error: journal dmg .app codesign verify failed"; exit 1; }; \
	    OUT="$$("$$MOUNT/journal.app/Contents/Resources/uv" --version 2>&1)"; \
	    echo "journal uv --version output: $$OUT"; \
	    echo "$$OUT" | grep -q "$(UV_VERSION)" || { echo "error: journal bundled uv reported wrong version (expected $(UV_VERSION))"; exit 1; }; \
	    PYOUT="$$("$$MOUNT/journal.app/Contents/Resources/python/bin/python3.13" --version 2>&1)"; \
	    echo "journal python --version output: $$PYOUT"; \
	    echo "$$PYOUT" | grep -Fq "Python $(PYTHON_VERSION)" || { echo "error: journal bundled python reported wrong version (expected $(PYTHON_VERSION))"; exit 1; }; \
	    test -f "$$MOUNT/journal.app/Contents/Resources/wheelhouse/MANIFEST.sha256" || { echo "error: journal bundled wheelhouse manifest missing"; exit 1; }; \
	    (cd "$$MOUNT/journal.app/Contents/Resources/wheelhouse" && shasum -a 256 -c MANIFEST.sha256) || { echo "error: journal bundled wheelhouse sha256 manifest verification failed"; exit 1; }; \
	    echo "release-dmg-smoke-journal: ok"

release-dmg-smoke-both:
	@test -f "$(BOTH_DMG_NAME)" || { echo "error: $(BOTH_DMG_NAME) not found — run make release-dmg-both first"; exit 1; }
	@MOUNT="$$(mktemp -d -t sol-journal-smoke)"; \
	    trap "hdiutil detach \"$$MOUNT\" -quiet -force >/dev/null 2>&1 || true; rm -rf \"$$MOUNT\"" EXIT; \
	    hdiutil attach "$(BOTH_DMG_NAME)" -mountpoint "$$MOUNT" -nobrowse -quiet || { echo "error: both hdiutil attach failed"; exit 1; }; \
	    codesign --verify --strict --deep --verbose=2 "$$MOUNT/solstone.app" || { echo "error: both dmg solstone.app codesign verify failed"; exit 1; }; \
	    codesign --verify --strict --deep --verbose=2 "$$MOUNT/journal.app" || { echo "error: both dmg journal.app codesign verify failed"; exit 1; }; \
	    BAD="$$(find "$$MOUNT/solstone.app" -path '*uv*' -o -path '*/python' -o -path '*python3.13*' -o -path '*wheelhouse*' 2>/dev/null | head -1)"; \
	    [ -z "$$BAD" ] || { echo "error: mounted both-DMG solstone.app must not ship the journal runtime plane (found: $$BAD)"; exit 1; }; \
	    "$$MOUNT/journal.app/Contents/Resources/uv" --version 2>&1 | grep -q "$(UV_VERSION)" || { echo "error: both-DMG journal uv reported wrong version"; exit 1; }; \
	    "$$MOUNT/journal.app/Contents/Resources/python/bin/python3.13" --version 2>&1 | grep -Fq "Python $(PYTHON_VERSION)" || { echo "error: both-DMG journal python reported wrong version"; exit 1; }; \
	    test -f "$$MOUNT/journal.app/Contents/Resources/wheelhouse/MANIFEST.sha256" || { echo "error: both-DMG journal wheelhouse manifest missing"; exit 1; }; \
	    (cd "$$MOUNT/journal.app/Contents/Resources/wheelhouse" && shasum -a 256 -c MANIFEST.sha256) || { echo "error: both-DMG journal wheelhouse sha256 manifest verification failed"; exit 1; }; \
	    echo "release-dmg-smoke-both: ok"

journal-materialize-smoke:
	@test -d journal.app || { echo "error: journal.app not found — run make bundle-dist-journal first"; exit 1; }
	@python3 scripts/journal_materialize_smoke.py journal.app "$(SOLSTONE_PIN_VERSION)"

# Install development dependencies needed for local build workflows
install: check-dev-deps
	@if command -v brew > /dev/null 2>&1; then \
		if command -v rsvg-convert > /dev/null 2>&1; then \
			echo "librsvg already installed"; \
		else \
			echo "Installing librsvg via Homebrew..."; \
			brew install librsvg; \
		fi; \
	else \
		echo "Homebrew not found; skipping optional icon dependency (librsvg)"; \
		echo "Install Homebrew and run 'brew install librsvg' if you need 'make icons'"; \
	fi
	@echo "Development dependencies are ready."
	@echo "Use 'make build' for a debug build or 'make bundle-dist' to produce the signed .app."

# Alias for install
setup: install

# Reset TCC permissions and app defaults for testing.
# NOTE: ScreenCapture is intentionally omitted — on macOS 26, tccutil reset ScreenCapture
# without sudo writes a DENIED entry to system TCC.db (it can't clear it without privileges),
# which silently blocks the permission dialog. Use: sudo tccutil reset All app.solstone.observer
reset:
	-tccutil reset Microphone app.solstone.observer
	-defaults delete app.solstone.observer 2>/dev/null
	-rm -f ~/Library/Preferences/app.solstone.observer.plist
	@echo "Microphone TCC and defaults reset."
	@echo "To fully reset screen recording: sudo tccutil reset All app.solstone.observer"

# Full "as-if-new-machine" wipe for reproducing first-run flows.
# Preserves captures/, parakeet/, journal/ — sync state is just a UserDefaults cache,
# segments are the source of truth and will be picked up by the next install.
# Steps requiring sudo or GUI interaction are echoed at the end, not executed
# (tccutil ScreenCapture without sudo writes a DENIED row on macOS 26 — worse than skipping).
reset-full:
	@echo "==> quitting solstone..."
	-@osascript -e 'tell application "solstone" to quit' 2>/dev/null
	-@killall -9 solstone 2>/dev/null
	@echo "==> removing installed app..."
	-@rm -rf /Applications/solstone.app
	@echo "==> wiping app state (keeping captures/, parakeet/, journal/)..."
	-@rm -f  "$(HOME)/Library/Application Support/Solstone/config.json.migrated"
	-@rm -rf "$(HOME)/Library/Application Support/Solstone/logs"
	-@rm -f  $(HOME)/Library/Preferences/app.solstone.capture.plist
	-@rm -f  $(HOME)/Library/Preferences/app.solstone.observer.plist
	-@rm -f  $(HOME)/Library/Preferences/app.solstone.observer.tests.*.plist
	-@killall cfprefsd 2>/dev/null
	@echo "==> clearing caches + LaunchServices registration..."
	-@rm -rf $(HOME)/Library/Caches/app.solstone.* $(HOME)/Library/Caches/com.solstone.*
	-@rm -rf "$(HOME)/Library/Saved Application State/app.solstone."* "$(HOME)/Library/Saved Application State/com.solstone."*
	-@/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -kill -r -domain local -domain system -domain user >/dev/null 2>&1 || true
	@echo ""
	@echo "Local state wiped. Captures preserved at:"
	@echo "  $(HOME)/Library/Application Support/Solstone/captures/"
	@echo ""
	@echo "MANUAL STEPS REMAINING (need sudo / GUI interaction):"
	@echo ""
	@echo "  1. reset TCC entries (requires sudo — unsudoed tccutil writes a DENIED"
	@echo "     row on Tahoe and silently blocks the dialog):"
	@echo "       sudo tccutil reset All app.solstone.observer"
	@echo "       sudo tccutil reset All app.solstone.capture"
	@echo ""
	@echo "  2. open System Settings and remove any stale 'solstone' rows the GUI"
	@echo "     still shows (CDHash-tied entries that tccutil can leave behind):"
	@echo "       open 'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture'"
	@echo "     check both Screen & System Audio Recording and Microphone."
	@echo ""
	@echo "  3. reboot to flush cfprefsd, tccd, and IconServices:"
	@echo "       sudo shutdown -r now"
	@echo ""
	@echo "Then: make bundle-dist && make run"

# Generate icon assets from SVG sources in assets/
# Requires: rsvg-convert (brew install librsvg), iconutil (built-in macOS)
# Run when SVGs change. Output files are committed so fresh checkouts build cleanly.
# SOURCE_DATE_EPOCH pins Cairo's PDF /CreationDate + /ID so `rsvg-convert -f pdf`
# is byte-deterministic. Without it, every run rewrites ALL template PDFs (Cairo
# embeds a live timestamp + a date-derived /ID), so a one-icon SVG change shows
# all four PDFs as modified. Value is arbitrary but MUST stay constant forever.
icons: export SOURCE_DATE_EPOCH := 1700000000
icons: check-icons-deps
	@echo "Generating icons from SVG sources..."
	@swift run -c release journal-icon-gen assets/icon-journal.svg
	@mkdir -p Sources/solstone/Resources Sources/journal/Resources
	@TMPDIR=$$(mktemp -d) && \
	ICONSET=$$TMPDIR/AppIcon.iconset && \
	JOURNAL_ICONSET=$$TMPDIR/JournalAppIcon.iconset && \
	mkdir -p $$ICONSET $$JOURNAL_ICONSET && \
	\
	echo "  Rendering app icon sizes (per-size SVG selection — never downsample)..." && \
	for size in 16 32 64 128 256 512 1024; do \
		svg=assets/icon-app.svg; \
		if [ -f assets/icon-app-$${size}.svg ]; then \
			svg=assets/icon-app-$${size}.svg; \
		fi; \
		rsvg-convert -w $$size -h $$size $$svg \
			-o $$TMPDIR/icon_$${size}.png; \
		echo "    $${size}x$${size}  ($$svg)"; \
	done && \
	\
	cp $$TMPDIR/icon_16.png    $$ICONSET/icon_16x16.png && \
	cp $$TMPDIR/icon_32.png    $$ICONSET/icon_16x16@2x.png && \
	cp $$TMPDIR/icon_32.png    $$ICONSET/icon_32x32.png && \
	cp $$TMPDIR/icon_64.png    $$ICONSET/icon_32x32@2x.png && \
	cp $$TMPDIR/icon_128.png   $$ICONSET/icon_128x128.png && \
	cp $$TMPDIR/icon_256.png   $$ICONSET/icon_128x128@2x.png && \
	cp $$TMPDIR/icon_256.png   $$ICONSET/icon_256x256.png && \
	cp $$TMPDIR/icon_512.png   $$ICONSET/icon_256x256@2x.png && \
	cp $$TMPDIR/icon_512.png   $$ICONSET/icon_512x512.png && \
	cp $$TMPDIR/icon_1024.png  $$ICONSET/icon_512x512@2x.png && \
	\
	iconutil -c icns $$ICONSET -o Sources/solstone/Resources/AppIcon.icns && \
	echo "  ✓ AppIcon.icns" && \
	\
	echo "  Rendering journal app icon sizes..." && \
	for size in 16 32 64 128 256 512 1024; do \
		rsvg-convert -w $$size -h $$size assets/icon-journal.svg \
			-o $$TMPDIR/journal_icon_$${size}.png; \
		echo "    $${size}x$${size}  (assets/icon-journal.svg)"; \
	done && \
	\
	cp $$TMPDIR/journal_icon_16.png    $$JOURNAL_ICONSET/icon_16x16.png && \
	cp $$TMPDIR/journal_icon_32.png    $$JOURNAL_ICONSET/icon_16x16@2x.png && \
	cp $$TMPDIR/journal_icon_32.png    $$JOURNAL_ICONSET/icon_32x32.png && \
	cp $$TMPDIR/journal_icon_64.png    $$JOURNAL_ICONSET/icon_32x32@2x.png && \
	cp $$TMPDIR/journal_icon_128.png   $$JOURNAL_ICONSET/icon_128x128.png && \
	cp $$TMPDIR/journal_icon_256.png   $$JOURNAL_ICONSET/icon_128x128@2x.png && \
	cp $$TMPDIR/journal_icon_256.png   $$JOURNAL_ICONSET/icon_256x256.png && \
	cp $$TMPDIR/journal_icon_512.png   $$JOURNAL_ICONSET/icon_256x256@2x.png && \
	cp $$TMPDIR/journal_icon_512.png   $$JOURNAL_ICONSET/icon_512x512.png && \
	cp $$TMPDIR/journal_icon_1024.png  $$JOURNAL_ICONSET/icon_512x512@2x.png && \
	\
	iconutil -c icns $$JOURNAL_ICONSET -o Sources/journal/Resources/AppIcon.icns && \
	echo "  ✓ journal AppIcon.icns" && \
	\
	echo "  Rendering status bar template icons (vector PDF — renders crisp at any density)..." && \
		rsvg-convert -f pdf assets/sol-ring-mb.svg \
			-o Sources/solstone/Resources/sol-ring-template.pdf && \
		echo "  ✓ sol-ring-template.pdf" && \
		echo "  Rendering status bar variant icons..." && \
		rsvg-convert -f pdf assets/sol-ring-mb-error.svg \
			-o Sources/solstone/Resources/sol-ring-icon-error-template.pdf && \
		echo "  ✓ sol-ring-icon-error-template.pdf" && \
		rsvg-convert -f pdf assets/sol-ring-mb-paused.svg \
			-o Sources/solstone/Resources/sol-ring-icon-paused-template.pdf && \
		echo "  ✓ sol-ring-icon-paused-template.pdf" && \
		rsvg-convert -f pdf assets/sol-ring-mb-half.svg \
			-o Sources/solstone/Resources/sol-ring-icon-half-template.pdf && \
	echo "  ✓ sol-ring-icon-half-template.pdf" && \
	\
	echo "  Rendering wordmark for UI..." && \
	rsvg-convert -w 128 -h 128 assets/sol-wordmark.svg \
		-o Sources/solstone/Resources/sol-wordmark.png && \
	rsvg-convert -w 256 -h 256 assets/sol-wordmark.svg \
		-o Sources/solstone/Resources/sol-wordmark@2x.png && \
	echo "  ✓ sol-wordmark.png + @2x" && \
	\
	rm -rf $$TMPDIR && \
	echo "Icons generated in Sources/solstone/Resources/ and Sources/journal/Resources/"

check-icons-deps:
	@which rsvg-convert > /dev/null 2>&1 || \
		(echo "error: rsvg-convert not found — run: brew install librsvg"; exit 1)
	@which iconutil > /dev/null 2>&1 || \
		(echo "error: iconutil not found (requires macOS)"; exit 1)

# ────────────────────────────────────────────────────────────────
# Publish targets — RELEASE HOST ONLY
# Do not run from a developer workstation. These are invoked from the
# release host during the release playbook. They require wrangler and the
# local vault private key.
# ────────────────────────────────────────────────────────────────

# Cloudflare account id (account "jer") — wrangler whoami must list this.
CF_ACCOUNT_ID          ?= 3f2c1528c7d4d9685819ea9e9e307c92

# Wrangler/CF-auth preflight. Run on the RELEASE HOST *before* dispatching the
# pro5e DMG build — wrangler's session OAuth degrades silently on a ~24h cadence,
# and the R2 publish is the final step, so a stale token otherwise wastes the
# full ~6min build + notarize before failing. `wrangler whoami` exercises the
# same account-lookup path that breaks on degrade; we assert exit 0 AND that the
# account id is listed (a set CLOUDFLARE_API_TOKEN shadowing the OAuth session
# surfaces here too). NOT `/user/tokens/verify` — it reports "Invalid API Token"
# for OAuth tokens even when healthy.
publish-preflight:
	@echo "preflight: checking wrangler Cloudflare auth on the release host…"
	@out="$$(wrangler whoami 2>&1)"; rc=$$?; \
	if [ $$rc -ne 0 ] || ! printf '%s' "$$out" | grep -q '$(CF_ACCOUNT_ID)'; then \
		echo "error: wrangler Cloudflare auth is degraded — run 'wrangler login' (browser OAuth refresh), then retry." >&2; \
		echo "       expected account id $(CF_ACCOUNT_ID) in 'wrangler whoami' output." >&2; \
		exit 1; \
	fi; \
	echo "preflight: wrangler OK (account $(CF_ACCOUNT_ID))"

# publish-appcast.py needs PyNaCl (Sparkle EdDSA enclosure signing) and boto3
# (R2 multipart upload for >300 MiB DMGs). Run it under an ephemeral uv env so
# the publish never depends on the release host's python site-packages — host
# env drift broke the 1.0.3 publish (host lost nacl/boto3 between trains).
PUBLISH_PY := uv run --no-project --with 'pynacl>=1.6,<2' --with boto3 python3

publish-appcast: publish-preflight
	$(PUBLISH_PY) scripts/publish-appcast.py $(DIST_VERSION) --app sol

publish-appcast-staging: publish-preflight
	$(PUBLISH_PY) scripts/publish-appcast.py $(DIST_VERSION) --app sol --staging

publish-appcast-journal: publish-preflight
	$(PUBLISH_PY) scripts/publish-appcast.py $(JOURNAL_DIST_VERSION) --app journal

publish-appcast-journal-staging: publish-preflight
	$(PUBLISH_PY) scripts/publish-appcast.py $(JOURNAL_DIST_VERSION) --app journal --staging

# Cut a GitHub Release: annotated tag + `gh release create` with the DMG
# attached and CHANGELOG notes. Run AFTER `make publish-appcast` and founder
# approval — the DMG must still be in CWD (publish-appcast.py's flow scp's it
# in). Sparkle is the primary update channel; this is source-release hygiene
# and the GitHub front door. Mirrors solstone / solstone-linux release.sh.
github-release:
	@bash scripts/github-release.sh --app sol $(DIST_VERSION)

github-release-journal:
	@bash scripts/github-release.sh --app journal $(JOURNAL_DIST_VERSION)

.PHONY: publish-preflight publish-appcast publish-appcast-staging publish-appcast-journal publish-appcast-journal-staging github-release github-release-journal
