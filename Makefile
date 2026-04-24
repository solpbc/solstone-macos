.PHONY: build release release-universal run clean test snapshot bundle bundle-universal install setup install-app open reset cert allow check-cert icons check-icons-deps check-dev-deps \
        signing-check unlock-signing bundle-dist dmg notarize staple verify-notarization release-dmg

# Code signing identity — run 'make cert' then 'make allow' to create and trust (one-time setup)
SIGN_IDENTITY ?= solstone dev

# ---------------------------------------------------------------------------
# Distribution signing (Apple Developer ID + notarization)
#
# Activated 2026-04-20 when the sol pbc Apple Developer Program went live
# (team 7QCG8V4M6H). Certs live in a dedicated sol-signing keychain on
# pro5e.local, isolated from the login keychain. Notarytool uses an ASC API
# key (no app-specific password). See shared/vendors/apple.md and
# cto/workspace/apple-signing-sequence-260420.md in the extro repo.
# ---------------------------------------------------------------------------
DEVELOPER_ID_APP       ?= Developer ID Application: sol pbc (7QCG8V4M6H)
DEVELOPER_ID_INSTALLER ?= Developer ID Installer: sol pbc (7QCG8V4M6H)
NOTARY_PROFILE         ?= sol-pbc-notary
SIGNING_KEYCHAIN       ?= $(HOME)/Library/Keychains/sol-signing.keychain-db
SIGNING_KC_PASS_FILE   ?= $(HOME)/.config/sol-pbc/signing/keychain-password
DIST_VERSION           := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Sources/solstone/Info.plist 2>/dev/null || echo 0.0.0)
DMG_NAME               ?= solstone-$(DIST_VERSION).dmg
SPARKLE_ARTIFACT_DIR   ?= .build/artifacts/sparkle/Sparkle
SPARKLE_FRAMEWORK      ?= $(SPARKLE_ARTIFACT_DIR)/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework

# Build debug version
build:
	swift build

# Build release version
release:
	swift build -c release

# Build universal binary (arm64 + x86_64)
release-universal:
	swift build -c release --arch arm64 --arch x86_64

# Run the installed app and stream all logs to a timestamped file in scratch/
# Keeps capturing across app restarts. Ctrl+C to stop.
run:
	@mkdir -p scratch; \
	LOG=scratch/$$(date +%Y%m%d_%H%M%S).log; \
	echo "Streaming logs → $$LOG  (Ctrl+C to stop)"; \
	/usr/bin/log stream --predicate 'subsystem == "app.solstone.observer"' --level debug > "$$LOG" 2>&1 & \
	STREAM_PID=$$!; \
	open /Applications/solstone.app; \
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

# Render view snapshots
snapshot:
	swift test --filter Snapshot

check-dev-deps:
	@xcodebuild -version > /dev/null 2>&1 || \
		{ echo "error: Xcode is required for local builds"; \
		  echo "       install the full Xcode app from the Mac App Store, then run it once"; \
		  exit 1; }

check-cert:
	@if security find-identity -v -p codesigning 2>/dev/null | grep -q '"$(SIGN_IDENTITY)"'; then \
		exit 0; \
	elif security find-identity -p codesigning 2>/dev/null | grep -q '"$(SIGN_IDENTITY)"'; then \
		echo "error: certificate '$(SIGN_IDENTITY)' exists but is not trusted"; \
		echo "       run 'make allow' — macOS will ask for your password"; \
		exit 1; \
	else \
		echo "error: signing identity '$(SIGN_IDENTITY)' not found in keychain"; \
		echo "       run 'make cert' then 'make allow' to create one"; \
		exit 1; \
	fi

# Create app bundle for distribution
bundle: check-cert release
	@echo "Creating app bundle..."
	@rm -rf solstone.app
	@mkdir -p solstone.app/Contents/MacOS
	@mkdir -p solstone.app/Contents/Resources
	@cp .build/release/solstone solstone.app/Contents/MacOS/
	@cp Sources/solstone/Info.plist solstone.app/Contents/
	@cp Sources/solstone/Resources/AppIcon.icns solstone.app/Contents/Resources/
	@cp -r .build/release/solstone_solstone.bundle solstone.app/Contents/Resources/
	@codesign --force --deep --sign "$(SIGN_IDENTITY)" --entitlements Sources/solstone/entitlements.plist solstone.app
	@echo "Created solstone.app"

