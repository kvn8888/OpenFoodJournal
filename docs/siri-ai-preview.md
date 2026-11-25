# OpenFoodJournal Siri AI preview

The preview exposes authenticated App Intents for iOS 27.3 Siri AI. The standard build keeps the existing App Shortcut provider and exposes the new read actions as ordinary App Intents. The preview build enables `OFJ_SIRI_AI_PREVIEW` to register tools and enable the new confirmed write actions.

Apple says enabling any tool intent changes how Siri uses the app's App Shortcuts. The preview also registers the existing saved-food logger, spoken logger, and Assistant handoff as tools. The App Shortcut definitions remain available for Shortcuts and other system surfaces. Verify all three Siri flows on the internal TestFlight build.

## What Siri can read

- Search active or archived Food Bank items by name and brand. Read exact saved macros and micronutrients, convert a portion, and inspect composite ingredients and calculator portion options.
- Read journal entries for a date or date range, with meal and food filters. Read totals, calendar-day averages, current goals, and remaining amounts on a single day.
- Read tracked containers, meal times, Food Shelf preferences, and an available Apple Health active-energy sample when sync is enabled.
- Find Assistant conversations and read their visible messages by page.

Reads fetch current data from the app. The new entities are not indexed in Spotlight. The intents require local device authentication and the read service checks protected data. Empty or unavailable Apple Health data is represented as an absent value. Journal ranges can cover up to 366 calendar days per request. Results that contain individual records are paginated as described in each action.

## What Siri can change

Siri can log a known portion, use the existing Food Bank-first spoken logging flow, edit or remove a journal entry, save a logged portion to the Food Bank, create or edit a saved food, archive or restore it, change its Food Shelf status, delete it, and update daily goals. Changing portions uses the saved conversion rules. Composite and calculator nutrition is derived from ingredient selections, which are edited in the app.

Writes require explicit confirmation and recheck device protection before persistence. The SwiftData writes refuse to run while the app has unsaved changes. Edits and deletes re-read the selected record after confirmation and ask the person to review it again if it changed. Recent matching logs prompt before adding another.

## Siri App Skills

The preview includes one Xcode resource, [Skills.skillsbundle](../Skills.skillsbundle/Skills/), containing six Apple App Skills. These are instructions for Siri to coordinate the existing tools, not additional intents, scripts, or the in-app Assistant's prompts.

| Skill | Guides Siri through |
| --- | --- |
| `log-food` | Food Bank-first logging, brand/portion clarification, known-nutrition logging, research handoff and post-save verification |
| `compare-saved-foods` | Finding exact saved brands, comparing equal portions, inspecting stored conversions and calculator options |
| `review-journal-nutrition` | Date/meal-specific summaries and entries, comparable periods, actual logged data, and current settings |
| `correct-journal-entry` | Resolving the exact historical entry, applying a targeted edit or deletion, and verifying the result |
| `manage-food-bank` | Saving logged portions, creating known-nutrition foods, editing templates, archive/restore, shelf membership, and deletion |
| `review-assistant-conversation` | Finding and reading selected saved Assistant conversations and distinguishing past chat from actual journal records |

Each skill is a `SKILL.md` in a lowercase, hyphenated directory. Only the `name` and `description` frontmatter fields are used; the description determines when Siri considers the body's guidance. Refer to tool intent titles in bold so the local validator can catch renamed or missing tools. Keep skills focused on multi-tool decisions rather than repeating intent parameters. No user records, credentials, supporting files, or executable code belong in the bundle.

Skills are advisory, not deterministic workflows. In particular, the app's existing authentication, conversion, confirmation, duplicate detection, and persistence checks still apply even if Siri doesn't load a skill. Use the same existing tool intents, not duplicate implementations. The source bundle is excluded from normal Debug and Release builds; Xcode 27.3 compiles it for `SiriAIPreview`.

## Build and verify

Use Xcode 27.3 beta 2 or newer for the preview. The stable CI and TestFlight workflows keep their pinned toolchain and omit the preview flag.

```bash
DEVELOPER_DIR=/Applications/Xcode-27.3-beta-2.app/Contents/Developer \
    ./ci/verify-siri-ai-preview.sh
```

The script validates the skill files, builds the shared `OpenFoodJournalSiriAIPreview` scheme for a generic iOS device without signing, and requires compiled `Metadata.appintents/Skills.skillsc`, the iOS 27.3 minimum, and Siri tool metadata in the app. The scheme uses the `SiriAIPreview` build configuration, which enables the tools and requires iOS 27.3. Apple's preview supports development-signed builds and internal TestFlight.

