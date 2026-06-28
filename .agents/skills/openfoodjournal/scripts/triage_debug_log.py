#!/usr/bin/env python3
"""Classify noisy OpenFoodJournal/Xcode debug logs.

The goal is not to replace a real debugger backtrace. It gives agents and
humans a quick first pass that collapses duplicated system noise and highlights
signals that probably need app-owned investigation.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path


@dataclass(frozen=True)
class Category:
    key: str
    title: str
    owner: str
    severity: str
    guidance: str
    patterns: tuple[re.Pattern[str], ...]


@dataclass
class MatchSummary:
    count: int = 0
    first_line: int | None = None
    samples: dict[str, int] = field(default_factory=dict)


def compile_patterns(*patterns: str) -> tuple[re.Pattern[str], ...]:
    return tuple(re.compile(pattern, re.IGNORECASE) for pattern in patterns)


CATEGORIES: tuple[Category, ...] = (
    Category(
        key="gemini_stream",
        title="Gemini scan/search instrumentation",
        owner="OpenFoodJournal",
        severity="info",
        guidance="Expected around scans. Investigate HTTP 4xx/5xx, parse failures, or missing final completion lines.",
        patterns=compile_patterns(r"Gemini", r"🧠", r"📐", r"📸"),
    ),
    Category(
        key="cloudkit_bg_task",
        title="SwiftData/CoreData CloudKit background task scheduling",
        owner="Apple framework",
        severity="watch",
        guidance="Usually framework scheduling noise when export activity is already active. Verify entitlements and actual sync before treating as app-owned.",
        patterns=compile_patterns(
            r"com\.apple\.coredata\.cloudkit\.activity\.export",
            r"BGSystemTaskSchedulerErrorDomain Code=3",
            r"updateTaskRequest (failed|called)",
        ),
    ),
    Category(
        key="coredata_maintenance",
        title="CoreData maintenance and checkpoint logging",
        owner="Apple framework",
        severity="low",
        guidance="Database vacuum/checkpoint rows are maintenance chatter, especially after many SwiftData writes. Investigate only with data loss, hangs, or failed saves.",
        patterns=compile_patterns(
            r"CoreData: debug: PostSaveMaintenance",
            r"CoreData: debug: WAL checkpoint",
            r"incremental_vacuum",
            r"Database did checkpoint",
        ),
    ),
    Category(
        key="unsafe_forced_sync",
        title="Swift concurrency unsafeForcedSync warning",
        owner="unknown without backtrace",
        severity="investigate",
        guidance="Requires a Swift runtime/concurrency breakpoint backtrace. Static log lines alone do not prove app ownership.",
        patterns=compile_patterns(r"unsafeForcedSync", r"Potential Structural Swift Concurrency Issue"),
    ),
    Category(
        key="keyboard_constraints",
        title="Keyboard/TextInput constraint noise",
        owner="Apple keyboard/TextInput",
        severity="low",
        guidance="Treat TUIKeyplane/TUIPrediction/RTI/dictation rows as system keyboard noise unless a stack points into an OpenFoodJournal view.",
        patterns=compile_patterns(
            r"TUIKeyplane",
            r"TUIPredictionViewCell",
            r"TUICandidate",
            r"RTIInputSystemClient",
            r"Got a keyboard will (change frame|hide) notification",
            r"_dictationButton",
            r"UIEmojiSearchOperations",
            r"variant selector cell",
        ),
    ),
    Category(
        key="glass_popover_constraints",
        title="UIKit glass popover/alert constraint warning",
        owner="Apple UIKit/SwiftUI presentation",
        severity="watch",
        guidance="Needs a symbolic breakpoint stack before app ownership is clear. If the stack enters an app confirmation dialog/menu, simplify that presentation.",
        patterns=compile_patterns(
            r"GlassPopoverContentViewRepresentable",
            r"_UIAlertControllerPhoneTVMacView",
        ),
    ),
    Category(
        key="liquid_glass",
        title="Liquid Glass per-frame update warning",
        owner="possibly app UI",
        severity="watch",
        guidance="Look for broad implicit animations or rapidly changing glass siblings. Prefer scoped explicit animations.",
        patterns=compile_patterns(r"glassEffect\(\) tried to update multiple times per frame"),
    ),
    Category(
        key="invalid_frame",
        title="Invalid frame dimension",
        owner="unknown from single line",
        severity="investigate",
        guidance="Needs a symbolic breakpoint stack. If adjacent constraints are TUI keyboard rows, classify with keyboard noise.",
        patterns=compile_patterns(r"Invalid frame dimension \(negative or non-finite\)"),
    ),
    Category(
        key="runningboard",
        title="RunningBoard/process-state entitlement noise",
        owner="Apple framework/debugger",
        severity="low",
        guidance="Usually debugger/process accounting noise, not an app entitlement request.",
        patterns=compile_patterns(r"RBSServiceErrorDomain", r"runningboard", r"FrontBoard", r"task port"),
    ),
    Category(
        key="launchservices_permission",
        title="LaunchServices database permission noise",
        owner="Apple LaunchServices/debugger",
        severity="low",
        guidance="Common when extensions or debugger-adjacent processes cannot map the LaunchServices database. Ignore unless app launch/open-url behavior is broken.",
        patterns=compile_patterns(
            r"LaunchServices:.*process may not map database",
            r"Attempt to map database failed",
            r"LSDReadService",
        ),
    ),
    Category(
        key="user_manager_persona",
        title="UserManager/persona XPC invalidation",
        owner="Apple framework",
        severity="low",
        guidance="Usually system persona/account lookup noise from the debug session. Ignore unless sign-in/account switching behavior is broken.",
        patterns=compile_patterns(
            r"mobile\.usermanagerd\.xpc",
            r"personaAttributesForPersonaType",
        ),
    ),
    Category(
        key="ui_context_menu",
        title="UIKit context menu visibility notice",
        owner="Apple UIKit",
        severity="low",
        guidance="A no-op UIKit notice when a menu update races with dismissal. Ignore unless a visible context menu fails to update.",
        patterns=compile_patterns(r"updateVisibleMenuWithBlock.*no context menu is visible"),
    ),
    Category(
        key="network_noise",
        title="Network framework noise",
        owner="Apple Network framework",
        severity="low",
        guidance="UDP/TCP cleanup messages are common around URLSession streams. Investigate only when paired with request failure.",
        patterns=compile_patterns(r"nw_protocol", r"tcp_output"),
    ),
    Category(
        key="pointer_ui",
        title="Pointer UI service noise",
        owner="Apple PointerUI",
        severity="low",
        guidance="Harmless on iPhone unless pointer interactions fail visibly.",
        patterns=compile_patterns(r"PointerUI", r"pointeruid"),
    ),
    Category(
        key="legacy_unarchive",
        title="NSKeyedUnarchiveFromData deprecation warning",
        owner="likely framework or persisted system data",
        severity="watch",
        guidance="Search app code before acting. If app code does not call it, keep as framework noise.",
        patterns=compile_patterns(r"NSKeyedUnarchiveFromData"),
    ),
)


ADDRESS_RE = re.compile(r"0x[0-9a-fA-F]+")
UUID_RE = re.compile(r"\b[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\b")
REPORTER_RE = re.compile(r"reporterID=\d+")


def normalize(line: str) -> str:
    line = ADDRESS_RE.sub("0xADDR", line.strip())
    line = UUID_RE.sub("UUID", line)
    line = REPORTER_RE.sub("reporterID=N", line)
    return line


def category_for(line: str) -> Category | None:
    for category in CATEGORIES:
        if any(pattern.search(line) for pattern in category.patterns):
            return category
    return None


def summarize(lines: list[str], sample_limit: int) -> dict[str, MatchSummary]:
    summaries = {category.key: MatchSummary() for category in CATEGORIES}

    for line_number, line in enumerate(lines, start=1):
        category = category_for(line)
        if category is None:
            continue

        summary = summaries[category.key]
        summary.count += 1
        if summary.first_line is None:
            summary.first_line = line_number

        sample = normalize(line)
        if sample and sample not in summary.samples and len(summary.samples) < sample_limit:
            summary.samples[sample] = line_number

    return summaries


def print_markdown(summaries: dict[str, MatchSummary]) -> None:
    print("| Category | Count | First Line | Owner | Severity | Guidance |")
    print("| --- | ---: | ---: | --- | --- | --- |")
    for category in CATEGORIES:
        summary = summaries[category.key]
        if summary.count == 0:
            continue
        print(
            f"| {category.title} | {summary.count} | {summary.first_line} | "
            f"{category.owner} | {category.severity} | {category.guidance} |"
        )

    print("\n## Deduped Samples")
    for category in CATEGORIES:
        summary = summaries[category.key]
        if summary.count == 0:
            continue
        print(f"\n### {category.title}")
        for sample, line_number in summary.samples.items():
            print(f"- line {line_number}: `{sample}`")


def load_lines(path: str | None) -> list[str]:
    if path is None or path == "-":
        return sys.stdin.read().splitlines()
    return Path(path).read_text(encoding="utf-8", errors="replace").splitlines()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log_file", nargs="?", help="Debug log file to classify. Reads stdin when omitted or '-'.")
    parser.add_argument("--sample-limit", type=int, default=5, help="Deduped sample lines per category.")
    args = parser.parse_args()

    lines = load_lines(args.log_file)
    print_markdown(summarize(lines, max(1, args.sample_limit)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
