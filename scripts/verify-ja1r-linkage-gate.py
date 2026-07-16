#!/usr/bin/env python3
"""
Verify the ja1r install/upgrade linkage-gate evidence set for a release.
Usage:
  verify-ja1r-linkage-gate.py --profile {sol,journal,paired} --report-dir DIR
      --sync-receipt PATH --product-commit SHA40 --expected-journal-runtime PIN
      [--expected-journal-baseline-runtime PIN]
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
scenario identity, provenance, the target journal-runtime pin, for
journal-upgrade the explicitly supplied baseline journal-runtime pin required by
the journal and paired profiles from LANE_SPECS, and, for the sol/paired
spl-link coordinator report, an independently recomputed Tier B synthetic-segment
identity that must land exactly once on a clean disposable-home baseline -- so
that a prior release's green JSON cannot authorize this one.

Exit 0 prints one JSON verdict on stdout. Every other path exits nonzero with
no stdout verdict.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import pathlib
import re
import sys


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
PIN_FILE = REPO_ROOT / "scripts" / "ja1r-gate" / "extro-tools.rev"

SCHEMA_VERSION = 1
PASS_RESULT = "PASS"

SHA40_RE = re.compile(r"^[0-9a-f]{40}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
RUN_ID_RE = re.compile(r"^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}$")
ISO_UTC_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")

SPL_LINK_REPORT_FILENAME = "spl-link.json"

# Schema-derived from extro-tools coordinator 122c5ba
# tools/solstone-macos-gate/spl_link_coordinator.py.
PAIR_LINK_TTL_S = 300.0
SPL_LINK_MAX_RUN_AGE_S = 24 * 60 * 60
SPL_LINK_FUTURE_SKEW_S = 5 * 60
TIER_B_NUMBER_MAX = 1_000_000_000
TIER_B_LANDING_BUDGET_S = 300.0
TIER_B_UPLOAD_STATE_RE = re.compile(r"^[a-z][a-z0-9_]{0,63}$")
COORDINATOR_REPORT_KEYS = frozenset(
    (
        "result",
        "run_id",
        "instance_id",
        "original_verdict",
        "phases",
        "lane",
        "tier_b",
        "binding",
        "pairing_timing",
        "cleanup",
        "error",
        "retry",
    )
)
COORDINATOR_PHASE_NAMES = (
    "create",
    "home_init",
    "enroll",
    "instance_read",
    "grant",
    "setup_verify",
    "home_baseline",
    "remote_prepare",
    "launch",
    "pid_wait",
    "ready_wait",
    "mint",
    "deliver",
    "exit_wait",
    "report_fetch_parse",
    "landing_verify",
)
COORDINATOR_PHASE_KEYS = frozenset(("status", "duration_s"))
COORDINATOR_BINDING_KEYS = frozenset(("complete", "invalid_fields"))
COORDINATOR_PAIRING_TIMING_KEYS = frozenset(
    (
        "ready_observed_at",
        "minted_at",
        "delivered_at",
        "mint_after_ready",
        "delivery_after_mint_s",
        "delivery_within_ttl",
    )
)
COORDINATOR_CLEANUP_STEPS = (
    "remote_lane",
    "synthetic_segment_remove",
    "relay_revoke",
    "private_link_disable",
    "sandbox_stop",
    "remote_run_dir_remove",
)
COORDINATOR_CLEANUP_ITEM_KEYS = frozenset(
    ("attempted", "required", "action_ok", "verified", "duration_s")
)
SPL_LINK_LANE_KEYS = frozenset(
    (
        "result",
        "lane",
        "schema_version",
        "to",
        "to_build",
        "checks",
        "oracles",
        "freshness",
        "identity_match",
        "dmg_sha256",
        "provenance",
        "error_type",
        "retry",
        "timings",
        "tier_b",
    )
)
SPL_LINK_CHECK_KEYS = (
    "initial_reset_clean",
    "pairing_precleaned",
    "pairing_preclean_idle",
    "pairing_preclean_disconnected",
    "final_reset_clean",
    "target_identity_matches",
    "local_discovery_not_found",
    "pairing_link_field_found",
    "pairing_initial_flow_idle",
    "pairing_initial_connection_disconnected",
    "ready_written",
    "link_received",
    "link_unlinked",
    "link_prefix_valid",
    "link_crockford_valid",
    "link_decoded_length_valid",
    "link_version_valid",
    "link_ca_tag_valid",
    "link_default_relay_valid",
    "pairing_link_set",
    "pairing_connect_dispatched",
    "pairing_flow_paired",
    "pairing_connection_connected",
    "pairing_mark_confirmed",
    "pairing_mark_cleared",
    "serverkey_trimmed_nonempty",
    "servicemode_external",
    "last_synced_fresh",
    "tier_b_segment_injected",
    "tier_b_probe_suppressed",
)
SPL_LINK_ORACLE_BOOLEAN_KEYS = (
    "serverkey_trimmed_nonempty",
    "servicemode_external",
    "last_synced_fresh",
)
SPL_LINK_ORACLE_KEYS = frozenset((*SPL_LINK_ORACLE_BOOLEAN_KEYS, "serverkey_sha256"))
SPL_LINK_FRESHNESS_KEYS = frozenset(
    (
        "last_synced_pre_raw",
        "last_synced_post_raw",
        "last_synced_pre_epoch",
        "last_synced_post_epoch",
        "baseline_kind",
        "ok",
    )
)
SPL_LINK_FRESHNESS_BASELINE_KINDS = frozenset(("observed", "absent_zero"))
SPL_LINK_PROVENANCE_KEYS = frozenset(("commit", "clean", "contracts"))
SPL_LINK_CONTRACT_KEYS = frozenset(("sol_sha256", "journal_sha256"))
SPL_LINK_TIMINGS_KEYS = frozenset(
    ("ready_at", "link_wait_started_at", "link_received_at", "link_wait_elapsed_s")
)
COORDINATOR_TIER_B_KEYS = frozenset(("expected", "baseline", "landing"))
COORDINATOR_TIER_B_EXPECTED_KEYS = frozenset(("day", "segment", "payload_sha256"))
COORDINATOR_TIER_B_BASELINE_KEYS = frozenset(
    ("segments_received", "duplicates_rejected", "identity_absent", "observed_at")
)
COORDINATOR_TIER_B_LANDING_KEYS = frozenset(
    (
        "attempted",
        "segments_received_before",
        "segments_received_after",
        "duplicates_rejected_before",
        "duplicates_rejected_after",
        "matching_artifacts",
        "digest_match",
        "canonical_path",
        "manifest_ok",
        "last_segment",
        "ingest_rejection_present",
        "reason",
        "observed_at",
        "elapsed_s",
    )
)
SPL_LINK_TIER_B_KEYS = frozenset(
    (
        "day",
        "segment",
        "payload_sha256",
        "payload_bytes",
        "created_at",
        "preexisting_completed_segments",
        "injected",
        "probe_not_created",
        "upload_state",
    )
)

# The canonical evidence-set filenames. README documents the producing command
# for each; scripts/tests/test_verify_ja1r_linkage_gate.py asserts the README
# list and this constant cannot drift apart.
REPORT_FILENAMES = (
    "drag.json",
    "sparkle.json",
    "fresh-journal-first.json",
    "fresh-sol-first.json",
    "fresh-acquire.json",
    "discovered-adopt.json",
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

    def __init__(
        self,
        lane,
        identity,
        pin_check_key,
        observes_runtime,
        order=None,
        baseline_pin=None,
    ):
        self.lane = lane
        self.identity = identity
        self.pin_check_key = pin_check_key
        self.observes_runtime = observes_runtime
        self.order = order
        self.baseline_pin = baseline_pin


class BaselinePinSpec:
    """Report keys that prove a linked journal-upgrade baseline runtime pin."""

    def __init__(self, report_key, linked_expected_key, check_key, fingerprint_key):
        self.report_key = report_key
        self.linked_expected_key = linked_expected_key
        self.check_key = check_key
        self.fingerprint_key = fingerprint_key


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
    # Both acquire-driven lanes mirror the fresh identity echo and, like fresh,
    # run the oracles + pin check without storing the fingerprint at top-level
    # `post` -- the strict check-key assertion is the whole of the pin proof.
    "fresh-acquire.json": LaneSpec(
        lane="fresh-acquire",
        identity=_FRESH_IDENTITY,
        pin_check_key="solstone_pin_matches",
        observes_runtime=False,
    ),
    "discovered-adopt.json": LaneSpec(
        lane="discovered-adopt",
        identity=_FRESH_IDENTITY,
        pin_check_key="solstone_pin_matches",
        observes_runtime=False,
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
        baseline_pin=BaselinePinSpec(
            report_key="expect_solstone_baseline",
            linked_expected_key="expected_runtime_version",
            check_key="baseline_solstone_pin_matches",
            fingerprint_key="journal_version",
        ),
    ),
}

PROFILES = {
    "sol": (
        "drag.json",
        "sparkle.json",
        "fresh-journal-first.json",
        "fresh-sol-first.json",
        "fresh-acquire.json",
        "discovered-adopt.json",
        "sol-upgrade.json",
        SPL_LINK_REPORT_FILENAME,
    ),
    "journal": (
        "drag.json",
        "fresh-journal-first.json",
        "fresh-sol-first.json",
        "fresh-acquire.json",
        "discovered-adopt.json",
        "journal-upgrade.json",
    ),
    "paired": REPORT_FILENAMES + (SPL_LINK_REPORT_FILENAME,),
}


class GateFailure(Exception):
    """Any condition that must refuse the publish."""


def required_identity_keys(profile):
    """Exactly the identities the profile's member lanes actually assert."""
    keys = set()
    for filename in PROFILES[profile]:
        if filename == SPL_LINK_REPORT_FILENAME:
            continue
        keys.update(LANE_SPECS[filename].identity.values())
    return sorted(keys)