On any toolchain, `python3 ci/validate-siri-skills.py` checks the source bundle's format, limits, and tool references. Stable CI also checks that the standard built app contains neither the uncompiled source bundle nor the compiled skill resource.

Run the manual **Siri AI Preview Verification** Xcode Cloud workflow to publish an internal TestFlight preview. It uses Xcode 27.3 beta 2, runs `OpenFoodJournalUnitTests` on an iOS 27.3 simulator, and archives the preview scheme for TestFlight Internal Only. The post-build script checks the archived app for Siri tools before distribution. Confirm the processed build is available to the **Testing** internal group in App Store Connect.

On an Apple Intelligence-capable device running iOS 27.3 beta 2, enable Siri AI and use a fresh conversation for each check. Include OpenFoodJournal in requests while the app is in the background.

| Check | Expected result |
| --- | --- |
| Ask what you logged yesterday and for today's remaining protein | Siri invokes the respective OFJ read tools and returns the same values as the app. |
| Search for milk and ask for the nutrition in one cup of a named saved brand | Siri uses the correct saved food and its stored conversion. |
| Invoke spoken logging for ambiguous milk, then say “It's the Amazon brand” | The shortcut resolves the reply among the saved choices and previews the exact food. |
| Confirm a journal edit with a new meal and date, then request the same record | One entry exists with the updated date and meal. |
| Cancel a create, update, or delete confirmation | The journal and Food Bank remain unchanged. |
| Repeat a matching log within two minutes | The shortcut asks before adding a second matching entry. |
| Request personal values while the phone is locked | The values are withheld until the device is authenticated. |
| Invoke each of the three existing voice flows on the preview and standard builds | Saved-food logging, freeform logging, and Assistant handoff each have a working entry point. |

### Skill selection and chaining

Use a dedicated test device with fictional journal and Food Bank records and an Apple Intelligence-supported system language. The current Siri AI preview uses the production app identity, not an isolated journal store; do not run automated destructive tests against a real journal. Include the app name in each new background conversation.

| Skill | Example request | Expected behavior |
| --- | --- | --- |
| `log-food` | “In OpenFoodJournal, log a cup of milk for breakfast yesterday, then tell me yesterday's totals.” | Ask which saved brand if ambiguous, confirm the correct portion and date, then read yesterday's summary only after saving. |
| `compare-saved-foods` | “In OpenFoodJournal, compare 100 grams of my two saved yogurts.” | Resolve both brands and compare stored values if both support grams. No writes. |
| `review-journal-nutrition` | “In OpenFoodJournal, compare my logged protein for the last seven days with the previous seven days, and tell me which days have entries.” | Use two non-overlapping summary ranges, optionally read entries for coverage details, and label calendar days versus tracked days. |
| `correct-journal-entry` | “In OpenFoodJournal, change yesterday's lunch yogurt from 150 grams to 200 grams.” | Find the historical record, clarify if necessary, use the edit tool, and let the person confirm. Cancellation changes nothing. |
| `manage-food-bank` | “In OpenFoodJournal, save that yogurt I logged yesterday to my Food Bank.” | Resolve one journal entry then save its actual portion as a reusable food after confirmation; no extra journal entry. |
| `review-assistant-conversation` | “In OpenFoodJournal, what did we discuss in my yogurt Assistant conversation, and did I actually log it yesterday?” | Find/read the correct conversation, then query the journal independently. No writes. |

Repeat requests using different wording and check the confirmation, cancellation, ambiguous match, unsupported-unit, and no-result cases as appropriate. With [Siri Evaluations](https://developer.apple.com/documentation/sirievaluations/evaluating-your-apps-integration-with-siri), assert skill selection with `Loads`, tool calls and their parameters with `Calls`, and disallowed mutations for read-only scenarios. A correct-looking Siri reply alone doesn't verify that OFJ provided the data. Siri Evaluations require compatible physical hardware and cannot run in Simulator.

[Apple's App Skills guidance](https://developer.apple.com/documentation/appintents/orchestrating-complex-actions-with-app-skills) · [Custom actions guidance](https://developer.apple.com/documentation/appintents/bringing-custom-actions-and-content-to-siri) · [iOS 27.3 beta release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27_3-release-notes)
