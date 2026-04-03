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
            // ── Left: Calorie count as the primary identifier ──
            VStack(alignment: .center, spacing: 2) {
                Text("\(Int(food.calories))")
                    .font(.headline)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                Text("cal")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 44)

            // ── Center: Food name + serving info ──
            VStack(alignment: .leading, spacing: 2) {
                // Show brand above food name if available
                if let brand = food.brand, !brand.isEmpty {
                    Text(brand)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(food.name)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)

                // Show serving size if available
                if let serving = food.servingSize {
                    Text(serving)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // ── Right: Macro chips matching the journal's EntryRowView ──
            HStack(spacing: 6) {
                MacroChip(value: food.protein, color: .blue, label: "P")
                MacroChip(value: food.carbs, color: .green, label: "C")
                MacroChip(value: food.fat, color: .yellow, label: "F")
            }
        }
        .padding(.vertical, 4)
        // Ensures the full row area is tappable/swipeable, even when brand is
        // absent and the row is shorter — prevents swipe gesture lag on compact rows
        .contentShape(Rectangle())
    }
}
