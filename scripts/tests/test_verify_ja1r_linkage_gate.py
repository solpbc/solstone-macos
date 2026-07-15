"""Tests for the ja1r linkage-gate evidence verifier.

FIXTURE HONESTY: the reports built here are SCHEMA-DERIVED, not captured. No
real PASS report exists in the harness repo or anywhere on disk, so these are
constructed from the pinned harness's own report emitters -- extro-tools
8c09723c, tools/solstone-macos-gate/gate.py: new_report() (direct-lane shape,
schema_version, lane, result), the per-lane scenario fields it sets, the
provenance block it fills, oracles() -> rep["post"] (the observed
journal_version), _run_linked_upgrade_lane() / establish_linked_baseline()
(linked_baseline.expected_runtime_version,
linked_baseline.journal_fingerprint.journal_version), and runtime_pin_check()
(the pin check keys, including checks.baseline_solstone_pin_matches), plus
tools/solstone-macos-gate/spl_link_coordinator.py
(coordinator envelope and sanitized spl-link lane subset). They are not dressed
up as recordings of a real run.
"""
from __future__ import annotations

import contextlib
from datetime import datetime, timedelta, timezone
import importlib.util
import io
import json
import math
import pathlib
import subprocess
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPTS = REPO_ROOT / "scripts"
MAKEFILE = REPO_ROOT / "Makefile"

# The verifier's filename is not a valid module name, so load it by path.
_spec = importlib.util.spec_from_file_location(
    "verify_ja1r_linkage_gate", SCRIPTS / "verify-ja1r-linkage-gate.py"
)
verifier = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(verifier)


PIN = (SCRIPTS / "ja1r-gate" / "extro-tools.rev").read_text().strip()
COMMIT = "a" * 40
OTHER_COMMIT = "b" * 40
BASELINE_RUNTIME_PIN = "0.8.2"
RUNTIME_PIN = "0.8.3"
OBSERVED_BASELINE_RUNTIME = "journal 0.8.2 (build 42)"
OBSERVED_RUNTIME = "journal 0.8.3 (build 43)"

SOL_V, SOL_B = "1.4.5", "56"
JOURNAL_V, JOURNAL_B = "1.0.4", "5"
SOL_BASE_V, SOL_BASE_B = "1.4.4", "55"
JOURNAL_BASE_V, JOURNAL_BASE_B = "1.0.3", "4"
COMPANION_SOL_V, COMPANION_SOL_B = "1.4.5", "56"
LEGACY_SOL_V = "1.3.31"
RUN_ID = "20260715T184501Z-a1b2c3d4e5f60718"
FIXED_NOW = datetime(2026, 7, 15, 18, 50, 0, tzinfo=timezone.utc)
DEFAULT_SOL_DMG_SHA = "e" * 64

IDENTITY_ARGS = {
    "sol-target-version": SOL_V,
    "sol-target-build": SOL_B,
    "journal-target-version": JOURNAL_V,
    "journal-target-build": JOURNAL_B,
    "sol-baseline-version": SOL_BASE_V,
    "sol-baseline-build": SOL_BASE_B,
    "journal-baseline-version": JOURNAL_BASE_V,
    "journal-baseline-build": JOURNAL_BASE_B,
    "companion-sol-version": COMPANION_SOL_V,
    "companion-sol-build": COMPANION_SOL_B,
    "legacy-sol-baseline-version": LEGACY_SOL_V,
}


def provenance():
    return {
        "checkout_path": "/Users/ja1r/projects/solstone-macos",
        "commit": COMMIT,
        "clean": True,
        "contracts": {"sol_sha256": "c" * 64, "journal_sha256": "d" * 64},
    }


def spl_link_provenance():
    return {
        "commit": COMMIT,
        "clean": True,
        "contracts": {"sol_sha256": "c" * 64, "journal_sha256": "d" * 64},
    }


def base_report(lane, checks, **scenario):
    report = {
        "schema_version": 1,
        "lane": lane,
        "result": "PASS",
        "provenance": provenance(),
        "checks": checks,
        "evidence": {"inputs": {}, "observations": {}, "actions": []},
    }
    report.update(scenario)
    return report


def phase_report():
    return {
        name: {"status": "ok", "duration_s": 0.001}
        for name in verifier.COORDINATOR_PHASE_NAMES
    }


def cleanup_report():
    return {
        name: {
            "attempted": True,
            "required": True,
            "action_ok": True,
            "verified": True,
            "duration_s": 0.001,
        }
        for name in verifier.COORDINATOR_CLEANUP_STEPS
    }


def spl_link_lane_subset(sol_dmg_sha256=DEFAULT_SOL_DMG_SHA):
    return {
        "result": "PASS",
        "lane": "spl-link",
        "schema_version": 1,
        "to": SOL_V,
        "to_build": SOL_B,
        "checks": {key: True for key in verifier.SPL_LINK_CHECK_KEYS},
        "oracles": {
            "serverkey_trimmed_nonempty": True,
            "servicemode_external": True,
            "last_synced_fresh": True,
            "serverkey_sha256": "f" * 64,
        },
        "freshness": {
            "last_synced_pre_raw": None,
            "last_synced_post_raw": "1",
            "last_synced_pre_epoch": 0,
            "last_synced_post_epoch": 1,
            "baseline_kind": "absent_zero",
            "ok": True,
        },
        "identity_match": True,
        "dmg_sha256": sol_dmg_sha256,
        "provenance": spl_link_provenance(),
        "error_type": None,
        "retry": None,
        "timings": {
            "ready_at": "2026-07-15T18:45:01Z",
            "link_wait_started_at": "2026-07-15T18:45:01Z",
            "link_received_at": "2026-07-15T18:45:02Z",
            "link_wait_elapsed_s": 1.0,
        },
    }


