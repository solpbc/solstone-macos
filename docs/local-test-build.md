# local test build

## prerequisites

- Xcode
- no Developer ID signing identity

## build and run

```bash
make bundle-adhoc
make run
```

`bundle-adhoc` writes `solstone.app` in the repository directory. `make run` opens that bundle and streams unified logs for local inspection.

## login-keychain pairing plane

the normal shipped app stores the SPL pairing bundle in the Team-ID-gated Data Protection keychain access group. Local ad-hoc builds are not entitled for that group, so `bundle-adhoc` seals the `SolstoneSPLKeychainPlane=login-keychain` marker into `solstone.app/Contents/Info.plist` and omits the Data Protection keychain and access-group query attributes.

that local-only build stores pairing material in the plain login keychain instead. This exists only so contributors can exercise SPL pairing and tunnel behavior without Developer ID signing identities. It is never update-served or shipped.

## optional stable dev certificate

```bash
scripts/adhoc-dev-cert.sh install
```

the script creates a self-signed code-signing identity named `solstone local dev` if one is missing. It is idempotent and touches only `~/Library/Keychains/login.keychain-db`.

when the cert exists, `bundle-adhoc` signs with that stable identity. Without it, the Makefile falls back to `--sign -` for pure ad-hoc signing. On some machines, `codesign` may ask for the login keychain password once when using the stable cert. The script runs `security set-key-partition-list`; set `ADHOC_KEYCHAIN_PASSWORD` for a noninteractive local run, or enter the login keychain password when prompted.

## debuggable variant

```bash
make bundle-adhoc-debug
```

this reuses the same bundle recipe with `Sources/solstone/entitlements-adhoc-debug.plist`, adding `com.apple.security.get-task-allow`. The build still uses hardened runtime, so debugger attach behavior can vary by macOS policy and local security settings.

## verification

```bash
codesign -dv --verbose=4 solstone.app
codesign -d --entitlements - --xml solstone.app | plutil -p -
codesign --verify --strict --verbose=2 solstone.app
```

the local bundle should contain `SolstoneSPLKeychainPlane = login-keychain` in `Contents/Info.plist` and should not contain `keychain-access-groups` or `com.apple.developer.team-identifier` entitlements.

## gotchas

- always-allow keychain prompts can recur across pure ad-hoc rebuilds because the app identity changes. Use the stable dev cert to keep a consistent local signing identity.
- `bundle-adhoc` overwrites `solstone.app` in the repository directory.
- `bundle-adhoc` and `bundle-adhoc-debug` are local test builds only. They are never update-served or shipped.
- `bundle-adhoc-debug` builds stay debug-attachable because they include `get-task-allow`.
- on a machine without the stable dev cert, `scripts/adhoc-dev-cert.sh identity` prints nothing and exits nonzero; the Makefile then signs with `-`.
