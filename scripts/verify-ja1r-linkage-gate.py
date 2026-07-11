#!/usr/bin/env python3
"""
Verify the ja1r install/upgrade linkage-gate evidence set for a release.
Usage:
  verify-ja1r-linkage-gate.py --profile {sol,journal,paired} --report-dir DIR
      --sync-receipt PATH --product-commit SHA40 --expected-journal-runtime PIN
      [identity flags -- see --help; which are required depends on --profile]
Inputs:
  - report dir holding the lane reports listed in REPORT_FILENAMES (operator
    creates them by redirecting each gate.py lane's stdout; the harness itself
    writes no files)
  - sync receipt written by `make ja1r-gate-sync` after it reads the harness
    revision marker back off the rig
  - scripts/ja1r-gate/extro-tools.rev -- the committed harness pin
  - every expected identity, passed explicitly; none is ever read out of the
    evidence being checked
Side effects:
  - none. Reads files, writes a verdict to stdout and diagnostics to stderr.
    Never touches the network, so a production publish stays offline.

This verifier does NOT re-implement the harness's oracles: a PASS report's own
checks remain authoritative. Its job is narrow -- freshness, completeness,
scenario identity, provenance, and the runtime pin -- so that a prior release's
green JSON cannot authorize this one.

Exit 0 prints one JSON verdict on stdout. Every other path exits nonzero with
no stdout verdict.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
PIN_FILE = REPO_ROOT / "scripts" / "ja1r-gate" / "extro-tools.rev"

SCHEMA_VERSION = 1
PASS_RESULT = "PASS"

SHA40_RE = re.compile(r"^[0-9a-f]{40}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")

# The canonical evidence-set filenames. README documents the producing command
# for each; scripts/tests/test_verify_ja1r_linkage_gate.py asserts the README
# list and this constant cannot drift apart.
REPORT_FILENAMES = (
    "drag.json",
    "sparkle.json",
    "fresh-journal-first.json",
    "fresh-sol-first.json",
    "sol-upgrade.json",
    "journal-upgrade.json",
)

# Identity keys, as passed on the CLI. Each maps to one scenario field in some
# lane's report. Nothing here is ever inferred from a report.
IDENTITY_KEYS = (
    "sol_target_version",
    "sol_target_build",
    "journal_target_version",
    "journal_target_build",
    "sol_baseline_version",
    "sol_baseline_build",
    "journal_baseline_version",
    "journal_baseline_build",
    "companion_sol_version",
    "companion_sol_build",
    "legacy_sol_baseline_version",
)


class LaneSpec:
    """How one report file must look.

    identity maps report scenario field -> identity key supplied on the CLI.
    pin_check_key is the harness check that proves the journal runtime pin was
    enforced. observes_runtime records whether the lane stores the oracles
    fingerprint (top-level `post`) in its report -- see verify_runtime_pin.
    """

    def __init__(self, lane, identity, pin_check_key, observes_runtime, order=None):
        self.lane = lane
        self.identity = identity
        self.pin_check_key = pin_check_key
        self.observes_runtime = observes_runtime
        self.order = order


_DRAG_SPARKLE_IDENTITY = {
    "from": "legacy_sol_baseline_version",
    "to": "sol_target_version",
    "to_build": "sol_target_build",
    "journal": "journal_target_version",
    "journal_build": "journal_target_build",
}

_FRESH_IDENTITY = {
    "to": "sol_target_version",
    "to_build": "sol_target_build",
    "journal": "journal_target_version",
    "journal_build": "journal_target_build",
}

# Lane -> shape. Derived from the pinned harness's report emitter (gate.py
# new_report), not from a captured run.
LANE_SPECS = {
    "drag.json": LaneSpec(
        lane="drag",
        identity=_DRAG_SPARKLE_IDENTITY,
        pin_check_key="solstone_pin_matches",
        observes_runtime=True,
    ),
    "sparkle.json": LaneSpec(
        lane="sparkle",
        identity=_DRAG_SPARKLE_IDENTITY,
        pin_check_key="solstone_pin_matches",
        observes_runtime=True,
    ),
    # Both fresh reports carry lane "fresh"; only `order` tells them apart.
    "fresh-journal-first.json": LaneSpec(
        lane="fresh",
        identity=_FRESH_IDENTITY,
        pin_check_key="solstone_pin_matches",
        observes_runtime=False,
        order="journal-first",
    ),
    "fresh-sol-first.json": LaneSpec(
        lane="fresh",
        identity=_FRESH_IDENTITY,
        pin_check_key="solstone_pin_matches",
        observes_runtime=False,
        order="sol-first",
    ),
    "sol-upgrade.json": LaneSpec(
        lane="sol-upgrade",
        identity={
            "from": "sol_baseline_version",
            "from_build": "sol_baseline_build",
            "to": "sol_target_version",
            "to_build": "sol_target_build",
            "journal": "journal_target_version",
            "journal_build": "journal_target_build",
        },
        pin_check_key="runtime_pin_matches",
        observes_runtime=True,
    ),
    "journal-upgrade.json": LaneSpec(
        lane="journal-upgrade",
        identity={
            # `to` here is the COMPANION sol riding along, not the sol being
            # published -- it gets its own explicit input.
            "to": "companion_sol_version",
            "to_build": "companion_sol_build",
            "journal": "journal_baseline_version",
            "journal_build": "journal_baseline_build",
            "journal_to": "journal_target_version",
            "journal_to_build": "journal_target_build",
        },
        pin_check_key="runtime_pin_matches",
        observes_runtime=True,
    ),
}

PROFILES = {
    "sol": (
        "drag.json",
        "sparkle.json",
        "fresh-journal-first.json",
        "fresh-sol-first.json",
        "sol-upgrade.json",
    ),
    "journal": (
        "drag.json",
        "fresh-journal-first.json",
        "fresh-sol-first.json",
        "journal-upgrade.json",
    ),
    "paired": REPORT_FILENAMES,
}


class GateFailure(Exception):
    """Any condition that must refuse the publish."""


def required_identity_keys(profile):
    """Exactly the identities the profile's member lanes actually assert."""
    keys = set()
    for filename in PROFILES[profile]:
        keys.update(LANE_SPECS[filename].identity.values())
    return sorted(keys)