def spl_link_report(sol_dmg_sha256=DEFAULT_SOL_DMG_SHA, run_id=RUN_ID):
    # Schema-derived from extro-tools 8c09723c, not captured live evidence.
    return {
        "result": "PASS",
        "run_id": run_id,
        "instance_id": "instance1",
        "original_verdict": "PASS",
        "phases": phase_report(),
        "lane": spl_link_lane_subset(sol_dmg_sha256),
        "binding": {"complete": True, "invalid_fields": []},
        "pairing_timing": {
            "ready_observed_at": "2026-07-15T18:45:01Z",
            "minted_at": "2026-07-15T18:45:02Z",
            "delivered_at": "2026-07-15T18:45:03Z",
            "mint_after_ready": True,
            "delivery_after_mint_s": 1.0,
            "delivery_within_ttl": True,
        },
        "cleanup": cleanup_report(),
        "error": None,
        "retry": None,
    }


def report_for(filename, sol_dmg_sha256=DEFAULT_SOL_DMG_SHA):
    """One honest PASS report per canonical filename."""
    if filename == verifier.SPL_LINK_REPORT_FILENAME:
        return spl_link_report(sol_dmg_sha256)
    if filename in ("drag.json", "sparkle.json"):
        lane = "drag" if filename == "drag.json" else "sparkle"
        return base_report(
            lane,
            {"solstone_pin_matches": True},
            **{
                "from": LEGACY_SOL_V,
                "to": SOL_V,
                "to_build": SOL_B,
                "journal": JOURNAL_V,
                "journal_build": JOURNAL_B,
            },
            post={"journal_version": OBSERVED_RUNTIME},
        )
    if filename in ("fresh-acquire.json", "discovered-adopt.json"):
        # Derived from gate.py at 8c09723c: new_report() scenario fields for the
        # acquire-driven lanes. Like fresh, they run the oracles + pin check but
        # store the fingerprint under linked_finish, never top-level `post` --
        # the pin is proved by the check alone.
        return base_report(
            filename.removesuffix(".json"),
            {"solstone_pin_matches": True},
            to=SOL_V,
            to_build=SOL_B,
            journal=JOURNAL_V,
            journal_build=JOURNAL_B,
        )
    if filename.startswith("fresh-"):
        order = "journal-first" if "journal-first" in filename else "sol-first"
        # The fresh lane runs the oracles but never stores the fingerprint, so
        # its report carries no `post` -- the pin is proved by the check alone.
        return base_report(
            "fresh",
            {"solstone_pin_matches": True},
            to=SOL_V,
            to_build=SOL_B,
            journal=JOURNAL_V,
            journal_build=JOURNAL_B,
            order=order,
        )
    if filename == "sol-upgrade.json":
        return base_report(
            "sol-upgrade",
            {"runtime_pin_matches": True},
            **{
                "from": SOL_BASE_V,
                "from_build": SOL_BASE_B,
                "to": SOL_V,
                "to_build": SOL_B,
                "journal": JOURNAL_V,
                "journal_build": JOURNAL_B,
            },
            post={"journal_version": OBSERVED_RUNTIME},
        )
    if filename == "journal-upgrade.json":
        # Derived from gate.py at 8c09723c: new_report(),
        # _run_linked_upgrade_lane(), and establish_linked_baseline().
        return base_report(
            "journal-upgrade",
            {"runtime_pin_matches": True, "baseline_solstone_pin_matches": True},
            to=COMPANION_SOL_V,
            to_build=COMPANION_SOL_B,
            journal=JOURNAL_BASE_V,
            journal_build=JOURNAL_BASE_B,
            journal_to=JOURNAL_V,
            journal_to_build=JOURNAL_B,
            expect_solstone=RUNTIME_PIN,
            expect_solstone_baseline=BASELINE_RUNTIME_PIN,
            linked_baseline={
                "ok": True,
                "expected_runtime_version": BASELINE_RUNTIME_PIN,
                "journal_fingerprint": {"journal_version": OBSERVED_BASELINE_RUNTIME},
            },
            post={"journal_version": OBSERVED_RUNTIME},
        )
    raise AssertionError(f"no fixture for {filename}")


def set_path(mapping, path, value):
    target = mapping
    parts = path.split(".")
    for part in parts[:-1]:
        target = target[part]
    target[parts[-1]] = value


def delete_path(mapping, path):
    target = mapping
    parts = path.split(".")
    for part in parts[:-1]:
        target = target[part]
    del target[parts[-1]]


class GateTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name)
        self.reports = self.root / "reports"
        self.reports.mkdir()
        self.receipt = self.root / "sync-receipt.json"
        self.sol_dmg = self.root / "sol.dmg"
        self.sol_dmg.write_bytes(b"schema-derived sol dmg fixture")
        self.sol_dmg_sha = verifier.hash_file_sha256(self.sol_dmg, "--sol-dmg")
        self.write_receipt()

    def write_receipt(self, **overrides):
        payload = {
            "harness_revision": PIN,
            "product_commit": COMMIT,
            "rig": "ja1r.local",
            "synced_at": "2026-07-11T12:00:00Z",
        }
        payload.update(overrides)
        self.receipt.write_text(json.dumps(payload, indent=2))

    def write_set(self, profile):
        for filename in verifier.PROFILES[profile]:
            self.write_report(filename, report_for(filename, self.sol_dmg_sha))

    def write_report(self, filename, report):
        (self.reports / filename).write_text(json.dumps(report, indent=2))

    def run_gate(
        self,
        profile="sol",
        include_baseline_runtime=None,
        include_sol_dmg=None,
        sol_dmg_path=None,
        now=FIXED_NOW,
    ):
        argv = [
            "--profile", profile,
            "--report-dir", str(self.reports),
            "--sync-receipt", str(self.receipt),
            "--product-commit", COMMIT,
            "--expected-journal-runtime", RUNTIME_PIN,
        ]
        if include_baseline_runtime is None:
            include_baseline_runtime = verifier.requires_baseline_runtime(profile)
        if include_baseline_runtime:
            argv += ["--expected-journal-baseline-runtime", BASELINE_RUNTIME_PIN]
        if include_sol_dmg is None:
            include_sol_dmg = verifier.SPL_LINK_REPORT_FILENAME in verifier.PROFILES[profile]
        if include_sol_dmg:
            argv += ["--sol-dmg", str(sol_dmg_path or self.sol_dmg)]
        for flag, value in IDENTITY_ARGS.items():
            argv += [f"--{flag}", value]

        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = verifier.main(argv, now=now)
        return code, out.getvalue(), err.getvalue()

    def assert_refused(self, profile="sol"):
        code, out, err = self.run_gate(profile)
        self.assertNotEqual(code, 0, "the gate should have refused this evidence set")
        self.assertEqual(out.strip(), "", "a refused gate must emit no stdout verdict")
        self.assertTrue(err.strip(), "a refused gate must explain itself on stderr")
        return err


class ValidSetsPass(GateTestCase):
    def test_valid_sol_set_passes(self):
        self.write_set("sol")
        code, out, _ = self.run_gate("sol")
        self.assertEqual(code, 0)
        verdict = json.loads(out)
        self.assertEqual(verdict["result"], "PASS")
        self.assertEqual(verdict["profile"], "sol")
        self.assertEqual(verdict["product_commit"], COMMIT)
        self.assertEqual(verdict["harness_revision"], PIN)
        self.assertNotIn("expected_journal_baseline_runtime", verdict)
        self.assertEqual(len(verdict["reports_verified"]), 8)

    def test_valid_journal_set_passes(self):
        self.write_set("journal")
        code, out, _ = self.run_gate("journal")
        self.assertEqual(code, 0)
        verdict = json.loads(out)
        self.assertEqual(verdict["profile"], "journal")
        self.assertEqual(verdict["expected_journal_baseline_runtime"], BASELINE_RUNTIME_PIN)
        self.assertEqual(len(verdict["reports_verified"]), 6)

    def test_valid_paired_set_passes(self):
        self.write_set("paired")
        code, out, _ = self.run_gate("paired")
        self.assertEqual(code, 0)
        verdict = json.loads(out)
        self.assertEqual(len(verdict["reports_verified"]), 9)
        self.assertEqual(verdict["expected_journal_baseline_runtime"], BASELINE_RUNTIME_PIN)

    def test_journal_profile_requires_drag(self):
        self.assertIn("drag.json", verifier.PROFILES["journal"])


class FreshnessAndProvenance(GateTestCase):
    def test_stale_product_commit_is_refused(self):
        self.write_set("sol")
        stale = report_for("drag.json")
        stale["provenance"]["commit"] = OTHER_COMMIT
        self.write_report("drag.json", stale)
        self.assertIn("another build", self.assert_refused())

    def test_dirty_contract_scope_is_refused(self):
        self.write_set("sol")
        dirty = report_for("sparkle.json")
        dirty["provenance"]["clean"] = False
        self.write_report("sparkle.json", dirty)
        self.assertIn("clean", self.assert_refused())

    def test_missing_provenance_is_refused(self):
        self.write_set("sol")
        broken = report_for("drag.json")
        del broken["provenance"]
        self.write_report("drag.json", broken)
        self.assert_refused()

    def test_missing_contract_hash_is_refused(self):
        self.write_set("sol")
        broken = report_for("drag.json")
        del broken["provenance"]["contracts"]["journal_sha256"]
        self.write_report("drag.json", broken)
        self.assertIn("journal_sha256", self.assert_refused())


class ReceiptBinding(GateTestCase):
    def test_receipt_with_stale_harness_revision_is_refused(self):
        self.write_set("sol")
        self.write_receipt(harness_revision="f" * 40)
        self.assertIn("does not match the pin", self.assert_refused())

    def test_receipt_for_another_product_commit_is_refused(self):
        self.write_set("sol")
        self.write_receipt(product_commit=OTHER_COMMIT)
        self.assertIn("not the one being", self.assert_refused())

    def test_missing_receipt_is_refused(self):
        self.write_set("sol")
        self.receipt.unlink()
        self.assert_refused()

    def test_malformed_receipt_is_refused(self):
        self.write_set("sol")
        self.receipt.write_text("{not json")
        self.assert_refused()


