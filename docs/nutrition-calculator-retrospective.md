# Nutrition Calculator Retrospective

## Context

The requested feature was a runtime-configurable nutrition calculator for restaurants or brands such as Chipotle. The goal was to avoid creating a long, separate saved-food object for every possible bowl/customization, while still preserving immutable journal history once a meal is logged.

The key clarification was that labels such as "little", "normal", and "extra" must not be hard-coded. The app should let users define whatever portion labels a restaurant or brand exposes, and logging should use those runtime values.

## Claude's Full Analysis

This is a strong concept, but I read your new `CompositeFoodBuilderView` and the biggest issue isn't in your data model — it's that **this feature already half-exists**, and you're at risk of shipping two overlapping things. Here's my practical critique.

## 1. Reconcile with Composite Food first (the #1 thing)

Your Composite Food builder already does most of what you're describing:
- Snapshots ingredients into a Codable array (`compositeIngredients: [CompositeIngredientSnapshot]`) so later edits don't change history — your snapshot requirement, already solved.
- Per-ingredient quantity + unit selection with live scaled totals.
- Stored as `SavedFood(kind: .composite)`, logs into a `NutritionEntry` like everything else.

A "Chipotle calculator" is just a **Composite Food with two added capabilities**: (a) *choice groups* (pick a protein, pick many toppings) instead of a fixed ingredient list, and (b) *portion presets* (little/normal/extra) instead of a raw quantity field. If you build a parallel `FoodCalculator` model tree, you'll duplicate the snapshot math, the scaling logic, the totals cards, the ingredient picker, and the OCR review — and users will have two confusingly similar "+" menu items.

**Recommendation:** Make Calculator the *configurable superset* of Composite, not a sibling. Either:
- Extend `SavedFood.kind` with `.calculator` and reuse the composite ingredient/totals machinery, or
- Frame the UI as "Composite Food = fixed recipe, Calculator = recipe you reconfigure each time you log." Same engine underneath.

Decide this before writing models, because it determines everything below.

## 2. Data model: keep the tree shallow, lean on Codable

You're already doing the right thing in Composite — `[CompositeIngredientSnapshot]` is a **Codable array on a `@Model`, not a relationship**. Keep that for the calculator. A 4-level `@Model` tree (Calculator → Group → Ingredient → Portion) under CloudKit means four optional relationships, four `safeX` unwrap patterns, sync-ordering risk, and migration pain. Don't.

Suggested shape (one `@Model`, everything else Codable — matches `ServingMapping`/`MicronutrientValue` convention):

```swift
@Model
final class FoodCalculator {
    var id: UUID = UUID()
    var name: String = ""              // "Chipotle"
    var brand: String? = nil
    var createdAt: Date = Date()
    var lastUsedAt: Date = Date()
    var groupsData: Data = Data()      // encoded [CalcGroup]
    // computed accessor decodes/encodes groupsData, like compositeIngredients
}

struct CalcGroup: Codable, Identifiable {   // "Protein", "Rice", "Toppings"
    var id = UUID()
    var name: String
    var selection: SelectionRule           // .one / .many  ← model this!
    var items: [CalcItem]
}

struct CalcItem: Codable, Identifiable {    // "Chicken", "White Rice"
    var id = UUID()
    var name: String
    var portions: [CalcPortion]            // little/normal/extra/scoop
}

struct CalcPortion: Codable, Identifiable {
    var id = UUID()
    var label: String                      // "Normal", "Extra"
    var calories, protein, carbs, fat: Double
    var micronutrients: [String: MicronutrientValue]
}
```

Two design calls baked in there that your proposal is missing:

