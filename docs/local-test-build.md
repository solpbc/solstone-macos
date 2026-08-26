# local test build

## prerequisites

- mac, version 15 or later
- Xcode with Swift 6.1 or later
- no Developer ID signing identity is required

## build and run

```bash
make bundle-adhoc
make run
```

`bundle-adhoc` writes `solstone.app` in the repository directory. `make run` opens that bundle and streams unified logs for local inspection.

## local pairing

local ad-hoc builds store pairing material in your login keychain, as set by the [`bundle-adhoc` build recipe](../Makefile), so you can test pairing without a Developer ID signing identity.

do not distribute local test builds.

## optional stable development certificate

```bash
scripts/adhoc-dev-cert.sh install
```

the script creates a self-signed code-signing identity named `solstone local dev` if one is missing. It is idempotent, imports the identity into `~/Library/Keychains/login.keychain-db`, and cleans up temporary key material through an exit trap.

when the certificate exists, `bundle-adhoc` signs with that stable identity. Without it, the Makefile falls back to `--sign -` for pure ad-hoc signing. On some machines, `security set-key-partition-list` may ask for the login keychain password. Set `ADHOC_KEYCHAIN_PASSWORD` for a noninteractive local run, or enter the login keychain password when prompted.

## debuggable variant

```bash
make bundle-adhoc-debug
```

this reuses the same bundle recipe with `Sources/solstone/entitlements-adhoc-debug.plist`, adding `com.apple.security.get-task-allow`. The build still uses hardened runtime, so debugger attach behavior can vary by mac system policy and local security settings.

## verification

```bash
codesign -dv --verbose=4 solstone.app
codesign -d --entitlements - --xml solstone.app | plutil -p -
codesign --verify --strict --verbose=2 solstone.app
```

the local bundle should contain `SolstoneSPLKeychainPlane = login-keychain` in `Contents/Info.plist` and should not contain `keychain-access-groups` or `com.apple.developer.team-identifier` entitlements.

## gotchas

- always-allow keychain prompts can recur across pure ad-hoc rebuilds because the app identity changes. Use the stable development certificate to keep a consistent local signing identity.
- `bundle-adhoc` overwrites `solstone.app` in the repository directory.
- do not distribute `bundle-adhoc` or `bundle-adhoc-debug` builds.
- `bundle-adhoc-debug` builds stay debug-attachable because they include `get-task-allow`.
- on a machine without the stable development certificate, `scripts/adhoc-dev-cert.sh identity` prints nothing and exits nonzero; the Makefile then signs with `-`.
