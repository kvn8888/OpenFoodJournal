# Task: Clean up client-facing developer nomenclature (Issue #13)

## Project context
- **App:** OpenFoodJournal — iOS 26.2+ food journal. SwiftUI + Liquid Glass, SwiftData + CloudKit (private DB), no SPM deps.
- **Branch:** `app-store`.
- **Build/verify (compile-only; no simulators installed):**
  ```
  xcodebuild -quiet -project OpenFoodJournal.xcodeproj -scheme OpenFoodJournal -destination generic/platform=iOS -derivedDataPath /private/tmp/OpenFoodJournalDerivedData CODE_SIGNING_ALLOWED=NO build
  ```
- Read `.claude/skills/openfoodjournal/SKILL.md` for conventions if needed.

## Goal
Replace developer-facing terms in **user-visible** UI strings with plain product language. Normal app workflows should read like a polished food journal, not an implementation note. Intentionally diagnostic/debug surfaces (Gemini log export, Turso debug, developer docs) may keep technical terms.

**Do NOT change:** code comments, variable/function names, print statements, #if DEBUG blocks, prompts sent to Gemini, or strings in non-user-visible contexts. Only change strings that a normal user would see on screen.

---

## Findings — exact strings to change

Each entry below gives the file, the current string, and the replacement. The line numbers are approximate — search for the exact string.

### 1. `OpenFoodJournal/Views/Settings/HealthDisclaimerView.swift`

**Current (~line 83):**
```swift
Text("Label scans read printed nutrition facts directly and are generally more accurate, but may still contain OCR errors. Review scanned values before logging.")
```
**Replace with:**
```swift
Text("Label scans read printed nutrition facts directly and are generally more accurate, but may still contain reading errors. Review scanned values before logging.")
```
*Rationale:* "OCR" is a technical acronym most users won't know. "Reading errors" conveys the same meaning in plain language. This is in a disclaimers view the user can navigate to, not a debug surface.

---

### 2. `OpenFoodJournal/Views/DailyLog/DailyLogView.swift`

These appear in the scan progress overlay shown during an active scan.

**Current (~line 321):**
```swift
Label("Gemini is thinking", systemImage: "brain.head.profile")
```
**Replace with:**
```swift
Label("Analyzing", systemImage: "brain.head.profile")
```

**Current (~line 325):**
```swift
Text("Thought summaries: \(thinkingTraceUpdateCount)")
```
**Replace with:**
```swift
Text("Analysis steps: \(thinkingTraceUpdateCount)")
```

**Current (~line 330):**
```swift
Text("Waiting for Gemini thought summaries...")
```
**Replace with:**
```swift
Text("Waiting for analysis...")
```

*Rationale:* Users don't know what "Gemini" or "thought summaries" mean. The scan overlay is a normal workflow surface. "Analyzing" and "analysis steps" communicate the same thing in user-friendly language.

---

### 3. `OpenFoodJournal/Views/FoodBank/AIFoodSearchView.swift`

Same pattern as DailyLogView — AI search progress overlay.

**Current (~line 164):**
```swift
Label("Gemini is thinking", systemImage: "brain.head.profile")
```
**Replace with:**
```swift
Label("Searching", systemImage: "brain.head.profile")
```

**Current (~line 167):**
```swift
Text("Thought summaries: \(thinkingTraceUpdateCount)")
```
**Replace with:**
```swift
Text("Search steps: \(thinkingTraceUpdateCount)")
```

**Current (~line 172):**
```swift
Text("Waiting for Gemini thought summaries...")
```
**Replace with:**
```swift
Text("Waiting for search results...")
```

*Rationale:* Same as #2. In the AI search context, "Searching" is more natural than "Analyzing".

---

### 4. `OpenFoodJournal/Views/Settings/SettingsView.swift`

**Current (~line 426):**
```swift
Text("This rewrites Apple Health nutrition samples for all OpenFoodJournal entries using the app's sync identifiers. It replaces OpenFoodJournal-owned samples instead of duplicating them, and does not modify nutrition data from other apps.")
```
**Replace with:**
```swift
Text("This rewrites Apple Health nutrition data for all OpenFoodJournal entries. It replaces data previously written by this app instead of duplicating it, and does not modify nutrition data from other apps.")
```
*Rationale:* "Sync identifiers" and "nutrition samples" are HealthKit implementation terms. Users don't need to know about HKSample identity or sync IDs — they just need to know it's safe and won't duplicate.

**Current (~line 286):**
```swift
Text("Apple Health repair rewrites OpenFoodJournal-owned nutrition samples for existing entries without touching nutrition data from other apps. Apple Health does not expose separate write types for added sugars or trans fat, so those stay in OpenFoodJournal only. OpenFoodJournal records successful Open Food Facts uploads on this device; if the status stays at zero, no contribution has been confirmed.")
```
**Replace with:**
```swift
Text("Apple Health repair rewrites nutrition data for existing entries without touching data from other apps. Apple Health does not support added sugars or trans fat, so those are tracked in OpenFoodJournal only. Successful Open Food Facts contributions are recorded on this device; if the count stays at zero, no upload has been confirmed.")
```
*Rationale:* "Nutrition samples", "OpenFoodJournal-owned", "separate write types", and "expose" are implementation language. Simplified to plain descriptions of what happens.

