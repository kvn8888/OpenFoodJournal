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
                        OptionalBoundMacroRow(label: "Fiber", unit: "g", value: $entry.fiber)
                        OptionalBoundMacroRow(label: "Sugar", unit: "g", value: $entry.sugar)
                        OptionalBoundMacroRow(label: "Sodium", unit: "mg", value: $entry.sodium)
                        OptionalBoundMacroRow(label: "Cholesterol", unit: "mg", value: $entry.cholesterol)
                        OptionalBoundMacroRow(label: "Saturated Fat", unit: "g", value: $entry.saturatedFat)
                        OptionalBoundMacroRow(label: "Trans Fat", unit: "g", value: $entry.transFat)

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
                        nutritionStore.saveChanges()
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

private struct OptionalBoundMacroRow: View {
    let label: String
    let unit: String
    @Binding var value: Double?

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            TextField("—", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .focused($isFocused)
                .frame(width: 80)
                .onChange(of: text) { _, newVal in value = Double(newVal) }
                .onChange(of: isFocused) { _, focused in
                    if !focused, let v = value { text = String(format: "%.1f", v) }
                }
            Text(unit)
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
        }
        .onAppear {
            if let v = value { text = String(format: "%.1f", v) }
        }
    }
}

#Preview {
    EditEntryView(entry: NutritionEntry.preview)
        .environment(NutritionStore(modelContext: ModelContainer.preview.mainContext))
        .environment(HealthKitService())
}
