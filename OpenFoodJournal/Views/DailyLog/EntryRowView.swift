// Macros — Food Journaling App
// AGPL-3.0 License

import SwiftUI

struct EntryRowView: View {
    let entry: NutritionEntry
    let onDelete: () -> Void

    /// Formats the entry's timestamp as a compact time string (e.g. "2:30 PM")
    private var timeString: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: entry.timestamp)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Macro mini-summary
            VStack(alignment: .leading, spacing: 2) {
                // Show brand above food name if available
                if let brand = entry.brand, !brand.isEmpty {
                    Text(brand)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(entry.name)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)

                HStack(spacing: 6) {
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
            HStack(spacing: 6) {
                MacroChip(value: entry.protein, color: .blue, label: "P")
                MacroChip(value: entry.carbs, color: .green, label: "C")
                MacroChip(value: entry.fat, color: .yellow, label: "F")
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.name), \(Int(entry.calories)) kilocalories, protein \(Int(entry.protein))g, carbs \(Int(entry.carbs))g, fat \(Int(entry.fat))g")
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

// MARK: - Subviews

struct MacroChip: View {
    let value: Double
    let color: Color
    let label: String

    var body: some View {
        Text("\(label) \(Int(value))g")
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }
}

private struct ConfidenceBadge: View {
    let scanMode: ScanMode
    let percent: Int

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: scanMode == .label ? "barcode.viewfinder" : "camera.viewfinder")
                .font(.system(size: 9))
            if scanMode == .foodPhoto {
                Text("~\(percent)%")
                    .font(.system(size: 9, weight: .medium))
            }
        }
        .foregroundStyle(scanMode == .label ? Color.teal : Color.orange)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            (scanMode == .label ? Color.teal : Color.orange).opacity(0.12),
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