def requires_baseline_runtime(profile):
    """Whether any lane in this profile asserts a baseline journal runtime pin."""
    return any(
        LANE_SPECS[filename].baseline_pin is not None
        for filename in PROFILES[profile]
        if filename != SPL_LINK_REPORT_FILENAME
    )


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


def _sorted_keys(keys):
    return ", ".join(sorted(str(key) for key in keys)) or "(none)"


def require_exact_keys(value, expected_keys, label):
    if not isinstance(value, dict):
        raise GateFailure(f"{label}: expected an object, got {type(value).__name__}")
    actual = set(value)
    expected = set(expected_keys)
    if actual != expected:
        missing = expected - actual
        extra = actual - expected
        raise GateFailure(
            f"{label}: key set mismatch "
            f"(missing: {_sorted_keys(missing)}; extra: {_sorted_keys(extra)})"
        )


def require_true(value, label):
    if value is not True:
        raise GateFailure(f"{label}: expected true, got {value!r}")


def require_false(value, label):
    if value is not False:
        raise GateFailure(f"{label}: expected false, got {value!r}")


def require_none(value, label):
    if value is not None:
        raise GateFailure(f"{label}: expected null, got {value!r}")


def require_sha40(value, label):
    if not isinstance(value, str) or not SHA40_RE.match(value):
        raise GateFailure(f"{label}: expected a lowercase 40-hex sha, got {value!r}")
    return value


