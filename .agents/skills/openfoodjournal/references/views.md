# Views Reference

## View Hierarchy

```
MacrosApp
└─ ContentView (TabView, 3 tabs, .tabBarMinimizeBehavior(.onScrollDown))
   ├─ "Journal" → DailyLogView
   │  ├─ DateSelectorView (chevrons, "Today"/"Yesterday" labels)
   │  ├─ MacroSummaryBar (glass card, calorie headline, 3× MacroRingView)
   │  ├─ MealSectionView (per MealType, collapsible)
   │  │  └─ EntryRowView (name, calories, confidence badge, P/C/F chips, swipe-to-delete)
   │  └─ FloatingScanButton (FAB, glass, namespace animation, expands to show Manual option)
   │
├─ "History" → HistoryView
│  ├─ DatePicker (graphical, bounded ≤ Date.now)
│  ├─ MacroChartView (segmented selector, stat pills, bar chart + goal rule line)
│  └─ NavigationLink → DayDetailView
   │
   └─ "Settings" → SettingsView
      ├─ Goals section → GoalsEditorView (4 GoalRow inputs, derived calorie check)
      ├─ Integrations (HealthKit toggle, iCloud status)
      ├─ Data (spreadsheet CSV export, JSON backup export/import, Gemini log CSV export)
      └─ About (version, source, license)
```

## Sheet Presentations (from DailyLogView)

```swift
enum DailyLogSheet: Identifiable {
    case scan                       → ScanCaptureView
    case manualEntry                → ManualEntryView
    case editEntry(NutritionEntry)  → EditEntryView
}
```

## Key View Details

### DailyLogView (`Views/DailyLog/DailyLogView.swift`)
- **State**: `selectedDate`, `presentedSheet`, `selectedEntry`
- **Environment**: `NutritionStore`, `ScanService`, `HealthKitService`, `UserGoals`
- Shows `EmptyLogView` when no entries for selected date
- Deletes remove OpenFoodJournal-owned HealthKit samples before deleting the local entry when HealthKit is enabled

### ScanCaptureView (`Views/Scan/ScanCaptureView.swift`)
- **State**: `mode` (ScanMode), `capturedEntry`, `cameraPermissionDenied`
- **CameraController**: `@Observable @MainActor`, owns `AVCaptureSession`
  - Uses `CheckedContinuation` to bridge delegate callback to async
  - `nonisolated` delegate method hops back to MainActor
- **UI**: mode toggle, torch button, capture button (ring + fill), ProgressView while scanning
- **Result**: `ScanResultCard` with editable fields, Retake/Add buttons

### ManualEntryView (`Views/ManualEntry/ManualEntryView.swift`)
- **Form sections**: Food info, core macros (MacroInputRow), additional details (DisclosureGroup)
- **Validation**: name non-empty && all 4 core macros are valid Double
- **Keyboard**: `@FocusState` per field with submitLabel routing
- Uses `fileprivate enum ManualEntryField` (not private — shared across structs in file)
- Logs to the selected journal date and calls `HealthKitService.sync` when Apple Health writes are enabled

### EditEntryView (`Views/ManualEntry/EditEntryView.swift`)
- **`@Bindable`** NutritionEntry for two-way binding
- Shows scan mode + confidence if not manual
- Save replaces OpenFoodJournal-owned HealthKit samples when needed; delete removes those samples before local deletion

### FoodBankView (`Views/FoodBank/FoodBankView.swift`)
- **Default list**: active foods only; foods auto-hide when `SavedFood.lastUsedAt` is older than 14 days or `archivedAt != nil`
- **Search**: non-empty search filters all saved foods, so archived foods remain discoverable
- **Plus menu**: AI Search, Composite Food, Nutrition Calculator, Search Open Food Facts, Manual Entry, Archive
- **Rows**: tap or leading swipe opens `LogFoodSheet` for single/composite foods or `NutritionCalculatorBuildView` for calculators; trailing swipe archives/unarchives or opens `EditFoodSheet`, `CompositeFoodBuilderView`, or `NutritionCalculatorEditorView` by food kind

