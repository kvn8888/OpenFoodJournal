# Privacy Policy — OpenFoodJournal

**Last Updated:** August 31, 2026

OpenFoodJournal ("the App") is an open-source food journaling application. This privacy policy explains what data the App handles, how it is used, which services may process it, and your choices.

## Data the App Handles

### Food, Nutrition, and Assistant Data

The App may store:

- Food names, brands, nutrition estimates, daily logs, and meal entries
- Macro and micronutrient values, goals, meal times, serving mappings, and preferences
- Saved foods, composites, nutrition calculators, Shelf state, and container tracking records
- Assistant conversations, attachments, tool activity, saved sources, context summaries, and usage totals
- Optional generated food icons and related metadata

This information is stored locally with SwiftData and may sync through your Apple iCloud private database. OpenFoodJournal does not operate an account service and does not have access to your private iCloud database.

### Camera, Photo, and File Inputs

When you scan food or a nutrition label, the App sends the selected images directly from your device to the AI provider you configured so it can return an editable nutrition estimate. Scan images are not retained as raw scan photos after the request completes.

When you intentionally attach an image or PDF to an Assistant conversation, that attachment and related conversation source records may remain in the conversation and sync through your private iCloud database. Generated food icons may also be saved with Food Bank or Journal records.

### API Keys and Service Credentials

API keys, Azure endpoints, and optional Turso credentials are stored in the iOS Keychain. Secrets are excluded from OpenFoodJournal backups and diagnostics. Requests are authenticated directly with the provider you selected; OpenFoodJournal does not receive your keys.

### AI Diagnostics and Usage Information

The App can record operational information such as provider and model names, request and run identifiers, token usage, estimated or reported cost, duration, timeout or retry state, and redacted error details.

Detailed AI diagnostics do not include prompts, answers, tool arguments or results, journal or HealthKit values, source URLs or content, attachments, raw provider responses, chain-of-thought, API keys, or image bytes. When you configure Turso diagnostics, detailed events are sent to your own Turso database and expire after 14 days. A bounded local delivery outbox may temporarily retain pending redacted events for up to 48 hours. Conversation history, terminal run state, and usage or cost aggregates may be retained with the rest of your app data.

## Apple Health

Apple Health integration is optional. If you grant access, the App may:

- Write calories, protein, carbohydrates, fat, and supported dietary micronutrients to Apple Health
- Read active energy burned to show calorie balance and answer an Assistant request that explicitly includes Apple Health energy

The App does not read other HealthKit categories. HealthKit data is not used for advertising, marketing, tracking, insurance, or data mining.

If you ask the Assistant to use Apple Health energy, the returned active-energy value becomes part of the tool result sent to the AI provider you selected so it can answer your request. You can avoid this processing by not requesting HealthKit-backed Assistant context, revoke Health access in iOS Settings, or disable Apple Health integration in the App.

OpenFoodJournal uses deterministic identifiers for its own Apple Health samples so edits can replace prior OpenFoodJournal-owned values instead of creating duplicates.

## Third-Party Processing

OpenFoodJournal does not operate a required proxy server. Depending on the features and providers you choose, your device may communicate directly with the following services over HTTPS.

### AI Conversation, Scan, and Image Providers

- Google Gemini
- OpenRouter
- Microsoft Azure OpenAI
- OpenAI
- Anthropic
- Meta Muse Spark or another user-configured OpenAI-compatible endpoint

The request may contain the text, image, PDF, source excerpt, journal fact, or tool result needed for the feature you initiated. Each provider processes data under its own terms and privacy policy. Provider settings are optional, and you can remove a saved key at any time.

### Web Research Providers

Assistant web research may use model-native search or a separately configured provider such as Tavily, Parallel, or Exa. Search queries and returned source material are processed by the selected service. URLs that you ask the Assistant to fetch are downloaded directly by the App and may be saved as conversation source artifacts.

### Open Food Facts

When you search Open Food Facts or scan a barcode, the search text or barcode is sent to the public Open Food Facts service. Results are shown for review before you save them.

### models.dev

The App may fetch public model capability and pricing metadata from models.dev. This refresh does not include your API keys, prompts, journal, attachments, or HealthKit values.

### Apple iCloud

SwiftData uses your private CloudKit database to sync supported app records across devices signed into the same Apple ID. Apple's iCloud terms and privacy policy apply.

### Optional Turso Mirror

You may configure your own Turso database. If enabled, the App can mirror food logs, saved foods, containers, preferences, settings, usage aggregates, and redacted diagnostics to that database. OpenFoodJournal does not operate or have access to your Turso database. You control the database, credentials, retention outside the App's diagnostic expiry, and deletion.

## No User Accounts, Ads, or Tracking

The App does not require an OpenFoodJournal account and does not collect an email address, username, password, advertising identifier, or cross-app tracking identifier. It does not include an advertising or analytics SDK and does not display ads.

OpenFoodJournal does not sell or rent your data. Data is disclosed only to the services described above when needed for a feature you choose, to your private iCloud database for sync, or to your own Turso database when you explicitly configure it.

## Your Choices and Deletion

You can:

- Review and edit AI-generated nutrition before saving it
- Remove provider keys, Azure settings, and Turso credentials in Settings
- Disable Apple Health integration or revoke Health permissions in iOS Settings
- Disable optional Turso mirroring and diagnostics
- Export spreadsheet data, a restore-grade JSON backup, or redacted diagnostics
- Delete individual Journal, Food Bank, Assistant, source, or container records in the App
- Delete OpenFoodJournal's Apple Health samples in the Health app
- Delete local app data by uninstalling the App
- Delete synced app data through iOS Settings → Apple ID → iCloud → Manage Storage → OpenFoodJournal
- Delete data in any provider account or user-owned Turso database through that service

Removing the App from one device does not automatically delete records already synced to iCloud or sent to a provider you selected. Those services apply their own retention and deletion rules.

## Children's Privacy

The App is not directed at children under 13. OpenFoodJournal does not knowingly collect children's personal information.

## Changes to This Policy

We may update this policy when the App's data practices change. Updates are posted in the source repository with a revised "Last Updated" date.

## Open Source and Contact

The source code is available at [github.com/kvn8888/OpenFoodJournal](https://github.com/kvn8888/OpenFoodJournal).

For privacy questions, requests, or concerns, open an issue at [github.com/kvn8888/OpenFoodJournal/issues](https://github.com/kvn8888/OpenFoodJournal/issues).
