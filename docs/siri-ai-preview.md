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

## Build and verify

Use Xcode 27.3 beta 2 or newer for the preview. The stable CI and TestFlight workflows keep their pinned toolchain and omit the preview flag.

```bash
DEVELOPER_DIR=/Applications/Xcode-27.3-beta-2.app/Contents/Developer \
    ./ci/verify-siri-ai-preview.sh
```

The script builds the shared `OpenFoodJournalSiriAIPreview` scheme for a generic iOS device without signing and checks the app's minimum iOS version and Siri tool metadata. The scheme uses the `SiriAIPreview` build configuration, which enables the tools and requires iOS 27.3. Apple's preview supports development-signed builds and internal TestFlight.

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

When scripting Siri Evaluations, assert both the selected tool and the returned value. A correct-looking Siri reply alone doesn't verify that OFJ provided the data.

[Apple's custom actions guidance](https://developer.apple.com/documentation/appintents/bringing-custom-actions-and-content-to-siri) · [iOS 27.3 beta release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27_3-release-notes) · [Siri Evaluations](https://developer.apple.com/documentation/sirievaluations/evaluating-your-apps-integration-with-siri)
