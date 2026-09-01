#!/usr/bin/env python3
"""Build once, capture selected screens, and export a checked PNG gallery."""

import datetime
import hashlib
import html
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

SCREENS = ("journal", "scan", "food-bank", "log-food", "history", "assistant", "settings")
DEVICES = ("iPhone 17 Pro", "iPhone 17 Pro Max")


def selections(value, allowed):
    result = list(allowed) if value == "all" else [part.strip() for part in value.split(",")]
    if not result or any(part not in allowed for part in result) or len(result) != len(set(result)):
        raise ValueError(f"Choose all or unique values from: {', '.join(allowed)}")
    return result


def export_images(export_root, output, selected, appearance):
    manifest = json.loads((export_root / "manifest.json").read_text())
    records = []
    for test in manifest:
        for attachment in test["attachments"]:
            match = re.search(r"ofj--([a-z-]+)--(light|dark)(?![a-z])", attachment["suggestedHumanReadableName"])
            if not match:
                continue
            screen, theme = match.groups()
            if screen not in selected or theme != appearance:
                raise ValueError(f"Unexpected screenshot: {screen}/{theme}")
            source = (export_root / attachment["exportedFileName"]).resolve()
            if not source.is_relative_to(export_root.resolve()):
                raise ValueError("Attachment path escaped export directory")
            data = source.read_bytes()
            if data[:8] != b"\x89PNG\r\n\x1a\n" or len(data) < 24:
                raise ValueError("Screenshot is not a valid PNG")
            name = f"{screen}-{theme}.png"
            destination = output / name
            if destination.exists():
                raise ValueError(f"Duplicate screenshot: {name}")
            shutil.copyfile(source, destination)
            records.append({"screen": screen, "appearance": theme, "file": name,
                            "width": int.from_bytes(data[16:20], "big"),
                            "height": int.from_bytes(data[20:24], "big"),
                            "sha256": hashlib.sha256(data).hexdigest()})
    if {record["screen"] for record in records} != set(selected):
        raise ValueError("Some requested screenshots are missing from the test attachments")
    records.sort(key=lambda record: selected.index(record["screen"]))
    return records


def write_gallery(output, manifest):
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    cards = "\n".join(
        f'<figure><a href="{html.escape(item["file"])}"><img loading="lazy" '
        f'src="{html.escape(item["file"])}" alt="{html.escape(item["screen"])} '
        f'{html.escape(item["appearance"])}"></a><figcaption>'
        f'{html.escape(item["screen"])} · {html.escape(item["appearance"])} '
        f'· {item["width"]} × {item["height"]}</figcaption></figure>'
        for item in manifest["images"]
    )
    status = "Complete" if manifest["complete"] else "Incomplete — inspect CI diagnostics"
    page = f'''<!doctype html><html lang="en"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>OpenFoodJournal screenshots</title><style>
body{{font:16px system-ui;margin:32px;background:#f5f5f7;color:#171719}}
main{{max-width:1440px;margin:auto}}h1{{margin-bottom:8px}}p{{color:#555}}
.grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:24px}}
figure{{margin:0}}img{{display:block;width:100%;height:auto;border-radius:20px}}
figcaption{{padding:12px 0;font-size:14px}}code{{overflow-wrap:anywhere}}</style>
<main><h1>OpenFoodJournal screenshots</h1><p>{status}. Synthetic test data; no personal records.</p>
<p>{html.escape(manifest.get("device", ""))} · Fixed date: August 12, 2026 · en_US · Large text</p>
<p>Source: <code>{html.escape(manifest["commit"])}</code></p><div class="grid">{cards}</div></main></html>'''
    (output / "index.html").write_text(page)


