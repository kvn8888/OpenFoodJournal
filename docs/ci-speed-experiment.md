# CI speed experiment — August 30, 2026

The fastest measured variant was **early simulator boot plus reuse of the
compiled simulator tests**. Its average validation time was **7m 56s**, compared
with **12m 13s** for the current sequence: a **35% reduction**, or **4m 16s saved**.
Production release workflows have not been changed.

## Results

These are measured execution times for validation plus the single-test startup
probe. They exclude runner queues, checkout, artifact upload, signing, Release
archiving, TestFlight upload, Apple processing, and approval waits.

| Variant | Repetition 1 | Repetition 2 | Average | Reduction from baseline |
| --- | ---: | ---: | ---: | ---: |
| Current sequence: validation, then a fresh simulator job | 13m 29s | 10m 56s | 12m 13s | — |
| Early boot and reuse | 7m 32s | 8m 20s | 7m 56s | 35.0% |
| Reuse without early boot | 9m 49s | 8m 11s | 9m 00s | 26.3% |

The baseline totals add each validation job's execution time to its separate
cold-canary job. The benchmark's matrix waits for both baseline validations
before starting either cold-canary job; this artificial wait is excluded.
The baseline range illustrates why a single run is not sufficient evidence.

The second check's command duration shows the clearest difference:

| Second-check setup | Repetition 1 | Repetition 2 |
| --- | ---: | ---: |
| Fresh job, build and test | 4m 47s | 4m 01s |
| Early boot, then reuse with `test-without-building` | 18s | 22s |
| Reuse alone with `test-without-building` | 1m 31s | 2m 24s |

Reusing compiled tests removes the second compilation. Explicitly starting the
simulator before testing also produced shorter subsequent test launches in
these samples. We did not record simulator state between test invocations, so
the results do not prove the precise simulator lifecycle cause.

## What was tested

- App source: TestFlight commit `d0e0ca7da7f887226b39071d1f1572a65d797395`.
- Hosted runner: `macos-26`, image `20260728.0273.1`.
- Xcode: 26.6, build `17F113`, checked by the existing toolchain guard.
- Simulator: iPhone 17 Pro, iOS 26.4.1, initially shut down.
- Every variant retained the generic iOS build of the app and all test targets,
  release-workflow checks, Debug/Release isolation checks, and the full non-UI
  test scheme.
- **217 unit tests passed in each of six full-validation jobs**, with no failures.
  The existing nine opt-in live tests skipped in each ordinary suite, as expected.
- Two separate cold-canary jobs completed, bringing the experiment to eight
  successful jobs total.
- The reuse-only follow-up ran later on fresh machines. Git tree/diff checks
  verified that app code, test code, project settings, and production workflow
  files were identical; only benchmark harness files differed.

## The live-test limitation and forwarding check

The production Gemini credential is restricted to the protected `testflight`
branch. The experiment did not change that restriction, read any deployment
secret, or invoke the Gemini API.

Every isolated canary probe intentionally used an empty API key and
`TEST_RUNNER_OFJ_RUN_LIVE_GEMINI_IMAGE_TESTS=1`. The harness required the exact
missing-key skip message and exactly one skipped test. This proves the enable
flag reached the test process, correcting the missing-flag behavior identified
in production logs. It does **not** establish that the live Gemini request works.

This expected skip belongs only to the credential-free benchmark. The real
protected release gate must require an actual passing test and reject skipped
tests. A production change must forward both the enable flag and the protected
key, and validate the test result after execution.

## Interpretation and recommendation

Early boot plus reuse is the best measured candidate for the protected TestFlight
validation job. Keep signing and upload in a separate downstream job, keep PR
checks secret-free, and expose the Gemini key only to its dedicated test step.
Use the same compiled simulator test bundle and simulator for the ordinary tests
and the live canary. Do not remove the device compile check or reduce test coverage.

Early boot had a cost: release-workflow checks rose from 0.6–1.1 seconds in the
baseline to 47–103 seconds while boot was running. One boot log recorded 77
seconds of first-boot initialization, including data migration. Resource
contention is a plausible explanation for slower concurrent commands, but CPU
and memory pressure were not measured. Starting boot after the lightweight
checks is a possible next experiment, not an already-proven optimization.

There are only two repetitions per variant, and the follow-up was not concurrent
with the original baseline. Treat 35% as the observed improvement in this sample,
not a guaranteed future runtime. No signed release was benchmarked, and actual
Gemini response time remains additional work once the real gate is fixed.

## Evidence and reproduction

- [Baseline and early-boot experiment](https://github.com/kvn8888/OpenFoodJournal/actions/runs/33337743508)
- [Reuse-only follow-up](https://github.com/kvn8888/OpenFoodJournal/actions/runs/33338184058)
- [Exact timing data](ci-speed-experiment-results.json)
- Harness: `.github/scripts/benchmark-ci.py`
- Analyzer: `.github/scripts/summarize-ci-benchmark.py`

From the `codex/ci-speed-reuse-only` experiment branch, download the artifacts
into two empty directories and run:

```bash
gh run download 33337743508 --repo kvn8888/OpenFoodJournal --dir /tmp/ofj-bench-first
gh run download 33338184058 --repo kvn8888/OpenFoodJournal --dir /tmp/ofj-bench-reuse
python3 .github/scripts/summarize-ci-benchmark.py /tmp/ofj-bench-first /tmp/ofj-bench-reuse
```

The analyzer checks completion, source equivalence, runner image, simulator,
unit-test counts, and expected probe behavior before comparing durations.
Detailed CI artifacts expire after three days; the compact timing JSON in this
branch preserves the measured results and tested commits.
