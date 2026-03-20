// OpenFoodJournal — ServingMappingSection
// A reusable Form section that displays and edits serving unit mappings.
// Shows existing mappings (e.g. "1 cup = 244 g") and lets users add new ones.
// Used in EditEntryView and could be used in a food detail view.
// AGPL-3.0 License

import SwiftUI

/// A Form section for viewing and editing per-food serving unit mappings.
/// Pass a binding to a `[ServingMapping]` array (e.g. from NutritionEntry or SavedFood).
struct ServingMappingSection: View {
    // ── Bindings to the food's serving data ───────────────────────
    @Binding var mappings: [ServingMapping]
    @Binding var servingQuantity: Double?
    @Binding var servingUnit: String?

    // ── State for the "Add Mapping" alert ─────────────────────────
    @State private var showAddMapping = false
    @State private var fromValue = ""
    @State private var fromUnit = ""
    @State private var toValue = ""
    @State private var toUnit = "g"   // Default "to" unit is grams (most common target)

    var body: some View {
        Section {
            // Current canonical serving (editable)
            canonicalServing

            // Existing mappings
            ForEach(Array(mappings.enumerated()), id: \.offset) { index, mapping in
                MappingRow(mapping: mapping) {
                    mappings.remove(at: index)
                }
            }

            // Add mapping button
            Button {
                // Pre-fill "from" with canonical serving if set
                if let qty = servingQuantity, let unit = servingUnit {
                    fromValue = String(format: qty == floor(qty) ? "%.0f" : "%.1f", qty)
                    fromUnit = unit
                }
                showAddMapping = true
            } label: {
                Label("Add Unit Mapping", systemImage: "plus.circle")
            }
        } header: {
            Text("Serving & Units")
        } footer: {
            Text("Map between units for this food. E.g. 1 cup = 244g.")
        }
        .alert("New Unit Mapping", isPresented: $showAddMapping) {
            TextField("Amount (e.g. 1)", text: $fromValue)
                .keyboardType(.decimalPad)
            TextField("Unit (e.g. cup)", text: $fromUnit)
            TextField("Equals (e.g. 244)", text: $toValue)
                .keyboardType(.decimalPad)
            TextField("Unit (e.g. g)", text: $toUnit)

            Button("Add") {
                addMapping()
            }
            Button("Cancel", role: .cancel) {
                clearFields()
            }
        } message: {
            Text("Enter two equivalent amounts for this food.")
        }
    }

    // MARK: - Canonical Serving

    /// Editable display of the food's canonical serving size
    private var canonicalServing: some View {
        HStack {
            Text("Serving")
                .foregroundStyle(.secondary)
            Spacer()

            // Quantity
            TextField("1", value: $servingQuantity, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 50)

            // Unit
            TextField("unit", text: Binding(
                get: { servingUnit ?? "" },
                set: { servingUnit = $0.isEmpty ? nil : $0 }
            ))
            .frame(width: 60)
            .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - Helpers

    private func addMapping() {
        guard let fv = Double(fromValue), !fromUnit.isEmpty,
              let tv = Double(toValue), !toUnit.isEmpty else {
            clearFields()
            return
        }

        let mapping = ServingMapping(
            from: ServingAmount(value: fv, unit: fromUnit.trimmingCharacters(in: .whitespaces)),
            to: ServingAmount(value: tv, unit: toUnit.trimmingCharacters(in: .whitespaces))
        )
        mappings.append(mapping)
        clearFields()
    }

    private func clearFields() {
        fromValue = ""
        fromUnit = ""
        toValue = ""
        toUnit = "g"
    }
}

// MARK: - Mapping Row

/// Displays a single mapping as "1 cup = 244 g" with a delete option
private struct MappingRow: View {
    let mapping: ServingMapping
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Text(mapping.from.displayString)
                .fontWeight(.medium)
            Text("=")
                .foregroundStyle(.secondary)
            Text(mapping.to.displayString)
                .fontWeight(.medium)

            Spacer()

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .font(.subheadline)
    }
}
