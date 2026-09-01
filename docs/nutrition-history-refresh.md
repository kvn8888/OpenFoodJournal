# Nutrition and History UI refresh

Owner-approved Mac concepts were ported to the iOS app on 2026-08-30. The release
branch starts at TestFlight 1.4 (29), not at the unrelated Journal-icon work.

## Presentation

- Nutrition: calorie ring plus macro bars, Day/Week/Month, date arrows in the
  navigation bar, native Journal back control, and complete nutrient sections.
- Nutrient drill-down: deterministic goal difference, 7/30-day chart, and food
  contributions. The selected historical date is retained through each level.
- History: monthly calendar, selected-day link directly beneath it, Week/Month
  only, one alphabetical tracked-micro row (without edge-arrow controls), and a consolidated comparison chart.
- Calendar cells use the reviewed 36pt ring, 2.5pt stroke and 16pt date number;
  progression uses the Journal's black/white, light green, green and D86669 red.
- Day detail includes all recorded micros in an expandable section, including
  custom nutrients and recorded zeros. A missing nutrient is not an invented zero.
- Food entries share `JournalEntryButton` and `EntryRowView`: tap to edit, hold
  for Edit / Save to Food Bank / nutrition info / Delete. Only the Journal's
  `MealSectionView` applies swipe actions; History has none.
- Journal List rows explicitly use a clear background. History meal sections
  do not add a solid card fill or full-section material over the page gradient.
  Macro pills retain their own Liquid Glass surfaces.

### Follow-up polish

The Nutrition picker, date label and macro card now share one List row with
explicit 10/14pt spacing; separate inset-grouped section/row gaps must not be
reintroduced between them. History's selected-day label, composite totals caption
and date-range label use the existing numeric text transition. A full-content
trigger handles changes in entry count, goal percentage or range length even if
the primary numeric value stays equal. Animation stays on text, respects Reduce
Motion, and does not animate the enclosing glass card.

Completed tracked containers now carry their existing `savedFoodID` into the
journal entry, matching immediate tare logging. Images are resolved by this UUID
from the Food Bank; nutrition remains the original tracking snapshot. No schema
or image-byte migration is needed. Previously orphaned entries cannot be safely
repaired from names alone and are not automatically relinked by this fix.

## Live-data contract

`NutritionLogQuery` observes bounded DailyLog date ranges. `NutritionAnalytics`
reconstructs display values on render, reusing the Journal's populated-row/UUID
duplicate-day rule and deduplicating repeated entry relationships by UUID.
Calendar, totals, chart and drill-down use these same values; there are no
cell-level store fetches or persisted presentation caches.

Known nutrient aliases normalize to canonical IDs. Compatible g/mg/mcg units
convert before summing. Incompatible units remain separately visible with no
invented goal. Canonical keys take precedence over aliases within an entry.
Non-finite/negative amounts are excluded from display aggregation.

Daily averages use recorded days for each nutrient, including recorded zeros.
Coverage is displayed as X of Y days recorded; absent dates remain chart gaps.
The verbose gaps caption is removed. Contributions use the same denominator
as their parent metric, including when opening one food's nutrient breakdown.

Chart coordinates are calendar-day slots, not automatic timezone-dependent
date buckets. Explicit rectangle bounds preserve first/last bars and missing
slots; weekday/month labels come from the exact date represented by that slot.

## Release boundary

No SwiftData model, CloudKit schema, backup format, service credential, or
HealthKit export contract changes. The earlier entry-owned icon generation
feature and its unverified CloudKit fields remain on the original local branch.
Do not include that branch wholesale in this release. S3/pagination and the
deferred native scroll-edge boundary investigation are not implemented here.

## Verification / manual smoke checklist

Automated phone/simulator UI tests are intentionally not run. Cloud CI compiles
all targets and runs the non-UI unit/provider suite; live provider contracts are
opt-in except the established protected release image contract.

Manual checklist (unexecuted on an iPhone):

- [ ] Open a past Journal day and Nutrition; confirm matching totals and date.
- [ ] Switch Day/Week/Month; check goals, coverage, edge bars and date navigation.
- [ ] Open a macro, known micro and custom nutrient, then a food contribution.
- [ ] History calendar selection updates the directly adjacent day link.
- [ ] Scroll the alphabetical micro row both ways; select an item near the end.
- [ ] Open History day detail; tap a food to edit and hold for the full menu.
- [ ] Confirm History has no swipe actions and Journal retains its swipes.
- [ ] Confirm light/dark row backgrounds reveal the selected-day gradient.
- [ ] Check missing data, recorded zeros, no-goal nutrients and large text.
- [ ] Edit/delete an entry and verify calendar, summary and chart update.

Release identifiers, CI counts and final processing state are recorded in the PR
and immutable TestFlight release manifest after verification completes.

### Release-gate correction

The first release attempt was cancelled during archive creation after its detailed
log revealed the protected image test had skipped despite a green job. It had not
received the host's opt-in environment variable. The follow-up explicitly forwards
`TEST_RUNNER_` variables into XCTest and requires the named test's passing event;
missing/skipped/failed/duplicate executions fail closed. Secret-bearing xcresult
bundles are no longer retained from this protected job. This corrects verification,
not the image request or the UI. Ordinary unprivileged live tests still skip.
