.PHONY: build release run clean reset-permissions bundle install icons check-icons-deps

# Build debug version
build:
	swift build

# Build release version
release:
	swift build -c release

# Build universal binary (arm64 + x86_64)
release-universal:
	swift build -c release --arch arm64 --arch x86_64

# Run the app (debug build)
run: build
	./.build/debug/SolstoneCapture

# Clean build artifacts
clean:
	swift package clean
	rm -rf .build
	rm -rf SolstoneCapture.app

# Reset TCC permissions for testing
reset-permissions:
	-tccutil reset ScreenCapture com.solstone.capture
	-tccutil reset Microphone com.solstone.capture
	@echo "TCC permissions reset. Restart the app to trigger permission prompts."

# Create app bundle for distribution
bundle: release
	@echo "Creating app bundle..."
	@rm -rf SolstoneCapture.app
	@mkdir -p SolstoneCapture.app/Contents/MacOS
	@mkdir -p SolstoneCapture.app/Contents/Resources
	@cp .build/release/SolstoneCapture SolstoneCapture.app/Contents/MacOS/
	@cp Sources/SolstoneCapture/Info.plist SolstoneCapture.app/Contents/
	@cp Sources/SolstoneCapture/Resources/AppIcon.icns SolstoneCapture.app/Contents/Resources/
	@cp -r .build/release/SolstoneCapture_SolstoneCapture.bundle SolstoneCapture.app/Contents/Resources/
	@echo "Created SolstoneCapture.app"

# Create universal app bundle
bundle-universal: release-universal
	@echo "Creating universal app bundle..."
	@rm -rf SolstoneCapture.app
	@mkdir -p SolstoneCapture.app/Contents/MacOS
	@mkdir -p SolstoneCapture.app/Contents/Resources
	@cp .build/apple/Products/Release/SolstoneCapture SolstoneCapture.app/Contents/MacOS/
	@cp Sources/SolstoneCapture/Info.plist SolstoneCapture.app/Contents/
	@cp Sources/SolstoneCapture/Resources/AppIcon.icns SolstoneCapture.app/Contents/Resources/
	@cp -r .build/apple/Products/Release/SolstoneCapture_SolstoneCapture.bundle SolstoneCapture.app/Contents/Resources/
	@echo "Created universal SolstoneCapture.app"

# Install to /Applications (resets TCC so rebuilt binary is recognized)
install: bundle
	@echo "Installing to /Applications..."
	@rm -rf /Applications/SolstoneCapture.app
	@cp -r SolstoneCapture.app /Applications/
	-@tccutil reset ScreenCapture com.solstone.capture 2>/dev/null
	-@tccutil reset Microphone com.solstone.capture 2>/dev/null
	@echo "Installed to /Applications/SolstoneCapture.app (TCC reset, will prompt on first launch)"

# Open the app
open: bundle
	open SolstoneCapture.app

# Generate all icon assets from SVG sources in ../assets/
# Requires: rsvg-convert (brew install librsvg), iconutil (built-in macOS)
# Run when SVGs change. Output files are committed so fresh checkouts build cleanly.
icons: check-icons-deps
	@echo "Generating icons from SVG sources..."
	@mkdir -p Sources/SolstoneCapture/Resources
	@TMPDIR=$$(mktemp -d) && \
	ICONSET=$$TMPDIR/AppIcon.iconset && \
	mkdir -p $$ICONSET && \
	\
	echo "  Rendering app icon sizes..." && \
	for size in 16 32 64 128 256 512 1024; do \
		rsvg-convert -w $$size -h $$size ../assets/sol-wordmark.svg \
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
	iconutil -c icns $$ICONSET -o Sources/SolstoneCapture/Resources/AppIcon.icns && \
	echo "  ✓ AppIcon.icns" && \
	\
	echo "  Rendering status bar template icons..." && \
	rsvg-convert -w 18 -h 18 ../assets/sol-ring.svg \
		-o Sources/SolstoneCapture/Resources/sol-ring-template.png && \
	rsvg-convert -w 36 -h 36 ../assets/sol-ring.svg \
		-o Sources/SolstoneCapture/Resources/sol-ring-template@2x.png && \
	echo "  ✓ sol-ring-template.png + @2x" && \
	\
	echo "  Rendering wordmark for UI..." && \
	rsvg-convert -w 128 -h 128 ../assets/sol-wordmark.svg \
		-o Sources/SolstoneCapture/Resources/sol-wordmark.png && \
	rsvg-convert -w 256 -h 256 ../assets/sol-wordmark.svg \
		-o Sources/SolstoneCapture/Resources/sol-wordmark@2x.png && \
	echo "  ✓ sol-wordmark.png + @2x" && \
	\
	rm -rf $$TMPDIR && \
	echo "Icons generated in Sources/SolstoneCapture/Resources/"

check-icons-deps:
	@which rsvg-convert > /dev/null 2>&1 || \
		(echo "error: rsvg-convert not found — run: brew install librsvg"; exit 1)
	@which iconutil > /dev/null 2>&1 || \
		(echo "error: iconutil not found (requires macOS)"; exit 1)
