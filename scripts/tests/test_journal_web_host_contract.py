import hashlib
import json
import pathlib
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
CONTRACT = REPO_ROOT / "Sources" / "solstone" / "Resources" / "host-contract.json"
PROVENANCE = REPO_ROOT / "Sources" / "solstone" / "host-contract.provenance.json"
EXPECTED_SHA256 = "96b6b5fa81608ea598f75856c3c4fd76cb79d589f1c1f48e9d079bb06166d22d"
EXPORT_CONTRACT = REPO_ROOT / "Sources" / "solstone" / "Resources" / "export-host-contract.json"
EXPORT_PROVENANCE = REPO_ROOT / "Sources" / "solstone" / "export-host-contract.provenance.json"
EXPECTED_EXPORT_SHA256 = "7c4f637d55dc879ba980cde392f4ab5f4e4fe1ab14960f6cae20f0f91b4809fc"


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

    def test_packaged_export_contract_matches_upstream_provenance(self):
        actual_sha256 = hashlib.sha256(EXPORT_CONTRACT.read_bytes()).hexdigest()
        provenance = json.loads(EXPORT_PROVENANCE.read_text(encoding="utf-8"))

        self.assertEqual(actual_sha256, provenance.get("sha256"))
        self.assertEqual(actual_sha256, EXPECTED_EXPORT_SHA256)
        self.assertEqual(set(provenance), {"path", "repository", "revision", "sha256"})
        self.assertEqual(provenance["revision"], "f26de8716b0d5f8b30008e56d14c3ca7f0be214e")
        self.assertEqual(provenance["path"], "contracts/journal-web-host/export-host-contract.json")
        self.assertEqual(provenance["repository"], "solpbc/solstone-journal")
