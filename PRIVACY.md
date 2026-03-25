# Privacy Policy — OpenFoodJournal

**Last Updated:** July 17, 2025

OpenFoodJournal ("the App") is an open-source food journaling application. This privacy policy explains what data we collect, how it's used, and your rights.

## Data We Collect

### Food & Nutrition Data
- Food names, brands, and nutritional information you enter or scan
- Daily food logs and meal entries
- Macro and micronutrient tracking data
- Saved food templates and container tracking data

This data is stored locally on your device using SwiftData and synced across your devices via **Apple iCloud (CloudKit Private Database)**. Your data is stored in your personal iCloud account — we do not have access to it.

### Camera Images
When you use the scan feature, the App captures photos of food items or nutrition labels. These images are:
- Sent directly from your device to **Google's Gemini AI** via HTTPS to extract nutritional information
- **Not stored on any server** — Google processes the image and returns structured nutrition data
- **Not stored on your device** after processing is complete

You provide your own Google Gemini API key to enable scanning. Your API key is stored securely in the iOS Keychain on your device — it is never transmitted to us or any third party other than Google.

### Health Data (Apple HealthKit)
If you opt in, the App writes nutritional data (calories, protein, carbs, fat) to Apple Health. We:
- **Never read HealthKit data** beyond what is needed for display
- **Never send HealthKit data to any server**
- **Never use HealthKit data for advertising or marketing**
- **Never share HealthKit data with third parties**

You can disable HealthKit integration at any time in Settings.

### Macro Goals & Preferences
Your daily calorie and macro goals, and UI preferences (e.g., ring display configuration), are stored locally on your device using UserDefaults.

## Data Processing

### Google Gemini AI (Direct API)
When you scan a food item, the image is sent directly from your device via HTTPS to **Google's Gemini AI** (`generativelanguage.googleapis.com`) for nutritional analysis. There is no intermediary server — your device communicates with Google's API directly using your personal API key.

- Images are sent as part of a single API request and are **not stored** by the App after processing
- Google may process and temporarily retain the image per their API terms
- No personally identifiable information is included in the request — only the food image and an analysis prompt
- You can revoke access at any time by deleting your API key in Settings or revoking it at [Google AI Studio](https://aistudio.google.com/apikey)

Google's use of data sent to Gemini is governed by [Google's Privacy Policy](https://policies.google.com/privacy) and [Google's Generative AI Terms](https://ai.google.dev/gemini-api/terms).

## Data Storage & Sync

All your food journal data is stored in **Apple's iCloud Private Database** via CloudKit. This means:
- Your data lives in your personal iCloud account
- We have **no ability to read, access, or delete** your cloud data
- Data syncs automatically across your devices signed into the same Apple ID
- Apple's iCloud terms and privacy policy apply to this storage

## No User Accounts

The App does not require or support user accounts. Each device operates independently, with iCloud handling cross-device sync for devices on the same Apple ID. We do not collect email addresses, usernames, passwords, or any personal identifiers.

## No Tracking or Analytics

The App does not:
- Use any analytics SDKs or tracking frameworks
- Collect device identifiers or advertising identifiers
- Track your usage patterns or behavior
- Display advertisements

## No Third-Party Data Sharing

We do not sell, rent, or share your data with any third parties, except as described above (Google Gemini for image processing during scans).

## Data Deletion

To delete your data:
- **Local data**: Uninstall the App from your device
- **iCloud data**: Go to iOS Settings → [Your Name] → iCloud → Manage Storage → OpenFoodJournal → Delete Data
- **Both**: Uninstalling the App and removing iCloud data permanently deletes all your information

## Children's Privacy

The App is not directed at children under 13. We do not knowingly collect data from children.

## Changes to This Policy

We may update this privacy policy from time to time. Changes will be posted in the App's source code repository and reflected in the "Last Updated" date above.

## Open Source

OpenFoodJournal is open-source software. You can review the complete source code to verify our privacy practices at: [https://github.com/kvn8888/OpenFoodJournal](https://github.com/kvn8888/OpenFoodJournal)

## Contact

For privacy questions or concerns, please open an issue on our GitHub repository.
