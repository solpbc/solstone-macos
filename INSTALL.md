# installing solstone-macos

these instructions are for a coding agent and human working together. solstone-macos is a native swift menu bar app that captures screen and audio on macOS, and uploads to a solstone server.

solstone must already be installed and running. if it isn't, start there: https://solstone.app/install

## before you begin

if `sol` is not in PATH, check `~/.local/bin/sol` or use `.venv/bin/sol` inside the solstone repo.

check if the app is already installed:

```
ls /Applications/solstone.app
sol observer list
```

if the app exists and shows as connected, you're done.

## requirements

- **Xcode** (full IDE, not just command line tools). this is a large download from the Mac App Store — your human needs to install it if they haven't already.
- macOS 15.0+

## what to sort out together

- **Xcode availability.** check if `xcodebuild -version` works. if not, the human needs to install Xcode from the App Store before you can build.

## install sequence

1. if not already cloned, clone into solstone's observers directory and build:
   ```
   cd "$(sol root)/observers"
   git clone https://github.com/solpbc/solstone-macos.git
   cd solstone-macos
   ```
   then install local build dependencies and the app:
   ```
   make install
   # or: make setup
   make install-app
   ```
   `make install` and `make setup` prepare the development environment. `make install-app` builds a release binary, creates an app bundle, and copies it to `/Applications`.

2. if macOS blocks the unsigned app, clear the quarantine flag:
   ```
   xattr -cr /Applications/solstone.app
   ```

3. launch the app:
   ```
   open /Applications/solstone.app
   ```

4. the app auto-registers with the solstone server at `http://localhost:5015`. your human needs to approve **screen recording** and **microphone** permission dialogs when macOS prompts for them.

5. verify the menu bar icon appears and the observer is connected:
   ```
   sol observer list
   ```

## notes

- if auto-registration fails (server not reachable), register manually with `sol observer create solstone-macos` and enter the server URL and API key in the app's setup screen.
- the app starts automatically at login once installed.
