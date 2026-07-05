import importlib.util
import os
import pathlib
import sys
import tempfile
import types
import unittest
from datetime import datetime, timezone
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
        item = module.build_item(
            module.APP_CONFIG["sol"],
            "1.3.0",
            9,
            "signature",
            123,
            "https://example.com/app.dmg",
            "### test\n- one",
        )
        description = item.find("description")

        self.assertIsNotNone(description)
        self.assertEqual(description.get(f"{{{module.SPARKLE_NS}}}format"), "markdown")

    def test_description_text_is_byte_identical_to_notes_argument(self):
        module = load_publish_appcast()
        notes = "### test\n- one"
        item = module.build_item(
            module.APP_CONFIG["sol"],
            "1.3.0",
            9,
            "signature",
            123,
            "https://example.com/app.dmg",
            notes,
        )
        description = item.find("description")

        self.assertIsNotNone(description)
        self.assertEqual(description.text, notes)

    def test_sol_pubdate_can_be_frozen_and_dmg_name_is_sol_prefixed(self):
        module = load_publish_appcast()
        config = module.APP_CONFIG["sol"]
        dmg_name = config["dmg_name"].format(version="1.2.3")
        item = module.build_item(
            config,
            "1.2.3",
            9,
            "signature",
            123,
            f"https://example.com/{dmg_name}",
            "notes",
            now=datetime(2026, 7, 5, 12, 34, tzinfo=timezone.utc),
        )

        self.assertEqual(dmg_name, "sol-1.2.3.dmg")
        self.assertEqual(item.find("pubDate").text, "Sun, 05 Jul 2026 12:34:00 GMT")
        self.assertTrue(item.find("enclosure").get("url").endswith("/sol-1.2.3.dmg"))


class AppConfigTest(unittest.TestCase):
    def test_per_app_mapping_isolated(self):
        module = load_publish_appcast()
        sol = module.APP_CONFIG["sol"]
        journal = module.APP_CONFIG["journal"]

        self.assertEqual(sol["prod_prefix"], "solstone-macos")
        self.assertEqual(sol["staging_prefix"], "solstone-macos/_staging")
        self.assertEqual(sol["plist_path"], "Sources/solstone/Info.plist")
        self.assertEqual(sol["changelog_path"], "CHANGELOG.md")
        self.assertEqual(sol["dmg_name"].format(version="1.2.3"), "sol-1.2.3.dmg")
        self.assertEqual(sol["item_title"].format(version="1.2.3"), "Solstone 1.2.3")

        self.assertEqual(journal["prod_prefix"], "journal-macos")
        self.assertEqual(journal["staging_prefix"], "journal-macos/_staging")
        self.assertEqual(journal["plist_path"], "Sources/journal/Info.plist")
        self.assertEqual(journal["changelog_path"], "CHANGELOG-journal.md")
        self.assertEqual(journal["dmg_name"].format(version="1.0.0"), "journal-1.0.0.dmg")
        self.assertEqual(journal["item_title"].format(version="1.0.0"), "journal 1.0.0")
        self.assertNotEqual(journal["plist_path"], sol["plist_path"])


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


class PreflightR2Test(unittest.TestCase):
    def fake_modules(self, fake_client):
        class FakeConfig:
            def __init__(self, **kwargs):
                self.kwargs = kwargs

        fake_boto3 = types.ModuleType("boto3")
        fake_boto3.client = fake_client
        fake_config_module = types.ModuleType("botocore.config")
        fake_config_module.Config = FakeConfig
        fake_botocore = types.ModuleType("botocore")
        fake_botocore.config = fake_config_module
        return {
            "boto3": fake_boto3,
            "botocore": fake_botocore,
            "botocore.config": fake_config_module,
        }

    def test_preflight_r2_lists_bucket_with_upload_client_kwargs(self):
        module = load_publish_appcast()
        client_calls = []
        list_calls = []

        class FakeClient:
            def list_objects_v2(self, **kwargs):
                list_calls.append(kwargs)
                return {}

        def fake_client(service, **kwargs):
            client_calls.append((service, kwargs))
            return FakeClient()

        with mock.patch.dict(sys.modules, self.fake_modules(fake_client)), \
             mock.patch.object(module, "load_r2_credentials", return_value={
                 "endpoint": "https://r2.example",
                 "access_key_id": "access",
                 "secret_access_key": "secret",
             }):
            module.preflight_r2()

        self.assertEqual(len(client_calls), 1)
        service, kwargs = client_calls[0]
        self.assertEqual(service, "s3")
        self.assertEqual(kwargs["endpoint_url"], "https://r2.example")
        self.assertEqual(kwargs["aws_access_key_id"], "access")
        self.assertEqual(kwargs["aws_secret_access_key"], "secret")
        self.assertEqual(kwargs["region_name"], "auto")
        self.assertEqual(kwargs["config"].kwargs, {"signature_version": "s3v4"})
        self.assertEqual(list_calls, [{"Bucket": module.R2_BUCKET, "MaxKeys": 1}])

    def test_preflight_r2_client_error_dies(self):
        module = load_publish_appcast()

        class FakeClient:
            def list_objects_v2(self, **kwargs):
                raise RuntimeError("denied")

        def fake_client(service, **kwargs):
            return FakeClient()

        with mock.patch.dict(sys.modules, self.fake_modules(fake_client)), \
             mock.patch.object(module, "load_r2_credentials", return_value={
                 "endpoint": "https://r2.example",
                 "access_key_id": "access",
                 "secret_access_key": "secret",
             }):
            with self.assertRaises(SystemExit) as ctx:
                module.preflight_r2()

        self.assertEqual(ctx.exception.code, 1)