# Create universal app bundle
bundle-universal: release-universal
	@echo "Creating universal app bundle..."
	@rm -rf solstone.app
	@mkdir -p solstone.app/Contents/MacOS
	@mkdir -p solstone.app/Contents/Resources
	@cp .build/apple/Products/Release/solstone solstone.app/Contents/MacOS/
	@cp Sources/solstone/Info.plist solstone.app/Contents/
	@cp Sources/solstone/Resources/AppIcon.icns solstone.app/Contents/Resources/
	@cp -r .build/apple/Products/Release/solstone_solstone.bundle solstone.app/Contents/Resources/
	@codesign --force --deep --sign "$(SIGN_IDENTITY)" --entitlements Sources/solstone/entitlements.plist solstone.app
	@echo "Created universal solstone.app"

# =======================================================================
# Distribution pipeline: Developer ID signed + notarized DMG
#
# Use `make release-dmg` to produce a signed, notarized, stapled DMG ready
# to hand out for ad-hoc install. All signing runs headless over SSH using
# the sol-signing keychain (see header). For local debug builds continue
# to use `bundle` / `bundle-universal` (self-signed `solstone dev` cert).
# =======================================================================

# Read-only check that Developer ID certs + notary profile are ready.
signing-check:
	@security find-identity -v -p codesigning | grep -q '"$(DEVELOPER_ID_APP)"' || \
		{ echo "error: '$(DEVELOPER_ID_APP)' not found in any keychain on the search list"; \
		  echo "       ensure $(SIGNING_KEYCHAIN) is in 'security list-keychains -d user'"; \
		  exit 1; }
	@security find-identity -v | grep -q '"$(DEVELOPER_ID_INSTALLER)"' || \
		{ echo "error: '$(DEVELOPER_ID_INSTALLER)' not found"; exit 1; }
	@xcrun notarytool history --keychain-profile "$(NOTARY_PROFILE)" --keychain "$(SIGNING_KEYCHAIN)" > /dev/null 2>&1 || \
		{ echo "error: notarytool profile '$(NOTARY_PROFILE)' not configured in $(SIGNING_KEYCHAIN)"; \
		  echo "       store with: xcrun notarytool store-credentials '$(NOTARY_PROFILE)' --key <p8> --key-id <id> --issuer <issuer> --keychain $(SIGNING_KEYCHAIN)"; \
		  exit 1; }
	@echo "✓ Developer ID certs + notary profile ready"

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
	@cp Sources/solstone/Info.plist solstone.app/Contents/
	@cp Sources/solstone/Resources/AppIcon.icns solstone.app/Contents/Resources/
	@cp -r .build/apple/Products/Release/solstone_solstone.bundle solstone.app/Contents/Resources/
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
		--entitlements Sources/solstone/entitlements.plist \
		solstone.app
	@codesign --verify --strict --deep --verbose=2 solstone.app
	@echo "✓ Signed: solstone.app"

# Create and sign the DMG.
dmg: bundle-dist
	@rm -f $(DMG_NAME)
	@hdiutil create -volname "solstone" -srcfolder solstone.app -ov -format UDZO $(DMG_NAME)
	@codesign --force --timestamp --sign "$(DEVELOPER_ID_APP)" --keychain "$(SIGNING_KEYCHAIN)" $(DMG_NAME)
	@echo "✓ Built: $(DMG_NAME)"

# Submit for notarization and block until Apple responds.
notarize: dmg
	@echo "Submitting $(DMG_NAME) for notarization (typically 1-5 min)…"
	@xcrun notarytool submit $(DMG_NAME) \
		--keychain-profile "$(NOTARY_PROFILE)" --keychain "$(SIGNING_KEYCHAIN)" \
		--wait

# Attach the notarization ticket to the DMG so Gatekeeper works offline.
staple: notarize
	@xcrun stapler staple $(DMG_NAME)

# Confirm the DMG will pass Gatekeeper on a fresh Mac.
verify-notarization: staple
	@spctl --assess --type open --context context:primary-signature -v $(DMG_NAME) || \
		{ echo "spctl verification failed"; exit 1; }
	@xcrun stapler validate $(DMG_NAME)
	@echo "✓ $(DMG_NAME) notarized + stapled"

