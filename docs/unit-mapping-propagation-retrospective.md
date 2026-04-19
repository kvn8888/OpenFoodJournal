# From "Add-Only" to Single Source of Truth: Building Bidirectional Unit Mapping Propagation

A user reported they could add serving unit mappings to foods but never update them. What started as a simple "add edit support" fix turned into rearchitecting how unit conversion data flows through the entire app — from the food template, to every logged entry, and back again.

## The Starting Point

OpenFoodJournal is an iOS food journaling app built with SwiftUI and SwiftData. One of its features is **serving unit mappings** — per-food conversion rules like "1 cup = 244g" that let users switch between measurement units when logging food. These mappings power the `ServingConverter`, a pure-value struct that handles all the math for converting between grams, cups, tablespoons, and arbitrary custom units like "slice" or "piece."

The problem: the UI only supported *adding* mappings, never *editing* or *deleting* them. But the deeper problem was architectural — each `NutritionEntry` (a logged meal) got its own independent *copy* of the mappings at log time. Changing a mapping on the `SavedFood` template wouldn't touch previously logged entries. There was no single source of truth.

Here's how `SavedFood.toNutritionEntry()` worked before:

```swift
func toNutritionEntry(mealType: MealType = .snack) -> NutritionEntry {
    NutritionEntry(
        name: name,
        // ...other fields...
        servingMappings: servingMappings  // Value-type copy — completely independent
    )
}
```

`ServingMapping` is a `Codable` struct (a Swift value type), so this created a deep copy every time. The food and the entry had no ongoing relationship.

## Step 1: Making the Sheet Support Editing

The `AddServingMappingSheet` was a simple form — "From" amount/unit, "To" amount/unit, Save button. It only worked in "add" mode because it had hardcoded initial values:

```swift
@State private var fromValue: String = "1"
@State private var fromUnit: String = "serving"
```

To support editing, I added a second initializer that accepts an existing mapping and pre-fills the fields:

```swift
init(existing: ServingMapping, onSave: @escaping (ServingMapping) -> Void) {
    self.onSave = onSave
    self.existing = existing
    let fv = existing.from.value
    _fromValue = State(initialValue: fv.truncatingRemainder(dividingBy: 1) == 0
        ? String(format: "%.0f", fv) : String(format: "%.2f", fv))
    _fromUnit = State(initialValue: existing.from.unit)
    // ...same for toValue/toUnit
}
```

The original `init(onAdd:)` remained unchanged for backward compatibility. The sheet detects which mode it's in via `var isEditing: Bool { existing != nil }` and changes its navigation title accordingly.

Each view that presents the sheet tracks `@State private var editingMappingIndex: Int?` — when `nil`, it's adding; when set, it's editing the mapping at that index. The `.sheet(isPresented:)` modifier checks this to decide which initializer to call:

```swift
.sheet(isPresented: $showAddMapping) {
    if let index = editingMappingIndex {
        AddServingMappingSheet(existing: entry.servingMappings[index]) { mapping in
            updateMapping(at: index, with: mapping)
        }
    } else {
        AddServingMappingSheet { mapping in
            addMapping(mapping)
        }
    }
}
```

## Step 2: Linking Entries to Their Parent Food

The key architectural addition: a `savedFoodID` on `NutritionEntry`.

```swift
// Links this entry back to the SavedFood it was logged from.
// Used to propagate mapping changes bidirectionally.
// Nil for entries that predate this field or were created without a SavedFood.
var savedFoodID: UUID?
```

This is a lightweight migration in SwiftData — adding an optional property with a default of `nil` doesn't require explicit migration code. CloudKit handles it gracefully: existing records just won't have the field, and it defaults to `nil` when materialized.

`SavedFood.toNutritionEntry()` now sets `savedFoodID: id` so every new entry from the Food Bank is automatically linked.

## Step 3: Bidirectional Propagation in NutritionStore

This was the core of the change. `NutritionStore` (the SwiftData CRUD layer) got a family of propagation methods. The central one is `updateMappings(on:to:)`, which comes in two flavors — one for SavedFood, one for NutritionEntry:

```swift
/// Updates a SavedFood's mappings and propagates to all linked entries.
func updateMappings(on food: SavedFood, to newMappings: [ServingMapping]) {
    let deduped = Self.dedupMappings(newMappings)
    food.servingMappings = deduped

    // Propagate to all entries linked to this food
    let foodID = food.id
    let descriptor = FetchDescriptor<NutritionEntry>(
        predicate: #Predicate { $0.savedFoodID == foodID }
    )
    if let entries = try? modelContext.fetch(descriptor) {
        for entry in entries {
            entry.servingMappings = deduped
        }
    }
    save()
}
```

The entry version does the reverse — updates the entry, finds the parent SavedFood, updates it, then finds all sibling entries:

