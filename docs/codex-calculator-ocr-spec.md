# Task: Simplify the Nutrition Calculator OCR import (name-first, per-ingredient)

## Project context
- **App:** OpenFoodJournal — iOS 26.2+ food journal. SwiftUI + Liquid Glass, SwiftData + CloudKit (private DB), no SPM deps.
- **Branch:** `app-store`.
- **Build/verify (compile-only; no simulators installed):**
  ```
  xcodebuild -project OpenFoodJournal.xcodeproj -scheme OpenFoodJournal -destination generic/platform=iOS build
  ```
- Optional but helpful: read `.claude/skills/openfoodjournal/SKILL.md` for conventions.

## Why
The "Nutrition Calculator" feature lets a user build a restaurant meal (e.g. a Chipotle bowl) from saved ingredients. Its prior OCR import was backwards and confusing: it dumped a whole image at Gemini, asked Gemini to extract *many* rows and *invent* a group/ingredient/portion structure, then auto-binned them by fuzzy name match. The user never named anything.

**Desired flow instead:** the user names one ingredient ("White Rice"), chooses an image of *that item's* nutrition panel, and Gemini fills in **just that ingredient**. Repeat per ingredient. Then assemble a meal from those ingredients and log it. This must generalize to any restaurant, not just Chipotle.

We are also **flattening** the calculator model: drop the `Group` layer, selection rules (single/multiple), "required" flags, and saved presets. A calculator is simply a named source holding a **flat list of ingredients**, each with one or more **portions**.

## Files in scope
- `OpenFoodJournal/Models/SavedFood.swift`
- `OpenFoodJournal/Services/ScanService.swift`
- `OpenFoodJournal/Views/FoodBank/NutritionCalculatorView.swift`
- `OpenFoodJournal/Views/FoodBank/FoodBankView.swift` (only if initializer signatures change — see below; aim to avoid)

**Do NOT touch:** `AIFoodSearchView.swift`, label/food-photo/barcode scan paths, Open Food Facts, Composite Food (`kind == .composite`), or any unrelated view.

---

## 1) Model changes — `SavedFood.swift`

**Delete these types entirely:** `CalculatorGroup`, `CalculatorSelectionRule`, `CalculatorPreset`.

**On `@Model final class SavedFood`:**
- Remove stored props `calculatorGroups: [CalculatorGroup]` and `calculatorPresets: [CalculatorPreset]` (and their `init` params + assignments).
- Add: `var calculatorIngredients: [CalculatorIngredient] = []` (CloudKit requires a default — `[]` satisfies it). Add a matching `init` param `calculatorIngredients: [CalculatorIngredient] = []` and assign it.
- Existing test calculators will reset — acceptable, the feature is unreleased on this branch.

**`CalculatorSelection`** — drop `groupID`; keep `ingredientID`, `portionID`, `quantity` (update both initializers and all references).

**Update the calculator helpers** to operate on `[CalculatorIngredient]` instead of `[CalculatorGroup]`:
- `calculatorTotals(for ingredients: [CalculatorIngredient], selections:)`
- `calculatorSelectionSummary(for ingredients: [CalculatorIngredient], selections:)` → produce `"Ingredient (Portion)"`, comma-joined (no group name).
- `missingCalculatorSelectionCount(for ingredients: [CalculatorIngredient], selections:)`
- private `resolve(_:in ingredients: [CalculatorIngredient]) -> (ingredient: CalculatorIngredient, portion: CalculatorPortionOption)?` (drop the group tuple element).
- `refreshCalculatorNutrition()` — change the `servingSize` string from groups-count to `"\(calculatorIngredients.count) ingredient\(calculatorIngredients.count == 1 ? "" : "s")"`.

**Add a portion-scaling convenience** (used by the ½×/2× scoop buttons):
```swift
extension CalculatorPortionOption {
    func scaledPortion(by factor: Double, label: String) -> CalculatorPortionOption {
        CalculatorPortionOption(
            label: label,
            calories: calories * factor,
            protein: protein * factor,
            carbs: carbs * factor,
            fat: fat * factor,
            micronutrients: micronutrients.mapValues {
                MicronutrientValue(value: $0.value * factor, unit: $0.unit)
            }
        )
    }
}
```
(Keep `CalculatorIngredient` and `CalculatorPortionOption` as they are — they already model name → portions with absolute macros + micros.)

---

## 2) Service changes — `ScanService.swift`

**Delete:** `CalculatorOCRRow`, `CalculatorOCRResponse`, `extractCalculatorRows(from:useProModel:)`, and the `calculatorOCRPrompt` static string.

