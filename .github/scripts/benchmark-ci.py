#!/usr/bin/env python3
"""Compare CI startup strategies without credentials, signing, or publishing.

The canary deliberately stops at its missing-key guard. This measures its
build/launch cost and verifies environment forwarding, not the Gemini API.
"""

import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time


mode = sys.argv[1]
if mode not in {"baseline-validation", "baseline-canary", "early-boot-reuse"}:
    raise SystemExit(f"Unknown benchmark mode: {mode}")

root = Path(os.environ["RUNNER_TEMP"]) / "ci-benchmark"
root.mkdir(parents=True, exist_ok=True)
metrics = {
    "mode": mode,
    "commit": os.environ["GITHUB_SHA"],
    "repetition": os.environ["BENCHMARK_REPETITION"],
    "image_version": os.environ.get("ImageVersion"),
    "started_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "phases": [],
    "complete": False,
    "live_api_called": False,
}
started = time.monotonic()
boot = None
boot_log = None
base = ["xcodebuild", "-project", "OpenFoodJournal.xcodeproj"]
derived = Path(os.environ["RUNNER_TEMP"]) / "DerivedData-benchmark-simulator"
canary_id = "OpenFoodJournalTests/ChatLiveProviderTests/testGeminiFoodIconImageLiveContract"


def run(name, command, extra_env=None):
    begin = time.monotonic()
    env = os.environ.copy()
    env.update(extra_env or {})
    record = {"name": name, "start_seconds": round(begin - started, 3)}
    metrics["phases"].append(record)
    print(f"BENCHMARK START {name}", flush=True)
    try:
        with (root / f"{name}.log").open("w") as output:
            result = subprocess.run(command, env=env, stdout=output,
                                    stderr=subprocess.STDOUT, timeout=1200)
        record["exit_code"] = result.returncode
        if result.returncode:
            print((root / f"{name}.log").read_text()[-16000:], flush=True)
            raise RuntimeError(f"{name} exited {result.returncode}")
    finally:
        record["duration_seconds"] = round(time.monotonic() - begin, 3)
        print(f"BENCHMARK END {name}: {record['duration_seconds']}s", flush=True)
    return (root / f"{name}.log").read_text()


def select_simulator():
    devices = json.loads(run("select-simulator", ["xcrun", "simctl", "list",
                                                "devices", "available", "--json"]))
    # Match the production selector so a device/runtime change cannot explain
    # a measured improvement. Record the selected runtime for comparison.
    for runtime, entries in devices["devices"].items():
        for device in entries:
            if device["name"].startswith("iPhone"):
                metrics["simulator"] = {"runtime": runtime, "name": device["name"],
                                        "initial_state": device["state"]}
                return device["udid"]
    raise RuntimeError("No available iPhone simulator")


def unit_command(simulator, action, result=None):
    command = base + ["-scheme", "OpenFoodJournalUnitTests", "-destination",
                      f"platform=iOS Simulator,id={simulator}",
                      "-derivedDataPath", str(derived),
                      "-parallel-testing-enabled", "NO", "CODE_SIGNING_ALLOWED=NO"]
    if result:
        command += ["-resultBundlePath", str(result)]
    return command + [action]


def export_summary(name, bundle):
    run(name, ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle)])
    (root / f"{name}.json").write_text((root / f"{name}.log").read_text())


def validate_units(log):
    match = re.search(r"Test run with (\d+) tests in (\d+) suites passed after ([\d.]+) seconds", log)
    if not match:
        raise RuntimeError("Missing successful Swift Testing suite summary")
    metrics["unit_tests"] = {"passed": int(match[1]), "suites": int(match[2]),
                              "execution_seconds": float(match[3])}
    if int(match[1]) < 200:
        raise RuntimeError("Unexpectedly low test count; benchmark coverage changed")


def canary_probe(simulator, action):
    bundle = Path(os.environ["RUNNER_TEMP"]) / "CanaryProbe.xcresult"
    command = unit_command(simulator, action, bundle)
    command.insert(-1, f"-only-testing:{canary_id}")
    log = run("canary-probe", command, {
        "TEST_RUNNER_OFJ_RUN_LIVE_GEMINI_IMAGE_TESTS": "1",
        "TEST_RUNNER_OFJ_GEMINI_API_KEY": "",
        "OFJ_GEMINI_API_KEY": "",
    })
    expected = "Missing OFJ_GEMINI_API_KEY; this provider's live contract is skipped."
    if expected not in log or "Executed 1 test, with 1 test skipped" not in log:
        raise RuntimeError("Canary did not reach the expected missing-key guard")
    if "Test skipped - Set OFJ_RUN_LIVE_GEMINI_IMAGE_TESTS=1" in log:
        raise RuntimeError("The enable flag did not reach the test process")
    metrics["canary_probe"] = {"environment_forwarded": True,
                               "expected_skipped_tests": 1,
                               "live_api_validated": False}
    export_summary("canary-summary", bundle)


try:
    if mode == "baseline-canary":
        simulator = select_simulator()
        canary_probe(simulator, "test")
    else:
        if mode == "early-boot-reuse":
            simulator = select_simulator()
            run("request-simulator-boot", ["xcrun", "simctl", "boot", simulator])
            boot_log = (root / "simulator-boot.log").open("w")
            boot = subprocess.Popen(["xcrun", "simctl", "bootstatus", simulator, "-b"],
                                    stdout=boot_log, stderr=subprocess.STDOUT)
            metrics["boot_requested_at_seconds"] = round(time.monotonic() - started, 3)

        run("release-contracts", ["bash", ".github/scripts/test-release-workflow.sh"])
        run("isolation-contracts", ["bash", ".github/scripts/test-debug-isolation.sh"])
        run("generic-device-build", base + ["-scheme", "OpenFoodJournal", "-destination",
            "generic/platform=iOS", "-derivedDataPath",
            str(Path(os.environ["RUNNER_TEMP"]) / "DerivedData-benchmark-generic"),
            "CODE_SIGNING_ALLOWED=NO", "build-for-testing"])

        bundle = Path(os.environ["RUNNER_TEMP"]) / "UnitTests.xcresult"
        if mode == "baseline-validation":
            simulator = select_simulator()
            log = run("simulator-build-and-test", unit_command(simulator, "test", bundle))
        else:
            run("simulator-build", unit_command(simulator, "build-for-testing"))
            boot_wait_start = time.monotonic()
            if boot.wait(timeout=300):
                raise RuntimeError("Simulator boot failed")
            metrics["remaining_boot_wait_seconds"] = round(time.monotonic() - boot_wait_start, 3)
            log = run("simulator-test-without-building", unit_command(simulator, "test-without-building", bundle))

        validate_units(log)
        export_summary("unit-summary", bundle)
        if mode == "early-boot-reuse":
            canary_probe(simulator, "test-without-building")
    metrics["complete"] = True
except Exception as error:
    metrics["error"] = str(error)
    raise
finally:
    if boot is not None and boot.poll() is None:
        boot.terminate()
        boot.wait(timeout=10)
    if boot_log is not None:
        boot_log.close()
    metrics["total_seconds"] = round(time.monotonic() - started, 3)
    (root / "metrics.json").write_text(json.dumps(metrics, indent=2) + "\n")
    print(json.dumps(metrics, indent=2), flush=True)