def read_pin():
    try:
        raw = PIN_FILE.read_text()
    except OSError as exc:
        raise GateFailure(f"cannot read harness pin {PIN_FILE}: {exc}") from exc
    pin = raw.strip()
    if not SHA40_RE.match(pin):
        raise GateFailure(f"harness pin {PIN_FILE} is not a 40-hex sha: {pin!r}")
    return pin


def load_json_object(path, label):
    """Parse exactly one JSON object. Trailing data is a hard failure."""
    try:
        raw = path.read_text()
    except FileNotFoundError as exc:
        raise GateFailure(f"{label}: missing -- {path}") from exc
    except OSError as exc:
        raise GateFailure(f"{label}: unreadable -- {exc}") from exc

    decoder = json.JSONDecoder()
    try:
        value, end = decoder.raw_decode(raw.lstrip())
    except ValueError as exc:
        raise GateFailure(f"{label}: invalid JSON -- {exc}") from exc
    if raw.lstrip()[end:].strip():
        raise GateFailure(f"{label}: trailing data after the JSON object")
    if not isinstance(value, dict):
        raise GateFailure(f"{label}: expected a JSON object, got {type(value).__name__}")
    return value


def as_identity(value, label):
    """Scenario identities are non-empty scalars; anything else is a failure."""
    if isinstance(value, bool) or not isinstance(value, (str, int)):
        raise GateFailure(f"{label}: expected a version/build scalar, got {value!r}")
    text = str(value).strip()
    if not text:
        raise GateFailure(f"{label}: empty")
    return text


