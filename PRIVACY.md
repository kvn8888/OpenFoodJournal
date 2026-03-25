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
- Sent to our proxy server for processing by **Google Gemini AI** to extract nutritional information
- **Not stored on our servers** — images are held in memory only during processing and discarded immediately after
- Optionally stored locally on your device (configurable in Settings)

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

### Gemini AI Scan Proxy
When you scan a food item, the image is sent via HTTPS to our proxy server hosted on Render (`openfoodjournal.onrender.com`), which forwards it to Google's Gemini AI for nutritional analysis. The proxy server:
- Does **not** store images or scan results
- Does **not** log personally identifiable information
- Processes images in memory only
- Returns the AI-generated nutritional data to your device

Google's use of data sent to Gemini is governed by [Google's Privacy Policy](https://policies.google.com/privacy).

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

OpenFoodJournal is open-source software. You can review the complete source code to verify our privacy practices at: [https://github.com/openFoodJournal/macros](https://github.com/openFoodJournal/macros)

## Contact

For privacy questions or concerns, please open an issue on our GitHub repository.