# One-shot: build + sign + notarize + staple + verify. This is the canonical
# entry point for creating an ad-hoc distributable DMG.
release-dmg: verify-notarization
	@echo ""
	@echo "✅ Distribution DMG ready: $(DMG_NAME)"
	@echo "   Signed:  $(DEVELOPER_ID_APP)"
	@echo "   Notary:  $(NOTARY_PROFILE)"
	@echo "   Size:    $$(du -h $(DMG_NAME) | cut -f1)"

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
	@echo "Use 'make build' for a debug build or 'make install-app' to bundle and copy the app to /Applications."

# Alias for install
setup: install

# Install the bundled app to /Applications
install-app: bundle
	@rm -rf /Applications/solstone.app
	@cp -r solstone.app /Applications/
	@echo "Installed to /Applications/solstone.app"

# Open the app
open: bundle
	open solstone.app

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

# Create a self-signed code signing certificate in your login keychain (one-time setup).
# Using a named cert instead of ad-hoc (-) gives a stable designated requirement so
# TCC permissions survive rebuilds. Run 'make allow' after this to trust the certificate.
cert:
	@if security find-identity -v -p codesigning 2>/dev/null | grep -q '"$(SIGN_IDENTITY)"'; then \
		echo "Certificate '$(SIGN_IDENTITY)' already exists and is trusted — nothing to do."; \
		exit 0; \
	fi
	@if security find-identity -p codesigning 2>/dev/null | grep -q '"$(SIGN_IDENTITY)"'; then \
		echo "Certificate '$(SIGN_IDENTITY)' exists but is not trusted — run 'make allow'."; \
		exit 0; \
	fi
	@echo "Creating self-signed code signing certificate '$(SIGN_IDENTITY)'..."
	@TMPDIR=$$(mktemp -d); \
	PASS=$$(openssl rand -hex 16); \
	printf '[req]\ndistinguished_name=dn\nx509_extensions=v3\nprompt=no\n[dn]\nCN=$(SIGN_IDENTITY)\n[v3]\nkeyUsage=critical,digitalSignature,keyCertSign\nextendedKeyUsage=codeSigning\nbasicConstraints=critical,CA:TRUE\n' \
		> $$TMPDIR/cert.conf; \
	openssl genrsa -out $$TMPDIR/key.pem 2048 2>/dev/null; \
	openssl req -new -x509 -key $$TMPDIR/key.pem -out $$TMPDIR/cert.pem \
		-days 3650 -config $$TMPDIR/cert.conf 2>/dev/null; \
	openssl pkcs12 -export -legacy -out $$TMPDIR/cert.p12 \
		-inkey $$TMPDIR/key.pem -in $$TMPDIR/cert.pem -passout pass:$$PASS 2>/dev/null; \
	security import $$TMPDIR/cert.p12 \
		-k "$$HOME/Library/Keychains/login.keychain-db" \
		-T /usr/bin/codesign -P "$$PASS"; \
	rm -rf $$TMPDIR; \
	echo "Certificate created. Now run 'make allow' — macOS will ask for your password."

# Trust the self-signed certificate for code signing (one-time setup).
# This MUST be run by a human at the Mac — macOS shows a system password dialog
# that cannot be bypassed or automated. Agents cannot run this step.
allow:
	@if security find-identity -v -p codesigning 2>/dev/null | grep -q '"$(SIGN_IDENTITY)"'; then \
		echo "Certificate '$(SIGN_IDENTITY)' is already trusted — nothing to do."; \
		exit 0; \
	fi
	@security find-certificate -c "$(SIGN_IDENTITY)" -p \
		"$$HOME/Library/Keychains/login.keychain-db" > /dev/null 2>&1 || \
		{ echo "error: certificate '$(SIGN_IDENTITY)' not found — run 'make cert' first"; exit 1; }
	@echo "Trusting certificate '$(SIGN_IDENTITY)' — macOS will ask for your password..."
	@CERT=$$(security find-certificate -c "$(SIGN_IDENTITY)" -p \
		"$$HOME/Library/Keychains/login.keychain-db"); \
	TMPFILE=$$(mktemp); \
	echo "$$CERT" > $$TMPFILE; \
	security add-trusted-cert -r trustRoot \
		-k "$$HOME/Library/Keychains/login.keychain-db" $$TMPFILE; \
	rm -f $$TMPFILE; \
	echo "Done — '$(SIGN_IDENTITY)' is trusted. Run 'make install-app' to build and install."

