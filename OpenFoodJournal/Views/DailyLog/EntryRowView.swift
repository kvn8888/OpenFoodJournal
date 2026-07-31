// Macros — Food Journaling App
// AGPL-3.0 License

import SwiftUI

struct EntryRowView: View {
    let entry: NutritionEntry
    let onDelete: () -> Void

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

            // Macro chips
            HStack(spacing: OFJSpace.s6) {
                MacroChip(value: entry.protein, color: OFJColor.protein, label: "P")
                MacroChip(value: entry.carbs, color: OFJColor.carbohydrates, label: "C")
                MacroChip(value: entry.fat, color: OFJColor.fat, label: "F")
            }
        }
        .padding(.vertical, OFJSpace.s4)
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
