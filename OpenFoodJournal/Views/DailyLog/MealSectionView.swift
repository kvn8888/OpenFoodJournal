// Macros — Food Journaling App
// AGPL-3.0 License

import SwiftUI

struct MealSectionView: View {
    let mealType: MealType
    let entries: [NutritionEntry]
    let onSelect: (NutritionEntry) -> Void
    let onDelete: (NutritionEntry) -> Void

    private var totalCalories: Double {
        entries.reduce(0) { $0 + $1.calories }
    }

    var body: some View {
        // Only render section if there are entries
        if !entries.isEmpty {
            Section {
                ForEach(entries) { entry in
                    Button {
                        onSelect(entry)
                    } label: {
                        EntryRowView(entry: entry, onDelete: { onDelete(entry) })
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        // Edit — opens the full edit sheet
                        Button {
                            onSelect(entry)
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }

                        // Quick info — shows macros inline
                        Button {} label: {
                            Label("\(Int(entry.calories)) kcal • P\(Int(entry.protein))g C\(Int(entry.carbs))g F\(Int(entry.fat))g", systemImage: "info.circle")
                        }
                        .disabled(true)

                        Divider()

                        // Delete
                        Button(role: .destructive) {
                            onDelete(entry)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } header: {
                HStack {
                    Label(mealType.rawValue, systemImage: mealType.systemImage)
                        .font(.footnote)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                    Spacer()
                    Text("\(Int(totalCalories)) kcal")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .textCase(nil)
                }
            }
        }
    }
}

#Preview {
    List {
        MealSectionView(
            mealType: .breakfast,
            entries: Array(NutritionEntry.samples.prefix(2)),
            onSelect: { _ in },
            onDelete: { _ in }
        )
        MealSectionView(
            mealType: .lunch,
            entries: [NutritionEntry.samples[2]],
            onSelect: { _ in },
            onDelete: { _ in }
        )
    }
}