# Generate icon assets from SVG sources in assets/
# Requires: rsvg-convert (brew install librsvg), iconutil (built-in macOS)
# Run when SVGs change. Output files are committed so fresh checkouts build cleanly.
icons: check-icons-deps
	@echo "Generating icons from SVG sources..."
	@mkdir -p Sources/solstone/Resources
	@TMPDIR=$$(mktemp -d) && \
	ICONSET=$$TMPDIR/AppIcon.iconset && \
	mkdir -p $$ICONSET && \
	\
	echo "  Rendering app icon sizes..." && \
	for size in 16 32 64 128 256 512 1024; do \
		rsvg-convert -w $$size -h $$size assets/icon-app.svg \
			-o $$TMPDIR/icon_$${size}.png; \
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
	echo "  Rendering status bar template icons..." && \
	rsvg-convert -w 18 -h 18 assets/sol-ring.svg \
		-o Sources/solstone/Resources/sol-ring-template.png && \
	rsvg-convert -w 36 -h 36 assets/sol-ring.svg \
		-o Sources/solstone/Resources/sol-ring-template@2x.png && \
	echo "  ✓ sol-ring-template.png + @2x" && \
	echo "  Rendering status bar variant icons..." && \
	rsvg-convert -w 18 -h 18 assets/sol-ring-icon-error.svg \
		-o Sources/solstone/Resources/sol-ring-icon-error-template.png && \
	rsvg-convert -w 36 -h 36 assets/sol-ring-icon-error.svg \
		-o Sources/solstone/Resources/sol-ring-icon-error-template@2x.png && \
	echo "  ✓ sol-ring-icon-error-template.png + @2x" && \
	rsvg-convert -w 18 -h 18 assets/sol-ring-icon-paused.svg \
		-o Sources/solstone/Resources/sol-ring-icon-paused-template.png && \
	rsvg-convert -w 36 -h 36 assets/sol-ring-icon-paused.svg \
		-o Sources/solstone/Resources/sol-ring-icon-paused-template@2x.png && \
	echo "  ✓ sol-ring-icon-paused-template.png + @2x" && \
	rsvg-convert -w 18 -h 18 assets/sol-ring-icon-half.svg \
		-o Sources/solstone/Resources/sol-ring-icon-half-template.png && \
	rsvg-convert -w 36 -h 36 assets/sol-ring-icon-half.svg \
		-o Sources/solstone/Resources/sol-ring-icon-half-template@2x.png && \
	echo "  ✓ sol-ring-icon-half-template.png + @2x" && \
	\
	echo "  Rendering wordmark for UI..." && \
	rsvg-convert -w 128 -h 128 assets/sol-wordmark.svg \
		-o Sources/solstone/Resources/sol-wordmark.png && \
	rsvg-convert -w 256 -h 256 assets/sol-wordmark.svg \
		-o Sources/solstone/Resources/sol-wordmark@2x.png && \
	echo "  ✓ sol-wordmark.png + @2x" && \
	\
	rm -rf $$TMPDIR && \
	echo "Icons generated in Sources/solstone/Resources/"

check-icons-deps:
	@which rsvg-convert > /dev/null 2>&1 || \
		(echo "error: rsvg-convert not found — run: brew install librsvg"; exit 1)
	@which iconutil > /dev/null 2>&1 || \
		(echo "error: iconutil not found (requires macOS)"; exit 1)

# ────────────────────────────────────────────────────────────────
# Publish targets — EXTRO-HOST ONLY
# Do not run on pro5e. These are invoked from the extro host by VPE
# during the release playbook. They require wrangler and the local
# vault private key.
# ────────────────────────────────────────────────────────────────
publish-appcast:
	python3 scripts/publish-appcast.py $(DIST_VERSION)

publish-appcast-staging:
	python3 scripts/publish-appcast.py $(DIST_VERSION) --staging

.PHONY: publish-appcast publish-appcast-staging
