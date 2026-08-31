# Optional screenshot gallery

`Generate Screenshots` builds the real app for an iPhone simulator, visits selected
screens, and exports PNGs, an offline HTML gallery, and a source/size/hash manifest.
It has no deployment secrets and never archives, uploads to TestFlight, or changes
release state. It is not a required release check.

## Run it

For a pull request targeting `testflight` or `app-store`, add the `ci:screenshots`
label. The workflow captures all seven screens in light and dark mode. New commits
to a labeled PR refresh the gallery; unlabeled PRs skip the screenshot job.

```bash
gh pr edit PR_NUMBER --repo kvn8888/OpenFoodJournal --add-label ci:screenshots
```

CLI dispatch on the feature branch was verified after the first labeled PR run
registered the workflow. The command below can be used without merging a release.
Once `screenshots.yml` is present on the repository's default branch, the web UI
also exposes **Actions → Generate Screenshots → Run workflow**. Select the source
branch there; use the CLI or PR label if the web button is not yet available.
Inputs are:

| Input | Values | Default |
| --- | --- | --- |
| Screens | `all` or a comma-separated subset of `journal,scan,food-bank,log-food,history,assistant,settings` | `all` |
| Appearance | `both`, `light`, `dark` | `both` |
| Device | `iPhone 17 Pro`, `iPhone 17 Pro Max` | `iPhone 17 Pro` |

```bash
gh workflow run screenshots.yml --repo kvn8888/OpenFoodJournal --ref YOUR_BRANCH \
  -f screens=journal,food-bank,log-food -f appearance=dark -f 'device=iPhone 17 Pro'
```

The source branch must contain the screenshot scheme, fixture support, and scripts.
PR runs capture GitHub's PR merge checkout, and the artifact records its exact SHA.

## View the result

Download `screenshots-RUN_ID` from the workflow's Artifacts section, unzip it, and
open `index.html`. Each image has a stable name such as `journal-light.png`.
`manifest.json` records the source SHA, selected device/runtime, fixture date,
appearance, pixel dimensions, PNG hashes, and screenshot-test outcomes.

A successful run must have every requested image and exactly one passing,
non-skipped screenshot test per appearance. Missing or duplicated images,
unexpected appearances, and failed/skipped tests fail the job. Partial galleries
are marked incomplete. Gallery artifacts are retained for 14 days; failed logs
and `.xcresult` diagnostics for three days. Compiled products and simulator data
are not retained.

## Reproducible, isolated state

- Screenshots require both `OFJ_UI_TEST_MODE=1` and `OFJ_SCREENSHOT_MODE=1` in a
  **Debug** build. The sample-data implementation is excluded from Release.
- The app uses an in-memory SwiftData store with no CloudKit. The seeder rejects
  non-memory configurations and does not duplicate an already-seeded store.
- Fixed presentation date: August 12, 2026, at 12:00 UTC. This affects the visible
  calendars/date controls, not production persistence/service clocks.
- Four weeks of sample meals, six foods, sample food icons, fixed nutrition goals,
  and a seeded Assistant conversation; no real food photos or personal records.
- English (US), Large text, Blue accent, 9:41 status-bar time, full battery, and
  explicitly selected light/dark system appearance.
- Onboarding and What's New are dismissed by the existing UI-test setup. Automatic
  food-image generation and HealthKit export are off. Assistant requests use the
  existing local UI-test proxy; screenshot navigation never sends a model request.
- `scan` opens through Journal's real add menu. The camera area is plain white
  behind the unchanged production `ScanCameraControls`, including its normal
  legibility gradient. All three scan modes and the 0.5×/1×/2× zoom controls are
  visible. Zoom/torch changes are simulated locally; shutter and photo-library
  actions are inert. No camera controller is created, no permissions are
  requested, and no photo, barcode lookup, or AI request is made. The initial
  capture uses Scan Food, 1×, torch off, and no retry button (no previous scan).

To capture just the scan controls in both appearances:

```bash
gh workflow run screenshots.yml --repo kvn8888/OpenFoodJournal --ref YOUR_BRANCH \
  -f screens=scan -f appearance=both
```

The existing generic UI tests keep their original fixture mode. Screenshot tests
skip unless the runner receives `OFJ_CAPTURE_SCREENSHOTS=1`. The script uses
`TEST_RUNNER_` forwarding for runner settings, and `XCUIApplication.launchEnvironment`
passes the app's fixture flags explicitly.

## Implementation and limitations

The workflow builds `OpenFoodJournalScreenshots` once, boots one simulator, and
runs the selected UI test using `test-without-building` for each appearance.
The test navigates through the actual tabs and Settings button; it does not
substitute a mock screen. `XCTAttachment.keepAlways` preserves images from passing
tests, and `xcresulttool export attachments` makes the PNGs downloadable without
opening Xcode.

This is visual evidence, not automatic pixel-diff regression testing. It does not
validate real camera hardware, CloudKit delivery, live AI responses, or HealthKit.
The supplied PNGs are app captures, not App Store marketing compositions.
Each image captures the visible simulator screen, including system chrome, at
the view's initial scroll position. Long views can be extended with additional
named captures after scrolling; the workflow does not stitch a whole scroll view.

To add a screen, extend the UI-test navigation and capture name, the script's
`SCREENS` allowlist, and the workflow's input description. Add deterministic test
data if needed, without enabling production services. Keep waits tied to visible
UI elements and preserve normal app behavior outside screenshot mode.
