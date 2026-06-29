import pathlib
import subprocess
import unittest


class SPLCLISmokeTest(unittest.TestCase):
    def test_status_and_unpair_on_empty_keychain(self):
        root = pathlib.Path(__file__).resolve().parents[2]

        build = subprocess.run(
            ["swift", "build", "--product", "sol-mac"],
            cwd=root,
            check=False,
            text=True,
            capture_output=True,
        )
        self.assertEqual(build.returncode, 0, build.stderr)

        bin_path = subprocess.run(
            ["swift", "build", "--show-bin-path"],
            cwd=root,
            check=False,
            text=True,
            capture_output=True,
        )
        self.assertEqual(bin_path.returncode, 0, bin_path.stderr)
        sol_mac = pathlib.Path(bin_path.stdout.strip()) / "sol-mac"

        status = subprocess.run(
            [str(sol_mac), "spl", "status"],
            cwd=root,
            check=False,
            text=True,
            capture_output=True,
        )
        self.assertEqual(status.returncode, 0, status.stderr)
        self.assertIn("not paired", status.stdout)

        unpair = subprocess.run(
            [str(sol_mac), "spl", "unpair"],
            cwd=root,
            check=False,
            text=True,
            capture_output=True,
        )
        self.assertEqual(unpair.returncode, 0, unpair.stderr)


if __name__ == "__main__":
    unittest.main()
