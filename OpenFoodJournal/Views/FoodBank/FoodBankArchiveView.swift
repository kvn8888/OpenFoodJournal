// OpenFoodJournal — FoodBankArchiveView
// Browses Food Bank items hidden from the main active list.
// Archive is cosmetic only: foods remain searchable and can still be logged.
// AGPL-3.0 License

import SwiftUI
import SwiftData

struct FoodBankArchiveView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(TursoMirrorService.self) private var tursoMirror

    let logDate: Date

    @Query(sort: \SavedFood.lastUsedAt, order: .reverse)
    private var allFoods: [SavedFood]

    @State private var searchText = ""
    @State private var selectedFood: SavedFood?
    @State private var foodToEdit: SavedFood?

    private var archivedFoods: [SavedFood] {
        let foods = allFoods.filter { $0.isArchivedInFoodBank }

        if searchText.isEmpty {
            return foods
        }

        return foods.filter(matchesSearch)
    }

    var body: some View {
        NavigationStack {
            Group {
                if archivedFoods.isEmpty {
                    emptyState
                } else {
                    archiveList
                }
            }
            .navigationTitle("Archive")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search archived foods")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $selectedFood) { food in
                if food.kind == .calculator {
                    NutritionCalculatorBuildView(calculator: food, logDate: logDate)
                } else {
                    LogFoodSheet(food: food, logDate: logDate)
                }
            }
            .sheet(item: $foodToEdit) { food in
                if food.kind == .calculator {
                    NutritionCalculatorEditorView(calculator: food)
                } else if food.kind == .composite {
                    CompositeFoodBuilderView(food: food)
                } else {
                    EditFoodSheet(food: food)
                }
            }
        }
    }

    private var archiveList: some View {
        List {
            Text("\(archivedFoods.count) archived food\(archivedFoods.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .listRowBackground(Color.clear)

            ForEach(archivedFoods) { food in
                Button {
                    selectedFood = food
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        SavedFoodRowView(food: food)
                        archiveStatusLine(for: food)
                    }
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button {
                        restore(food)
                    } label: {
                        Label("Unarchive", systemImage: "tray.and.arrow.up")
                    }
                    .tint(.green)

                    Button {
                        foodToEdit = food
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(.blue)
                }
                .swipeActions(edge: .leading) {
                    Button {
                        selectedFood = food
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .tint(.green)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(searchText.isEmpty ? "No Archived Foods" : "No Results", systemImage: "archivebox")
        } description: {
            Text(searchText.isEmpty
                ? "Foods you have not logged in over two weeks will appear here automatically."
                : "Try a different food name or brand.")
        }
    }

    @ViewBuilder
    private func archiveStatusLine(for food: SavedFood) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "archivebox")
            Text(archiveStatusText(for: food))
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.leading, 56)
    }

    private func archiveStatusText(for food: SavedFood) -> String {
        if food.archivedAt != nil {
            return "Archived manually"
        }

        return "Auto archived: last logged \(food.lastUsedAt.formatted(date: .abbreviated, time: .omitted))"
    }

    private func matchesSearch(_ food: SavedFood) -> Bool {
        food.name.localizedCaseInsensitiveContains(searchText) ||
        (food.brand?.localizedCaseInsensitiveContains(searchText) ?? false)
    }

    private func restore(_ food: SavedFood) {
        food.restoreFromFoodBankArchive()
        try? modelContext.save()
        tursoMirror.scheduleMirror(reason: "food_bank_restore")
    }
}
