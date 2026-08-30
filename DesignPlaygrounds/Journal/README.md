# Journal design playground

A disposable **native macOS SwiftUI mock** for fine-tuning the Journal like CSS.
The layout, styling, sample food, and previews live in **JournalDesign.swift**.
It intentionally duplicates presentation. It does not import the iPhone app.

## Open and edit

1. This checkout is already prepared. On a fresh checkout, first run
   `bash DesignPlaygrounds/Journal/build.sh prepare` from the repo root to put
   Xcode's per-user preview cache on DevDisk. Then open **JournalPlayground.xcodeproj**,
   not the main OpenFoodJournal project.
2. Select **JournalPlayground → My Mac** in Xcode's scheme/destination selector.
3. Open **JournalDesign.swift** and turn on **Editor → Canvas**.
4. Resume the preview. Choose Light, Dark, Empty, or Over Goal along the Canvas.
5. Edit the `JournalStyle` values at the top or the SwiftUI modifiers below.
   If Canvas is paused, resume it. If it keeps an old compiled value, build again.

You can also press **⌘R** to run a normal Mac window. Its small workbench offers
a sample-state picker, dark-mode switch, and zoom slider. The running window
requires another build/run after source edits; Xcode Canvas is the live-edit path.
Close the playground window to quit this single-window app.

Requires macOS 26+ and Xcode 26+ for real SwiftUI Liquid Glass. Kevin's installed
macOS 27/Xcode 27 beta meets this requirement. No iOS simulator runtime, iPhone,
iPhone device support download, package manager, or third-party library needed.

## Where to make changes

Use Xcode's jump bar or search `MARK:` to find a section:

| Section | Tweak here | Real app destination later |
| --- | --- | --- |
| `JournalStyle` | Fonts, padding, ring sizes, colors, radii | `Views/Shared/OFJDesignSystem.swift` or the owning view |
| `JournalDesign` | Overall spacing, background, composition | `Views/DailyLog/DailyLogView.swift` |
| `JournalHeader` | Month title and Today/gear appearance | `DailyLogView` toolbar (native implementation) |
| `JournalCalendar` / `JournalDayCell` | Date cells and their states | `Views/DailyLog/WeeklyCalendarStrip.swift` |
| `JournalMacroCard` / `JournalNutrientRing` | Calories and nutrients | `MacroSummaryBar.swift` / `Shared/MacroRingView.swift` |
| `JournalMealSection` / `JournalFoodRow` | Meal headers, rows, chips | `MealSectionView.swift` / `EntryRowView.swift` |
| `JournalRadialMenu` / `JournalTabBar` | Floating menu and tab appearance | `Shared/RadialMenuButton.swift` / `ContentView.swift` |
| `SampleDay` | Mock meals and amounts | Nowhere — this data is fictional |

Example:

```swift
static let pageInset: CGFloat = 20      // left/right space
static let titleSize: CGFloat = 32      // month heading
static let rowVerticalPadding: CGFloat = 10
static let cardRadius: CGFloat = 24
```

All sizes are **points**. Workbench zoom only changes viewing scale, not layout.
The `lightGradient(progress:)` and `darkGradient(progress:)` functions inside
`JournalStyle` independently control each mode's background colors and opacity.
They start with identical values; lower an `.opacity(...)` only in the dark
function to soften dark mode without changing light mode. The gradient's radius
and position remain shared in `JournalDesign`.
The default phone-sized artboard is 393 × 852 points. For another width, edit
`phoneWidth`; text truncation, ring spacing, and rows respond to that width.

Tap a weekday to change the sample totals and gradient. Friday August 21, 2026
is always the mock "today", so screenshots stay reproducible. Saturday is
disabled with a dashed ring. Tap + to expand the menu. Mock destination buttons
do not open the real app. Tab buttons only change selection styling.

### Entry chip variants

- **Neutral pill** (default): one smooth, untinted Liquid Glass capsule with
  lavender/green/amber numbers and units. No scalloped circle boundaries.
- **RGB glass** (optional experiment): blue protein, green carbs, red fat glass with white
  stacked numbers/units. Tint inputs are exact sRGB primaries, not system colors.
- **Saved Neutral** (circles): the untinted-glass design with its original
  lavender/green/amber text. Available in the two `Chips · Saved Neutral` Canvas
  previews, or through the **Entry chips** selector in the running Mac window.
