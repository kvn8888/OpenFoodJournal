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
      ├─ Data (save photos toggle, CSV export via ShareLink)
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
- **Environment**: `NutritionStore`, `UserGoals`
- Shows `EmptyLogView` when no entries for selected date

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

### EditEntryView (`Views/ManualEntry/EditEntryView.swift`)
- **`@Bindable`** NutritionEntry for two-way binding
- Shows scan mode + confidence if not manual
- Delete with confirmation dialog

### HistoryView / MacroChartView (`Views/History/`)
- MacroChartView: segmented picker (cal/protein/carbs/fat), stat pills (avg, goal, vs goal %), bar marks with goal RuleMark

### Shared Components
| Component | File | Purpose |
|-----------|------|---------|
| `MacroRingView` | `Views/Shared/MacroRingView.swift` | Circular progress, orange if over goal |
| `MacroSummaryBar` | `Views/DailyLog/MacroSummaryBar.swift` | Glass card with calorie headline + 3 rings |
| `EntryRowView` | `Views/DailyLog/EntryRowView.swift` | List cell with swipe-to-delete |
| `MealSectionView` | `Views/DailyLog/MealSectionView.swift` | Collapsible per-MealType section |
| `CameraPreviewView` | `Views/Scan/CameraPreviewView.swift` | UIViewRepresentable for AVCaptureVideoPreviewLayer |
| `GoalsEditorView` | `Views/Settings/GoalsEditorView.swift` | 4 goal inputs with derived calorie sanity check |