**Add draft decode types** (do **not** decode directly into `CalculatorPortionOption`/`CalculatorIngredient` — they carry `id: UUID` that Gemini won't supply; decode into id-less drafts, then map in the view):
```swift
struct CalculatorPortionDraft: Codable, Sendable {
    var label: String
    var calories: Double
    var protein: Double
    var carbs: Double
    var fat: Double
    var micronutrients: [String: MicronutrientValue]
}
struct CalculatorIngredientDraft: Codable, Sendable {
    var name: String
    var portions: [CalculatorPortionDraft]
}
```

**Add method** (mirror the old `extractCalculatorRows` plumbing: image prep at maxDimension 1600 / JPEG 0.72, `ModelConfig.aiSearch(useProModel:)`, the `callGeminiText` / streaming path, and `recordGeminiScanLog` success/failure calls):
```swift
func extractCalculatorIngredient(
    named name: String,
    from images: [UIImage],
    useProModel: Bool = false
) async throws -> CalculatorIngredientDraft
```
- Inject `name` into the prompt (below). Decode the returned text into `CalculatorIngredientDraft`. Filter out portions whose `label` is blank.
- The returned `name` is a fallback only; the view keeps the user-typed name authoritative.

**Add prompt** (a function that injects the name):
```swift
static func calculatorIngredientPrompt(name: String) -> String {
"""
You are importing ONE ingredient for a restaurant/brand nutrition calculator in a food journal.

The user is importing the ingredient named: "\(name)".

Read the provided image(s) of this item's nutrition information. Extract data for THIS ingredient only — ignore any other menu items visible in the image.

Return a JSON object with this EXACT structure:
{
  "name": "<the ingredient name as the source labels it>",
  "portions": [
    {
      "label": "<serving/portion label exactly as shown, e.g. '4 oz', '1 scoop', 'Single', 'Double'>",
      "calories": <number>,
      "protein": <grams as number>,
      "carbs": <grams as number>,
      "fat": <grams as number>,
      "micronutrients": { "<nutrient_id>": {"value": <number>, "unit": "<g|mg|mcg|IU|%>"} }
    }
  ]
}

Rules:
- If the source lists multiple serving sizes for this one item (e.g. 4 oz vs 8 oz, single vs double, regular vs large), return ONE portion object per size, labeled exactly as shown.
- If only one amount is shown, return a single portion using the visible serving label, or "Serving" if none is visible.
- Do not invent extra sizes. Do not return other ingredients.
- Use 0 for a macro only when the source explicitly shows 0; omit micronutrients you can't read.
- Prefer canonical micronutrient IDs: fiber, added_sugars, sugar, sodium, cholesterol, saturated_fat, trans_fat, calcium, iron, potassium, vitamin_a, vitamin_c, vitamin_d.
- Return only JSON. No markdown, comments, citations, or prose.
"""
}
```

---

## 3) View changes — `NutritionCalculatorView.swift`

**Preserve these initializer signatures** so `FoodBankView` needs no changes:
- `NutritionCalculatorLibraryView(logDate: Date)`
- `NutritionCalculatorEditorView(calculator: SavedFood? = nil)`
- `NutritionCalculatorBuildView(calculator: SavedFood, logDate: Date)`

**Delete:** `CalculatorGroupEditorSheet`, `CalculatorGroupRow`, `CalculatorOCRRowView`.

**`NutritionCalculatorEditorView`:**
- Remove the calculator-level OCR section and all its state: `selectedPhotoItems`, `stagedRows`, `ocrError`, `isImportingOCR`, `extractOCRRows()`, `importStagedRows()`, plus `editingGroup` and the group sheet.
- Replace `groups` state with `@State private var ingredients: [CalculatorIngredient]` initialized from `calculator?.calculatorIngredients ?? []`. Remove `presets`.
- Replace `groupsSection` with an **Ingredients** section: list ingredients (tap → `CalculatorIngredientEditorSheet`), `.onDelete` to remove, and an "Add Ingredient" button that opens the ingredient editor with a blank `CalculatorIngredient`.
- `saveCalculator()`: write `calculator.calculatorIngredients = ingredients`; on create, pass `calculatorIngredients:` to the `SavedFood` initializer and set `servingSize` to the ingredient-count string. Drop all preset handling. Keep the existing `tursoMirror.scheduleMirror(reason:)` calls (adjust reason strings as needed).

**`CalculatorIngredientEditorSheet`** (the core of the new flow — add OCR here):
- Keep name + note fields and the existing editable **Portions** list (rows open `CalculatorPortionEditorSheet`, which stays as-is for manual edits).
- Add an **Import Nutrition** section:
  - A **Choose Image** button opens a source picker with Photo Library and Take Photo.
  - An **Import from Image** button — disabled unless `name` is non-empty **and** at least one image is selected/captured (the typed name anchors extraction). On tap: load the `UIImage`s, call `scanService.extractCalculatorIngredient(named: name, from: images, useProModel:)` (read `@AppStorage("scan.useProModel")` like the rest of the app), map each returned `CalculatorPortionDraft` → `CalculatorPortionOption(label:"", calories:protein:carbs:fat:micronutrients:)`, and **append** them to `portions`. Gemini fills nutrition only; users then enter actual portion names before saving. Show an inline progress label while running and an inline red error string on failure.
- Add **scoop quick-actions**, visible once `portions` has at least one entry. Treat the **first** portion as the base ("Normal"):
  - **"Add Light (½×)"** → append `base.scaledPortion(by: 0.5, label: "Light")`
  - **"Add Extra (2×)"** → append `base.scaledPortion(by: 2.0, label: "Extra")`
  - **"Add Custom…"** → open `CalculatorPortionEditorSheet` with a blank portion for manual label + numbers.
  - If a portion with that label already exists, replace it rather than duplicating.
- Get `ScanService` via `@Environment(ScanService.self)`.

**`NutritionCalculatorBuildView`:**
- Remove `presetsSection`, the preset alerts, and state `presetName` / `showPresetPrompt` / `presetWarning` / `applyPreset()` / `savePreset()` and the "Save Build Preset" button.
- Remove `missingRequiredGroups`; simplify `canLog` to `!selections.isEmpty && !buildName.trimmed.isEmpty`.
- Replace `groupsSection` with a flat **Ingredients** section: one `Section`/row per `calculator.calculatorIngredients`, each a `Picker` over that ingredient's `portions` with a `"None"` tag (`""`). Selecting a portion adds/updates a `CalculatorSelection(ingredientID:portionID:quantity:)`; "None" removes it. (This is the old `.multiple` path applied uniformly — no single/multiple distinction, nothing required.)
- Simplify `selectionKey`/`selection(from:)` to encode just `ingredientID|portionID` (two components).
- `totals` → `SavedFood.calculatorTotals(for: calculator.calculatorIngredients, selections: selections)`.
- Keep `quantitiesSection` (per-selection quantity stepper) using the new flat `resolvedSelection`.
- `logBuild()` → summary via `SavedFood.calculatorSelectionSummary(for: calculator.calculatorIngredients, selections:)`.

**Update `#Preview`** if it references removed symbols.

---

## Constraints & gotchas (this codebase)
- CloudKit: every stored `@Model` property needs a default; enum defaults must be **fully qualified** (`SavedFoodKind.single`, not `.single`). The new `calculatorIngredients: [CalculatorIngredient] = []` is fine.
- `.swipeActions` only works **inside a `List`** (silently ignored elsewhere). For tappable list rows, use `Button { } label: { Row() }.buttonStyle(.plain)`.
- Swift named params must be passed in declaration order — when you change an initializer, update all call sites.
- A `private` type is scoped to the enclosing type, not the file; use `fileprivate` for helpers shared across structs in the same file.
- Keep the existing `@Environment(TursoMirrorService.self)` usage and `scheduleMirror(reason:)` calls in the editor/build views.

## Definition of done
1. `xcodebuild … -destination generic/platform=iOS build` succeeds.
2. No remaining references to: `calculatorGroups`, `calculatorPresets`, `CalculatorGroup`, `CalculatorPreset`, `CalculatorSelectionRule`, `groupID`, `extractCalculatorRows`, `CalculatorOCRRow`, `calculatorOCRPrompt`, `CalculatorGroupEditorSheet`, `CalculatorGroupRow`, `CalculatorOCRRowView`, `presetsSection`, `missingRequiredGroups`, `applyPreset`, `savePreset` (grep to confirm).
3. Manual flow works: Food Bank → **+** → Nutrition Calculator → **+** → name "Chipotle" → Add Ingredient "White Rice" → type name, choose an image, **Import from Image** populates ≥1 unnamed portion → name the actual portion → **Add Extra (2×)** and **Add Light (½×)** produce scaled portions → save → add "Chicken" → save calculator → tap it → pick a portion per ingredient + quantity → totals update → **Add to Journal** logs one entry with a summary like `White Rice (Extra), Chicken (Double)`.
