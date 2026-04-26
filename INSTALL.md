# installing solstone-macos

these instructions are for a coding agent and human working together. solstone-macos is a native swift menu bar app — one of the owner's observers, experiencing screen and audio along with them on macOS, with segments uploaded to a solstone server.

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
- **Code signing trust.** one step below (`make allow`) requires the human — macOS shows a system password dialog that cannot be automated or run over SSH. the agent can do everything else.

## install sequence

1. if not already cloned, clone into solstone's observers directory:
   ```
   cd "$(sol root)/observers"
   git clone https://github.com/solpbc/solstone-macos.git
   cd solstone-macos
   ```

2. install build dependencies and create a self-signed code signing certificate:
   ```
   make install
   make cert
   ```
   `make install` checks for Xcode and installs optional icon dependencies. `make cert` creates a local code signing certificate so the app gets a stable identity (TCC permissions survive rebuilds).

3. **[human required]** trust the certificate — macOS will show a system password dialog:
   ```
   make allow
   ```
   this cannot be run by an agent or over SSH. the human enters their mac password once and they're done.

4. build and install the app:
   ```
   make install-app
   ```
   this builds a release binary, signs it, bundles the app, and copies it to `/Applications`.

5. if macOS blocks the app on first launch, clear the quarantine flag:
   ```
   xattr -cr /Applications/solstone.app
   ```

6. launch the app:
   ```
   open /Applications/solstone.app
   ```

7. register the observer and push config into the app. this creates the server-side registration and writes the credentials directly into the app's UserDefaults — the app detects the change automatically and starts syncing:
   ```
   key=$(sol observer --json create solstone-macos | jq -r .key)
   defaults write app.solstone.observer serverURL "http://localhost:5015"
   defaults write app.solstone.observer serverKey "$key"
   ```
   if `sol observer create` fails with "already exists", the observer was registered by a previous install. revoke and recreate:
   ```
   sol observer revoke solstone-macos
   key=$(sol observer --json create solstone-macos | jq -r .key)
   defaults write app.solstone.observer serverURL "http://localhost:5015"
   defaults write app.solstone.observer serverKey "$key"
   ```

8. your human needs to approve **screen recording** and **microphone** permission dialogs when macOS prompts for them.

9. verify the menu bar icon appears and the observer is connected:
   ```
   sol observer list
   ```

## if your server is not on localhost

if you point solstone at a server on your LAN using a `.local` name, a private IP address, or a local IPv6 address, macOS may ask for Local Network access. if uploads fail and the app says `Can't reach local network. Open System Settings → Privacy & Security → Local Network and allow solstone.`, open that settings page and enable `solstone`. `http://localhost:5015` does not need Local Network permission, so a standard local install usually will not show this prompt. if you denied the prompt earlier, toggle it there and run the connection test again.

solstone ships with an App Transport Security exception (`NSAllowsArbitraryLoads`) so the app can reach `http://` servers on local networks and Tailscale CGNAT IPs (`100.64.0.0/10`), which ATS does not cover via `NSAllowsLocalNetworking` alone.

## notes

- the app detects `defaults write` changes automatically — no need to restart it after writing config.
- if the agent flow above doesn't work, the human can click "connect to local service" in the app's settings as a fallback.
- the app starts automatically at login once installed.