class Completeness(GateTestCase):
    def test_missing_member_is_refused(self):
        self.write_set("sol")
        (self.reports / "sol-upgrade.json").unlink()
        self.assertIn("missing", self.assert_refused())

    def test_sol_reports_cannot_authorize_a_journal_publish(self):
        # A complete, valid sol set lacks journal-upgrade.json entirely.
        self.write_set("sol")
        (self.reports / "journal-upgrade.json").unlink(missing_ok=True)
        self.assert_refused("journal")

    def test_empty_report_dir_is_refused(self):
        self.assert_refused()


class SPLLinkCoordinatorReport(GateTestCase):
    def spl_path(self):
        return self.reports / verifier.SPL_LINK_REPORT_FILENAME

    def read_spl(self):
        return json.loads(self.spl_path().read_text())

    def write_spl(self, report):
        self.spl_path().write_text(json.dumps(report, indent=2))

    def assert_spl_mutation_refused(self, mutate, profile="sol", **run_kwargs):
        self.write_set(profile)
        report = self.read_spl()
        mutate(report)
        self.write_spl(report)
        code, out, err = self.run_gate(profile, **run_kwargs)
        self.assertNotEqual(code, 0, "the gate should have refused this evidence set")
        self.assertEqual(out.strip(), "", "a refused gate must emit no stdout verdict")
        self.assertTrue(err.strip(), "a refused gate must explain itself on stderr")
        return err

    def test_missing_spl_link_is_refused_for_sol_and_paired(self):
        for profile in ("sol", "paired"):
            with self.subTest(profile=profile):
                self.write_set(profile)
                self.spl_path().unlink()
                self.assertIn("missing", self.assert_refused(profile))

    def test_sol_dmg_argument_is_profile_conditional(self):
        self.write_set("sol")
        code, out, err = self.run_gate("sol", include_sol_dmg=False)
        self.assertNotEqual(code, 0)
        self.assertEqual(out.strip(), "")
        self.assertIn("--sol-dmg", err)

        self.write_set("journal")
        code, out, err = self.run_gate("journal", include_sol_dmg=True)
        self.assertNotEqual(code, 0)
        self.assertEqual(out.strip(), "")
        self.assertIn("must not supply --sol-dmg", err)

    def test_sol_dmg_file_failures_are_refused(self):
        missing = self.root / "missing.dmg"
        directory = self.root / "not-a-file.dmg"
        directory.mkdir()
        unreadable = self.root / "unreadable.dmg"
        unreadable.write_bytes(b"secret")
        unreadable.chmod(0)
        try:
            cases = (
                ("missing", missing),
                ("non-file", directory),
                ("unreadable", unreadable),
            )
            for _label, path in cases:
                with self.subTest(path=path):
                    self.write_set("sol")
                    code, out, err = self.run_gate("sol", sol_dmg_path=path)
                    self.assertNotEqual(code, 0)
                    self.assertEqual(out.strip(), "")
                    self.assertIn("--sol-dmg", err)
        finally:
            unreadable.chmod(0o600)

    def test_hash_for_different_same_version_dmg_is_refused(self):
        other = self.root / "other-sol.dmg"
        other.write_bytes(b"different dmg bytes for same version")
        self.write_set("sol")
        code, out, err = self.run_gate("sol", sol_dmg_path=other)
        self.assertNotEqual(code, 0)
        self.assertEqual(out.strip(), "")
        self.assertIn("dmg_sha256", err)

    def test_outer_envelope_refusals(self):
        cases = (
            ("missing outer key", lambda r: delete_path(r, "retry")),
            ("extra outer key", lambda r: r.__setitem__("unknown", True)),
            ("result", lambda r: r.__setitem__("result", "FAIL")),
            ("original_verdict", lambda r: r.__setitem__("original_verdict", "FAIL")),
            ("error", lambda r: r.__setitem__("error", {"type": "x", "phase": "y"})),
            ("retry", lambda r: r.__setitem__("retry", "retry")),
            ("instance_id", lambda r: r.__setitem__("instance_id", "")),
        )
        for label, mutate in cases:
            with self.subTest(label=label):
                self.assert_spl_mutation_refused(mutate)

    def test_run_id_wall_clock_refusals(self):
        cases = (
            ("malformed", lambda r: r.__setitem__("run_id", "not-a-run-id"), FIXED_NOW),
            (
                "stale",
                lambda r: r.__setitem__("run_id", "20260714T184459Z-a1b2c3d4e5f60718"),
                FIXED_NOW,
            ),
            (
                "future",
                lambda r: r.__setitem__("run_id", "20260715T185501Z-a1b2c3d4e5f60718"),
                FIXED_NOW,
            ),
        )
        for label, mutate, now in cases:
            with self.subTest(label=label):
                self.assert_spl_mutation_refused(mutate, now=now)

    def test_phase_schema_and_duration_refusals(self):
        for phase in verifier.COORDINATOR_PHASE_NAMES:
            with self.subTest(phase=phase, case="missing-key"):
                self.assert_spl_mutation_refused(
                    lambda r, phase=phase: delete_path(r, f"phases.{phase}.duration_s")
                )
            with self.subTest(phase=phase, case="extra-key"):
                self.assert_spl_mutation_refused(
                    lambda r, phase=phase: r["phases"][phase].__setitem__("extra", True)
                )
        cases = (
            ("non-ok status", lambda r: set_path(r, "phases.create.status", "error")),
            ("bool duration", lambda r: set_path(r, "phases.create.duration_s", True)),
            ("negative duration", lambda r: set_path(r, "phases.create.duration_s", -0.1)),
            ("non-finite duration", lambda r: set_path(r, "phases.create.duration_s", math.inf)),
        )
        for label, mutate in cases:
            with self.subTest(label=label):
                self.assert_spl_mutation_refused(mutate)

    def test_binding_refusals(self):
        cases = (
            ("missing", lambda r: delete_path(r, "binding.complete")),
            ("extra", lambda r: r["binding"].__setitem__("extra", True)),
            ("incomplete", lambda r: set_path(r, "binding.complete", False)),
            ("invalid-fields", lambda r: set_path(r, "binding.invalid_fields", ["to"])),
        )
        for label, mutate in cases:
            with self.subTest(label=label):
                self.assert_spl_mutation_refused(mutate)

    def test_pairing_timing_refusals(self):
        cases = (
            ("missing", lambda r: delete_path(r, "pairing_timing.minted_at")),
            ("extra", lambda r: r["pairing_timing"].__setitem__("extra", True)),
            ("mint false", lambda r: set_path(r, "pairing_timing.mint_after_ready", False)),
            ("ttl false", lambda r: set_path(r, "pairing_timing.delivery_within_ttl", False)),
            ("over ttl", lambda r: set_path(r, "pairing_timing.delivery_after_mint_s", 301.0)),
            ("contradictory", lambda r: set_path(r, "pairing_timing.delivery_after_mint_s", 5.0)),
            ("out of order", lambda r: set_path(r, "pairing_timing.minted_at", "2026-07-15T18:45:04Z")),
        )
        for label, mutate in cases:
            with self.subTest(label=label):
                self.assert_spl_mutation_refused(mutate)

    def test_cleanup_refusals(self):
        cases = (
            ("missing step", lambda r: r["cleanup"].pop("remote_lane")),
            ("extra step", lambda r: r["cleanup"].__setitem__("extra", cleanup_report()["remote_lane"])),
            ("attempted false", lambda r: set_path(r, "cleanup.remote_lane.attempted", False)),
            ("required false", lambda r: set_path(r, "cleanup.remote_lane.required", False)),
            ("action false", lambda r: set_path(r, "cleanup.remote_lane.action_ok", False)),
            ("verified false", lambda r: set_path(r, "cleanup.remote_lane.verified", False)),
            ("required non-bool", lambda r: set_path(r, "cleanup.remote_lane.required", "true")),
            ("bad duration", lambda r: set_path(r, "cleanup.remote_lane.duration_s", -1)),
        )
        for label, mutate in cases:
            with self.subTest(label=label):
                self.assert_spl_mutation_refused(mutate)

    def test_lane_shape_and_identity_refusals(self):
        cases = (
            ("missing", lambda r: delete_path(r, "lane.retry")),
            ("extra", lambda r: r["lane"].__setitem__("extra", True)),
            ("result", lambda r: set_path(r, "lane.result", "FAIL")),
            ("lane", lambda r: set_path(r, "lane.lane", "fresh")),
            ("schema", lambda r: set_path(r, "lane.schema_version", True)),
            ("to", lambda r: set_path(r, "lane.to", "9.9.9")),
            ("to_build", lambda r: set_path(r, "lane.to_build", "999")),
            ("identity", lambda r: set_path(r, "lane.identity_match", False)),
            ("nested error", lambda r: set_path(r, "lane.error_type", "pairing_timeout")),
            ("nested retry", lambda r: set_path(r, "lane.retry", "retry")),
        )
        for label, mutate in cases:
            with self.subTest(label=label):
                self.assert_spl_mutation_refused(mutate)

    def test_each_spl_link_check_must_be_true(self):
        for key in verifier.SPL_LINK_CHECK_KEYS:
            with self.subTest(key=key):
                self.assert_spl_mutation_refused(
                    lambda r, key=key: set_path(r, f"lane.checks.{key}", False)
                )

    def test_nested_spl_link_objects_reject_missing_and_extra_keys(self):
        cases = (
            ("lane.checks", "initial_reset_clean"),
            ("lane.oracles", "serverkey_sha256"),
            ("lane.freshness", "ok"),
            ("lane.provenance", "commit"),
            ("lane.provenance.contracts", "sol_sha256"),
            ("lane.timings", "ready_at"),
        )
        for object_path, child_key in cases:
            with self.subTest(object_path=object_path, case="missing"):
                self.assert_spl_mutation_refused(
                    lambda r, object_path=object_path, child_key=child_key: delete_path(
                        r, f"{object_path}.{child_key}"
                    )
                )
            with self.subTest(object_path=object_path, case="extra"):
                self.assert_spl_mutation_refused(
                    lambda r, object_path=object_path: set_path(
                        r, f"{object_path}.extra", True
                    )
                )

    def test_lane_timing_refusals(self):
        cases = (
            (
                "out of order",
                lambda r: set_path(
                    r, "lane.timings.link_received_at", "2026-07-15T18:45:00Z"
                ),
            ),
            (
                "over ttl",
                lambda r: set_path(r, "lane.timings.link_wait_elapsed_s", 301.0),
            ),
            (
                "bool elapsed",
                lambda r: set_path(r, "lane.timings.link_wait_elapsed_s", True),
            ),
            (
                "negative elapsed",
                lambda r: set_path(r, "lane.timings.link_wait_elapsed_s", -1.0),
            ),
            (
                "non-finite elapsed",
                lambda r: set_path(r, "lane.timings.link_wait_elapsed_s", math.inf),
            ),
            (
                "malformed iso",
                lambda r: set_path(r, "lane.timings.ready_at", "not-a-timestamp"),
            ),
        )
        for label, mutate in cases:
            with self.subTest(label=label):
                self.assert_spl_mutation_refused(mutate)

    def test_truthy_non_bool_strings_are_refused_for_booleans(self):
        paths = (
            "binding.complete",
            "pairing_timing.mint_after_ready",
            "pairing_timing.delivery_within_ttl",
            "cleanup.remote_lane.attempted",
            "cleanup.remote_lane.required",
            "cleanup.remote_lane.action_ok",
            "cleanup.remote_lane.verified",
            "lane.checks.initial_reset_clean",
            "lane.oracles.serverkey_trimmed_nonempty",
            "lane.freshness.ok",
            "lane.provenance.clean",
            "lane.identity_match",
        )
        for path in paths:
            with self.subTest(path=path):
                self.assert_spl_mutation_refused(lambda r, path=path: set_path(r, path, "true"))

    def test_oracle_refusals(self):
        cases = (
            ("missing", lambda r: delete_path(r, "lane.oracles.serverkey_sha256")),
            ("false tier-a", lambda r: set_path(r, "lane.oracles.last_synced_fresh", False)),
            ("bad sha", lambda r: set_path(r, "lane.oracles.serverkey_sha256", "x" * 64)),
            ("none literal", lambda r: set_path(r, "lane.oracles.serverkey_sha256", "NONE")),
        )
        for label, mutate in cases:
            with self.subTest(label=label):
                self.assert_spl_mutation_refused(mutate)

    def test_freshness_refusals(self):
        cases = (
            ("bad baseline", lambda r: set_path(r, "lane.freshness.baseline_kind", "unknown")),
            ("equal", lambda r: set_path(r, "lane.freshness.last_synced_post_epoch", 0)),
            (
                "stale",
                lambda r: (
                    set_path(r, "lane.freshness.last_synced_pre_epoch", 2),
                    set_path(r, "lane.freshness.last_synced_post_epoch", 1),
                ),
            ),
            ("non-numeric", lambda r: set_path(r, "lane.freshness.last_synced_post_epoch", "1")),
            ("bool epoch", lambda r: set_path(r, "lane.freshness.last_synced_pre_epoch", False)),
        )
        for label, mutate in cases:
            with self.subTest(label=label):
                self.assert_spl_mutation_refused(mutate)

    def test_provenance_refusals(self):
        cases = (
            ("commit", lambda r: set_path(r, "lane.provenance.commit", OTHER_COMMIT)),
            ("dirty", lambda r: set_path(r, "lane.provenance.clean", False)),
            ("sol hash", lambda r: set_path(r, "lane.provenance.contracts.sol_sha256", "x" * 64)),
            ("journal hash", lambda r: set_path(r, "lane.provenance.contracts.journal_sha256", "NONE")),
        )
        for label, mutate in cases:
            with self.subTest(label=label):
                self.assert_spl_mutation_refused(mutate)


