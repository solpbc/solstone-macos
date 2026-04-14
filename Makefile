.PHONY: build release release-universal run clean test snapshot bundle bundle-universal install setup install-app open reset cert allow check-cert icons check-icons-deps check-dev-deps

# Code signing identity — run 'make cert' then 'make allow' to create and trust (one-time setup)
SIGN_IDENTITY ?= solstone dev

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
