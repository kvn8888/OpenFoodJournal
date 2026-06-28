// OpenFoodJournal — Health Disclaimer & Sources
// Provides citations for all health and nutrition data displayed in the app,
// as required by Apple's App Store Review Guideline 1.4.1.
//
// AGPL-3.0 License

import SwiftUI

/// A view listing every source of health/nutrition information used in the app,
/// along with a general medical disclaimer. Accessible from Settings → About.
struct HealthDisclaimerView: View {

    var body: some View {
        List {
            // MARK: - General Disclaimer
            // This section tells users the app is NOT medical advice.
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Not Medical Advice", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)

                    Text("OpenFoodJournal is a food journaling tool designed to help you track what you eat. It is not intended to diagnose, treat, cure, or prevent any disease or health condition.")

                    Text("The nutrition information displayed in this app, including AI-estimated values, daily reference values, and macro calculations, is provided for informational purposes only. Always consult a qualified healthcare professional before making dietary changes, especially if you have a medical condition or specific nutritional needs.")
                }
                .font(.subheadline)
            }

            // MARK: - FDA Daily Values
            // The micronutrient progress bars use these reference values.
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Micronutrient Daily Values", systemImage: "chart.bar.fill")
                        .font(.headline)

                    Text("Daily reference values for vitamins and minerals shown in the Nutrition tab are based on the FDA's updated Daily Values for nutrition labeling (2020), calculated for a 2,000-calorie daily diet.")
                }
                .font(.subheadline)

                // Each Link gets its own list row so only that row is tappable
                Link(destination: URL(string: "https://www.fda.gov/food/nutrition-facts-label/daily-value-nutrition-and-supplement-facts-labels")!) {
                    Label("FDA: Daily Value on Nutrition Labels", systemImage: "link")
                        .font(.subheadline)
                }

                Link(destination: URL(string: "https://www.ecfr.gov/current/title-21/chapter-I/subchapter-B/part-101/subpart-A/section-101.9")!) {
                    Label("21 CFR §101.9: Nutrition Labeling", systemImage: "link")
                        .font(.subheadline)
                }
            } header: {
                Text("Nutrition References")
            }

            // MARK: - Atwater System (Macro Calorie Formula)
            // The 4/4/9 formula shown in Goals Editor.
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Calorie Conversion Factors", systemImage: "function")
                        .font(.headline)

                    Text("The macro-to-calorie conversion (protein 4 kcal/g, carbohydrates 4 kcal/g, fat 9 kcal/g) follows the Atwater general factor system, the standard used on U.S. nutrition labels.")
                }
                .font(.subheadline)

                Link(destination: URL(string: "https://www.nal.usda.gov/programs/fnic")!) {
                    Label("USDA Food & Nutrition Information Center", systemImage: "link")
                        .font(.subheadline)
                }
            }

            // MARK: - AI Nutrition Estimates
            // Covers Gemini-powered food photo scanning and AI Search.
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Label("AI-Estimated Nutrition", systemImage: "wand.and.sparkles")
                        .font(.headline)

                    Text("When you scan a food photo or use AI Search, the app sends your request to Google's Gemini AI to estimate or retrieve nutritional content. These results are approximations and may differ significantly from actual values.")

                    Text("Factors that affect accuracy include portion size, food preparation method, lighting, image angle, and source quality. Always verify critical nutrition information against the product's official nutrition label or a certified nutrition database.")

                    Text("Label scans read printed nutrition facts directly and are generally more accurate, but may still contain reading errors. Review scanned values before logging.")
                }
                .font(.subheadline)
            } header: {
                Text("AI Scanning")
            }

            // MARK: - Apple Health Integration
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Apple Health", systemImage: "heart.fill")
                        .font(.headline)
                        .foregroundStyle(.red)

                    Text("When enabled, the app writes your logged nutrition data (calories, macronutrients, and select micronutrients) to Apple Health. It reads your active energy burned to display your daily calorie balance. This data stays on your device and in your iCloud account unless you enable optional Turso mirroring with your own database credentials.")
                }
                .font(.subheadline)
            } header: {
                Text("Health Data")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Sources & Disclaimers")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        HealthDisclaimerView()
    }
}
