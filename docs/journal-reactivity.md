# Journal calendar and macro reactivity

Implemented 2026-08-30 on `codex/multi-provider-agent`.

## What changed

Previously, the macro summary's parent observed `NutritionStore.changeCount`,
but calendar cells performed independent `fetchLog` calls. An empty fetch did
not subscribe to the new DailyLog that could later be inserted. Calendar arcs
also had no progress-driven animation.

`DailyLogView` now owns one SwiftData `@Query` for the calendar-history range.
`JournalDayData` resolves duplicate days using the existing populated-row then
UUID rule. `JournalDayTotals` derives macro/micronutrient values during rendering;
the calendar, macro bar, and selected-day background receive values from that
same snapshot. There is no new persisted cache, schema change, or data migration.

Calendar arc/color changes animate independently of day selection. The date
number's font-weight transaction remains unchanged; Reduce Motion disables the
new progress animation. History retains the live-log MacroSummaryBar initializer.

## Verification

- App, unit-test target, and UI-test target compiled successfully with Xcode beta
  using generic iOS `build-for-testing`, unsigned, with isolated DevDisk output.
- Eight non-UI regression tests added in `JournalDayDataTests`: first-entry query
  membership, existing-entry Observation, late relationship Observation, moves
  and deletes, direct persistence without the store counter, duplicate days,
  changed/invalid goals, and macro/micronutrient totals.
- These tests were compiled, not executed. No simulator/phone UI automation ran.
- `git diff --check` passed. Existing unrelated compiler warnings remain.

## Manual smoke checks still to run

- Keep an empty day selected, add its first food, and confirm the headline and
  calendar ring update without scrolling or changing dates.
- Edit calories, move an entry to another day, delete it, and change the calorie
  goal. Both displays should agree after every action.
- Leave Journal open while another device syncs a new day or edits an entry.
  This checks real CloudKit delivery; direct-persistence tests do not prove it.
- With Reduce Motion on/off, check ring updates and confirm the selected-day
  rectangle/date weight still behave normally.
