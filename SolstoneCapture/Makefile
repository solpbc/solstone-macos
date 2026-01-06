.PHONY: build release run clean reset-permissions bundle install

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
	@echo "Created SolstoneCapture.app"

# Create universal app bundle
bundle-universal: release-universal
	@echo "Creating universal app bundle..."
	@rm -rf SolstoneCapture.app
	@mkdir -p SolstoneCapture.app/Contents/MacOS
	@mkdir -p SolstoneCapture.app/Contents/Resources
	@cp .build/apple/Products/Release/SolstoneCapture SolstoneCapture.app/Contents/MacOS/
	@cp Sources/SolstoneCapture/Info.plist SolstoneCapture.app/Contents/
	@echo "Created universal SolstoneCapture.app"

# Install to /Applications
install: bundle
	@echo "Installing to /Applications..."
	@rm -rf /Applications/SolstoneCapture.app
	@cp -r SolstoneCapture.app /Applications/
	@echo "Installed to /Applications/SolstoneCapture.app"

# Open the app
open: bundle
	open SolstoneCapture.app