def require_sha256(value, label):
    if not isinstance(value, str) or not SHA256_RE.match(value):
        raise GateFailure(f"{label}: expected a lowercase 64-hex sha256, got {value!r}")
    return value


def require_nonnegative_finite_number(value, label):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise GateFailure(f"{label}: expected a nonnegative finite number, got {value!r}")
    if not math.isfinite(value) or value < 0:
        raise GateFailure(f"{label}: expected a nonnegative finite number, got {value!r}")
    return value


def require_bounded_integer(value, label, *, minimum=0, maximum=TIER_B_NUMBER_MAX):
    if isinstance(value, bool) or not isinstance(value, int):
        raise GateFailure(
            f"{label}: expected an integer between {minimum} and {maximum}, got {value!r}"
        )
    if value < minimum or value > maximum:
        raise GateFailure(
            f"{label}: expected an integer between {minimum} and {maximum}, got {value!r}"
        )
    return value


def require_iso_utc(value, label):
    if not isinstance(value, str) or not ISO_UTC_RE.match(value):
        raise GateFailure(f"{label}: expected ISO UTC timestamp, got {value!r}")
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def require_schema_version(value, label):
    if type(value) is not int or value != SCHEMA_VERSION:
        raise GateFailure(f"{label}: schema_version is {value!r}, expected {SCHEMA_VERSION}")


def require_bounded_nonempty_string(value, label, *, max_length=256, no_whitespace=False):
    if (
        not isinstance(value, str)
        or not value.strip()
        or len(value) > max_length
        or any(ord(character) < 32 for character in value)
        or (no_whitespace and any(character.isspace() for character in value))
    ):
        raise GateFailure(f"{label}: expected a bounded non-empty string, got {value!r}")
    return value


def require_raw_epoch(value, label):
    if value is None:
        return None
    if isinstance(value, str) and len(value) <= 20 and value.isdigit():
        return value
    raise GateFailure(f"{label}: expected null or an epoch digit string, got {value!r}")


