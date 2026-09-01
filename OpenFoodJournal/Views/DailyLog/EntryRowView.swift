// Macros — Food Journaling App
// AGPL-3.0 License

import SwiftUI

struct EntryRowView: View {
    let entry: NutritionEntry
    let onDelete: () -> Void
    @AppStorage(JournalAppearanceSettings.showFoodImagesKey) private var showFoodImages = JournalAppearanceSettings.defaultShowFoodImages
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Shared formatter — static so it's created once, not on every render
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    /// Formats the entry's timestamp as a compact time string (e.g. "2:30 PM")
    private var timeString: String {
        Self.timeFormatter.string(from: entry.timestamp)
    }

    var body: some View {
        HStack(spacing: OFJSpace.s12) {
            if showFoodImages {
                JournalEntryFoodImage(entryID: entry.id, savedFoodID: entry.savedFoodID)
            }
            // Macro mini-summary
            VStack(alignment: .leading, spacing: OFJSpace.s2) {
                // Show brand above food name if available
                if let brand = entry.brand, !brand.isEmpty {
                    Text(brand)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(entry.name)
                    .font(OFJType.rowTitle)
                    .lineLimit(1)

                HStack(spacing: OFJSpace.s6) {
                    Text("\(Int(entry.calories)) kcal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .ofjNumericTextTransition(value: entry.calories)

                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(timeString)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let pct = entry.confidencePercent {
                        ConfidenceBadge(scanMode: entry.scanMode, percent: pct)
                    }
                }
            }

            Spacer()

            if !dynamicTypeSize.isAccessibilitySize {
                FoodMacroPill(protein: entry.protein, carbs: entry.carbs, fat: entry.fat)
            }
        }
        .safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 8) {
            if dynamicTypeSize.isAccessibilitySize {
                FoodMacroPill(protein: entry.protein, carbs: entry.carbs, fat: entry.fat)
            }
        }
        .padding(.vertical, OFJLayout.journalRowVerticalPadding)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.name), \(Int(entry.calories)) kilocalories, protein \(Int(entry.protein))g, carbs \(Int(entry.carbs))g, fat \(Int(entry.fat))g")
    }
}

// MARK: - Subviews

struct MacroChip: View {
    let value: Double
    let color: Color
    let label: String

    var body: some View {
        Text("\(label) \(Int(value))g")
            .font(OFJType.macroChip)
            .foregroundStyle(color)
            .ofjNumericTextTransition(value: value)
            .padding(.horizontal, OFJSpace.s6)
            .padding(.vertical, OFJSpace.s3)
            .background(color.opacity(0.12), in: Capsule())
    }
}

private struct ConfidenceBadge: View {
    let scanMode: ScanMode
    let percent: Int

    var body: some View {
        let color = scanMode == .label ? OFJColor.labelConfidence : OFJColor.estimateConfidence

        HStack(spacing: OFJSpace.s2) {
            Image(systemName: scanMode == .label ? "barcode.viewfinder" : "camera.viewfinder")
                .font(OFJType.confidenceIcon)
            if scanMode == .foodPhoto {
                Text("~\(percent)%")
                    .font(OFJType.confidenceText)
                    .ofjNumericTextTransition(value: percent)
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, OFJSpace.s5)
        .padding(.vertical, OFJSpace.s2)
        .background(
            color.opacity(0.12),
            in: Capsule()
        )
    }
}

#Preview {
    List {
        EntryRowView(entry: NutritionEntry.samples[0], onDelete: {})
        EntryRowView(entry: NutritionEntry.samples[1], onDelete: {})
        EntryRowView(entry: NutritionEntry.samples[2], onDelete: {})
    }
}
