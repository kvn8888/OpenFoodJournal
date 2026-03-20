// OpenFoodJournal — SavedFoodRowView
// A compact row displaying a saved food's name, key macros, and origin badge.
// Used in the FoodBankView list. Designed for quick scanning of saved foods.
// AGPL-3.0 License

import SwiftUI

struct SavedFoodRowView: View {
    // The saved food item to display in this row
    let food: SavedFood

    var body: some View {
        HStack(spacing: 12) {
            // ── Left: Source icon based on how the food was originally captured ──
            // Gives visual context: camera = label scan, fork = food photo, pencil = manual
            sourceIcon
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 32)

            // ── Center: Food name + serving info ──
            VStack(alignment: .leading, spacing: 2) {
                Text(food.name)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)

                // Show serving size if available, otherwise show how it was captured
                if let serving = food.servingSize {
                    Text(serving)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // ── Right: Calorie count as the primary macro ──
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Int(food.calories))")
                    .font(.headline)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                Text("cal")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    // Maps the original scan mode to a meaningful SF Symbol
    private var sourceIcon: Image {
        switch food.originalScanMode {
        case .label:
            Image(systemName: "barcode.viewfinder")
        case .foodPhoto:
            Image(systemName: "fork.knife")
        case .manual:
            Image(systemName: "pencil.circle")
        }
    }
}