class UploadRoutingTest(unittest.TestCase):
    def test_small_upload_uses_wrangler(self):
        module = load_publish_appcast()
        with tempfile.NamedTemporaryFile() as tmp:
            tmp.write(b"small")
            tmp.flush()
            calls = []

            def fake_run(cmd, **kwargs):
                calls.append(cmd)
                return types.SimpleNamespace(returncode=0, stdout="", stderr="")

            with mock.patch.object(module, "run", fake_run), mock.patch.object(module, "upload_r2_s3") as s3:
                module.upload(tmp.name, "path/object.txt", "text/plain")

        self.assertFalse(s3.called)
        self.assertEqual(calls[0][0:4], ["wrangler", "r2", "object", "put"])
        self.assertIn("solstone-updates/path/object.txt", calls[0])

    def test_large_upload_uses_r2_s3_fallback(self):
        module = load_publish_appcast()
        with tempfile.NamedTemporaryFile() as tmp:
            with mock.patch.object(os.path, "getsize", return_value=module.WRANGLER_MAX_UPLOAD_BYTES + 1), \
                 mock.patch.object(module, "run") as run, \
                 mock.patch.object(module, "upload_r2_s3") as s3:
                module.upload(tmp.name, "path/object.dmg", "application/x-apple-diskimage")

        self.assertFalse(run.called)
        s3.assert_called_once_with(tmp.name, "path/object.dmg", "application/x-apple-diskimage")


class Appcast404Test(unittest.TestCase):
    def test_404_without_first_publish_dies(self):
        module = load_publish_appcast()

        def fake_run(cmd, **kwargs):
            return types.SimpleNamespace(returncode=0, stdout="404", stderr="")

        with mock.patch.object(sys, "argv", ["publish-appcast.py", "1.3.31", "--app", "sol"]), \
             mock.patch.object(module, "preflight_wrangler"), \
             mock.patch.object(module, "preflight_r2"), \
             mock.patch.object(module, "load_private_key", return_value=object()), \
             mock.patch.object(module, "sign_dmg", return_value=("signature", 123)), \
             mock.patch.object(module, "read_info_plist", return_value=31), \
             mock.patch.object(module, "extract_release_notes", return_value="notes"), \
             mock.patch.object(module, "run", fake_run), \
             mock.patch.object(module, "seed_appcast", wraps=module.seed_appcast) as seed, \
             mock.patch.object(module, "upload") as upload:
            with self.assertRaises(SystemExit) as ctx:
                module.main()

        self.assertEqual(ctx.exception.code, 1)
        seed.assert_not_called()
        upload.assert_not_called()

    def test_404_with_first_publish_seeds(self):
        module = load_publish_appcast()

        def fake_run(cmd, **kwargs):
            return types.SimpleNamespace(returncode=0, stdout="404", stderr="")

        with mock.patch.object(sys, "argv", ["publish-appcast.py", "1.3.31", "--app", "sol", "--first-publish"]), \
             mock.patch.object(module, "preflight_wrangler"), \
             mock.patch.object(module, "preflight_r2"), \
             mock.patch.object(module, "load_private_key", return_value=object()), \
             mock.patch.object(module, "sign_dmg", return_value=("signature", 123)), \
             mock.patch.object(module, "read_info_plist", return_value=31), \
             mock.patch.object(module, "extract_release_notes", return_value="notes"), \
             mock.patch.object(module, "run", fake_run), \
             mock.patch.object(module, "seed_appcast", wraps=module.seed_appcast) as seed, \
             mock.patch.object(module, "upload") as upload, \
             mock.patch.object(module, "head_check"):
            module.main()

        seed.assert_called_once_with(module.APP_CONFIG["sol"], module.APP_CONFIG["sol"]["prod_prefix"])
        self.assertEqual(upload.call_count, 2)

    def test_journal_staging_first_publish_uses_journal_paths(self):
        module = load_publish_appcast()
        plist_paths = []

        def fake_run(cmd, **kwargs):
            return types.SimpleNamespace(returncode=0, stdout="404", stderr="")

        def fake_read_info(version, plist_path):
            plist_paths.append(plist_path)
            return 1

        with mock.patch.object(sys, "argv", [
            "publish-appcast.py",
            "1.0.0",
            "--app",
            "journal",
            "--staging",
            "--first-publish",
        ]), \
             mock.patch.object(module, "preflight_wrangler"), \
             mock.patch.object(module, "preflight_r2"), \
             mock.patch.object(module, "load_private_key", return_value=object()), \
             mock.patch.object(module, "sign_dmg", return_value=("signature", 123)), \
             mock.patch.object(module, "read_info_plist", side_effect=fake_read_info), \
             mock.patch.object(module, "extract_release_notes", return_value="notes"), \
             mock.patch.object(module, "run", fake_run), \
             mock.patch.object(module, "seed_appcast", wraps=module.seed_appcast) as seed, \
             mock.patch.object(module, "upload") as upload, \
             mock.patch.object(module, "head_check"):
            module.main()

        self.assertEqual(plist_paths, ["Sources/journal/Info.plist"])
        seed.assert_called_once_with(module.APP_CONFIG["journal"], module.APP_CONFIG["journal"]["staging_prefix"])
        self.assertEqual(upload.call_args_list[0].args[1], "journal-macos/_staging/releases/v1.0.0/journal-1.0.0.dmg")
        self.assertEqual(upload.call_args_list[1].args[1], "journal-macos/_staging/appcast.xml")


if __name__ == "__main__":
    unittest.main()
