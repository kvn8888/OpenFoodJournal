# App Store 1.3 Submission Checklist

Use this checklist before uploading the 1.3 archive to App Store Connect.

## Repo State

- `MARKETING_VERSION` is `1.3`.
- `CURRENT_PROJECT_VERSION` is `3`.
- App Store Connect rejected `1.3 (1)` because build number `1` had already been uploaded. Build `1.3 (2)` uploaded successfully, then build `1.3 (3)` was prepared with the export-compliance Info.plist disclosure.
- `ITSAppUsesNonExemptEncryption` is `false` because OpenFoodJournal does not use custom or non-exempt encryption; it uses standard Apple/platform transport and storage protections such as HTTPS, CloudKit, and Keychain.
- Run a compile check before archiving:

```bash
xcodebuild -project OpenFoodJournal.xcodeproj \
  -scheme OpenFoodJournal \
  -destination generic/platform=iOS \
  -derivedDataPath /private/tmp/OpenFoodJournalDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## App Store Connect

- Create or select version `1.3`.
- Paste the `What's New (version 1.3)` text from `docs/app-store-metadata.md`.
- Paste the updated App Review Notes from `docs/app-store-metadata.md`.
- Create a dedicated Gemini API key for review and paste it into the review notes. Do not commit the key.
- Confirm the privacy policy URL points to the updated `PRIVACY.md`.
- Confirm HealthKit usage is disclosed in App Privacy and review notes.
- Confirm screenshots show populated data, not empty states.

## Reviewer Smoke Test Path

1. Open the app and enter the reviewer Gemini API key during onboarding or in Settings.
2. Add a manual food without using Gemini.
3. Use Food Bank `+` to verify AI Search, Composite Food, Nutrition Calculator, Open Food Facts, Manual Entry, and Archive are reachable.
4. Scan one nutrition label photo and confirm the editable result screen appears before saving.
5. In Settings, verify Sources & Disclaimers, backup/export, Gemini diagnostics, and Apple Health controls are reachable.

## Notes

- OpenFoodJournal has no user account, subscriptions, ads, or external payment flow.
- Gemini features are BYOK and call Google directly from the device.
- Optional Turso mirroring is user-configured and off by default.
- Apple Health sync is opt-in and writes OpenFoodJournal-owned nutrition samples only after permission is granted.
