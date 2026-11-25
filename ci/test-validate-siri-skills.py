#!/usr/bin/env python3
"""Regression tests for the preview resource and source validation."""

import contextlib
import io
import runpy
import tempfile
import unittest
from pathlib import Path


validator = runpy.run_path(str(Path(__file__).with_name("validate-siri-skills.py")))
validate_bundle = validator["validate_bundle"]
validate_app = validator["validate_app"]
tool_titles = validator["tool_titles"]


class SkillsValidationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.bundle = self.root / "Skills.skillsbundle"
        self.skill = self.bundle / "Skills" / "test-skill"
        self.skill.mkdir(parents=True)
        self.markdown = self.skill / "SKILL.md"
        self.markdown.write_text(
            "---\nname: test-skill\ndescription: Test description\n---\n"
            "Call **Find Item** and then **Read Item**.\n", encoding="utf-8"
        )
        self.titles = {"Find Item", "Read Item"}
        self.app = self.root / "OpenFoodJournal.app"
        self.app.mkdir()
        (self.app / "Info.plist").touch()

    def test_real_bundle_references_existing_tools(self):
        self.assertGreater(validate_bundle(validator["BUNDLE"], tool_titles(validator["INTENTS"])), 0)

    def test_valid_skill(self):
        self.assertEqual(validate_bundle(self.bundle, self.titles), 1)

    def test_reject_mismatched_name(self):
        self.markdown.write_text(self.markdown.read_text().replace("name: test-skill", "name: other"))
        with self.assertRaisesRegex(ValueError, "matching the folder"):
            validate_bundle(self.bundle, self.titles)

    def test_reject_extra_file(self):
        (self.skill / "notes.md").touch()
        with self.assertRaisesRegex(ValueError, "expected only SKILL.md"):
            validate_bundle(self.bundle, self.titles)

    def test_reject_unknown_tool(self):
        with self.assertRaisesRegex(ValueError, "unknown tool titles: Read Item"):
            validate_bundle(self.bundle, {"Find Item"})

    def test_reject_extra_frontmatter(self):
        self.markdown.write_text(self.markdown.read_text().replace("description: Test description", "description: Test description\nversion: 1"))
        with self.assertRaisesRegex(ValueError, "expected name and description"):
            validate_bundle(self.bundle, self.titles)

    def test_preview_requires_nonempty_compiled_resource(self):
        compiled = self.app / validator["COMPILED_SKILLS"]
        with self.assertRaisesRegex(ValueError, "Missing or empty"):
            validate_app(self.app, preview=True)
        compiled.parent.mkdir()
        compiled.touch()
        with self.assertRaisesRegex(ValueError, "Missing or empty"):
            validate_app(self.app, preview=True)
        compiled.write_bytes(b"test fixture")
        validate_app(self.app, preview=True)
        with self.assertRaisesRegex(ValueError, "Standard build contains preview skills"):
            validate_app(self.app, preview=False)

    def test_no_raw_skills_in_either_build(self):
        validate_app(self.app, preview=False)
        (self.app / "Skills.skillsbundle").mkdir()
        for preview in (True, False):
            with self.assertRaisesRegex(ValueError, "Uncompiled skills source"):
                validate_app(self.app, preview=preview)


if __name__ == "__main__":
    with contextlib.redirect_stdout(io.StringIO()):
        unittest.main()