class ScenarioIdentity(GateTestCase):
    def test_wrong_fresh_order_is_refused(self):
        self.write_set("sol")
        # Both fresh files present, but both ran sol-first.
        wrong = report_for("fresh-sol-first.json")
        self.write_report("fresh-journal-first.json", wrong)
        self.assertIn("order", self.assert_refused())

    def test_prior_version_is_refused(self):
        self.write_set("sol")
        stale = report_for("drag.json")
        stale["to"] = "1.4.4"
        self.write_report("drag.json", stale)
        self.assertIn("expected", self.assert_refused())

    def test_prior_build_is_refused(self):
        self.write_set("sol")
        stale = report_for("sol-upgrade.json")
        stale["to_build"] = "55"
        self.write_report("sol-upgrade.json", stale)
        self.assert_refused()

    def test_wrong_lane_is_refused(self):
        self.write_set("sol")
        swapped = report_for("drag.json")
        swapped["lane"] = "sparkle"
        self.write_report("drag.json", swapped)
        self.assertIn("lane", self.assert_refused())

    def test_missing_scenario_field_is_refused(self):
        self.write_set("sol")
        broken = report_for("drag.json")
        del broken["from"]
        self.write_report("drag.json", broken)
        self.assert_refused()

    def test_journal_upgrade_companion_sol_is_checked(self):
        self.write_set("journal")
        report = report_for("journal-upgrade.json")
        report["to"] = "9.9.9"
        self.write_report("journal-upgrade.json", report)
        self.assert_refused("journal")


