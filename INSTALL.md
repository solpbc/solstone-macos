# installing solstone-macos

these instructions are for a coding agent and human working together. solstone-macos is a native swift menu bar app — one of the owner's observers, experiencing screen and audio along with them on macOS, with observations sent to your solstone journal.

## default install path — signed DMG

the easiest install is the signed + notarized DMG from <https://solstone.app/download/macos>. download, open, drag to `/Applications`, and launch. the app installs your observer and journal, opens the first-run wizard, and updates over a signed channel. no Xcode, no certificates, no source build.

## source-build path — Apple Developer Program required

build from source only if you need to modify the app or are a sol pbc maintainer. `make bundle-dist` signs under `Developer ID Application: sol pbc (7QCG8V4M6H)` and requires those identities in the local keychain. a fresh machine without those identities should use the DMG.

source builds assume solstone is already installed and running. if it isn't, start there: https://solstone.app/install

## before you begin

if `sol` is not in PATH, check `~/.local/bin/sol`.

check if the app is already installed:

```
ls /Applications/solstone.app
journal observer list
```

if the app exists and shows as connected, you're done.

## requirements (source build)

- **Xcode** (full IDE, not just command line tools). this is a large download from the Mac App Store — your human needs to install it if they haven't already.
- macOS 15.0+
- sol pbc Developer ID Application + Developer ID Installer identities in the local keychain (sol-signing keychain)

## what to sort out together

- **Xcode availability.** check if `xcodebuild -version` works. if not, the human needs to install Xcode from the App Store before you can build.
- **Signing keychain unlocked.** `make signing-check` confirms Developer ID identities are present and the notary profile is healthy.

## first-launch permission prompts

macOS may show permission prompts for solstone's python runtime the first time the app starts.
allow them so sol can read transcripts and observations into your journal.
Apple may revise the exact wording, so follow the permission intent rather than matching text here.

## install sequence (source build)

1. if not already cloned, clone into solstone's observers directory:
   ```
   cd "$(sol root)/observers"
   git clone https://github.com/solpbc/solstone-macos.git
   cd solstone-macos
   ```

2. install build dependencies and verify the signing keychain:
   ```
   make install
   make signing-check
   ```
   `make install` checks for Xcode and installs optional icon dependencies. `make signing-check` confirms the Developer ID identities + notarytool profile are present (auto-restores the notary profile if it has evicted).

3. build the signed .app:
   ```
   make bundle-dist
   ```
   this builds a universal release binary, vendors uv + python into the bundle, signs everything under Developer ID Application with hardened runtime, and writes `solstone.app` in the source tree.

4. install to `/Applications` (optional — `make run` launches directly from the source tree):
   ```
   cp -r solstone.app /Applications/
   ```

5. launch the app:
   ```
   open solstone.app                  # from the source tree
   # OR
   open /Applications/solstone.app    # if you copied it
   ```

6. connect the app to your journal. launch the app and click **"connect your journal →"** in its settings — the app registers itself against the local journal at `http://localhost:5015` and starts syncing, with no key to copy or paste. this is the primary path.

   once connected, macOS emits a diagnostics-only observer health beacon on the existing heartbeat. it carries operational sync state only and intentionally excludes screen/audio content and local segment file paths; journal-side ingest rejections remain a separate health source from the journal.

   **maintainer escape hatch (scripted installs only):** to wire the app without the wizard, mint a key on the journal host and write it into the app's UserDefaults directly — the app detects the change automatically and starts syncing:
   ```
   key=$(journal observer --json create solstone-macos | jq -r .key)
   defaults write app.solstone.observer serverURL "http://localhost:5015"
   defaults write app.solstone.observer serverKey "$key"
   ```
   if `journal observer create` fails with "already exists", the observer was registered by a previous install. revoke and recreate:
   ```
   journal observer revoke solstone-macos
   key=$(journal observer --json create solstone-macos | jq -r .key)
   defaults write app.solstone.observer serverURL "http://localhost:5015"
   defaults write app.solstone.observer serverKey "$key"
   ```

7. your human needs to approve **screen recording** and **microphone** permission dialogs when macOS prompts for them.

8. verify the menu bar icon appears and the observer is connected:
   ```
   journal observer list
   ```

## if your journal is not on localhost

if you point solstone at a journal on your LAN using a `.local` name, a private IP address, or a local IPv6 address, macOS may ask for Local Network access. if uploads fail and the app says `Can't reach local network. Open System Settings → Privacy & Security → Local Network and allow solstone.`, open that settings page and enable `solstone`. `http://localhost:5015` does not need Local Network permission, so a standard local install usually will not show this prompt. if you denied the prompt earlier, toggle it there and run the connection test again.

solstone ships with an App Transport Security exception (`NSAllowsArbitraryLoads`) so the app can reach journal endpoints over `http://` on local networks and Tailscale CGNAT IPs (`100.64.0.0/10`), which ATS does not cover via `NSAllowsLocalNetworking` alone.

## notes

- the app detects `defaults write` changes automatically — no need to restart it after writing config.
- the in-app "connect your journal →" wizard (step 6) is the primary way to connect; the `defaults write` flow is a maintainer escape hatch for scripted installs only.
- the app starts automatically at login once installed.