def hash_file_sha256(path, label):
    if path is None:
        raise GateFailure(f"{label}: required for this profile")
    path = pathlib.Path(path)
    if not path.is_file():
        raise GateFailure(f"{label}: missing or not a file -- {path}")
    digest = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            while True:
                chunk = handle.read(1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
    except OSError as exc:
        raise GateFailure(f"{label}: unreadable -- {exc}") from exc
    return digest.hexdigest()


def parse_run_timestamp(run_id):
    if not isinstance(run_id, str) or RUN_ID_RE.match(run_id) is None:
        raise GateFailure(f"spl-link.json: run_id is invalid: {run_id!r}")
    try:
        return datetime.strptime(
            run_id.split("-", 1)[0], "%Y%m%dT%H%M%SZ"
        ).replace(tzinfo=timezone.utc)
    except ValueError:
        raise GateFailure(f"spl-link.json: run_id is invalid: {run_id!r}") from None


def derive_tier_b_identity(run_id):
    parse_run_timestamp(run_id)
    day = run_id[:8]
    hhmmss = run_id[9:15]
    suffix = run_id.split("-", 1)[1]
    length = 1 + (int(suffix, 16) % 9999)
    segment = f"{hhmmss}_{length}"
    payload = (
        f"solstone-gate tier-b synthetic capture payload run={run_id}\n".encode("ascii")
    )
    return {
        "day": day,
        "segment": segment,
        "payload_sha256": hashlib.sha256(payload).hexdigest(),
        "payload_bytes": len(payload),
    }


def verify_run_wall_clock_freshness(run_id, now):
    if now.tzinfo is None or now.utcoffset() is None:
        raise GateFailure("spl-link.json: verifier clock must be timezone-aware UTC")
    run_timestamp = parse_run_timestamp(run_id)
    age_s = (now.astimezone(timezone.utc) - run_timestamp).total_seconds()
    if age_s > SPL_LINK_MAX_RUN_AGE_S:
        raise GateFailure("spl-link.json: run is older than 24 hours")
    if age_s < -SPL_LINK_FUTURE_SKEW_S:
        raise GateFailure("spl-link.json: run timestamp is more than 5 minutes in the future")


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


def _require_string(container, key, filename, dotted_key, flag):
    if not isinstance(container, dict) or key not in container:
        raise GateFailure(
            f"{filename}: {dotted_key} is missing -- cannot prove the baseline "
            f"journal runtime pin from {flag}"
        )
    value = container[key]
    if not isinstance(value, str) or not value.strip():
        raise GateFailure(
            f"{filename}: {dotted_key} is missing, empty, or not a string -- cannot "
            f"prove the baseline journal runtime pin from {flag}"
        )
    return value


def verify_baseline_runtime_pin(report, filename, spec, expected_baseline_runtime):
    """Prove journal-upgrade asserted the baseline runtime pin before upgrading."""
    pin = spec.baseline_pin
    if pin is None:
        return

    flag = "--expected-journal-baseline-runtime"
    if (
        not isinstance(expected_baseline_runtime, str)
        or not expected_baseline_runtime.strip()
    ):
        raise GateFailure(
            f"{filename}: {flag} is required -- cannot prove the baseline "
            "journal runtime pin"
        )

    actual_report_pin = _require_string(
        report, pin.report_key, filename, pin.report_key, flag
    )
    if actual_report_pin != expected_baseline_runtime:
        raise GateFailure(
            f"{filename}: {pin.report_key} is {actual_report_pin!r}, expected "
            f"{expected_baseline_runtime!r} from {flag} -- cannot prove the "
            "baseline journal runtime pin"
        )

    linked = report.get("linked_baseline")
    if not isinstance(linked, dict):
        raise GateFailure(
            f"{filename}: linked_baseline is missing or not an object -- cannot prove "
            f"the baseline journal runtime pin from {flag}"
        )

    linked_key = f"linked_baseline.{pin.linked_expected_key}"
    actual_linked_pin = _require_string(
        linked, pin.linked_expected_key, filename, linked_key, flag
    )
    if actual_linked_pin != expected_baseline_runtime:
        raise GateFailure(
            f"{filename}: {linked_key} is {actual_linked_pin!r}, expected "
            f"{expected_baseline_runtime!r} from {flag} -- cannot prove the "
            "baseline journal runtime pin"
        )

    checks = report.get("checks")
    if not isinstance(checks, dict):
        raise GateFailure(
            f"{filename}: checks is missing or not an object -- cannot prove the "
            f"baseline journal runtime pin from {flag}"
        )
    check_key = f"checks.{pin.check_key}"
    if pin.check_key not in checks:
        raise GateFailure(
            f"{filename}: {check_key} is absent -- cannot prove the baseline "
            f"journal runtime pin from {flag}"
        )
    verdict = checks[pin.check_key]
    if verdict is not True:
        raise GateFailure(
            f"{filename}: {check_key} is {verdict!r}, not true -- the baseline "
            f"journal runtime pin was not enforced from {flag}"
        )

    fingerprint = linked.get("journal_fingerprint")
    if not isinstance(fingerprint, dict):
        raise GateFailure(
            f"{filename}: linked_baseline.journal_fingerprint is missing or not an "
            f"object -- cannot prove the baseline journal runtime pin from {flag}"
        )
    observed_key = f"linked_baseline.journal_fingerprint.{pin.fingerprint_key}"
    observed = _require_string(
        fingerprint, pin.fingerprint_key, filename, observed_key, flag
    )
    if expected_baseline_runtime not in observed:
        raise GateFailure(
            f"{filename}: observed baseline journal runtime {observed!r} does not "
            f"carry the expected baseline pin {expected_baseline_runtime!r} from "
            f"{flag}"
        )


def verify_coordinator_phases(phases, filename):
    require_exact_keys(phases, COORDINATOR_PHASE_NAMES, f"{filename}: phases")
    for name in COORDINATOR_PHASE_NAMES:
        phase = phases[name]
        label = f"{filename}: phases.{name}"
        require_exact_keys(phase, COORDINATOR_PHASE_KEYS, label)
        if phase["status"] != "ok":
            raise GateFailure(f"{label}.status is {phase['status']!r}, expected 'ok'")
        require_nonnegative_finite_number(phase["duration_s"], f"{label}.duration_s")


def verify_coordinator_binding(binding, filename):
    require_exact_keys(binding, COORDINATOR_BINDING_KEYS, f"{filename}: binding")
    require_true(binding["complete"], f"{filename}: binding.complete")
    if binding["invalid_fields"] != []:
        raise GateFailure(
            f"{filename}: binding.invalid_fields is {binding['invalid_fields']!r}, expected []"
        )


def verify_coordinator_pairing_timing(timing, filename):
    require_exact_keys(
        timing, COORDINATOR_PAIRING_TIMING_KEYS, f"{filename}: pairing_timing"
    )
    ready = require_iso_utc(
        timing["ready_observed_at"], f"{filename}: pairing_timing.ready_observed_at"
    )
    minted = require_iso_utc(timing["minted_at"], f"{filename}: pairing_timing.minted_at")
    delivered = require_iso_utc(
        timing["delivered_at"], f"{filename}: pairing_timing.delivered_at"
    )
    if not (ready <= minted <= delivered):
        raise GateFailure(f"{filename}: pairing_timing timestamps are out of order")
    require_true(timing["mint_after_ready"], f"{filename}: pairing_timing.mint_after_ready")
    require_true(
        timing["delivery_within_ttl"],
        f"{filename}: pairing_timing.delivery_within_ttl",
    )
    elapsed = require_nonnegative_finite_number(
        timing["delivery_after_mint_s"],
        f"{filename}: pairing_timing.delivery_after_mint_s",
    )
    if elapsed > PAIR_LINK_TTL_S:
        raise GateFailure(f"{filename}: pairing_timing.delivery_after_mint_s exceeds TTL")
    observed = (delivered - minted).total_seconds()
    if abs(elapsed - observed) > 1.0:
        raise GateFailure(
            f"{filename}: pairing_timing.delivery_after_mint_s disagrees with timestamps"
        )


def verify_coordinator_cleanup(cleanup, filename):
    require_exact_keys(cleanup, COORDINATOR_CLEANUP_STEPS, f"{filename}: cleanup")
    for name in COORDINATOR_CLEANUP_STEPS:
        item = cleanup[name]
        label = f"{filename}: cleanup.{name}"
        require_exact_keys(item, COORDINATOR_CLEANUP_ITEM_KEYS, label)
        require_true(item["attempted"], f"{label}.attempted")
        require_true(item["required"], f"{label}.required")
        require_true(item["action_ok"], f"{label}.action_ok")
        require_true(item["verified"], f"{label}.verified")
        require_nonnegative_finite_number(item["duration_s"], f"{label}.duration_s")


def verify_coordinator_tier_b(tier_b, filename, tier_b_identity, landing_verify_duration_s):
    label = f"{filename}: tier_b"
    require_exact_keys(tier_b, COORDINATOR_TIER_B_KEYS, label)

    expected = tier_b["expected"]
    expected_label = f"{label}.expected"
    require_exact_keys(expected, COORDINATOR_TIER_B_EXPECTED_KEYS, expected_label)
    for key in COORDINATOR_TIER_B_EXPECTED_KEYS:
        if expected[key] != tier_b_identity[key]:
            raise GateFailure(
                f"{expected_label}.{key} is {expected[key]!r}, "
                f"expected {tier_b_identity[key]!r}"
            )

    baseline = tier_b["baseline"]
    baseline_label = f"{label}.baseline"
    require_exact_keys(baseline, COORDINATOR_TIER_B_BASELINE_KEYS, baseline_label)
    baseline_segments = require_bounded_integer(
        baseline["segments_received"], f"{baseline_label}.segments_received"
    )
    if baseline_segments != 0:
        raise GateFailure(
            f"{baseline_label}.segments_received is {baseline_segments!r}, expected 0"
        )
    baseline_duplicates = require_bounded_integer(
        baseline["duplicates_rejected"], f"{baseline_label}.duplicates_rejected"
    )
    if baseline_duplicates != 0:
        raise GateFailure(
            f"{baseline_label}.duplicates_rejected is {baseline_duplicates!r}, expected 0"
        )
    require_true(baseline["identity_absent"], f"{baseline_label}.identity_absent")
    baseline_observed = require_iso_utc(
        baseline["observed_at"], f"{baseline_label}.observed_at"
    )

    landing = tier_b["landing"]
    landing_label = f"{label}.landing"
    require_exact_keys(landing, COORDINATOR_TIER_B_LANDING_KEYS, landing_label)
    for key in ("attempted", "digest_match", "canonical_path", "manifest_ok"):
        require_true(landing[key], f"{landing_label}.{key}")
    require_false(
        landing["ingest_rejection_present"],
        f"{landing_label}.ingest_rejection_present",
    )
    require_none(landing["reason"], f"{landing_label}.reason")

    segments_before = require_bounded_integer(
        landing["segments_received_before"],
        f"{landing_label}.segments_received_before",
    )
    if segments_before != baseline_segments:
        raise GateFailure(
            f"{landing_label}.segments_received_before is {segments_before!r}, "
            f"expected {baseline_segments!r}"
        )
    duplicates_before = require_bounded_integer(
        landing["duplicates_rejected_before"],
        f"{landing_label}.duplicates_rejected_before",
    )
    if duplicates_before != baseline_duplicates:
        raise GateFailure(
            f"{landing_label}.duplicates_rejected_before is {duplicates_before!r}, "
            f"expected {baseline_duplicates!r}"
        )

    segments_after = require_bounded_integer(
        landing["segments_received_after"],
        f"{landing_label}.segments_received_after",
    )
    if segments_after <= segments_before:
        raise GateFailure(f"{landing_label}.segments_received_after did not advance")
    duplicates_after = require_bounded_integer(
        landing["duplicates_rejected_after"],
        f"{landing_label}.duplicates_rejected_after",
    )
    if duplicates_after < duplicates_before:
        raise GateFailure(f"{landing_label}.duplicates_rejected_after regressed")

    matching_artifacts = require_bounded_integer(
        landing["matching_artifacts"], f"{landing_label}.matching_artifacts"
    )
    if matching_artifacts != 1:
        raise GateFailure(
            f"{landing_label}.matching_artifacts is {matching_artifacts!r}, expected 1"
        )
    if landing["last_segment"] != tier_b_identity["segment"]:
        raise GateFailure(
            f"{landing_label}.last_segment is {landing['last_segment']!r}, "
            f"expected {tier_b_identity['segment']!r}"
        )

    landing_observed = require_iso_utc(
        landing["observed_at"], f"{landing_label}.observed_at"
    )
    if landing_observed < baseline_observed:
        raise GateFailure(f"{landing_label}.observed_at is before baseline observed_at")

    elapsed = require_nonnegative_finite_number(
        landing["elapsed_s"], f"{landing_label}.elapsed_s"
    )
    if elapsed > TIER_B_LANDING_BUDGET_S + 1.0:
        raise GateFailure(f"{landing_label}.elapsed_s exceeds Tier B landing budget")
    phase_elapsed = require_nonnegative_finite_number(
        landing_verify_duration_s, f"{filename}: phases.landing_verify.duration_s"
    )
    if phase_elapsed > TIER_B_LANDING_BUDGET_S + 1.0:
        raise GateFailure(
            f"{filename}: phases.landing_verify.duration_s exceeds Tier B landing budget"
        )
    if abs(elapsed - phase_elapsed) > 1.0:
        raise GateFailure(
            f"{landing_label}.elapsed_s disagrees with phases.landing_verify.duration_s"
        )


def verify_spl_link_tier_b(tier_b, filename, tier_b_identity):
    label = f"{filename}: lane.tier_b"
    require_exact_keys(tier_b, SPL_LINK_TIER_B_KEYS, label)
    for key in ("day", "segment", "payload_sha256"):
        if tier_b[key] != tier_b_identity[key]:
            raise GateFailure(
                f"{label}.{key} is {tier_b[key]!r}, expected {tier_b_identity[key]!r}"
            )
    payload_bytes = require_bounded_integer(
        tier_b["payload_bytes"], f"{label}.payload_bytes"
    )
    if payload_bytes != tier_b_identity["payload_bytes"]:
        raise GateFailure(
            f"{label}.payload_bytes is {payload_bytes!r}, "
            f"expected {tier_b_identity['payload_bytes']!r}"
        )
    require_iso_utc(tier_b["created_at"], f"{label}.created_at")
    require_bounded_integer(
        tier_b["preexisting_completed_segments"],
        f"{label}.preexisting_completed_segments",
    )
    require_true(tier_b["injected"], f"{label}.injected")
    require_true(tier_b["probe_not_created"], f"{label}.probe_not_created")
    upload_state = tier_b["upload_state"]
    if upload_state is not None and (
        not isinstance(upload_state, str)
        or TIER_B_UPLOAD_STATE_RE.match(upload_state) is None
    ):
        raise GateFailure(
            f"{label}.upload_state: expected null or bounded lowercase token, "
            f"got {upload_state!r}"
        )


def verify_spl_link_checks(checks, filename):
    require_exact_keys(checks, SPL_LINK_CHECK_KEYS, f"{filename}: lane.checks")
    for key in SPL_LINK_CHECK_KEYS:
        require_true(checks[key], f"{filename}: lane.checks.{key}")


def verify_spl_link_oracles(oracles, filename):
    require_exact_keys(oracles, SPL_LINK_ORACLE_KEYS, f"{filename}: lane.oracles")
    for key in SPL_LINK_ORACLE_BOOLEAN_KEYS:
        require_true(oracles[key], f"{filename}: lane.oracles.{key}")
    require_sha256(oracles["serverkey_sha256"], f"{filename}: lane.oracles.serverkey_sha256")


def verify_spl_link_freshness(freshness, filename):
    require_exact_keys(freshness, SPL_LINK_FRESHNESS_KEYS, f"{filename}: lane.freshness")
    require_raw_epoch(freshness["last_synced_pre_raw"], f"{filename}: lane.freshness.last_synced_pre_raw")
    require_raw_epoch(
        freshness["last_synced_post_raw"],
        f"{filename}: lane.freshness.last_synced_post_raw",
    )
    pre = require_nonnegative_finite_number(
        freshness["last_synced_pre_epoch"],
        f"{filename}: lane.freshness.last_synced_pre_epoch",
    )
    post = require_nonnegative_finite_number(
        freshness["last_synced_post_epoch"],
        f"{filename}: lane.freshness.last_synced_post_epoch",
    )
    if freshness["baseline_kind"] not in SPL_LINK_FRESHNESS_BASELINE_KINDS:
        raise GateFailure(
            f"{filename}: lane.freshness.baseline_kind is {freshness['baseline_kind']!r}"
        )
    require_true(freshness["ok"], f"{filename}: lane.freshness.ok")
    if post <= pre:
        raise GateFailure(f"{filename}: lane.freshness lastSynced did not strictly advance")


def verify_spl_link_provenance(provenance, filename, expected_commit):
    require_exact_keys(provenance, SPL_LINK_PROVENANCE_KEYS, f"{filename}: lane.provenance")
    commit = require_sha40(provenance["commit"], f"{filename}: lane.provenance.commit")
    if commit != expected_commit:
        raise GateFailure(
            f"{filename}: lane.provenance.commit {commit} is not the commit being "
            f"published ({expected_commit})"
        )
    require_true(provenance["clean"], f"{filename}: lane.provenance.clean")
    contracts = provenance["contracts"]
    require_exact_keys(
        contracts, SPL_LINK_CONTRACT_KEYS, f"{filename}: lane.provenance.contracts"
    )
    for key in ("sol_sha256", "journal_sha256"):
        require_sha256(
            contracts[key], f"{filename}: lane.provenance.contracts.{key}"
        )


def verify_spl_link_timings(timings, filename):
    require_exact_keys(timings, SPL_LINK_TIMINGS_KEYS, f"{filename}: lane.timings")
    started = require_iso_utc(
        timings["link_wait_started_at"], f"{filename}: lane.timings.link_wait_started_at"
    )
    ready = require_iso_utc(timings["ready_at"], f"{filename}: lane.timings.ready_at")
    received = require_iso_utc(
        timings["link_received_at"], f"{filename}: lane.timings.link_received_at"
    )
    if not (ready <= started <= received):
        raise GateFailure(f"{filename}: lane.timings timestamps are out of order")
    elapsed = require_nonnegative_finite_number(
        timings["link_wait_elapsed_s"],
        f"{filename}: lane.timings.link_wait_elapsed_s",
    )
    if elapsed > PAIR_LINK_TTL_S:
        raise GateFailure(f"{filename}: lane.timings.link_wait_elapsed_s exceeds TTL")


def verify_spl_link_lane(
    lane,
    filename,
    expected_version,
    expected_build,
    expected_commit,
    sol_dmg_sha256,
    tier_b_identity,
):
    require_exact_keys(lane, SPL_LINK_LANE_KEYS, f"{filename}: lane")
    if lane["result"] != PASS_RESULT:
        raise GateFailure(f"{filename}: lane.result is {lane['result']!r}, expected 'PASS'")
    if lane["lane"] != "spl-link":
        raise GateFailure(f"{filename}: lane.lane is {lane['lane']!r}, expected 'spl-link'")
    require_schema_version(lane["schema_version"], f"{filename}: lane")
    if lane["to"] != expected_version:
        raise GateFailure(
            f"{filename}: lane.to is {lane['to']!r}, expected {expected_version!r}"
        )
    if lane["to_build"] != expected_build:
        raise GateFailure(
            f"{filename}: lane.to_build is {lane['to_build']!r}, expected {expected_build!r}"
        )
    verify_spl_link_checks(lane["checks"], filename)
    verify_spl_link_oracles(lane["oracles"], filename)
    verify_spl_link_freshness(lane["freshness"], filename)
    require_true(lane["identity_match"], f"{filename}: lane.identity_match")
    dmg_sha256 = require_sha256(lane["dmg_sha256"], f"{filename}: lane.dmg_sha256")
    if dmg_sha256 != sol_dmg_sha256:
        raise GateFailure(f"{filename}: lane.dmg_sha256 does not match --sol-dmg")
    verify_spl_link_provenance(lane["provenance"], filename, expected_commit)
    require_none(lane["error_type"], f"{filename}: lane.error_type")
    require_none(lane["retry"], f"{filename}: lane.retry")
    verify_spl_link_timings(lane["timings"], filename)
    verify_spl_link_tier_b(lane["tier_b"], filename, tier_b_identity)


def verify_coordinator_report(
    path,
    filename,
    expected_version,
    expected_build,
    expected_commit,
    sol_dmg_sha256,
    now,
):
    report = load_json_object(path, filename)
    require_exact_keys(report, COORDINATOR_REPORT_KEYS, filename)
    if report["result"] != PASS_RESULT:
        raise GateFailure(f"{filename}: result is {report['result']!r}, expected 'PASS'")
    if report["original_verdict"] != PASS_RESULT:
        raise GateFailure(
            f"{filename}: original_verdict is {report['original_verdict']!r}, expected 'PASS'"
        )
    require_none(report["error"], f"{filename}: error")
    require_none(report["retry"], f"{filename}: retry")
    verify_run_wall_clock_freshness(report["run_id"], now)
    require_bounded_nonempty_string(
        report["instance_id"], f"{filename}: instance_id", no_whitespace=True
    )
    verify_coordinator_phases(report["phases"], filename)
    tier_b_identity = derive_tier_b_identity(report["run_id"])
    landing_verify_duration_s = report["phases"]["landing_verify"]["duration_s"]
    verify_coordinator_tier_b(
        report["tier_b"], filename, tier_b_identity, landing_verify_duration_s
    )
    verify_coordinator_binding(report["binding"], filename)
    verify_coordinator_pairing_timing(report["pairing_timing"], filename)
    verify_coordinator_cleanup(report["cleanup"], filename)
    verify_spl_link_lane(
        report["lane"],
        filename,
        expected_version,
        expected_build,
        expected_commit,
        sol_dmg_sha256,
        tier_b_identity,
    )


def verify_report(
    path,
    filename,
    spec,
    expected,
    expected_commit,
    expected_runtime,
    expected_baseline_runtime,
):
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
    verify_baseline_runtime_pin(report, filename, spec, expected_baseline_runtime)


def build_parser():
    parser = argparse.ArgumentParser(
        description="Verify the ja1r linkage-gate evidence set for a release.",
    )
    parser.add_argument("--profile", required=True, choices=sorted(PROFILES))
    parser.add_argument("--report-dir", required=True, type=pathlib.Path)
    parser.add_argument("--sync-receipt", required=True, type=pathlib.Path)
    parser.add_argument("--product-commit", required=True)
    parser.add_argument("--expected-journal-runtime", required=True)
    parser.add_argument("--expected-journal-baseline-runtime", default=None)
    parser.add_argument("--sol-dmg", default=None, type=pathlib.Path)
    for key in IDENTITY_KEYS:
        parser.add_argument(f"--{key.replace('_', '-')}", dest=key, default=None)
    return parser


def main(argv=None, *, now=None):
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

    needs_baseline_runtime = requires_baseline_runtime(args.profile)
    if needs_baseline_runtime and not (
        args.expected_journal_baseline_runtime or ""
    ).strip():
        print(
            f"error: profile {args.profile!r} requires --expected-journal-baseline-runtime",
            file=sys.stderr,
        )
        return 2

    profile_requires_spl_link = SPL_LINK_REPORT_FILENAME in PROFILES[args.profile]
    verification_now = now or datetime.now(timezone.utc)

    try:
        sol_dmg_sha256 = None
        if profile_requires_spl_link:
            sol_dmg_sha256 = hash_file_sha256(args.sol_dmg, "--sol-dmg")
        elif args.sol_dmg is not None:
            raise GateFailure(
                f"profile {args.profile!r} does not include {SPL_LINK_REPORT_FILENAME} "
                "and must not supply --sol-dmg"
            )

        pin = read_pin()
        verify_receipt(args.sync_receipt, pin, args.product_commit)
        for filename in PROFILES[args.profile]:
            if filename == SPL_LINK_REPORT_FILENAME:
                verify_coordinator_report(
                    args.report_dir / filename,
                    filename,
                    expected["sol_target_version"],
                    expected["sol_target_build"],
                    args.product_commit,
                    sol_dmg_sha256,
                    verification_now,
                )
            else:
                verify_report(
                    args.report_dir / filename,
                    filename,
                    LANE_SPECS[filename],
                    expected,
                    args.product_commit,
                    args.expected_journal_runtime,
                    (
                        args.expected_journal_baseline_runtime
                        if needs_baseline_runtime
                        else None
                    ),
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
    if needs_baseline_runtime:
        verdict["expected_journal_baseline_runtime"] = args.expected_journal_baseline_runtime
    print(json.dumps(verdict, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
