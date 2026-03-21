# The Serving Unit Bug: When "serving" ≠ "Cup"

OpenFoodJournal's LogFoodSheet lets you pick a food from your Food Bank, adjust the quantity and unit (grams, cups, oz), and log it. The unit conversion math was supposed to scale macros proportionally — 1 cup of milk at 160 cal should mean 1 gram ≈ 0.64 cal. Instead, switching units did nothing. 1 gram = 160 calories. The macros were frozen to the base serving no matter what unit you picked.

---

## The Starting Point

The conversion pipeline had three layers, each a fallback for the next:

1. **`ServingSize.convert()`** — the structured enum (`.mass(grams:)`, `.volume(ml:)`, `.both(grams:ml:)`) with standard conversion tables for mass and volume units. Handles same-dimension conversions (g → oz) and cross-dimension if the food has `.both` (cups → grams via density).

2. **`servingMappings`** — an array of `ServingMapping` structs per food, each storing a `from: ServingAmount` / `to: ServingAmount` pair. These are per-food custom conversions like "1 cup = 244 g", created by Gemini during scanning or added manually by the user.

3. **Canonical SI bridge** — if the `ServingSize` enum knows the food weighs 240g per serving, derive conversions to other mass units through that anchor.

The `factorFor(_ unit:)` function tried each layer and returned the first match. If none matched, it returned `1.0` — which silently meant "1 of this unit equals 1 of the base unit." That's the fallback that was always firing.

---

## Step 1: Building the Conversion Pipeline

The initial implementation of `factorFor` was straightforward:

```swift
private func factorFor(_ unit: String) -> Double {
    if unit == baseUnit { return 1.0 }
    if let factor = food.serving?.convert(1.0, from: baseUnit, to: unit) {
        return factor
    }
    for mapping in food.servingMappings {
        if mapping.from.unit == baseUnit && mapping.to.unit == unit {
            return mapping.to.value / mapping.from.value
        }
    }
    return 1.0
}
```

This worked in the simple case — food has a `.both(grams:ml:)` serving, both dimensions are known, `convert()` handles everything. But real-world food data from Gemini rarely has `.both`. Milk comes back as `.volume(ml: 240)` because it's a liquid. The weight comes separately in a `servingMapping`.

I added a chaining step: if a mapping gets you to an intermediate unit (e.g., "cup → g"), then standard conversion tables can get you the rest of the way (e.g., "g → oz"). I also added the canonical SI bridge for cases where `ServingSize` has grams/mL but the base unit isn't a standard measurement unit.

None of this fixed the bug.

---

## Step 2: The Screenshot That Explained Everything

After two rounds of code changes that built successfully but didn't fix the issue, a screenshot from the actual device showed the answer:

- Food: **Lactose Free Whole Milk**
- Serving: **1 Cup (240mL)**
- Unit Mappings section: **1 serving → 250 g**
- Selected unit: **g**
- Quantity: **1**
- Calories: **160** (unchanged from the full serving)

The mapping said `1 serving → 250 g`. But `baseUnit` was `"Cup"` — derived from `food.servingUnit`. The lookup code compared:

```swift
mapping.from.unit == baseUnit  // "serving" == "Cup" → false
```

Every step in the pipeline checked against `baseUnit`. The word "serving" in the mapping is a generic synonym for "one of whatever this food's serving is" — but the code treated it as a literal unit name. Since `"serving" != "Cup"`, the mapping was invisible to the conversion logic, and `factorFor` fell through to the `return 1.0` default.

This is the kind of bug that's obvious in hindsight but hard to find by reading code alone. The logic was correct for its assumptions. The assumption — that mapping units always use the same string as `servingUnit` — was wrong.

---

## The Gotcha: Gemini Says "serving", the Food Says "Cup"

When Gemini scans a nutrition label, it returns structured data including `servingUnit` (e.g., `"Cup"`) and `servingWeightGrams` (e.g., `250`). The scan processing code in `ScanService` creates a mapping:

```swift
mappings.append(ServingMapping(
    from: ServingAmount(value: qty, unit: unit),  // "Cup"
    to: ServingAmount(value: grams, unit: "g")
))
```

This uses the literal `servingUnit` — so the mapping would be `1 Cup → 250 g`. But somewhere in the data pipeline (possibly from Turso sync, manual editing, or a different Gemini response format), the mapping ended up as `1 serving → 250 g`. The word "serving" is semantically correct — it IS one serving — but it's not the same string as the `servingUnit` field.

The fix was a three-line helper:

```swift
private func isBaseUnit(_ unit: String) -> Bool {
    unit == baseUnit || unit.lowercased() == "serving"
}
```

Then every mapping comparison used `isBaseUnit()` instead of `== baseUnit`. This treats "serving" as an alias for whatever the food's actual base unit is. Applied to both `LogFoodSheet` and `EditEntryView` so the behavior is consistent everywhere you can change units.

---

## The Revision: From One Bug to Three Fixes

What started as "unit conversion doesn't work" turned into three distinct improvements:

1. **The alias fix** — `isBaseUnit()` treating "serving" as a synonym for `baseUnit`. This was the actual bug.

2. **Mapping chaining** — Even after the alias fix, switching from "Cup" to "oz" would fail if the only mapping was `Cup → g`. The chaining step bridges through an intermediate: `Cup → 250 g` (from mapping) then `g → oz` (from standard table, dividing by 28.35) = `~8.82 oz`. Without chaining, you'd need a separate mapping for every target unit.

3. **Format specifier fix** — The `%.2g` format used for the auto-converted quantity produces scientific notation for numbers above ~100. `String(format: "%.2g", 250.0)` gives `"2.5e+02"`, not `"250"`. Changed to `%.2f` which always gives decimal notation.

---

## What's Next

This debugging session surfaced several design questions worth addressing:

**Rename "Micronutrients" to "Nutrition"** — The micronutrient summary view already has a time-period picker (daily/weekly/monthly) and progress bars against FDA daily values. It should consolidate macros *and* micros into one "Nutrition" view rather than treating them as separate concepts. Macros are already shown elsewhere, but having one unified nutrition detail view makes more sense.

**History view needs rethinking** — Currently, tapping a date card opens a `DayDetailView` as a separate navigation push. That's one extra tap just to glance at what you ate. The entries should be visible inline. The "Past 7 Days" chart should become a "Last Week vs This Week" comparison for each macro, and a day/week/month segmented picker should let you choose the averaging window.

**iCloud integration is redundant** — The app syncs to Turso (a hosted SQLite database) as its cloud backend. The Settings view shows "iCloud Sync: Automatic" as a static label, but there's no actual iCloud/CloudKit integration — SwiftData *can* do this, but we don't need two cloud sync paths. Replace it with "Last synced to server" showing the Turso sync timestamp.

**"Save scan photos" needs clarity** — The toggle (`retain.source.images` in `@AppStorage`) controls whether the source JPEG from the camera is persisted on the `NutritionEntry` via `@Attribute(.externalStorage)`. It exists because scan photos can be large and most users won't need them after the nutrition data is extracted. The label should probably say "Keep original scan photos" with a caption explaining the storage tradeoff.

---

The lesson from this bug is older than Swift: when two systems name the same concept differently, the glue code between them is where bugs hide. Gemini called it "serving." The food model called it "Cup." The conversion code assumed they'd agree. They didn't, and 1 gram of milk briefly contained an entire cup's worth of calories.
