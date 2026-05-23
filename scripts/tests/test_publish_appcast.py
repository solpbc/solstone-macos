import importlib.util
import pathlib
import unittest


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


if __name__ == "__main__":
    unittest.main()
