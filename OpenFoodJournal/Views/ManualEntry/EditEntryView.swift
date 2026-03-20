// Macros — Food Journaling App
// AGPL-3.0 License

import SwiftUI
import SwiftData

/// Edit an existing log entry.
struct EditEntryView: View {
    @Environment(NutritionStore.self) private var nutritionStore
    @Environment(HealthKitService.self) private var healthKit
    @Environment(\.dismiss) private var dismiss

    @Bindable var entry: NutritionEntry

    @State private var showDeleteConfirm = false
    @State private var showExtended = false
    @State private var showAddMicro = false
    @State private var newMicroName = ""
    @State private var newMicroUnit = "g"
    @State private var savedToBank = false  // Shows checkmark after saving to food bank

    var body: some View {
        NavigationStack {
            Form {
                Section("Food Info") {
                    TextField("Food name", text: $entry.name)

                    Picker("Meal", selection: $entry.mealType) {
                        ForEach(MealType.allCases) { type in
                            Label(type.rawValue, systemImage: type.systemImage)
                                .tag(type)
                        }
                    }

                    if let pct = entry.confidencePercent {
                        HStack {
                            Label(
                                entry.scanMode == .label ? "Scanned from label" : "Estimated from photo",
                                systemImage: entry.scanMode == .label ? "barcode.viewfinder" : "camera.viewfinder"
                            )
                            Spacer()
                            Text("\(pct)%")
                                .foregroundStyle(.secondary)
                        }
                        .foregroundStyle(entry.scanMode == .label ? .teal : .orange)
                    }
                }

                Section("Core Macros") {
                    BoundMacroRow(label: "Calories", unit: "kcal", value: $entry.calories)
                    BoundMacroRow(label: "Protein", unit: "g", value: $entry.protein)
                    BoundMacroRow(label: "Carbs", unit: "g", value: $entry.carbs)
                    BoundMacroRow(label: "Fat", unit: "g", value: $entry.fat)
                }

                Section {
                    DisclosureGroup("Additional Details", isExpanded: $showExtended) {
                        // Dynamic micronutrient rows — shows whatever the entry has
                        ForEach(entry.sortedMicronutrientNames, id: \.self) { nutrientName in
                            if let micro = entry.micronutrients[nutrientName] {
                                MicronutrientBoundRow(
                                    label: nutrientName,
                                    unit: micro.unit,
                                    entry: entry,
                                    nutrientName: nutrientName
                                )
                            }
                        }

                        // "Add Micronutrient" button for adding new ones during editing
                        Button {
                            showAddMicro = true
                        } label: {
                            Label("Add Micronutrient", systemImage: "plus.circle")
                        }

                        HStack {
                            Text("Serving Size")
                            Spacer()
                            TextField("e.g. 170g", text: Binding(
                                get: { entry.servingSize ?? "" },
                                set: { entry.servingSize = $0.isEmpty ? nil : $0 }
                            ))
                            .multilineTextAlignment(.trailing)
                        }
                    }
                }

                // Serving unit mappings — per-food conversions (e.g. 1 cup = 244g)
                ServingMappingSection(
                    mappings: $entry.servingMappings,
                    servingQuantity: $entry.servingQuantity,
                    servingUnit: $entry.servingUnit
                )

                // Save to Food Bank — copies this entry as a reusable food template
                Section {
                    Button {
                        let saved = SavedFood(from: entry)
                        nutritionStore.modelContext.insert(saved)
                        try? nutritionStore.modelContext.save()
                        let sync = nutritionStore.syncService
                        Task { try? await sync?.createFood(saved) }
                        withAnimation { savedToBank = true }
                    } label: {
                        Label(
                            savedToBank ? "Saved to Food Bank" : "Save to Food Bank",
                            systemImage: savedToBank ? "checkmark.circle.fill" : "refrigerator"
                        )
                    }
                    .disabled(savedToBank)
                    .tint(savedToBank ? .green : .accentColor)
                }

                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete Entry", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("Edit Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        nutritionStore.saveAndSyncEntry(entry)
                        Task { await healthKit.write(entry) }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .confirmationDialog(
                "Delete this entry?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    nutritionStore.delete(entry)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This cannot be undone.")
            }
            .alert("Add Micronutrient", isPresented: $showAddMicro) {
                TextField("Name (e.g. Vitamin A)", text: $newMicroName)
                TextField("Unit (e.g. mg, mcg)", text: $newMicroUnit)
                Button("Add") {
                    let trimmed = newMicroName.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        entry.micronutrients[trimmed] = MicronutrientValue(value: 0, unit: newMicroUnit)
                    }
                    newMicroName = ""
                    newMicroUnit = "g"
                }
                Button("Cancel", role: .cancel) {
                    newMicroName = ""
                    newMicroUnit = "g"
                }
            }
        }
    }
}

// MARK: - BoundMacroRow

private struct BoundMacroRow: View {
    let label: String
    let unit: String
    @Binding var value: Double

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .focused($isFocused)
                .frame(width: 80)
                .onChange(of: text) { _, newVal in
                    if let d = Double(newVal) { value = d }
                }
                .onChange(of: isFocused) { _, focused in
                    if !focused { text = String(format: "%.1f", value) }
                }
            Text(unit)
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
        }
        .onAppear { text = String(format: "%.1f", value) }
    }
}

/// Row for editing a micronutrient value on an existing entry.
/// Reads/writes directly to the entry's micronutrients dictionary.
private struct MicronutrientBoundRow: View {
    let label: String
    let unit: String
    let entry: NutritionEntry
    let nutrientName: String

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .focused($isFocused)
                .frame(width: 80)
                .onChange(of: text) { _, newVal in
                    if let d = Double(newVal) {
                        entry.micronutrients[nutrientName] = MicronutrientValue(value: d, unit: unit)
                    }
                }
                .onChange(of: isFocused) { _, focused in
                    if !focused, let micro = entry.micronutrients[nutrientName] {
                        text = String(format: "%.1f", micro.value)
                    }
                }
            Text(unit)
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
        }
        .onAppear {
            if let micro = entry.micronutrients[nutrientName] {
                text = String(format: "%.1f", micro.value)
            }
        }
    }
}

#Preview {
    EditEntryView(entry: NutritionEntry.preview)
        .environment(NutritionStore(modelContext: ModelContainer.preview.mainContext))
        .environment(HealthKitService())
}
