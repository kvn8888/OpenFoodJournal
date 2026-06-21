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
                if food.kind == .calculator {
                    Image(systemName: "slider.horizontal.3")
                        .font(.headline)
                        .foregroundStyle(.teal)
                    Text("\(food.calculatorGroups.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(Int(food.calories))")
                        .font(.headline)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                    Text("cal")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
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

                if food.kind == .calculator {
                    Label("Calculator · \(food.calculatorGroups.count) group\(food.calculatorGroups.count == 1 ? "" : "s")", systemImage: "slider.horizontal.3")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if food.kind == .composite {
                    Label("Composite", systemImage: "square.stack.3d.up")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

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
            if food.kind == .calculator {
                Text("\(food.calculatorPresets.count) preset\(food.calculatorPresets.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    MacroChip(value: food.protein, color: .blue, label: "P")
                    MacroChip(value: food.carbs, color: .green, label: "C")
                    MacroChip(value: food.fat, color: .yellow, label: "F")
                }
            }
        }
        .padding(.vertical, 4)
        // Ensures the full row area is tappable/swipeable, even when brand is
        // absent and the row is shorter — prevents swipe gesture lag on compact rows
        .contentShape(Rectangle())
    }
}
