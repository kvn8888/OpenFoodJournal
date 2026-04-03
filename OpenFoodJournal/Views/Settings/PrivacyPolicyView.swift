// OpenFoodJournal — PrivacyPolicyView
// Displays the app's privacy policy in-app so it's available offline.
// Content mirrors PRIVACY.md at the repo root.
// Accessed from Settings → About → Privacy Policy.
// AGPL-3.0 License

import SwiftUI

/// In-app privacy policy view. Renders the privacy policy as native SwiftUI
/// sections so it's accessible without a network connection — required for
/// App Store Review Guideline 5.1.1.
struct PrivacyPolicyView: View {
    var body: some View {
        List {
            // Header with last-updated date
            Section {
                Text("Last Updated: July 17, 2025")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("OpenFoodJournal is an open-source food journaling application. This privacy policy explains what data we collect, how it's used, and your rights.")
                    .font(.subheadline)
            }

            // ── Data We Collect ──────────────────────────────────────
            Section("Data We Collect") {
                policyItem(
                    title: "Food & Nutrition Data",
                    body: "Food names, brands, nutritional information, daily logs, meal entries, macro/micronutrient tracking, saved food templates, and container tracking. Stored locally via SwiftData and synced via Apple iCloud (CloudKit Private Database). We do not have access to your data."
                )
                policyItem(
                    title: "Camera Images",
                    body: "Photos of food or nutrition labels are sent directly to Google's Gemini AI via HTTPS to extract nutrition data. Images are not stored on any server or on your device after processing. Your API key is stored in the iOS Keychain — never transmitted to us."
                )
                policyItem(
                    title: "Health Data (Apple HealthKit)",
                    body: "If you opt in, the app writes nutritional data (calories, protein, carbs, fat, micronutrients) to Apple Health and reads active energy burned for net calorie balance. We never read other HealthKit data, never send it to any server, never use it for advertising, and never share it with third parties."
                )
                policyItem(
                    title: "Goals & Preferences",
                    body: "Daily calorie/macro goals and UI preferences are stored locally on your device using UserDefaults."
                )
            }

            // ── Data Processing ──────────────────────────────────────
            Section("Data Processing") {
                policyItem(
                    title: "Google Gemini AI",
                    body: "When you scan food, the image is sent directly from your device to Google's Gemini API (generativelanguage.googleapis.com) using your personal API key. No intermediary server. No personally identifiable information is included — only the food image and an analysis prompt. You can revoke access anytime by deleting your API key in Settings."
                )
            }

            // ── Storage & Sync ───────────────────────────────────────
            Section("Data Storage & Sync") {
                policyItem(
                    title: "iCloud Private Database",
                    body: "All food journal data is stored in Apple's iCloud Private Database via CloudKit. Your data lives in your personal iCloud account — we have no ability to read, access, or delete your cloud data."
                )
            }

            // ── No Accounts / No Tracking ────────────────────────────
            Section("What We Don't Do") {
                bulletItem("No user accounts — no email, username, or password collection")
                bulletItem("No analytics SDKs or tracking frameworks")
                bulletItem("No device identifiers or advertising identifiers")
                bulletItem("No usage pattern tracking")
                bulletItem("No advertisements")
                bulletItem("No selling, renting, or sharing data with third parties")
            }

            // ── Data Deletion ────────────────────────────────────────
            Section("Data Deletion") {
                policyItem(
                    title: "How to delete your data",
                    body: "Local data: Uninstall the app. iCloud data: Settings → [Your Name] → iCloud → Manage Storage → OpenFoodJournal → Delete Data. Both actions permanently delete all your information."
                )
            }

            // ── Children & Open Source ───────────────────────────────
            Section("Other") {
                policyItem(
                    title: "Children's Privacy",
                    body: "This app is not directed at children under 13. We do not knowingly collect data from children."
                )
                policyItem(
                    title: "Open Source",
                    body: "OpenFoodJournal is open-source software. You can review the complete source code to verify our privacy practices."
                )
                // Link to the full policy on GitHub (for users who want the
                // canonical markdown version or to check for updates)
                Link(destination: URL(string: "https://github.com/kvn8888/OpenFoodJournal/blob/main/PRIVACY.md")!) {
                    Label("View Full Policy on GitHub", systemImage: "safari")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Helpers

    /// A policy item with a bold title and body text
    private func policyItem(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
            Text(body)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// A bullet-point item for the "What We Don't Do" list
    private func bulletItem(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
