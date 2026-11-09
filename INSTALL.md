# Installing the solstone app on macos

These instructions are for a coding agent and human working together. The solstone app on macos takes in what you share with it, and all of it goes into your journal.

The solstone app and the journal are separate apps. Install the journal on the computer where you choose to keep it: <https://solstone.app/download/journal>.

## Install the signed DMG

Download the signed and notarized DMG from <https://solstone.app/download/macos>. Open it, drag the solstone app to `/Applications`, and launch it. If this mac is also where you keep your journal, install the journal separately.

## Build from source

Build from source when you need to modify the app. Follow [the local test build guide](docs/local-test-build.md) for the supported public path.

```bash
git clone https://github.com/solpbc/solstone-macos.git
cd solstone-macos
make install
make build
make test
make run
```

## Permissions and connection

macos may show permission prompts for the solstone app. Allow the permissions for material you choose to share; that material goes into your journal.

Launch the app and select **connect your journal →** in its settings. This connection setup registers the installation with the local journal at `http://localhost:5015`; material then goes into your journal, with no key to copy or paste.

## A journal on your network

If you point the solstone app at a journal on your LAN using a `.local` name, a private IP address, or a local IPv6 address, macos may ask for Local Network access. If uploads fail and the app says `Can't reach local network. Open System Settings → Privacy & Security → Local Network and allow solstone.`, open that settings page and enable `solstone`. `http://localhost:5015` does not need Local Network permission, so a standard local install usually will not show this prompt. If you denied the prompt earlier, toggle it there and run the connection test again.

The solstone app includes an App Transport Security exception (`NSAllowsArbitraryLoads`). This permits access to journal endpoints over `http://` on local networks and Tailscale CGNAT IPs (`100.64.0.0/10`), which ATS does not cover via `NSAllowsLocalNetworking` alone.

## Notes

- The app starts automatically at login once installed.
- See [README.md](README.md) for development commands and [AGENTS.md](AGENTS.md) for contributor guidance.

## Your tmux sessions

The app can take in your tmux sessions, and all of it goes into your journal. It's off until you turn on terminal in Settings > Sources, and it needs tmux on this Mac. It runs whenever the app does, and works in any terminal session, including when you SSH into this Mac. Pausing or quitting the app stops it.

If solstone for tmux is on this Mac, turning terminal on asks first, then moves it in: what it still has waiting goes into your journal through this app, anything that can't go stays on this Mac, and solstone for tmux stops for good.