---

### 5. `OpenFoodJournal/Views/FoodBank/NutritionCalculatorView.swift`

**Current (~line 403):**
```swift
Text("Use quantities for adjustments like double portions or multiple scoops without changing the saved calculator.")
```
**Replace with:**
```swift
Text("Adjust quantities for double portions or multiple scoops without changing saved nutrition values.")
```
*Rationale:* Minor — "saved calculator" is internal naming. Users think of it as saved nutrition data.

**Current (~line 420):**
```swift
Text("Choose at least one ingredient portion to log a calculator build.")
```
**Replace with:**
```swift
Text("Choose at least one ingredient to log this meal.")
```
*Rationale:* "Calculator build" is developer framing. Users are logging a meal.

**Current (~line 720):**
```swift
Text("Type the ingredient name first. After Gemini fills nutrients, name each portion.")
```
**Replace with:**
```swift
Text("Type the ingredient name first, then import nutrition from an image or add portions manually.")
```
*Rationale:* "Gemini fills nutrients" exposes the AI implementation. Describes user actions instead.

**Current (~line 752):**
```swift
Text("Import nutrition from an image, then name the portions shown by the restaurant or brand.")
```
**Replace with:**
```swift
Text("Choose an image showing this ingredient's nutrition info. Portions will be filled in automatically.")
```
*Rationale:* Cleaner instruction that focuses on the user action rather than explaining implementation.

---

### 6. `OpenFoodJournal/Views/Settings/SettingsView.swift` — data privacy footer

**Current (~line 333):**
```swift
Text("Your journal is stored locally and in your private iCloud database. Optional Turso mirroring sends a push-only copy to a Turso database you configure.")
```
**Replace with:**
```swift
Text("Your journal is stored locally and in your private iCloud account. Optional Turso mirroring sends a read-only copy to an external database you configure.")
```
*Rationale:* "Push-only" is a sync implementation term. "Read-only copy" and "external database" are more accessible. "iCloud database" → "iCloud account" since users think in terms of their account, not a database.

---

### 7. `OpenFoodJournal/Views/Settings/SettingsView.swift` — backup import

**Current (~line 399):**
```swift
Text("This upserts records by UUID, so importing the same backup again updates existing data instead of duplicating it.\n\n\(pendingBackup?.importSummaryText ?? "")")
```
**Replace with:**
```swift
Text("Importing the same backup again updates existing data instead of duplicating it.\n\n\(pendingBackup?.importSummaryText ?? "")")
```
*Rationale:* "Upserts records by UUID" is pure database jargon. The user just needs to know it's safe to re-import.

---

## Intentional keeps (do NOT change)

These strings use technical terms but are on intentionally diagnostic/advanced surfaces:

| File | String | Why keep |
|---|---|---|
| `SettingsView.swift` | "Export Gemini Logs" | Export feature is for debugging; "Gemini" is the product name users configured |
| `SettingsView.swift` | "Gemini API Key", "Gemini Usage", "Estimated from Gemini token usage..." | Settings sections about the user's API key — "Gemini" is what they signed up for |
| `SettingsView.swift` | "Gemini scan and AI Search logs from the last 30 days..." | Log export section — intentionally diagnostic |
| `TursoIntegrationSettingsView.swift` | All strings | Entire view is an advanced integration surface for SQL developers |
| `HealthDisclaimerView.swift` | FDA citations, Atwater system | Regulatory/scientific terms that should stay precise |
| `OnboardingView.swift` | "Google's Gemini AI" | Explaining what the API key is for — appropriate context |
| `ScanService.swift` prompts | All Gemini prompts | Sent to the model, not shown to users |

---

## Definition of done

1. Build succeeds:
   ```
   xcodebuild -quiet -project OpenFoodJournal.xcodeproj -scheme OpenFoodJournal -destination generic/platform=iOS -derivedDataPath /private/tmp/OpenFoodJournalDerivedData CODE_SIGNING_ALLOWED=NO build
   ```

2. Run these grep checks and confirm **zero hits in user-visible strings** (comments/variable names/prompts are fine):
   ```bash
   # Should return no Text/Label hits (comments are OK):
   grep -rn 'Text(".*OCR' OpenFoodJournal/Views/ --include="*.swift"
   grep -rn 'Text(".*thought summar' OpenFoodJournal/Views/ --include="*.swift"
   grep -rn 'Text(".*sync identifier' OpenFoodJournal/Views/ --include="*.swift"
   grep -rn 'Text(".*upsert' OpenFoodJournal/Views/ --include="*.swift"
   grep -rn 'Text(".*calculator build' OpenFoodJournal/Views/ --include="*.swift"
   grep -rn 'Label("Gemini is thinking' OpenFoodJournal/Views/ --include="*.swift"
   ```

3. No functional changes — only string content in `Text()`, `Label()`, and similar SwiftUI string views. No logic, layout, or navigation changes.

4. Verify that the "Intentional keeps" listed above are **not** changed.
