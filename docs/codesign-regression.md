# verify-notarization regression test

Run this manual check once per codesign-chain change to prove the `verify-notarization` Team ID gate is actually checking the nested CLI signature. This is a local regression gate, not a CI step.

1. Run `make bundle-dist`.
2. Re-sign the inner CLI with the `solstone dev` cert, preserving hardened runtime, timestamp, and identifier `app.solstone.observer.cli`.
3. Re-sign the outer `.app` with the `solstone dev` cert.
4. Run only the inner-CLI Team ID gate from `verify-notarization:`.

```sh
make bundle-dist

codesign --force --options runtime --timestamp --identifier app.solstone.observer.cli \
  --sign "solstone dev" solstone.app/Contents/MacOS/sol-mac

codesign --force --options runtime --timestamp \
  --entitlements Sources/solstone/entitlements.plist \
  --sign "solstone dev" solstone.app

codesign -dvvv solstone.app/Contents/MacOS/sol-mac 2>&1 | grep -q 'TeamIdentifier=7QCG8V4M6H'
```

This regression passes if the Team ID grep fails with a non-zero exit, proving the verification gate is actually checking the Team ID. If that command exits `0`, the gate is broken and must be fixed before merging.
