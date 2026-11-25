#!/usr/bin/env python3
"""Check OFJ's Siri skill sources and (optionally) their built app resource."""

import argparse
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BUNDLE = ROOT / "Skills.skillsbundle"
INTENTS = ROOT / "OpenFoodJournal" / "Intents"
COMPILED_SKILLS = Path("Metadata.appintents/Skills.skillsc")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def tool_titles(intents):
    titles = set()
    for swift in intents.glob("*.swift"):
        # Only match declarations marked as Siri tools, including conditionally
        # marked ones. Do not treat unrelated App Intents as available to skills.
        titles.update(re.findall(
            r'@AppIntent\(\.tool\)\s*(?:#endif\s*)?struct\s+\w+[^\{]*\{\s*'
            r'static let title: LocalizedStringResource = "([^"]+)"',
            swift.read_text(encoding="utf-8"),
        ))
    require(titles, f"No Siri tool titles found in {intents}")
    return titles


def validate_bundle(bundle, titles):
    skills = bundle / "Skills"
    require(bundle.is_dir() and set(bundle.iterdir()) == {skills} and skills.is_dir(),
            f"{bundle}: expected exactly one Skills directory")
    directories = sorted(skills.iterdir())
    require(directories, f"{bundle}: no skills")

    for directory in directories:
        name = directory.name
        require(directory.is_dir() and len(name) <= 64 and
                re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", name),
                f"{directory}: invalid skill directory name")
        markdown = directory / "SKILL.md"
        require(set(directory.iterdir()) == {markdown} and markdown.is_file(),
                f"{directory}: expected only SKILL.md")
        lines = markdown.read_text(encoding="utf-8").splitlines()

        # OFJ uses the two required plain, single-line frontmatter values.
        require(len(lines) >= 5 and lines[0] == "---" and lines[3] == "---" and
                lines[1] == f"name: {name}" and lines[2].startswith("description: "),
                f"{markdown}: expected name and description matching the folder")
        description = lines[2].removeprefix("description: ")
        require(0 < len(description.strip()) <= 1024 and len(description) <= 1024,
                f"{markdown}: missing or too-long description")
        require(": " not in description and " #" not in description and
                description[0].isalnum(),
                f"{markdown}: description must be plain YAML text")
        body = "\n".join(lines[4:]).strip()
        require(0 < len(body) <= 10000, f"{markdown}: missing or too-long body")

        # Bold tool titles are our authoring convention, allowing a title
        # rename or typo to fail CI instead of silently degrading Siri routing.
        references = set(re.findall(r"\*\*([^*\n]+)\*\*", body))
        require(len(references) >= 2, f"{markdown}: expected a multi-tool workflow")
        unknown = references - titles
        require(not unknown, f"{markdown}: unknown tool titles: {', '.join(sorted(unknown))}")
        print(f"Validated {name} ({len(references)} tool references)")

    return len(directories)


def validate_app(app, *, preview):
    require(app.is_dir() and (app / "Info.plist").is_file(), f"App not found: {app}")
    raw = list(app.rglob("*.skillsbundle"))
    compiled = list(app.rglob("*.skillsc"))
    require(not raw, f"Uncompiled skills source found in {app}: {raw}")
    if preview:
        output = app / COMPILED_SKILLS
        require(output.is_file() and output.stat().st_size > 0,
                f"Missing or empty compiled Siri App Skills: {output}")
        print(f"Verified compiled Siri App Skills in {output}")
    else:
        require(not compiled, f"Standard build contains preview skills: {compiled}")
        print(f"Verified no preview skills in {app}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--app", type=Path, help="Require compiled skills in the preview app")
    mode.add_argument("--standard-app", type=Path, help="Require no skills in the standard app")
    args = parser.parse_args()
    try:
        count = validate_bundle(BUNDLE, tool_titles(INTENTS))
        print(f"Validated {count} Siri App Skills.")
        if args.app:
            validate_app(args.app, preview=True)
        elif args.standard_app:
            validate_app(args.standard_app, preview=False)
    except (OSError, ValueError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