- **Selection cardinality per group** (`.one` vs `.many`). Chipotle = one base, one protein (or double), *many* toppings. Without this flag the build screen can't validate or guide the user — and "double protein" needs a clean answer (let `.one` groups allow a quantity multiplier, e.g. ×2).
- **Portions store absolute nutrition, not multipliers.** Tempting to make normal=1×, extra=2×, but real "light rice" isn't 0.5× and "extra cheese" isn't always 2×. Storing nutrition per portion is more data entry but is honest and is exactly what OCR will import anyway. If you want to reduce typing, let a portion *optionally* be "×N of Normal" with an explicit override — default to multiplier, allow absolute.

## 3. Snapshot vs. preset — your instinct is right, one watch-out

- **Snapshot on log** → denormalize the computed selection into a `NutritionEntry` exactly like a scan does. Set `brand = "Chipotle"`. This is consistent with your existing scan→entry and TrackedContainer flows.
- **Build preset** → store as a *selection*, not nutrition: `[{ groupID, itemID, portionID, multiplier }]`. Recalc walks the *current* calculator and re-applies.

Watch-out: **presets hold IDs that can dangle** when you edit the calculator (delete a topping, rename a group). Use stable UUIDs (above), and on recalc, skip-with-warning any missing reference rather than crashing or silently zeroing. Show the user "2 items in this preset no longer exist." Also store a **non-relational** `sourceCalculatorID: UUID?` on the logged entry — useful for "log again," but never a hard SwiftData relationship (keeps history immutable and avoids cascade surprises).

## 4. The real risk: authoring burden

Fully defining Chipotle by hand is *dozens* of items × multiple portions × 4+ macros each. Most users will start, feel the weight, and abandon. This is the feature's actual failure mode, not the data model. Mitigate:

- **OCR is the on-ramp, not a nicety.** Make "import from screenshot" the primary creation path, manual entry the fallback. Your `ScanResultCard` review pattern already exists — reuse it: OCR dumps rows into an editable staging table, user assigns each row to a group/portion, then commits. Never auto-commit OCR.
- **Make calculators incrementally useful.** A calculator with one group and three items should already be loggable. Don't gate logging behind "fully defined."
- **Seed one example** (a small built-in calculator) so the empty state teaches the model instead of describing it.

Be realistic that CloudKit is *private* DB — there's no community sharing of calculators without real backend work. Don't promise it.

## 5. UX flow nits

- **Separate Edit mode from Build mode.** Authoring the calculator (define groups/items/portions) and building-a-meal-to-log (pick portions, see running total like a cart) are different mental tasks — different screens. Don't overload one Form.
- **Plus menu crowding.** That menu is already AI Search / Composite / OFF / Manual / Archive. Adding Calculator makes 6. If you fold Calculator into the Composite concept (per §1), you avoid a sixth item.
- **Live running total while building** — you already have the `CompositeMacroCard` grid; reuse it as a sticky footer in the build screen.

## 6. CloudKit checklist (you know these, but for the new model)
All stored props need defaults; fully-qualify enum defaults (`SelectionRule.one`); no `@Attribute(.unique)` — dedup calculators app-side like `fetchOrCreateLog`; keep the Codable-blob approach so you add exactly one model to the schema and dodge nested-relationship migrations.

---

**Bottom line:** the snapshot/preset split is correct and already proven in your codebase — keep it. The data model should be one `@Model` + Codable groups, not a deep relationship tree. But before any of that, decide whether Calculator *is* an evolution of Composite Food or a parallel feature. I'd strongly push for evolution — same engine, add choice-groups and portion-presets — or you'll maintain two snapshotting systems that do 80% of the same thing.

Want me to sketch the concrete `kind: .calculator` extension to `SavedFood` so it reuses the composite totals math, or draft the build-vs-edit screen split?

## Implementation Decisions

I followed Claude's core recommendation: the calculator is a new `SavedFood.kind == .calculator`, not a separate `FoodCalculator` SwiftData model. That keeps it in the Food Bank, keeps CloudKit schema risk low, and reuses the existing pattern of "saved template now, copied nutrition when logged."

