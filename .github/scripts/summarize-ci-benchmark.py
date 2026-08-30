#!/usr/bin/env python3
"""Summarize downloaded CI benchmark artifacts without conflating queue time."""

import json
from pathlib import Path
import statistics
import sys


artifact_root = Path(sys.argv[1])
records = [json.loads(path.read_text()) for path in sorted(artifact_root.glob("*/metrics.json"))]
if len(records) != 6 or not all(record["complete"] for record in records):
    raise SystemExit("Expected six successful benchmark job artifacts")
if len({record["commit"] for record in records}) != 1:
    raise SystemExit("Cannot compare different source commits")
if len({(record["simulator"]["runtime"], record["simulator"]["name"]) for record in records}) != 1:
    raise SystemExit("Cannot compare different simulator configurations")
if len({record["image_version"] for record in records}) != 1:
    raise SystemExit("Cannot compare different runner images")

indexed = {(record["mode"], record["repetition"]): record for record in records}
pairs = []
for repetition in ["1", "2"]:
    validation = indexed[("baseline-validation", repetition)]
    cold = indexed[("baseline-canary", repetition)]
    optimized = indexed[("early-boot-reuse", repetition)]
    if validation["unit_tests"]["passed"] != optimized["unit_tests"]["passed"]:
        raise SystemExit("Test counts differ between baseline and optimized")
    if not all(record["canary_probe"]["environment_forwarded"] for record in [cold, optimized]):
        raise SystemExit("Canary environment forwarding failed")
    original = validation["total_seconds"] + cold["total_seconds"]
    improved = optimized["total_seconds"]
    phases = {phase["name"]: phase["duration_seconds"] for phase in optimized["phases"]}
    cold_phases = {phase["name"]: phase["duration_seconds"] for phase in cold["phases"]}
    pairs.append({
        "repetition": repetition,
        "baseline_validation_seconds": validation["total_seconds"],
        "baseline_cold_canary_seconds": cold["total_seconds"],
        "baseline_combined_seconds": round(original, 3),
        "optimized_combined_seconds": improved,
        "saved_seconds": round(original - improved, 3),
        "reduction_percent": round((original - improved) / original * 100, 2),
        "passed_unit_tests": validation["unit_tests"]["passed"],
        "baseline_canary_probe_seconds": cold_phases["canary-probe"],
        "reused_canary_probe_seconds": phases["canary-probe"],
        "remaining_boot_wait_seconds": optimized["remaining_boot_wait_seconds"],
    })

baseline_mean = statistics.mean(pair["baseline_combined_seconds"] for pair in pairs)
optimized_mean = statistics.mean(pair["optimized_combined_seconds"] for pair in pairs)
print(json.dumps({
    "benchmark_commit": records[0]["commit"],
    "runner_image_version": records[0]["image_version"],
    "simulator": records[0]["simulator"],
    "comparison": "Sum of measured phase execution, excluding runner queues and artifact transfer",
    "limitations": [
        "Two repetitions per variant; runner startup times remain variable",
        "Both canary probes intentionally skip at the missing-key guard; no Gemini request was made",
        "Signing, Release archive, upload, Apple processing, and approval waits were not benchmarked",
        "Baseline matrix dependency waits for both validations; compare measured work, not whole workflow wall time",
        "Early boot and reuse are bundled, so this does not isolate each change's individual contribution",
    ],
    "pairs": pairs,
    "mean": {
        "baseline_seconds": round(baseline_mean, 3),
        "optimized_seconds": round(optimized_mean, 3),
        "saved_seconds": round(baseline_mean - optimized_mean, 3),
        "reduction_percent": round((baseline_mean - optimized_mean) / baseline_mean * 100, 2),
    },
    "jobs": records,
}, indent=2))
