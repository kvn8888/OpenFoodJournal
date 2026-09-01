#!/usr/bin/env python3
"""Check that missing, mismatched, or unsafe attachments cannot pass export."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("screenshots", Path(__file__).with_name("generate-screenshots.py"))
screenshots = importlib.util.module_from_spec(spec)
spec.loader.exec_module(screenshots)


class ScreenshotExportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.exported = self.root / "exported"
        self.output = self.root / "gallery"
        self.exported.mkdir()
        self.output.mkdir()
        # A known 1x1 PNG; image bytes are only fixtures for the export contract.
        import base64
        (self.exported / "image.png").write_bytes(base64.b64decode(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="))

    def manifest(self, name="ofj--journal--light.png", filename="image.png"):
        (self.exported / "manifest.json").write_text(json.dumps([
            {"attachments": [{"suggestedHumanReadableName": name, "exportedFileName": filename}]}]))

    def test_exports_named_png_and_dimensions(self):
        self.manifest()
        result = screenshots.export_images(self.exported, self.output, ["journal"], "light")
        self.assertEqual(result[0]["file"], "journal-light.png")
        self.assertEqual((result[0]["width"], result[0]["height"]), (1, 1))

    def test_missing_requested_screen_fails(self):
        self.manifest()
        with self.assertRaisesRegex(ValueError, "missing"):
            screenshots.export_images(self.exported, self.output, ["journal", "history"], "light")

    def test_wrong_appearance_fails(self):
        self.manifest("ofj--journal--dark.png")
        with self.assertRaisesRegex(ValueError, "Unexpected"):
            screenshots.export_images(self.exported, self.output, ["journal"], "light")

    def test_path_escape_fails(self):
        self.manifest(filename="../private.png")
        with self.assertRaisesRegex(ValueError, "escaped"):
            screenshots.export_images(self.exported, self.output, ["journal"], "light")

    def test_duplicate_file_fails(self):
        self.manifest()
        screenshots.export_images(self.exported, self.output, ["journal"], "light")
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            screenshots.export_images(self.exported, self.output, ["journal"], "light")

    def test_input_selection_rejects_unknown_and_duplicate_values(self):
        for value in ["", "journal,journal", "../secret", "journal; echo nope"]:
            with self.assertRaises(ValueError):
                screenshots.selections(value, screenshots.SCREENS)


if __name__ == "__main__":
    unittest.main()
