#!/usr/bin/env python3
"""Compare sequential and parallel validation, including actual overlap."""

from datetime import datetime
import json
from pathlib import Path
import statistics
import sys

root = Path(sys.argv[1])
records = [json.loads(p.read_text()) for p in sorted(root.glob("*/metrics.json"))]
if len(records) != 6 or not all(j["complete"] for j in records):
    raise SystemExit("Expected six successful benchmark records")
for field in ["commit", "image_version"]:
    if len({j[field] for j in records}) != 1:
        raise SystemExit(f"Different {field} values")
simulators = [j["simulator"] for j in records if "simulator" in j]
if len(simulators) != 4 or any(s != simulators[0] for s in simulators):
    raise SystemExit("Simulator configurations differ")

index = {(j["mode"], j["repetition"]): j for j in records}
required_device = {"release-contracts", "isolation-contracts", "generic-device-build"}
required_simulator = {"select-simulator", "request-simulator-boot", "simulator-build",
                      "simulator-test-without-building", "unit-summary", "canary-probe", "canary-summary"}
comparisons = []
for repetition in ["1", "2"]:
    device = index[("parallel-device", repetition)]
    simulator = index[("parallel-simulator", repetition)]
    control = index[("early-boot-reuse", repetition)]
    if not required_device.issubset({p["name"] for p in device["phases"]}):
        raise SystemExit("Missing device validation")
    if not required_simulator.issubset({p["name"] for p in simulator["phases"]}):
        raise SystemExit("Missing simulator validation")
    if control["unit_tests"]["passed"] != simulator["unit_tests"]["passed"]:
        raise SystemExit("Unit test counts differ")
    if not all(j["canary_probe"]["environment_forwarded"] for j in [control, simulator]):
        raise SystemExit("Test environment forwarding failed")
    starts = [datetime.fromisoformat(j["started_at"]).timestamp() for j in [device, simulator]]
    ends = [start + j["total_seconds"] for start, j in zip(starts, [device, simulator])]
    observed = max(ends) - min(starts)
    parallel_work = max(device["total_seconds"], simulator["total_seconds"])
    comparisons.append({
        "repetition": repetition,
        "sequential_seconds": control["total_seconds"],
        "device_seconds": device["total_seconds"],
        "simulator_seconds": simulator["total_seconds"],
        "parallel_work_seconds": parallel_work,
        "observed_parallel_window_seconds": round(observed, 3),
        "overlap_seconds": round(max(0, min(ends) - max(starts)), 3),
        "parallel_total_machine_seconds": round(device["total_seconds"] + simulator["total_seconds"], 3),
        "saved_observed_seconds": round(control["total_seconds"] - observed, 3),
        "passed_unit_tests": simulator["unit_tests"]["passed"],
    })

sequential = statistics.mean(p["sequential_seconds"] for p in comparisons)
parallel = statistics.mean(p["observed_parallel_window_seconds"] for p in comparisons)
print(json.dumps({
    "workflow_run": "https://github.com/kvn8888/OpenFoodJournal/actions/runs/33339128089",
    "benchmark_commit": records[0]["commit"],
    "comparisons": comparisons,
    "mean": {
        "sequential_seconds": round(sequential, 3),
        "parallel_seconds": round(parallel, 3),
        "saved_seconds": round(sequential - parallel, 3),
        "reduction_percent": round((sequential - parallel) / sequential * 100, 2),
        "parallel_machine_seconds": round(statistics.mean(p["parallel_total_machine_seconds"] for p in comparisons), 3),
    },
    "limitations": [
        "Two repetitions per approach; hosted-runner timing varies",
        "Parallel elapsed time runs from the first component's harness start until both finish",
        "Initial runner queue, checkout, artifact transfer, and downstream gate setup are excluded",
        "All canary probes intentionally stop at the missing-key guard; no live Gemini API call",
        "No signing, Release archive, upload, Apple processing, or approval waits were tested",
    ],
    "jobs": records,
}, indent=2))
