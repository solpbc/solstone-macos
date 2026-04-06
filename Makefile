.PHONY: build release release-universal run clean test snapshot bundle bundle-universal install open reset-permissions icons check-icons-deps

# Build debug version
build:
	swift build

# Build release version
release:
	swift build -c release

# Build universal binary (arm64 + x86_64)
release-universal:
	swift build -c release --arch arm64 --arch x86_64

# Run the app
run:
	swift run

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

# Create app bundle for distribution
bundle: release
	@echo "Creating app bundle..."
	@rm -rf solstone.app
	@mkdir -p solstone.app/Contents/MacOS
	@mkdir -p solstone.app/Contents/Resources
	@cp .build/release/solstone solstone.app/Contents/MacOS/
	@cp Sources/solstone/Info.plist solstone.app/Contents/
	@cp Sources/solstone/Resources/AppIcon.icns solstone.app/Contents/Resources/
	@cp -r .build/release/solstone_solstone.bundle solstone.app/Contents/Resources/
	@codesign --force --deep --sign - solstone.app
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
	@codesign --force --deep --sign - solstone.app
	@echo "Created universal solstone.app"

# Install to /Applications (resets TCC so rebuilt binary is recognized)
install: bundle
	-@pkill -f solstone 2>/dev/null
	@echo "Installing to /Applications..."
	@rm -rf /Applications/solstone.app
	@cp -r solstone.app /Applications/
	-@tccutil reset ScreenCapture app.solstone.capture 2>/dev/null
	-@tccutil reset Microphone app.solstone.capture 2>/dev/null
	-@defaults delete app.solstone.capture 2>/dev/null
	@echo "Installed to /Applications/solstone.app (TCC + defaults reset, will prompt on first launch)"

# Open the app
open: bundle
	open solstone.app

# Reset TCC permissions for testing
reset-permissions:
	-tccutil reset ScreenCapture app.solstone.capture
	-tccutil reset Microphone app.solstone.capture
	@echo "TCC permissions reset. Restart the app to trigger permission prompts."

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