class RuntimePin(GateTestCase):
    def test_skipped_pin_string_is_refused(self):
        # The trap: runtime_pin_check returns this truthy STRING when
        # --expect-solstone was not passed, and the lane can still say PASS.
        self.write_set("sol")
        skipped = report_for("drag.json")
        skipped["checks"]["solstone_pin_matches"] = "SKIPPED (no --expect-solstone)"
        self.write_report("drag.json", skipped)
        self.assertIn("not true", self.assert_refused())

    def test_false_pin_check_is_refused(self):
        self.write_set("sol")
        failed = report_for("sol-upgrade.json")
        failed["checks"]["runtime_pin_matches"] = False
        self.write_report("sol-upgrade.json", failed)
        self.assert_refused()

    def test_absent_pin_check_is_refused(self):
        self.write_set("sol")
        broken = report_for("fresh-sol-first.json")
        broken["checks"] = {}
        self.write_report("fresh-sol-first.json", broken)
        self.assertIn("solstone_pin_matches", self.assert_refused())

    def test_observed_runtime_without_the_pin_is_refused(self):
        self.write_set("sol")
        wrong = report_for("sol-upgrade.json")
        wrong["post"]["journal_version"] = "journal 0.7.9 (build 41)"
        self.write_report("sol-upgrade.json", wrong)
        self.assertIn("expected pin", self.assert_refused())

    def test_missing_observed_runtime_is_refused(self):
        self.write_set("sol")
        wrong = report_for("drag.json")
        del wrong["post"]
        self.write_report("drag.json", wrong)
        self.assert_refused()

    def test_mismatched_baseline_report_input_is_refused(self):
        self.write_set("journal")
        wrong = report_for("journal-upgrade.json")
        wrong["expect_solstone_baseline"] = RUNTIME_PIN
        self.write_report("journal-upgrade.json", wrong)
        self.assertIn("--expected-journal-baseline-runtime", self.assert_refused("journal"))

    def test_mismatched_linked_baseline_runtime_is_refused(self):
        self.write_set("journal")
        wrong = report_for("journal-upgrade.json")
        wrong["linked_baseline"]["expected_runtime_version"] = RUNTIME_PIN
        self.write_report("journal-upgrade.json", wrong)
        self.assertIn("linked_baseline.expected_runtime_version", self.assert_refused("journal"))

    def test_skipped_baseline_pin_check_is_refused(self):
        self.write_set("journal")
        wrong = report_for("journal-upgrade.json")
        wrong["checks"]["baseline_solstone_pin_matches"] = "SKIPPED (no --expect-solstone)"
        self.write_report("journal-upgrade.json", wrong)
        self.assertIn("baseline_solstone_pin_matches", self.assert_refused("journal"))

    def test_false_baseline_pin_check_is_refused(self):
        self.write_set("journal")
        wrong = report_for("journal-upgrade.json")
        wrong["checks"]["baseline_solstone_pin_matches"] = False
        self.write_report("journal-upgrade.json", wrong)
        self.assertIn("not true", self.assert_refused("journal"))

    def test_absent_baseline_pin_check_is_refused(self):
        self.write_set("journal")
        wrong = report_for("journal-upgrade.json")
        del wrong["checks"]["baseline_solstone_pin_matches"]
        self.write_report("journal-upgrade.json", wrong)
        self.assertIn("baseline_solstone_pin_matches", self.assert_refused("journal"))

    def test_baseline_observed_runtime_without_the_pin_is_refused(self):
        self.write_set("journal")
        wrong = report_for("journal-upgrade.json")
        wrong["linked_baseline"]["journal_fingerprint"]["journal_version"] = OBSERVED_RUNTIME
        self.write_report("journal-upgrade.json", wrong)
        self.assertIn("expected baseline pin", self.assert_refused("journal"))

    def test_missing_baseline_observed_runtime_is_refused(self):
        self.write_set("journal")
        wrong = report_for("journal-upgrade.json")
        del wrong["linked_baseline"]["journal_fingerprint"]["journal_version"]
        self.write_report("journal-upgrade.json", wrong)
        self.assertIn("linked_baseline.journal_fingerprint.journal_version", self.assert_refused("journal"))

    def test_baseline_and_target_pins_are_not_interchangeable(self):
        self.write_set("journal")
        baseline_has_target = report_for("journal-upgrade.json")
        baseline_has_target["linked_baseline"]["journal_fingerprint"]["journal_version"] = (
            OBSERVED_RUNTIME
        )
        self.write_report("journal-upgrade.json", baseline_has_target)
        self.assert_refused("journal")

        self.write_set("journal")
        target_has_baseline = report_for("journal-upgrade.json")
        target_has_baseline["post"]["journal_version"] = OBSERVED_BASELINE_RUNTIME
        self.write_report("journal-upgrade.json", target_has_baseline)
        self.assert_refused("journal")


