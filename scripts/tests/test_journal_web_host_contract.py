import hashlib
import json
import pathlib
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
CONTRACT = REPO_ROOT / "Sources" / "solstone" / "Resources" / "host-contract.json"
PROVENANCE = REPO_ROOT / "Sources" / "solstone" / "host-contract.provenance.json"
EXPECTED_SHA256 = "96b6b5fa81608ea598f75856c3c4fd76cb79d589f1c1f48e9d079bb06166d22d"


class JournalWebHostContractPinTests(unittest.TestCase):
    def test_packaged_contract_matches_upstream_provenance(self):
        actual_sha256 = hashlib.sha256(CONTRACT.read_bytes()).hexdigest()
        provenance = json.loads(PROVENANCE.read_text(encoding="utf-8"))

        self.assertEqual(
            actual_sha256,
            provenance.get("sha256"),
        )
        self.assertEqual(actual_sha256, EXPECTED_SHA256)
        self.assertEqual(set(provenance), {"path", "repository", "revision", "sha256"})
        self.assertEqual(provenance["revision"], "05705f731e156f8ea1956d038ec60896fdd6219e")
        self.assertEqual(provenance["path"], "contracts/journal-web-host/host-contract.json")
        self.assertEqual(provenance["repository"], "solpbc/solstone-journal")