- The complete neutral Journal, including Kevin's refinements, is preserved in
  commit `a7c743b`. Switching variants shares current layout; the commit preserves
  the exact earlier file if later geometry experiments need to be compared.

Circle geometry recorded before the pill experiment: **40 pt diameter, 5 pt
overlap**, giving a **110 × 40 pt** group (`3 × 40 − 2 × 5`) and **35 pt**
between text-column centers. The pill preserves that footprint and label
positioning; `entryMacroPillWidth` is derived from the same values. The circle
variants remain selectable with these settings.

`entryMacroGlassTintOpacity` affects RGB glass only. `entryMacroOverlap` and the
size/font values affect all variants. Apple documents glass tinting and shape
merging, not a guaranteed additive RGB or subtractive pigment mixing operation.
Pure RGB inputs therefore don't guarantee cyan/yellow/white overlap results.
See [Apple's Liquid Glass guide](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views).

## Move a finished design back

Tell Codex which sections to bring back, or provide a screenshot and the edited
file. Port only the chosen visual values/layout into the existing app views;
retain real observation, navigation, persistence, accessibility, and actions.
Never replace the shipping Journal with this mock or import its fixtures into
production. The sandbox does not need to remain in sync with the app.

This is **visual exploration, not iPhone regression testing**. iOS navigation/
status/tab bars are hand-drawn approximations. macOS glass, font metrics, mouse
interaction, and scroll behavior can differ. The mock uses a ScrollView instead
of the production swipeable List; real swipe actions/sticky headers aren't tested.
One sample week is sufficient for tuning date cells; it isn't the real year-long
calendar. There is no scan/HealthKit/LLM/data logic to preserve in this project.

## Storage and isolation

- The project and source live on DevDisk under `DesignPlaygrounds/Journal`.
- CLI builds explicitly use `.build/DerivedData` here. Compiler module caches
  are also redirected into `.build`; generated files are ignored by Git.
- The build helper installs the checked-in workspace template as this project's
  **per-user** Xcode settings. Xcode 27 ignores the shared location alone.
  Both are configured to put Canvas/build DerivedData at
  `/Volumes/DevDisk/ActiveProjects/OpenFoodJournal/DesignPlaygrounds/Journal/.build/DerivedData`.
  Xcode may append a project-name/hash subdirectory inside that folder.
  If you move the checkout, rerun `bash build.sh prepare` from this folder before
  using Canvas. You can confirm the path in **File → Project Settings → Derived Data**.
- Xcode/macOS can still keep small app preferences, logs, and system caches in
  your user Library. This does not promise zero internal writes or zero build
  storage; it avoids installing a multi-GB iOS runtime and keeps project caches
  on the external disk. The first compile prepares Apple SDK modules; later
  incremental builds reuse them.
- No databases, credentials, production app sources, provisioning profiles,
  CloudKit containers, or network permissions are included. The bundle ID is
  `dev.openfoodjournal.JournalDesignPlayground`, with local ad-hoc signing.
- Deleting **only this playground's `.build` folder** after closing it/Xcode
  removes its disposable build products. Do not delete the main app's data or
  shared DerivedData. The next preview will rebuild the cache.

## Optional terminal build

From the repository root:

```sh
bash DesignPlaygrounds/Journal/build.sh build
bash DesignPlaygrounds/Journal/build.sh run
```

The helper defaults to Xcode beta on DevDisk if present. Set `DEVELOPER_DIR`
explicitly to use a different Xcode. It never downloads dependencies or selects
an iOS destination, and it never archives/uploads anything to TestFlight.

## Verification (2026-08-30)

- Native arm64 Mac Debug build passed with Xcode 27 beta; all four `#Preview`
  declarations compile. Only `JournalPlaygroundApp.swift` and `JournalDesign.swift`
  are in its source build phase; there are no target/package dependencies.
- Opened this project in Xcode, selected `JournalDesign.swift`, and resumed
  Canvas on **My Mac**. The Journal rendered live beside its editable source.
- Opened the resulting Mac window and inspected the actual rendering. Checked
  sample weekday selection, Today return, dark mode, and expanded radial menu.
- Verified the executable has only app-sandbox/debug entitlements, not CloudKit,
  HealthKit, camera, or network access entitlements.
- Verified Xcode's effective build paths without an explicit `-derivedDataPath`
  point inside this playground on DevDisk after local workspace preparation.
- No shipping-app build, iPhone installation, simulator test, or TestFlight upload.
