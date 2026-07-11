"""Tests for the ja1r linkage-gate evidence verifier.

FIXTURE HONESTY: the reports built here are SCHEMA-DERIVED, not captured. No
real PASS report exists in the harness repo or anywhere on disk, so these are
constructed from the pinned harness's own report emitter -- extro-tools
eb7328d8, tools/solstone-macos-gate/gate.py: new_report() (top-level shape,
schema_version, lane, result), the per-lane scenario fields it sets, the
provenance block it fills, oracles() -> rep["post"] (the observed
journal_version), and runtime_pin_check() (the pin check keys). They are not
dressed up as recordings of a real run.
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import pathlib
import subprocess
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPTS = REPO_ROOT / "scripts"

# The verifier's filename is not a valid module name, so load it by path.
_spec = importlib.util.spec_from_file_location(
    "verify_ja1r_linkage_gate", SCRIPTS / "verify-ja1r-linkage-gate.py"
)
verifier = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(verifier)


PIN = (SCRIPTS / "ja1r-gate" / "extro-tools.rev").read_text().strip()
COMMIT = "a" * 40
OTHER_COMMIT = "b" * 40
RUNTIME_PIN = "0.8.0"
OBSERVED_RUNTIME = "journal 0.8.0 (build 42)"

SOL_V, SOL_B = "1.4.5", "56"
JOURNAL_V, JOURNAL_B = "1.0.4", "5"
SOL_BASE_V, SOL_BASE_B = "1.4.4", "55"
JOURNAL_BASE_V, JOURNAL_BASE_B = "1.0.3", "4"
COMPANION_SOL_V, COMPANION_SOL_B = "1.4.5", "56"
LEGACY_SOL_V = "1.3.31"

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


def report_for(filename):
    """One honest PASS report per canonical filename."""
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
        return base_report(
            "journal-upgrade",
            {"runtime_pin_matches": True},
            to=COMPANION_SOL_V,
            to_build=COMPANION_SOL_B,
            journal=JOURNAL_BASE_V,
            journal_build=JOURNAL_BASE_B,
            journal_to=JOURNAL_V,
            journal_to_build=JOURNAL_B,
            post={"journal_version": OBSERVED_RUNTIME},
        )
    raise AssertionError(f"no fixture for {filename}")


class GateTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name)
        self.reports = self.root / "reports"
        self.reports.mkdir()
        self.receipt = self.root / "sync-receipt.json"
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
            self.write_report(filename, report_for(filename))

    def write_report(self, filename, report):
        (self.reports / filename).write_text(json.dumps(report, indent=2))

    def run_gate(self, profile="sol"):
        argv = [
            "--profile", profile,
            "--report-dir", str(self.reports),
            "--sync-receipt", str(self.receipt),
            "--product-commit", COMMIT,
            "--expected-journal-runtime", RUNTIME_PIN,
        ]
        for flag, value in IDENTITY_ARGS.items():
            argv += [f"--{flag}", value]

        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = verifier.main(argv)
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

    def test_valid_journal_set_passes(self):
        self.write_set("journal")
        code, out, _ = self.run_gate("journal")
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out)["profile"], "journal")

    def test_valid_paired_set_passes(self):
        self.write_set("paired")
        code, out, _ = self.run_gate("paired")
        self.assertEqual(code, 0)
        self.assertEqual(len(json.loads(out)["reports_verified"]), 6)

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


if __name__ == "__main__":
    unittest.main()
