# From Macro-Only HealthKit Sync to Micronutrient Repair

OpenFoodJournal could write food entries to Apple Health, but the historical data told a strange story: calories, protein, carbs, and fat showed up across dates, while micronutrients mostly did not. This session turned that symptom into a concrete bug class: the app stored micronutrients with multiple key shapes, but the HealthKit writer only understood one of them.

## The Starting Point

The app stores macros as fixed properties on `NutritionEntry`:

```swift
entry.calories
entry.protein
entry.carbs
entry.fat
```

HealthKit writes those directly, so macro export was reliable.

Micronutrients are different. They live in a dictionary because Gemini, Open Food Facts, manual entry, and nutrition calculators can all return different nutrient sets:

```swift
var micronutrients: [String: MicronutrientValue] = [:]
```

That flexibility is useful, but it also means the key string matters. In Swift dictionaries, `"Sodium"` and `"sodium"` are unrelated keys. The app had historical entries using both display names and canonical IDs, but HealthKit was only reading display names.

## Step 1: Reproducing the Real Failure

I used the optional Turso mirror as a read-only debugging window. Turso is the user-configured SQL mirror of SwiftData; it is not the source of truth, but it lets us ask questions that are awkward from the app UI.

The important result was not that micronutrients were missing from app data. They were present:

- Almost every mirrored nutrition entry had non-empty micronutrient JSON.
- Every logged date in the mirrored range had micronutrient data.
- Every entry was marked `healthkit_sync_status = synced`.
- Every entry had a stored HealthKit write hash.

That explained why the Settings backfill button did nothing. The app was not seeing those entries as missing or stale; it thought they were already exported.

The code made the reason obvious:

```swift
if !force,
   entry.healthKitSyncStatus == HealthKitSyncStatus.synced,
   entry.healthKitLastWriteHash == writeHash {
    return .skipped
}
```

That short-circuit is correct for normal sync. It prevents duplicate work. But it is not enough when the old writer marked an entry synced after writing only macros.

## Step 2: Finding the Key Mismatch

Issue #4 was directly related to issue #10. Issue #4 said AI Search normalized micronutrients to canonical IDs like `sodium` and `fiber`, while some downstream screens still looked for display names like `Sodium` and `Fiber`.

HealthKit had exactly that problem:

```swift
SampleDefinition(key: "dietarySodium", ...) {
    $0.micronutrients["Sodium"]?.value
}
```

That works for manual entries that store `"Sodium"`, but it fails for Gemini-backed entries that store `"sodium"`.

The fix was to move lookup behavior into one shared helper:

```swift
static func value(
    in micronutrients: [String: MicronutrientValue],
    forID id: String,
    aliases: [String] = []
) -> MicronutrientValue? {
    let canonicalID = normalize(id)

    for (key, value) in micronutrients where normalize(key) == canonicalID {
        return value
    }

    return nil
}
```

Now HealthKit can ask for `"sodium"` and still read older `"Sodium"` entries. The same helper also supports Manual Entry prefill, so AI Search results with canonical keys populate the visible rows instead of appending confusing duplicate rows.

## Step 3: Treating Total Sugar as Its Own Nutrient

There was another small modeling gap: `added_sugars` existed, but total sugar did not. Apple Health's `dietarySugar` is total sugar, not added sugar. So I added `sugar` as a known nutrient distinct from `added_sugars`.

That matters because these are not interchangeable:

- `sugar`: total dietary sugar
- `added_sugars`: the subset added during processing/preparation

Total sugar has no FDA Daily Value, so the UI needed to avoid showing a fake `0 g/day` target. The ring picker now displays `No DV` for known nutrients without a daily value.

## Step 4: Adding an Explicit Repair Action

The normal button remains incremental:

- **Sync Missing Nutrition to Apple Health** only writes entries whose HealthKit status or hash says they need work.

The new button is explicit:

- **Repair Apple Health Nutrition** rewrites all OpenFoodJournal entries to Apple Health with `force: true`.

That distinction matters because repair is historical. It intentionally ignores the synced/hash short-circuit, deletes samples owned by OpenFoodJournal for each entry, and writes replacements using the same deterministic HealthKit sync identifiers.

That gives us the behavior we need:

```swift
let result = await sync(entry, in: modelContext, force: force)
```

Repair is safe from duplication because the app deletes only samples matching identifiers like:

```swift
k3vnc.OpenFoodJournal.<entry-id>.<sample-key>
```

It does not touch HealthKit samples from other apps.

## The Gotcha: June 17 and June 22 Were Both Clues

The reported behavior was more nuanced than the first diagnosis:

- A June 21 HealthKit sync wrote macros across dates.
- Micronutrients only appeared for June 17 at first.
- Later, June 22 micronutrients appeared too.

The June 22 explanation was clean: that entry used display-name keys like `"Sodium"` and `"Fiber"`, which the old writer could read.

June 17 was less clean. The current mirrored data for June 17 uses canonical keys, so the current writer would not write those micronutrients either. That means the visible June 17 HealthKit samples likely came from an older write path, older key shape, or Health app state that persisted after the app's local data was normalized.

That was the important correction: the reliable root cause is not "June 17 is special." The reliable root cause is "the writer only read one key shape."

## What's Next

This fixes the key bridge and gives users a repair path for historical macro-only HealthKit exports. It does not expand the list of HealthKit nutrients beyond the current supported set. That remains issue #11.

The next improvements should be:

- Expand HealthKit sample definitions for additional nutrients Apple supports.
- Add a dedicated automated test around Manual Entry prefill from canonical AI Search data.
- Consider recording a HealthKit writer schema version so future writer changes can automatically mark old entries stale without needing a manual repair button.

---

Flexible data is useful only if every consumer agrees on how to read it.
