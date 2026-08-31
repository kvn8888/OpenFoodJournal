# Design versions

The source files are versioned in Git. We also name useful checkpoints using
`design/journal/...` and `design/nutrition/...` tags so they are easier to find.
Tags are local until explicitly pushed; they are not TestFlight releases.

History now has its own `HistoryDesign.swift` and `design/history/...` namespace.
Use `bash DesignPlaygrounds/Journal/history.sh history list` (or `versions`,
`diff`, `export`, `save`) for the same non-overwriting workflow. The first
`calendar-trends-v1` checkpoint follows the owner reference's hierarchy, not
its orange palette, website framing, or Settings tab. It uses the Journal's
40pt rings/3pt strokes, 80/95/105% progress palette, native Liquid Glass date
controls, three-row tracked-micro selection, and a separate mock day breakdown.
Journal/Nutrition source files are not changed by this concept.

From the repo root:

```sh
bash DesignPlaygrounds/Journal/history.sh journal versions
bash DesignPlaygrounds/Journal/history.sh journal list
bash DesignPlaygrounds/Journal/history.sh journal diff design/journal/neutral-pill-v1
bash DesignPlaygrounds/Journal/history.sh journal export design/journal/neutral-pill-v1
```

`export` writes a separate Swift file under the ignored `.build/design-history`
folder on DevDisk. It refuses to overwrite an existing export and never touches
your working design. Compare that file in Xcode before deciding what to bring
back. `diff` includes your current uncommitted edits in the comparison.

To name a new version: save and commit the chosen design file in Xcode's source
control UI (or ask Codex), then run:

```sh
bash DesignPlaygrounds/Journal/history.sh journal save my-next-design
```

The helper refuses to create a checkpoint of an uncommitted design, because that
would silently tag an older version. Existing tags cannot be overwritten. Use
`nutrition` instead of `journal` for the separate Nutrition file.

## Initial checkpoints

- `design/journal/neutral-pill-v1`: released Journal mock with the tuned neutral
  macro pill, 51pt image placeholders, and separate light/dark gradients.
- `design/nutrition/baseline-v1`: first isolated Nutrition view, before tuning.
- `design/nutrition/reference-aligned-v1`: closer visual baseline matching the
  app's nutrient order, complete metadata, bar metrics, and value formatting.

Both initial tags point to local commit `6315e0e`; that commit contains the
respective screen versions. The helper's export refuses to overwrite an existing
copy, so the working design is never the restore destination by accident.

Verification: the Mac target builds with both design files, and Nutrition renders
in Xcode Canvas on My Mac. History list/version/diff/export were checked locally.

The Journal's earlier circle/RGB/neutral-chip variants also remain in the file's
Git history. `history.sh journal list` searches all local branches, including
the detailed playground commits that preceded the squashed release PR.

## Nutrition workspace

Open `NutritionDesign.swift` in this same Xcode project; select My Mac and resume
Canvas. Its `NutritionStyle` values are independent from `JournalStyle`.
Light/dark previews use fictional data. Running the Mac app adds **Designs →
Journal / Nutrition** menu commands (⌥⌘1 / ⌥⌘2). No app logic or services are
shared, and none of these mock files belongs to the shipping target.

### Calorie ring + macro bars concept

`design/nutrition/ring-and-bars-v1` follows the owner-supplied Claude reference's
basic structure: Day/Week/Month tabs, date/context line, one glass summary card
with a calorie ring beside three macro bars, and a divided summary line below.
The orange accent, 104pt ring/10pt stroke, card padding, bar height, and caption
size are editable in `NutritionStyle`. Below-target bars are neutral; near-target
bars use the accent; over-target bars show a hatched end and an explicit percentage.

The summary is deterministic text computed from fictional values, not AI advice.
The mock data and all 37 detailed nutrient definitions are retained. This concept
intentionally replaces the previous macro grid/date-arrow layout; historical date
navigation and real aggregation would need to be preserved when porting to the app.
The reference-aligned and original baseline tags remain available for comparison.
Verified with a native Mac build and live Xcode Canvas rendering; no shipping-app
changes or release are part of this concept.

### Reference-aligned Nutrition baseline

Compared with `OpenFoodJournal/Views/Shared/NutritionDetailView.swift`:

- Preserves the two-column macro grid, 100pt rings, 5pt strokes, 15% tracks,
  20pt values (standard iPhone title3), 9pt units, and percentage labels.
- Uses Vitamins → Minerals → Other Nutrients. All 37 reference nutrient names,
  units, goals, category assignments and common flags match: 13 common, 24 more.
- Micronutrient bars are 6pt with a quaternary track, 6pt content gap and 2pt
  vertical content padding. Text includes percentages and missing-data dashes;
  zero-DV nutrients don't receive invented goals or percentages.
- Removed the original mock's additional glass cards/shadows and arbitrary
  22pt spacing. Section layout is a flat grouped approximation, not a redesign.
- Date buttons now use 32pt labels and the app's native glass button style;
  the framework's final shape/appearance can still differ on macOS.
- Added direction-aware numeric transitions and a missing-data preview/toggle.

Native Mac List rendered normally in the standalone app, but its outline-list
handling asserted in this Xcode 27 beta's Canvas host. The working mock therefore
uses ScrollView + grouped wrappers for preview reliability. Section margins,
rounded backgrounds, native navigation/button chrome and Mac font rendering
remain approximations, not pixel-verified iPhone parity. Do not transfer this
wrapper over the production app's native List. Dates, aggregates and breakdown
navigation remain intentionally mocked; sample amounts are not real journal data.

Verified: native Mac build, live Canvas rendering, reference-metadata comparison,
and missing-data/dark/expanded content in a normal Mac window. The earlier
`baseline-v1` tag is retained; no shipping app file changed for this alignment.
