import importlib.util
import pathlib
import types
import unittest
from unittest import mock


def load_publish_appcast():
    path = pathlib.Path(__file__).resolve().parents[1] / "publish-appcast.py"
    spec = importlib.util.spec_from_file_location("publish_appcast", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ImportWithoutPyNaClTest(unittest.TestCase):
    def test_import_succeeds_without_pynacl(self):
        load_publish_appcast()


class BuildItemMarkdownFormatTest(unittest.TestCase):
    def test_description_has_sparkle_format_markdown(self):
        module = load_publish_appcast()
        item = module.build_item("1.3.0", 9, "signature", 123, "https://example.com/app.dmg", "### test\n- one")
        description = item.find("description")

        self.assertIsNotNone(description)
        self.assertEqual(description.get(f"{{{module.SPARKLE_NS}}}format"), "markdown")

    def test_description_text_is_byte_identical_to_notes_argument(self):
        module = load_publish_appcast()
        notes = "### test\n- one"
        item = module.build_item("1.3.0", 9, "signature", 123, "https://example.com/app.dmg", notes)
        description = item.find("description")

        self.assertIsNotNone(description)
        self.assertEqual(description.text, notes)


class PreflightWranglerTest(unittest.TestCase):
    """The release-host wrangler/CF-auth gate must fail fast on a degraded OAuth
    token (the silent ~24h-cadence degrade) and pass only when whoami exits 0 AND
    lists the expected account id. subprocess.run is patched per-case (and
    restored) so the real wrangler is never invoked and no global state leaks."""

    def _assert_dies(self, fake_run):
        module = load_publish_appcast()
        with mock.patch.object(module.subprocess, "run", fake_run):
            with self.assertRaises(SystemExit) as ctx:
                module.preflight_wrangler()
        self.assertEqual(ctx.exception.code, 1)

    def test_passes_when_whoami_exit0_and_account_listed(self):
        module = load_publish_appcast()
        fake = lambda cmd, **kw: types.SimpleNamespace(
            returncode=0, stdout=f"account jer | {module.CF_ACCOUNT_ID}", stderr=""
        )
        with mock.patch.object(module.subprocess, "run", fake):
            module.preflight_wrangler()  # must not raise

    def test_passes_when_account_id_only_on_stderr(self):
        # wrangler routes the whoami table to stdout or stderr depending on
        # TTY/pipe detection — an id on stderr with a clean exit must still pass.
        module = load_publish_appcast()
        fake = lambda cmd, **kw: types.SimpleNamespace(
            returncode=0, stdout="", stderr=f"account jer | {module.CF_ACCOUNT_ID}"
        )
        with mock.patch.object(module.subprocess, "run", fake):
            module.preflight_wrangler()  # must not raise

    def test_dies_when_whoami_nonzero(self):
        self._assert_dies(
            lambda cmd, **kw: types.SimpleNamespace(
                returncode=1,
                stdout="Failed to automatically retrieve account IDs",
                stderr="incorrect permissions on your API token",
            )
        )

    def test_dies_when_account_id_absent(self):
        self._assert_dies(
            lambda cmd, **kw: types.SimpleNamespace(
                returncode=0, stdout="account other | deadbeefdeadbeefdeadbeefdeadbeef", stderr=""
            )
        )

    def test_dies_when_wrangler_missing(self):
        def missing(cmd, **kwargs):
            raise FileNotFoundError()

        self._assert_dies(missing)


if __name__ == "__main__":
    unittest.main()
