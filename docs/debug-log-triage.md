# Debug Log Triage

OpenFoodJournal debug sessions include app logs, SwiftData/CoreData CloudKit logs, UIKit keyboard logs, Network framework logs, and debugger-only diagnostics in one stream. Treat the first scary line as a clue, not a root cause.

Use the helper first:

```bash
python .agents/skills/openfoodjournal/scripts/triage_debug_log.py /path/to/xcode-log.txt
```

The script deduplicates dynamic addresses/UUIDs and groups known noisy families.

## Current Scan-Session Findings

The June 2026 scan-session log had one successful two-photo Gemini label scan, then framework noise:

- Gemini completed successfully with HTTP 200, 18 text deltas, and a final `interaction.completed` event.
- Repeated CloudKit lines referenced `com.apple.coredata.cloudkit.activity.export` and `BGSystemTaskSchedulerErrorDomain Code=3`.
- Unsatisfiable constraints referenced `TUIKeyplane`, `TUIPredictionViewCell`, `TUICandidateGradientContentLabel`, `RTIInputSystemClient`, dictation, and emoji search internals.
- The `unsafeForcedSync` warning appeared without a backtrace and adjacent to keyboard/TextInput diagnostics.
- `Invalid frame dimension` appeared without a stack; the nearby constraints were keyboard-owned.
- `glassEffect() tried to update multiple times per frame` is the only warning family that plausibly points back at app UI composition.

## Food Emoji Backfill Findings

The later June 2026 log was dominated by sequential Gemini Flash calls with tiny payloads and tiny JSON responses, matching Food Bank emoji backfill. The Gemini calls completed with HTTP 200, but every emoji attempt also inserted a `GeminiScanLog`, updated the cost accumulator, and saved SwiftData. Successful assignments then saved SwiftData again. With a large Food Bank, that produced a wall of CoreData/CloudKit export scheduling lines.

Mitigation: Food emoji backfill now batches its Gemini diagnostic logs, cost updates, and emoji assignments. Normal scan/search logging still saves immediately; only the sequential backfill path defers persistence for a small batch so CloudKit is not asked to schedule an export for each individual emoji attempt.

## Classification Rules

| Pattern | Default Owner | Action |
| --- | --- | --- |
| `TUIKeyplane`, `TUIPredictionViewCell`, `TUICandidate`, `RTIInputSystemClient`, `_dictationButton` | Apple keyboard/TextInput | Ignore unless a symbolic breakpoint stack enters an OpenFoodJournal view. |
| `Got a keyboard will change frame notification`, `Got a keyboard will hide notification` | Apple keyboard/TextInput | Ignore unless paired with a visible keyboard bug in the app. |
| `com.apple.coredata.cloudkit.activity.export`, `BGSystemTaskSchedulerErrorDomain Code=3`, `already running/updated task` | SwiftData/CoreData CloudKit | Verify entitlements and actual sync, then treat as framework scheduling noise. |
| `CoreData: debug: PostSaveMaintenance`, `WAL checkpoint`, `incremental_vacuum` | Apple CoreData maintenance | Treat as database maintenance chatter unless saves fail, data disappears, or the app hangs. |
| `unsafeForcedSync` | Unknown without backtrace | Capture a Swift runtime/concurrency breakpoint stack before changing app code. |
| `Invalid frame dimension` | Unknown without stack | Add a symbolic breakpoint and inspect the stack; keyboard-adjacent occurrences are usually system-owned. |
| `GlassPopoverContentViewRepresentable`, `_UIAlertControllerPhoneTVMacView` | UIKit/SwiftUI presentation | Needs a symbolic breakpoint stack before app ownership is clear; if it enters an app confirmation dialog/menu, simplify that presentation. |
| `glassEffect() tried to update multiple times per frame` | Possibly app UI | Search for broad implicit animations around glass-heavy overlays and scope them. |
| `nw_protocol`, `tcp_output` | Network framework | Ignore unless paired with HTTP failure or scan failure. |
| `RBSServiceErrorDomain`, `runningboard`, `FrontBoard`, `task port` | Debugger/system process accounting | Ignore unless app functionality is broken. |
| `LaunchServices ... process may not map database`, `LSDReadService` | Apple LaunchServices/debugger | Ignore unless app launch or open-url behavior is broken. |
| `mobile.usermanagerd.xpc`, `personaAttributesForPersonaType` | Apple UserManager/persona services | Ignore unless account/persona behavior is broken. |
| `updateVisibleMenuWithBlock ... no context menu is visible` | UIKit context menu | Ignore unless a visible context menu fails to update. |
| `NSKeyedUnarchiveFromData` | Framework or persisted system data unless app code calls it | `rg` the app first; do not assume ownership. |

## Breakpoints For Real Ownership

Use these only when the line keeps recurring with visible app symptoms:

- `UIViewAlertForUnsatisfiableConstraints` for Auto Layout conflicts.
- Swift concurrency runtime warning breakpoint for `unsafeForcedSync`; record the full backtrace.
- A SwiftUI invalid frame symbolic breakpoint if Xcode resolves one for the active SDK.

Evidence threshold for app-owned layout work:

- A stack includes `OpenFoodJournal/Views/...`, or
- The warning disappears after a small app-side layout/animation change, or
- The warning reproduces with the keyboard closed and no TextInput/Prediction framework frames.

## Current App-Side Mitigation

`ScanCaptureView` no longer applies multiple root-level implicit animations across the full camera overlay. Scan phase transitions already use explicit `withAnimation` at the state mutation sites, so keeping broad `.animation(_:value:)` modifiers on the root `ZStack` was unnecessary and could ask Liquid Glass to update several glass-heavy overlay branches during the same frame.

## CloudKit Code 3 Checklist

Before treating CloudKit `BGSystemTaskSchedulerErrorDomain Code=3` as a bug:

1. Confirm `Info.plist` or build settings include `UIBackgroundModes = remote-notification`.
2. Confirm entitlements include CloudKit and `aps-environment`.
3. Confirm the built app bundle still contains `UIBackgroundModes`.
4. Confirm SwiftData exports or CloudKit dashboard/device logs show records are actually stuck before changing code.

Current static evidence:

- `OpenFoodJournal/Info.plist` contains `UIBackgroundModes` with `remote-notification`.
- The Xcode project sets `INFOPLIST_KEY_UIBackgroundModes = "remote-notification"` for Debug and Release.
- `OpenFoodJournal.entitlements` contains CloudKit container/service entries and `aps-environment`.
- The app does not register its own `BGTaskScheduler` identifiers; the logged identifier is CoreData/CloudKit-owned.