def verify_receipt(receipt_path, pin, expected_commit):
    """The sync receipt is what makes the harness revision evidence.

    ja1r-gate-sync reads the revision marker back off the rig after rsync and
    records what it actually found there, bound to the product HEAD it pushed.
    Typing the expected hash cannot forge this: the values must come from a
    real successful sync.
    """
    receipt = load_json_object(receipt_path, "sync receipt")

    revision = receipt.get("harness_revision")
    if not isinstance(revision, str) or not SHA40_RE.match(revision):
        raise GateFailure(
            f"sync receipt: harness_revision is not a 40-hex sha: {revision!r}"
        )
    if revision != pin:
        raise GateFailure(
            "sync receipt: harness revision on the rig does not match the pin "
            f"({revision} != {pin}) -- re-run `make ja1r-gate-sync`"
        )

    commit = receipt.get("product_commit")
    if not isinstance(commit, str) or not SHA40_RE.match(commit):
        raise GateFailure(
            f"sync receipt: product_commit is not a 40-hex sha: {commit!r}"
        )
    if commit != expected_commit:
        raise GateFailure(
            "sync receipt: the synced product commit is not the one being "
            f"published ({commit} != {expected_commit}) -- re-run "
            "`make ja1r-gate-sync`"
        )
    return receipt


def verify_provenance(report, filename, expected_commit):
    provenance = report.get("provenance")
    if not isinstance(provenance, dict):
        raise GateFailure(f"{filename}: provenance is missing or not an object")

    checkout = provenance.get("checkout_path")
    if not isinstance(checkout, str) or not checkout.strip():
        raise GateFailure(f"{filename}: provenance.checkout_path is missing or empty")

    commit = provenance.get("commit")
    if not isinstance(commit, str) or not SHA40_RE.match(commit):
        raise GateFailure(
            f"{filename}: provenance.commit is not a 40-hex sha: {commit!r}"
        )
    if commit != expected_commit:
        raise GateFailure(
            f"{filename}: provenance.commit {commit} is not the commit being "
            f"published ({expected_commit}) -- this evidence is from another build"
        )

    # `clean` is scoped to the two AX contracts. A dirty scope means the
    # contracts the lane asserted against were not the committed ones.
    if provenance.get("clean") is not True:
        raise GateFailure(
            f"{filename}: provenance.clean is {provenance.get('clean')!r}, not true "
            "-- the AX contract scope was dirty on the rig"
        )

    contracts = provenance.get("contracts")
    if not isinstance(contracts, dict):
        raise GateFailure(f"{filename}: provenance.contracts is missing or not an object")
    for key in ("sol_sha256", "journal_sha256"):
        digest = contracts.get(key)
        if not isinstance(digest, str) or not SHA256_RE.match(digest):
            raise GateFailure(
                f"{filename}: provenance.contracts.{key} is not a 64-hex sha256: {digest!r}"
            )


def verify_runtime_pin(report, filename, spec, expected_runtime):
    """Prove the journal runtime pin was actually enforced for this lane.

    Two independent assertions, because the harness leaves a hole: when
    --expect-solstone is absent, runtime_pin_check returns the *string*
    "SKIPPED (no --expect-solstone)" -- which is truthy -- and the lane omits
    the check from its `must` list, so the report can still say PASS. A
    truthiness test would sail straight past that. Hence `is True`.

    The observed-runtime substring check is the stronger one, but only the
    lanes that store the oracles fingerprint at top-level `post` can carry it.
    The fresh lane runs the oracles and checks the pin, but never writes that
    fingerprint into its report -- so for fresh, the strict check-key assertion
    below is the whole of the enforcement. We do not invent a path that the
    harness does not emit.
    """
    checks = report.get("checks")
    if not isinstance(checks, dict):
        raise GateFailure(f"{filename}: checks is missing or not an object")

    if spec.pin_check_key not in checks:
        raise GateFailure(
            f"{filename}: checks.{spec.pin_check_key} is absent -- cannot prove the "
            "journal runtime pin was enforced"
        )
    verdict = checks[spec.pin_check_key]
    if verdict is not True:
        raise GateFailure(
            f"{filename}: checks.{spec.pin_check_key} is {verdict!r}, not true -- the "
            "journal runtime pin was not enforced (a skipped pin reports a truthy "
            "string, not a pass)"
        )

    if not spec.observes_runtime:
        return

    post = report.get("post")
    if not isinstance(post, dict):
        raise GateFailure(
            f"{filename}: post is missing or not an object -- no observed journal "
            "runtime to check the pin against"
        )
    observed = post.get("journal_version")
    if not isinstance(observed, str) or not observed.strip():
        raise GateFailure(
            f"{filename}: post.journal_version is missing or empty -- no observed "
            "journal runtime to check the pin against"
        )
    if expected_runtime not in observed:
        raise GateFailure(
            f"{filename}: observed journal runtime {observed!r} does not carry the "
            f"expected pin {expected_runtime!r}"
        )


