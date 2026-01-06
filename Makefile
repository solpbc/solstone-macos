.PHONY: build release run clean test bundle install open reset-permissions

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