The current implementation uses flat value types under `SavedFood`:
- `CalculatorIngredient` for each restaurant or brand component.
- `CalculatorPortionOption` for portion names and absolute nutrition values.
- `CalculatorSelection` for a user's current build selection: ingredient, portion, quantity.

Portion names are plain strings entered by the user after nutrients are filled. The app does not model a fixed enum for labels like little/normal/extra. Quantity multipliers in the build screen handle cases such as double protein or multiple scoops without changing the saved calculator definition.

## What Shipped

### Food Bank entry point

`FoodBankView` now adds `Nutrition Calculator` to the same plus menu that already holds AI Search, Composite Food, Open Food Facts, Manual Entry, and Archive. Calculator rows use `SavedFoodRowView` with a calculator icon and ingredient count.

Tapping a calculator opens `NutritionCalculatorBuildView`; editing opens `NutritionCalculatorEditorView`. Archive and nested edit flows route calculators to those same views.

### Authoring flow

`NutritionCalculatorEditorView` supports:
- Restaurant/brand identity.
- A flat ingredient list.
- User-defined portion names.
- Macro and micronutrient entry per portion.
- Per-ingredient image import, including photo library and direct camera capture.
- Portion names entered after nutrient import, so Gemini fills numbers but users assign the actual restaurant/brand labels before saving.
- Quick Light (1/2x), Extra (2x), and Custom portion creation from the first portion.
- Deleting calculators without affecting old logged entries.

Draft rows are only inserted when the nested editor is saved. Cancelling an "Add Ingredient" or "Add Portion" sheet does not leave a placeholder behind.

### Gemini OCR import

`ScanService.extractCalculatorIngredient(named:from:useProModel:)` accepts up to 4 images for one user-named ingredient. The typed name anchors Gemini so it fills only that ingredient's portions instead of inventing a full calculator structure.

The ingredient editor appends returned nutrition as unnamed portions for review. Users then enter the actual portion names before saving the ingredient.

### Build and logging flow

`NutritionCalculatorBuildView` separates meal-building from authoring:
- Pick one portion per ingredient.
- Adjust quantity multipliers for selected items.
- See live macro totals.
- Add the build to the journal.

Logging creates a normal `NutritionEntry` with copied macros, micronutrients, `savedFoodID`, `servingUnit = "build"`, and a human-readable `selectionSummary`. Old entries are immutable snapshots; later calculator edits affect only future logs.

### Export/import

Backup DTOs now include:
- `SavedFood.calculatorIngredients`
- `NutritionEntry.selectionSummary`

These are additive fields under schema version 1. Older backup files still decode with defaults for missing calculator data.

CSV export now includes `Selection Summary` for analytics visibility.

### Project knowledge

The README and `.agents/skills/openfoodjournal` references were updated so future agents see calculators as a third saved-food kind, understand the portion naming rule, and know the new scan/OCR and backup surface area.

## Things I Ran Into

The main compiler issue was SwiftUI type inference in the quantities section. `Section("Quantities")` plus an optional row body from `if let` confused generic inference, so the final code uses an explicit `Section { } header: { } footer: { }` initializer and wraps optional content in `Group`.

The first editor draft inserted placeholder groups/items/portions immediately before opening a sheet. That worked but produced bad cancel behavior. I changed Add flows to create an in-memory draft and append only from the nested sheet's save callback.

I also checked whether the new Swift file needed project-file wiring. This project uses `PBXFileSystemSynchronizedRootGroup`, so adding `OpenFoodJournal/Views/FoodBank/NutritionCalculatorView.swift` on disk is enough for the target.

## Verification

Ran:

```bash
git diff --check
xcodebuild -quiet -project OpenFoodJournal.xcodeproj -scheme OpenFoodJournal -destination generic/platform=iOS -derivedDataPath /private/tmp/OpenFoodJournalDerivedData CODE_SIGNING_ALLOWED=NO build
```

Result: build succeeded. Existing unrelated warnings remain in `EditFoodSheet.swift` and `ContainerListView.swift` for unused local IDs.