```swift
func updateMappings(on entry: NutritionEntry, to newMappings: [ServingMapping]) {
    let deduped = Self.dedupMappings(newMappings)
    entry.servingMappings = deduped

    guard let foodID = entry.savedFoodID else {
        save()  // Orphaned entry — just save locally
        return
    }

    // Update parent SavedFood
    let foodDescriptor = FetchDescriptor<SavedFood>(
        predicate: #Predicate { $0.id == foodID }
    )
    if let food = try? modelContext.fetch(foodDescriptor).first {
        food.servingMappings = deduped
    }

    // Update all sibling entries
    let entryID = entry.id
    let entryDescriptor = FetchDescriptor<NutritionEntry>(
        predicate: #Predicate { $0.savedFoodID == foodID && $0.id != entryID }
    )
    if let siblings = try? modelContext.fetch(entryDescriptor) {
        for sibling in siblings {
            sibling.servingMappings = deduped
        }
    }
    save()
}
```

Higher-level convenience methods (`addMapping`, `replaceMapping`) delegate to these. The views call the convenience methods and never touch `servingMappings` directly anymore.

## Step 4: Deduplication — One Mapping Per Unit

The user had a "Milk" food with two separate unit mappings that should have been one. This happens when someone adds "1 cup = 244g" and then adds another "1 cup = 250g" without realizing the first one exists.

The dedup function uses the `from.unit` (lowercased, trimmed) as the unique key. When duplicates exist, the last one wins:

```swift
static func dedupMappings(_ mappings: [ServingMapping]) -> [ServingMapping] {
    var seen: [String: Int] = [:]  // from.unit → index in result
    var result: [ServingMapping] = []
    for mapping in mappings {
        let key = mapping.from.unit.lowercased().trimmingCharacters(in: .whitespaces)
        if let existingIndex = seen[key] {
            result[existingIndex] = mapping  // Replace with newer
        } else {
            seen[key] = result.count
            result.append(mapping)
        }
    }
    return result
}
```

This runs automatically in every `updateMappings` call, so duplicate mappings are structurally impossible going forward.

## Step 5: Migrating Existing Data

There were two migration tasks:

1. **Retrolink orphaned entries** — Existing entries have no `savedFoodID`. The migration matches them to SavedFoods by `name + brand` (both lowercased) and links them:

```swift
func retrolinkOrphanedEntries() {
    let entryDescriptor = FetchDescriptor<NutritionEntry>(
        predicate: #Predicate { $0.savedFoodID == nil }
    )
    guard let orphans = try? modelContext.fetch(entryDescriptor), !orphans.isEmpty else { return }

    // Build lookup: "name|brand" → SavedFood
    var foodLookup: [String: SavedFood] = [:]
    for food in foods {
        foodLookup["\(food.name.lowercased())|\(food.brand?.lowercased() ?? "")"] = food
    }

    for entry in orphans {
        let key = "\(entry.name.lowercased())|\(entry.brand?.lowercased() ?? "")"
        if let food = foodLookup[key] {
            entry.savedFoodID = food.id
            entry.servingMappings = food.servingMappings  // Sync from source of truth
        }
    }
}
```

2. **Dedup all existing mappings** — Scans every SavedFood and NutritionEntry, deduplicating any that have more than one mapping.

Both run once on app launch, gated by `@AppStorage("hasRetrolinkedMappings")`.

## The Design Decision: Why No Delete?

I initially added swipe-to-delete on mapping rows. The user caught this and asked: "What happens if we delete unit mappings and references are lost on saved food items?"

The answer is bad. If an entry was logged with `selectedUnit = "cup"` (from a "1 cup = 244g" mapping), and that mapping gets deleted, the `ServingConverter.factorFor("cup")` falls through all four conversion strategies and returns `1.0`. That means "1 cup" would be treated as "1 serving" — macros would display incorrectly for every historical entry that used that unit.

The safe choice: **no delete, only edit and add.** If you got the conversion wrong (e.g. "1 cup = 244g" should be "1 cup = 250g"), you edit it. The mapping still exists, the unit reference remains valid, and propagation updates every entry that uses it.

This is a case where data integrity trumps UI flexibility. A delete button feels natural, but the consequences are silent data corruption across historical entries.

## What's Next

- **Container tracking** doesn't carry mappings yet — `TrackedContainer.toNutritionEntry()` creates entries without `savedFoodID` or `servingMappings`. If containers need unit switching, they'll need the same linking.
- **Conflict resolution** — If two devices edit the same mapping simultaneously via CloudKit, SwiftData picks a winner silently. For unit mappings this is probably fine (last-write-wins on a rarely-changed field), but worth monitoring.
- **`ServingMappingSection`** in `Views/Shared/` is dead code — it was a reusable component that neither view ended up using (both have inline mapping sections). Should be cleaned up.

---

The lesson: a "can't edit" bug in the UI exposed a "no source of truth" bug in the architecture. The edit button was the easy part. Making it mean something across every copy of the data — that was the real work.