class MalformedReports(GateTestCase):
    def test_trailing_json_is_refused(self):
        self.write_set("sol")
        good = json.dumps(report_for("drag.json"))
        (self.reports / "drag.json").write_text(good + "\n{}\n")
        self.assertIn("trailing", self.assert_refused())

    def test_non_object_json_is_refused(self):
        self.write_set("sol")
        (self.reports / "drag.json").write_text("[]")
        self.assert_refused()

    def test_wrong_schema_version_is_refused(self):
        self.write_set("sol")
        report = report_for("drag.json")
        report["schema_version"] = 2
        self.write_report("drag.json", report)
        self.assertIn("schema_version", self.assert_refused())

    def test_non_pass_result_is_refused(self):
        self.write_set("sol")
        for bad in ("FAIL", "RED", "ERROR", "INCONCLUSIVE"):
            report = report_for("drag.json")
            report["result"] = bad
            self.write_report("drag.json", report)
            self.assertIn("result", self.assert_refused())


class MissingIdentityInputs(GateTestCase):
    def test_missing_identities_are_listed_actionably(self):
        self.write_set("sol")
        argv = [
            "--profile", "sol",
            "--report-dir", str(self.reports),
            "--sync-receipt", str(self.receipt),
            "--product-commit", COMMIT,
            "--expected-journal-runtime", RUNTIME_PIN,
        ]
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = verifier.main(argv)
        self.assertNotEqual(code, 0)
        self.assertEqual(out.getvalue().strip(), "")
        self.assertIn("--sol-target-version", err.getvalue())
        self.assertIn("--legacy-sol-baseline-version", err.getvalue())

    def test_sol_profile_does_not_demand_journal_baseline(self):
        # Only the identities the profile's lanes actually assert are required.
        self.assertNotIn("journal_baseline_version", verifier.required_identity_keys("sol"))
        self.assertIn("journal_baseline_version", verifier.required_identity_keys("journal"))
        self.assertFalse(verifier.requires_baseline_runtime("sol"))

    def test_missing_baseline_runtime_is_listed_for_journal_and_paired(self):
        for profile in ("journal", "paired"):
            with self.subTest(profile=profile):
                self.write_set(profile)
                code, out, err = self.run_gate(profile, include_baseline_runtime=False)
                self.assertNotEqual(code, 0)
                self.assertEqual(out.strip(), "")
                self.assertIn("--expected-journal-baseline-runtime", err)

    def test_sol_profile_does_not_require_baseline_runtime(self):
        self.write_set("sol")
        code, out, _ = self.run_gate("sol", include_baseline_runtime=False)
        self.assertEqual(code, 0)
        self.assertNotIn("expected_journal_baseline_runtime", json.loads(out))