def main():
    selected = selections(os.environ.get("SCREENSHOT_SCREENS", "all"), SCREENS)
    appearance = os.environ.get("SCREENSHOT_APPEARANCE", "both")
    if appearance not in ("both", "light", "dark"):
        raise ValueError("Appearance must be both, light, or dark")
    appearances = ["light", "dark"] if appearance == "both" else [appearance]
    device_name = os.environ.get("SCREENSHOT_DEVICE", DEVICES[0])
    if device_name not in DEVICES:
        raise ValueError("Unsupported screenshot device")
    temporary = Path(os.environ["RUNNER_TEMP"])
    output = temporary / "screenshot-gallery"
    diagnostics = temporary / "screenshot-diagnostics"
    output.mkdir(parents=True, exist_ok=False)
    diagnostics.mkdir(parents=True, exist_ok=True)
    manifest = {"commit": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
                "device": device_name, "screens": selected, "appearances": appearances,
                "fixtureDate": "2026-08-12T12:00:00Z", "locale": "en_US", "dynamicType": "Large",
                "generatedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "complete": False, "images": [], "tests": {}}
    if "scan" in selected:
        manifest["scanPreview"] = "White placeholder; simulated zoom/torch; no camera, Photos, or inference access"

    def run(name, arguments, environment=None, check=True):
        print(f"SCREENSHOTS: {name}", flush=True)
        log = diagnostics / f"{name}.log"
        with log.open("w") as stream:
            result = subprocess.run(arguments, stdout=stream, stderr=subprocess.STDOUT,
                                    env=environment, timeout=1_200)
        if check and result.returncode:
            print(log.read_text()[-16_000:], flush=True)
            raise RuntimeError(f"{name} failed ({result.returncode})")
        return result.returncode, log.read_text()

    boot = None
    boot_stream = None
    try:
        _, devices_json = run("list-devices", ["xcrun", "simctl", "list", "devices", "available", "--json"])
        available = json.loads(devices_json)["devices"]
        candidates = [(runtime, device) for runtime, devices in available.items()
                      if ".iOS-26-" in runtime for device in devices if device["name"] == device_name]
        if not candidates:
            raise RuntimeError(f"No available iOS 26 simulator named {device_name}")
        runtime, device = max(candidates, key=lambda item: tuple(int(n) for n in re.findall(r"\d+", item[0])))
        identifier = device["udid"]
        manifest["runtime"] = runtime
        if device["state"] != "Booted":
            run("boot", ["xcrun", "simctl", "boot", identifier])
        boot_stream = (diagnostics / "boot-status.log").open("w")
        boot = subprocess.Popen(["xcrun", "simctl", "bootstatus", identifier, "-b"],
                                stdout=boot_stream, stderr=subprocess.STDOUT)
        build = ["xcodebuild", "-project", "OpenFoodJournal.xcodeproj", "-scheme", "OpenFoodJournalScreenshots",
                 "-destination", f"platform=iOS Simulator,id={identifier},arch=arm64",
                 "-derivedDataPath", str(temporary / "ScreenshotDerivedData"),
                 "-parallel-testing-enabled", "NO", "CODE_SIGNING_ALLOWED=NO"]
        run("build", build + ["build-for-testing"])
        if boot.wait(timeout=300):
            raise RuntimeError("Simulator boot failed")
        run("status-bar", ["xcrun", "simctl", "status_bar", identifier, "override", "--time", "9:41",
                           "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3",
                           "--batteryState", "charged", "--batteryLevel", "100"])
        for theme in appearances:
            run(f"appearance-{theme}", ["xcrun", "simctl", "ui", identifier, "appearance", theme])
            environment = os.environ.copy()
            environment.update({"TEST_RUNNER_OFJ_CAPTURE_SCREENSHOTS": "1",
                                "TEST_RUNNER_OFJ_SCREENSHOT_SCREENS": ",".join(selected),
                                "TEST_RUNNER_OFJ_SCREENSHOT_APPEARANCE": theme})
            bundle = diagnostics / f"screenshots-{theme}.xcresult"
            code, _ = run(f"test-{theme}", build + ["-resultBundlePath", str(bundle),
                         "-only-testing:OpenFoodJournalUITests/ScreenshotTests/testCaptureSelectedScreens",
                         "test-without-building"], environment, check=False)
            if bundle.exists():
                exported = temporary / f"screenshot-export-{theme}"
                run(f"export-{theme}", ["xcrun", "xcresulttool", "export", "attachments",
                    "--path", str(bundle), "--output-path", str(exported)])
                _, summary = run(f"summary-{theme}", ["xcrun", "xcresulttool", "get", "test-results", "summary",
                                                     "--path", str(bundle)])
                results = json.loads(summary)
                manifest["tests"][theme] = {key: results.get(key) for key in ["passedTests", "failedTests", "skippedTests"]}
                manifest["images"].extend(export_images(exported, output, selected, theme))
                if results.get("passedTests") != 1 or results.get("failedTests") != 0 or results.get("skippedTests") != 0:
                    raise RuntimeError(f"{theme} screenshot test did not pass without skips")
            if code:
                raise RuntimeError(f"{theme} screenshot test failed; inspect test-{theme}.log")
        if len(manifest["images"]) != len(selected) * len(appearances):
            raise RuntimeError("Screenshot count does not match the requested gallery")
        manifest["complete"] = True
    finally:
        if boot is not None and boot.poll() is None:
            boot.terminate()
            boot.wait(timeout=10)
        if boot_stream is not None:
            boot_stream.close()
        write_gallery(output, manifest)
        print(json.dumps(manifest, indent=2), flush=True)


if __name__ == "__main__":
    main()
