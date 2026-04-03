// OpenFoodJournal — What's New Sheet (v1.1)
// Shown once after updating to a new version. Highlights new features
// so users discover what's changed. Dismissed with a single button.
// AGPL-3.0 License

import SwiftUI

/// A scrollable sheet that showcases new features in the current release.
/// Presented once per version using an @AppStorage("lastSeenVersion") flag.
/// Each feature is displayed as a row with an icon, title, and description.
struct WhatsNewSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    // Header section — version badge + welcome text
                    headerSection

                    // Feature list — one FeatureRow per new capability
                    VStack(spacing: 24) {
                        FeatureRow(
                            icon: "magnifyingglass",
                            color: .green,
                            title: "Open Food Facts Search",
                            description: "Search over 3 million products from the Open Food Facts database. Find nutrition info for packaged foods instantly."
                        )

                        FeatureRow(
                            icon: "barcode.viewfinder",
                            color: .orange,
                            title: "Barcode Scanning",
                            description: "Scan a product barcode with your camera to look up nutrition data automatically from Open Food Facts."
                        )

                        FeatureRow(
                            icon: "bolt",
                            color: .blue,
                            title: "Faster Food Photo Scans",
                            description: "Food photo scans now use a lighter AI model by default for faster results. Enable Gemini Pro in Settings for more accuracy."
                        )

                        FeatureRow(
                            icon: "arrow.up.arrow.down",
                            color: .purple,
                            title: "Reorderable Nutrient Rings",
                            description: "Drag to reorder the nutrient rings on your daily summary. Prioritize the nutrients that matter most to you."
                        )

                        FeatureRow(
                            icon: "calendar.badge.clock",
                            color: .teal,
                            title: "Nutrition History Navigation",
                            description: "Browse your nutrition history by day, week, or month. Navigate forward and backward to compare trends over time."
                        )
                    }
                    .padding(.horizontal, 24)
                }
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .toolbar {
                // Dismiss button in the top-right corner
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Header

    /// Version badge and introductory text at the top of the sheet
    private var headerSection: some View {
        VStack(spacing: 12) {
            // Version pill — shows the current release number
            Text("Version 1.1")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())

            // Title
            Text("What's New")
                .font(.largeTitle.bold())

            // Subtitle
            Text("Here's what we've been working on")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 20)
    }
}

// MARK: - Feature Row

/// A single feature highlight row with a colored icon, title, and description.
/// Laid out horizontally: icon circle on the left, text stack on the right.
private struct FeatureRow: View {
    let icon: String       // SF Symbol name
    let color: Color       // Background color for the icon circle
    let title: String      // Feature name (bold)
    let description: String // One-sentence explanation

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // Colored circle with SF Symbol icon
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 12))

            // Text stack — title above description
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)

                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }
}

// MARK: - Preview

#Preview {
    WhatsNewSheet()
}