### CompositeFoodBuilderView (`Views/FoodBank/CompositeFoodBuilderView.swift`)
- **Purpose**: creates or edits a `SavedFood(kind: .composite)` from Food Bank ingredient snapshots
- **Ingredient behavior**: picker copies selected `SavedFood` nutrition into `CompositeIngredientSnapshot`; no source-food references are stored
- **Portion behavior**: each ingredient row has editable quantity/unit; summary recalculates the composite's `1 portion` nutrition live
- **Save behavior**: updates the composite saved-food template only; existing `NutritionEntry` rows stay unchanged

### NutritionCalculatorView (`Views/FoodBank/NutritionCalculatorView.swift`)
- **Library**: `NutritionCalculatorLibraryView` lists `SavedFood(kind: .calculator)` rows from the Food Bank and opens build/edit sheets
- **Editor**: `NutritionCalculatorEditorView` creates or edits calculator identity and a flat list of ingredients with portion names and macro/micro values
- **OCR import**: the ingredient editor can choose an image from the library or camera, then calls `ScanService.extractCalculatorIngredient(named:from:useProModel:)`; the typed ingredient name anchors Gemini, returned nutrients are appended as unnamed portions, and users must name portions before saving
- **Builder**: `NutritionCalculatorBuildView` lets users pick one portion per ingredient, adjust quantities, see live totals, and add the calculated result to the journal
- **Logging behavior**: logs a normal `NutritionEntry` with copied macros/micros and `selectionSummary`; previous entries are not connected to later calculator edits

### FoodBankArchiveView (`Views/FoodBank/FoodBankArchiveView.swift`)
- **Purpose**: browse foods hidden from the active Food Bank list
- **Actions**: search archived foods, log, edit, or unarchive
- **Unarchive behavior**: clears `archivedAt` and refreshes `lastUsedAt` so the food appears in the active list

### HistoryView / MacroChartView (`Views/History/`)
- MacroChartView: segmented picker (cal/protein/carbs/fat), stat pills (avg, goal, vs goal %), bar marks with goal RuleMark

### SettingsView (`Views/Settings/SettingsView.swift`)
- **Data exports**: spreadsheet CSV via `NutritionStore.exportCSV()`, restore-grade JSON backup via `NutritionStore.exportBackup(...)`, and Gemini diagnostics CSV via `GeminiScanLog.exportCSV(from:)`
- **Gemini logs**: export includes scan and AI Search logs from the last 30 days; empty state shows a "No Gemini logs" alert
- **Gemini usage**: shows estimated token cost, request counts, input/output/thinking tokens, grounded AI Search prompt count, last estimate, and a reset action backed by `GeminiCostAccumulator`
- **Apple Health**: shows pending HealthKit sync count and a "Sync Missing Nutrition to Apple Health" backfill action for unsynced/stale `NutritionEntry` rows

### Shared Components
| Component | File | Purpose |
|-----------|------|---------|
| `MacroRingView` | `Views/Shared/MacroRingView.swift` | Circular progress, orange if over goal |
| `MacroSummaryBar` | `Views/DailyLog/MacroSummaryBar.swift` | Glass card with calorie headline + 3 rings |
| `EntryRowView` | `Views/DailyLog/EntryRowView.swift` | List cell with swipe-to-delete |
| `MealSectionView` | `Views/DailyLog/MealSectionView.swift` | Collapsible per-MealType section |
| `CameraPreviewView` | `Views/Scan/CameraPreviewView.swift` | UIViewRepresentable for AVCaptureVideoPreviewLayer |
| `GoalsEditorView` | `Views/Settings/GoalsEditorView.swift` | 4 goal inputs with derived calorie sanity check |
