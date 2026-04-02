.PHONY: build release run clean test snapshot bundle install open reset-permissions icons

# Build both packages (debug)
build:
	swift build --package-path SolstoneCaptureCore
	swift build --package-path SolstoneCapture

# Build release
release:
	swift build --package-path SolstoneCaptureCore -c release
	swift build --package-path SolstoneCapture -c release

# Run the app
run:
	$(MAKE) -C SolstoneCapture run

# Clean all build artifacts
clean:
	swift package clean --package-path SolstoneCaptureCore
	rm -rf SolstoneCaptureCore/.build
	swift package clean --package-path SolstoneCapture
	rm -rf SolstoneCapture/.build
	rm -rf SolstoneCapture/SolstoneCapture.app

# Run tests
test:
	swift test --package-path SolstoneCaptureCore
	swift test --package-path SolstoneCapture

# Render view snapshots
snapshot:
	swift test --package-path SolstoneCapture --filter Snapshot

# Create app bundle
bundle:
	$(MAKE) -C SolstoneCapture bundle

# Install to /Applications
install:
	$(MAKE) -C SolstoneCapture install

# Open the app
open:
	$(MAKE) -C SolstoneCapture open

# Reset TCC permissions
reset-permissions:
	$(MAKE) -C SolstoneCapture reset-permissions

# Generate icon assets from SVG sources (requires macOS + librsvg)
# Run when assets/ SVGs change: make icons && git add -A SolstoneCapture/Sources/SolstoneCapture/Resources
icons:
	$(MAKE) -C SolstoneCapture icons