def verify_report(path, filename, spec, expected, expected_commit, expected_runtime):
    report = load_json_object(path, filename)

    if report.get("schema_version") != SCHEMA_VERSION:
        raise GateFailure(
            f"{filename}: schema_version is {report.get('schema_version')!r}, "
            f"expected {SCHEMA_VERSION}"
        )
    if report.get("result") != PASS_RESULT:
        raise GateFailure(
            f"{filename}: result is {report.get('result')!r}, expected {PASS_RESULT!r}"
        )
    if report.get("lane") != spec.lane:
        raise GateFailure(
            f"{filename}: lane is {report.get('lane')!r}, expected {spec.lane!r}"
        )
    if spec.order is not None and report.get("order") != spec.order:
        raise GateFailure(
            f"{filename}: order is {report.get('order')!r}, expected {spec.order!r} "
            "-- the two fresh reports must cover both install orders"
        )

    for field, identity_key in sorted(spec.identity.items()):
        if field not in report:
            raise GateFailure(f"{filename}: scenario field {field!r} is absent")
        actual = as_identity(report[field], f"{filename}: {field}")
        wanted = expected[identity_key]
        if actual != wanted:
            raise GateFailure(
                f"{filename}: {field} is {actual!r}, expected {wanted!r} "
                f"(from --{identity_key.replace('_', '-')})"
            )

    verify_provenance(report, filename, expected_commit)
    verify_runtime_pin(report, filename, spec, expected_runtime)


def build_parser():
    parser = argparse.ArgumentParser(
        description="Verify the ja1r linkage-gate evidence set for a release.",
    )
    parser.add_argument("--profile", required=True, choices=sorted(PROFILES))
    parser.add_argument("--report-dir", required=True, type=pathlib.Path)
    parser.add_argument("--sync-receipt", required=True, type=pathlib.Path)
    parser.add_argument("--product-commit", required=True)
    parser.add_argument("--expected-journal-runtime", required=True)
    for key in IDENTITY_KEYS:
        parser.add_argument(f"--{key.replace('_', '-')}", dest=key, default=None)
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)

    if not SHA40_RE.match(args.product_commit):
        print(
            f"error: --product-commit must be a full 40-hex sha, got "
            f"{args.product_commit!r}",
            file=sys.stderr,
        )
        return 2

    if not args.expected_journal_runtime.strip():
        print("error: --expected-journal-runtime must not be empty", file=sys.stderr)
        return 2

    needed = required_identity_keys(args.profile)
    missing = [key for key in needed if not (getattr(args, key) or "").strip()]
    if missing:
        print(
            f"error: profile {args.profile!r} requires these identities, which were "
            "not supplied:",
            file=sys.stderr,
        )
        for key in missing:
            print(f"  --{key.replace('_', '-')}", file=sys.stderr)
        return 2
    expected = {key: getattr(args, key).strip() for key in needed}

    try:
        pin = read_pin()
        verify_receipt(args.sync_receipt, pin, args.product_commit)
        for filename in PROFILES[args.profile]:
            verify_report(
                args.report_dir / filename,
                filename,
                LANE_SPECS[filename],
                expected,
                args.product_commit,
                args.expected_journal_runtime,
            )
    except GateFailure as failure:
        print(f"ja1r linkage gate: REFUSED -- {failure}", file=sys.stderr)
        return 1

    verdict = {
        "result": PASS_RESULT,
        "profile": args.profile,
        "product_commit": args.product_commit,
        "harness_revision": pin,
        "expected_journal_runtime": args.expected_journal_runtime,
        "reports_verified": list(PROFILES[args.profile]),
    }
    print(json.dumps(verdict, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