class PinIsASingleSourceOfTruth(unittest.TestCase):
    def test_pin_file_is_one_bare_sha(self):
        raw = (SCRIPTS / "ja1r-gate" / "extro-tools.rev").read_text()
        self.assertRegex(raw, r"^[0-9a-f]{40}\n$")

    def test_pinned_sha_appears_in_exactly_one_committed_file(self):
        pin = (SCRIPTS / "ja1r-gate" / "extro-tools.rev").read_text().strip()
        # --untracked so this holds while the pin is still staged for its first
        # commit, and keeps holding after; ignored paths (the .ja1r-gate/
        # evidence dir) are excluded either way.
        hits = subprocess.run(
            ["git", "grep", "-l", "--untracked", pin],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
        )
        files = [line for line in hits.stdout.splitlines() if line.strip()]
        self.assertEqual(
            files,
            ["scripts/ja1r-gate/extro-tools.rev"],
            "the harness pin must live in exactly one file — not restated in the "
            "Makefile, README, or tests",
        )


class MakefileContract(unittest.TestCase):
    # Behavioral `make verify-ja1r-gate-journal` would hit the clean-tree
    # prerequisite before require_gate_vars, so this stays a text contract.
    def target_block(self, target):
        text = MAKEFILE.read_text()
        start = text.index(f"{target}:")
        next_target = text.find("\nverify-ja1r-gate-", start + 1)
        if next_target == -1:
            next_target = text.find("\n# Production publishes", start)
        if next_target == -1:
            next_target = len(text)
        return text[start:next_target]

    def test_baseline_runtime_var_is_only_required_and_forwarded_for_baseline_profiles(self):
        sol = self.target_block("verify-ja1r-gate-sol")
        journal = self.target_block("verify-ja1r-gate-journal")
        paired = self.target_block("verify-ja1r-gate-paired")

        baseline_var = "JA1R_GATE_JOURNAL_BASELINE_RUNTIME_PIN"
        baseline_flag = "--expected-journal-baseline-runtime"

        self.assertNotIn(baseline_var, sol)
        self.assertNotIn(baseline_flag, sol)

        for block in (journal, paired):
            self.assertIn(baseline_var, block)
            self.assertIn(baseline_flag, block)

    def test_sol_dmg_is_only_forwarded_for_profiles_with_spl_link(self):
        sol = self.target_block("verify-ja1r-gate-sol")
        journal = self.target_block("verify-ja1r-gate-journal")
        paired = self.target_block("verify-ja1r-gate-paired")

        self.assertIn("--sol-dmg '$(DMG_NAME)'", sol)
        self.assertNotIn("--sol-dmg", journal)
        self.assertIn("--sol-dmg '$(DMG_NAME)'", paired)


class ReadmeDoesNotDrift(unittest.TestCase):
    def test_readme_lists_exactly_the_canonical_report_filenames(self):
        readme = (REPO_ROOT / "README.md").read_text()
        block = readme.split("<!-- ja1r-report-filenames:start -->")[1]
        block = block.split("<!-- ja1r-report-filenames:end -->")[0]
        listed = [
            line.strip().lstrip("-").strip().strip("`")
            for line in block.splitlines()
            if line.strip().startswith("-")
        ]
        self.assertEqual(listed, list(verifier.REPORT_FILENAMES))

    def test_readme_states_profile_report_counts(self):
        readme = (REPO_ROOT / "README.md").read_text()
        normalized = " ".join(readme.split())
        expected = (
            f"sol={len(verifier.PROFILES['sol'])}, "
            f"journal={len(verifier.PROFILES['journal'])}, and "
            f"paired={len(verifier.PROFILES['paired'])}"
        )
        self.assertIn(expected, normalized)


if __name__ == "__main__":
    unittest.main()
