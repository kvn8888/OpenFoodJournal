// Macros — Food Journaling App
// AGPL-3.0 License

import SwiftUI

struct MealSectionView: View {
    @Environment(NutritionStore.self) private var nutritionStore
    @State private var foodBankMessage: String?
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
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    // Swipe left (trailing) — Delete action (moved here from EntryRowView
                    // to avoid double swipeActions registration which causes gesture lag)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            onDelete(entry)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    // Swipe right (leading) — Edit shortcut, same as tapping the row
                    .swipeActions(edge: .leading) {
                        Button {
                            onSelect(entry)
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.blue)
                        Button {
                            saveToFoodBank(entry)
                        } label: {
                            Label("Save to Food Bank", systemImage: "tray.and.arrow.down")
                        }
                        .tint(.green)
                    }
                    // Swipe left (trailing) — Delete, already defined in EntryRowView,
                    // rendered here because DailyLogView now uses a List (where
                    // swipeActions fire correctly).
                    .contextMenu {
                        // Edit — opens the full edit sheet
                        Button {
                            onSelect(entry)
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }

                        Button {
                            saveToFoodBank(entry)
                        } label: {
                            Label("Save to Food Bank", systemImage: "tray.and.arrow.down")
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
                    } preview: {
                        EntryContextMenuPreview(entry: entry)
                    }
                }
            } header: {
                HStack {
                    Label(mealType.rawValue, systemImage: mealType.systemImage)
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                    Spacer()
                    Text("\(Int(totalCalories)) kcal")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                        .ofjNumericTextTransition(value: totalCalories)
                }
            }
            .alert("Food Bank", isPresented: Binding(
                get: { foodBankMessage != nil },
                set: { if !$0 { foodBankMessage = nil } }
            )) {
                Button("OK", role: .cancel) { foodBankMessage = nil }
            } message: {
                Text(foodBankMessage ?? "")
            }
        }
    }

    private func saveToFoodBank(_ entry: NutritionEntry) {
        switch nutritionStore.saveJournalEntryToFoodBank(entry) {
        case .saved(let food):
            foodBankMessage = "Saved \(food.name) as a reusable copy of this logged portion. The journal entry is unchanged."
        case .alreadySaved(let food):
            foodBankMessage = "This entry is already saved as \(food.name). No duplicate was created."
        case .failed:
            foodBankMessage = "Could not save this food. Please try again."
        }
    }
}

/// The default context-menu preview inherited the List row's full proposed
/// width, including its invisible spacer. A compact explicit preview keeps the
/// long-press outline attached to the food content the user can actually see.
private struct EntryContextMenuPreview: View {
    let entry: NutritionEntry

    var body: some View {
        VStack(alignment: .leading, spacing: OFJSpace.s8) {
            if let brand = entry.brand, !brand.isEmpty {
                Text(brand)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(entry.name)
                .font(OFJType.rowTitle)
                .lineLimit(2)
            Text("\(Int(entry.calories)) kcal")
                .font(.caption)
                .foregroundStyle(.secondary)
            FoodMacroPill(protein: entry.protein, carbs: entry.carbs, fat: entry.fat)
        }
        .padding(OFJSpace.s16)
        .frame(width: 280, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: OFJRadius.compactCard))
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
