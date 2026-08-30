# Parallel CI experiment — August 30, 2026

Parallel validation was faster in both measured repetitions. It averaged
**7m 22s**, compared with **10m 16s** for fresh sequential controls: **2m 54s
saved, or 28.2%**. These are small samples with substantial runner variation,
not a promise that every run will finish in five minutes.

This follows the [earlier CI experiments](ci-speed-experiment.md). The control
here is the earlier best approach: early simulator boot and test-bundle reuse,
with all validation on one runner. Fresh controls are used instead of comparing
only against the earlier batch's eight-minute average.

## Work split

Two independent macOS jobs start together:

- **Device job:** release-workflow contracts, Debug/Release isolation checks,
  and the generic iOS build of the app and all test targets.
- **Simulator job:** explicit simulator boot, simulator build, full non-UI test
  suite, and the single-test probe using `test-without-building` on the same runner.

A downstream `Require both parallel checks` job depends on both jobs and fails
unless both report success. It passed in this experiment. It does not deploy.
A production rollout would preserve an equivalent required gate and keep signing
and uploading downstream of it.

## Results

| Repetition | Sequential control | Parallel device | Parallel simulator | Parallel elapsed | Time saved |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 12m 52s | 1m 26s | 9m 30s | 9m 30s | 3m 21s |
| 2 | 7m 41s | 1m 13s | 5m 14s | 5m 14s | 2m 27s |
| **Average** | **10m 16s** | **1m 19s** | **7m 22s** | **7m 22s** | **2m 54s** |

Parallel elapsed time is measured from the earlier component's harness start
until both component harnesses finish. Both device jobs overlapped completely
with their simulator counterparts. The first device job initially queued, but
finished before its simulator job, so that queue did not lengthen the measured
parallel path.

Initial queue/setup, checkout, artifact transfer, and downstream gate setup are
excluded from this table. GitHub's displayed whole-job times are therefore a
little longer. The entire experiment workflow also waits for the deliberately
slow sequential controls; that is not the proposed production dependency chain.

The sum of device and simulator harness time averaged **8m 42s** per repetition,
versus **10m 16s** on the sequential runner. This is summed runner wall time, not
a CPU-utilization or billing measurement. The parallel layout needs two macOS
runners simultaneously and can be affected by account concurrency limits.

## Coverage and safety

- Six benchmark jobs and the combined gate all succeeded.
- All four full simulator/control suites passed the same **217 unit tests**,
  with zero failures and nine expected opt-in live-test skips.
- Both device jobs completed all three required build/contract phases.
- All jobs used the same benchmark commit, `385480cc72f0c26c33c9015b4085824b65f01b85`,
  and unchanged app/test/project contents from TestFlight source `d0e0ca7`.
- Xcode 26.6 build `17F113`, macOS runner image `20260728.0273.1`, and
  iPhone 17 Pro / iOS 26.4.1 were held constant.
- No protected environments, signing secrets, provider keys, release commands,
  build-number allocation, or TestFlight uploads were used.
- The single-test probe intentionally stopped at the missing Gemini key guard.
  Its expected skip proves the enable flag reached the test process and measures
  startup cost. It does not validate a real Gemini request. The production live
  gate still needs credential forwarding and rejection of skipped tests.

## Remaining bottleneck

The parallel device jobs finished quickly: their lightweight checks took
7.5–10.6 seconds, followed by 65–75 seconds compiling for a device. Moving those
checks away from simulator boot avoided the much slower check durations observed
in the sequential controls.

The simulator job now determines completion time. Its build alone took **3m 49s
and 6m 58s**. The unit-test bodies took only **5–7 seconds**; the second probe took
**26–28 seconds**. Further speedups should investigate simulator compilation and
runner/startup variability rather than adding parallelism to the already-fast
test bodies.

Splitting did not make every individual phase faster. Simulator compilation on
the separate fresh runners was slower than in the sequential controls. The
experiment does not isolate cold-cache effects from runner performance, and
does not establish the CPU or memory-pressure cause. Retain both repetitions
when assessing the result; do not use only the 5m 14s run.

## Evidence and reproduction

- [GitHub experiment run](https://github.com/kvn8888/OpenFoodJournal/actions/runs/33339128089)
- [Exact measurements and job timestamps](ci-parallel-experiment-results.json)
- Workflow: `.github/workflows/ci-parallel-experiment.yml`
- Harness: `.github/scripts/benchmark-ci.py`
- Analyzer: `.github/scripts/summarize-parallel-benchmark.py`

From `codex/ci-speed-parallel`, using an empty output directory:

```bash
gh run download 33339128089 --repo kvn8888/OpenFoodJournal --dir /tmp/ofj-parallel-evidence
python3 .github/scripts/summarize-parallel-benchmark.py /tmp/ofj-parallel-evidence
```

CI artifacts expire after three days. The checked-in JSON preserves compact
timings and job evidence. Production release workflows and branch protections
remain unchanged; this branch contains experiments and their results only.
