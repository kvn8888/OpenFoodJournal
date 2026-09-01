# Journal visual tuning → production

The design playground is a visual reference, not application logic. The approved
transfer uses its neutral pill, image-slot sizing, fitted nutrient values, and
light/dark gradients. Mock dates, nutrition (including the stress-test yogurt),
fake status/tab bars, and alternate RGB/circle experiments stay in the playground.

Journal and Food Bank share `FoodMacroPill`, so subsequent pill tuning affects
both. Native list swipe actions, the Today/Settings toolbar, day observation,
write approvals, HealthKit sync, and existing navigation remain in production.

Settings → Journal → **Show Food Images** is on by default. It only displays
existing saved-food image data, uses a placeholder for missing/invalid data, and
can be switched off to remove the image column. It does not opt into image
generation. The setting is restored from backups; older backups default on.

Matching uses the entry's `savedFoodID` or a saved food's `sourceJournalEntryID`,
never name similarity. Archived saved foods remain eligible. Newly saved scans
and manual foods retain source-entry provenance. Older entries without either
link remain placeholders; this release does not guess or backfill relationships.

## Verification and manual smoke checklist

Cloud CI must compile all app/test targets and run non-UI unit/provider tests.
`JournalAppearanceTests` covers palette/geometry/gradients, old-backup defaults,
preference round-trip and generation independence, exact-ID predicates, archived
images, missing images, new source provenance, and updated image data. The
TestFlight workflow additionally gates release on its live Gemini image canary.
No local simulator or phone UI test is required or performed.

Unexecuted manual checks on the processed TestFlight build:

- [ ] Journal light/dark: correct gradients, calendar/live totals, fitted rings.
- [ ] Journal and Food Bank: same pill, large values, narrow screen, large text.
- [ ] Image appears for linked food; missing/old unlinked food shows placeholder.
- [ ] Toggle images off/on: row space collapses/restores; restart retains choice.
- [ ] No image-generation requests are caused by scrolling or toggling display.
- [ ] Today/gear transitions, edit/delete/swipe, and save-to-Food-Bank still work.
- [ ] Calculator customizations persist; stale selections cannot silently log.
- [ ] Backup/import retains the icon setting and existing data.

Cloud run/build identifiers belong in the PR/release manifest after verification;
this document does not claim that unexecuted device checks have passed.
