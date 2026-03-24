// Macros — Food Journaling App
// AGPL-3.0 License

import SwiftUI

// MARK: - Macro nutrient IDs (used alongside KnownMicronutrients IDs)
// Prefix with "macro_" so they don't collide with micronutrient IDs.

/// Represents a macro nutrient option that can fill a ring slot.
/// Macros pull their value/goal from DailyLog totals + UserGoals.
enum MacroNutrientID: String, CaseIterable {
    case protein  = "macro_protein"
    case carbs    = "macro_carbs"
    case fat      = "macro_fat"
    case calories = "macro_calories"

    var label: String {
        switch self {
        case .protein:  "Protein"
        case .carbs:    "Carbs"
        case .fat:      "Fat"
        case .calories: "Calories"
        }
    }

    var unit: String {
        switch self {
        case .protein, .carbs, .fat: "g"
        case .calories: "kcal"
        }
    }

    var color: Color {
        switch self {
        case .protein:  .blue
        case .carbs:    .green
        case .fat:      .yellow
        case .calories: .orange
        }
    }
}

/// Glass card showing daily calorie headline + up to 5 configurable nutrient rings.
/// Each slot can hold a macro (protein/carbs/fat/calories) or a micronutrient.
/// Long-press → context menu → edit sheet to reconfigure all slots.
struct MacroSummaryBar: View {
    let log: DailyLog?
    let goals: UserGoals

    // ── 5 persisted ring slots ────────────────────────────────────
    // Each stores a nutrient ID: "macro_protein", "macro_carbs", "macro_fat",
    // "macro_calories", or a micronutrient ID like "sodium", "fiber".
    // Empty string = slot is unassigned (shows + button).
    @AppStorage("summaryBar.slot1") private var slot1: String = MacroNutrientID.protein.rawValue
    @AppStorage("summaryBar.slot2") private var slot2: String = MacroNutrientID.carbs.rawValue
    @AppStorage("summaryBar.slot3") private var slot3: String = MacroNutrientID.fat.rawValue
    @AppStorage("summaryBar.slot4") private var slot4: String = ""
    @AppStorage("summaryBar.slot5") private var slot5: String = ""

    // ── State ─────────────────────────────────────────────────────
    @State private var editingSlot: Int? = nil    // Which slot index is being picked (1–5)
    @State private var showEditSheet = false       // Context menu edit mode

    // ── Computed ──────────────────────────────────────────────────
    private var calories: Double { log?.totalCalories ?? 0 }
    private var protein: Double { log?.totalProtein ?? 0 }
    private var carbs: Double { log?.totalCarbs ?? 0 }
    private var fat: Double { log?.totalFat ?? 0 }

    /// All 5 slot bindings as an array for easy indexed access
    private var slotIDs: [String] { [slot1, slot2, slot3, slot4, slot5] }

    /// Aggregated micronutrient totals for the day — sum across all entries
    private var microTotals: [String: Double] {
        guard let entries = log?.entries else { return [:] }
        var totals: [String: Double] = [:]
        for entry in entries {
            for (key, micro) in entry.micronutrients {
                let normalizedKey = KnownMicronutrients.normalize(key)
                totals[normalizedKey, default: 0] += micro.value
            }
        }
        return totals
    }

    var body: some View {
        VStack(spacing: 12) {
            // Calorie headline
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(calories, format: .number.precision(.fractionLength(0)))
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                Text("/ \(Int(goals.dailyCalories)) kcal")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            // Ring row: all 5 configurable slots
            GlassEffectContainer(spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(1...5, id: \.self) { index in
                        slotView(slotID: slotIDs[index - 1], slotIndex: index)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .padding()
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
        .contextMenu {
            Button {
                showEditSheet = true
            } label: {
                Label("Edit Tracked Nutrients", systemImage: "slider.horizontal.3")
            }
        }
        .sheet(isPresented: $showEditSheet) {
            SlotEditSheet(
                slot1: $slot1, slot2: $slot2, slot3: $slot3,
                slot4: $slot4, slot5: $slot5,
                allSlotIDs: slotIDs
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $editingSlot) { slot in
            NutrientPickerSheet(
                selectedID: bindingForSlot(slot),
                otherSlotIDs: slotIDs.enumerated()
                    .filter { $0.offset != slot - 1 }
                    .map { $0.element }
            )
            .presentationDetents([.medium, .large])
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Daily macro summary")
    }

    // MARK: - Unified Slot View

    /// Shows a ring for any nutrient (macro or micro), or a + button if empty.
    @ViewBuilder
    private func slotView(slotID: String, slotIndex: Int) -> some View {
        if let macroID = MacroNutrientID(rawValue: slotID) {
            // Macro slot — pull value/goal from DailyLog totals + UserGoals
            let (value, goal) = macroValueAndGoal(for: macroID)
            MacroRingView(
                value: value,
                goal: goal,
                color: macroID.color,
                label: macroID.label,
                unit: macroID.unit
            )
        } else if let nutrient = KnownMicronutrients.nutrient(forID: slotID) {
            // Micro slot — pull value from aggregated microTotals
            let value = microTotals[nutrient.id] ?? 0
            MacroRingView(
                value: value,
                goal: nutrient.dailyValue,
                color: colorForSlot(slotIndex),
                label: nutrient.name,
                unit: nutrient.unit
            )
        } else {
            // Empty slot — show + button
            Button {
                editingSlot = slotIndex
            } label: {
                VStack(spacing: 4) {
                    ZStack {
                        Circle()
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 5)
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 56, height: 56)

                    Text("Add")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .frame(width: 56)
                }
                .frame(width: 56, alignment: .top)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Helpers

    /// Returns (current value, goal) for a macro nutrient
    private func macroValueAndGoal(for macro: MacroNutrientID) -> (Double, Double) {
        switch macro {
        case .protein:  (protein, goals.dailyProtein)
        case .carbs:    (carbs, goals.dailyCarbs)
        case .fat:      (fat, goals.dailyFat)
        case .calories: (calories, goals.dailyCalories)
        }
    }

    /// Assigns a color to a slot based on its position (for micro slots only)
    private func colorForSlot(_ index: Int) -> Color {
        let colors: [Color] = [.blue, .green, .yellow, .mint, .indigo]
        return colors[(index - 1) % colors.count]
    }

    /// Returns a binding to the slot at the given 1-based index
    private func bindingForSlot(_ index: Int) -> Binding<String> {
        switch index {
        case 1: $slot1
        case 2: $slot2
        case 3: $slot3
        case 4: $slot4
        default: $slot5
        }
    }
}

// MARK: - Int Identifiable (for sheet item binding)

extension Int: @retroactive Identifiable {
    public var id: Int { self }
}

// MARK: - Nutrient Picker Sheet (for + button taps)

/// Lets the user pick any nutrient (macro or micro) for a slot.
/// Excludes nutrients already assigned to other slots.
private struct NutrientPickerSheet: View {
    @Binding var selectedID: String
    let otherSlotIDs: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    /// Macros not already used in other slots
    private var availableMacros: [MacroNutrientID] {
        MacroNutrientID.allCases.filter { macro in
            !otherSlotIDs.contains(macro.rawValue) &&
            (searchText.isEmpty || macro.label.localizedCaseInsensitiveContains(searchText))
        }
    }

    /// Micros not already used in other slots
    private var availableMicros: [KnownMicronutrient] {
        KnownMicronutrients.all.filter { nutrient in
            !otherSlotIDs.contains(nutrient.id) &&
            (searchText.isEmpty || nutrient.name.localizedCaseInsensitiveContains(searchText))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // Clear option if currently assigned
                if !selectedID.isEmpty {
                    Button(role: .destructive) {
                        selectedID = ""
                        dismiss()
                    } label: {
                        Label("Remove", systemImage: "minus.circle")
                    }
                }

                // Macros section
                if !availableMacros.isEmpty {
                    Section("Macros") {
                        ForEach(availableMacros, id: \.rawValue) { macro in
                            Button {
                                selectedID = macro.rawValue
                                dismiss()
                            } label: {
                                HStack {
                                    Circle()
                                        .fill(macro.color)
                                        .frame(width: 10, height: 10)
                                    Text(macro.label)
                                    Spacer()
                                    Text(macro.unit)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if macro.rawValue == selectedID {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.blue)
                                    }
                                }
                            }
                            .tint(.primary)
                        }
                    }
                }

                // Micros grouped by category
                ForEach(KnownMicronutrient.Category.allCases, id: \.self) { category in
                    let nutrients = availableMicros.filter { $0.category == category }
                    if !nutrients.isEmpty {
                        Section(category.rawValue) {
                            ForEach(nutrients) { nutrient in
                                Button {
                                    selectedID = nutrient.id
                                    dismiss()
                                } label: {
                                    HStack {
                                        Text(nutrient.name)
                                        Spacer()
                                        Text("\(nutrient.dailyValue, specifier: "%.0f") \(nutrient.unit)/day")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        if nutrient.id == selectedID {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(.blue)
                                        }
                                    }
                                }
                                .tint(.primary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Choose Nutrient")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search nutrients")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Slot Edit Sheet (Context Menu)

/// Edit sheet for all 5 configurable slots.
/// Each row is tappable to navigate to an inline picker.
private struct SlotEditSheet: View {
    @Binding var slot1: String
    @Binding var slot2: String
    @Binding var slot3: String
    @Binding var slot4: String
    @Binding var slot5: String
    let allSlotIDs: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Ring Slots") {
                    slotRow(index: 1, binding: $slot1)
                    slotRow(index: 2, binding: $slot2)
                    slotRow(index: 3, binding: $slot3)
                    slotRow(index: 4, binding: $slot4)
                    slotRow(index: 5, binding: $slot5)
                }

                Section {
                    Button(role: .destructive) {
                        slot1 = MacroNutrientID.protein.rawValue
                        slot2 = MacroNutrientID.carbs.rawValue
                        slot3 = MacroNutrientID.fat.rawValue
                        slot4 = ""
                        slot5 = ""
                    } label: {
                        Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                    }
                }
            }
            .navigationTitle("Edit Summary Bar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// A single row: shows the nutrient name (or "Empty — tap to add") and navigates to the picker
    @ViewBuilder
    private func slotRow(index: Int, binding: Binding<String>) -> some View {
        let otherIDs = allSlotIDs.enumerated()
            .filter { $0.offset != index - 1 }
            .map { $0.element }

        NavigationLink {
            InlineNutrientPicker(selectedID: binding, otherSlotIDs: otherIDs)
        } label: {
            HStack {
                Image(systemName: "\(index).circle.fill")
                    .foregroundStyle(colorForEditSlot(index))

                if let macro = MacroNutrientID(rawValue: binding.wrappedValue) {
                    Text(macro.label)
                } else if let micro = KnownMicronutrients.nutrient(forID: binding.wrappedValue) {
                    Text(micro.name)
                } else {
                    Text("Empty — tap to add")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !binding.wrappedValue.isEmpty {
                    Button("Remove") { binding.wrappedValue = "" }
                        .font(.caption)
                        .tint(.red)
                }
            }
        }
    }

    private func colorForEditSlot(_ index: Int) -> Color {
        let colors: [Color] = [.blue, .green, .yellow, .teal, .purple]
        return colors[(index - 1) % colors.count]
    }
}

// MARK: - Inline Nutrient Picker (for Edit Sheet navigation)

/// Nutrient picker embedded inside the SlotEditSheet's NavigationStack.
/// Shows macros + micros. Selecting auto-pops back.
private struct InlineNutrientPicker: View {
    @Binding var selectedID: String
    let otherSlotIDs: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var availableMacros: [MacroNutrientID] {
        MacroNutrientID.allCases.filter { macro in
            !otherSlotIDs.contains(macro.rawValue) &&
            (searchText.isEmpty || macro.label.localizedCaseInsensitiveContains(searchText))
        }
    }

    private var availableMicros: [KnownMicronutrient] {
        KnownMicronutrients.all.filter { nutrient in
            !otherSlotIDs.contains(nutrient.id) &&
            (searchText.isEmpty || nutrient.name.localizedCaseInsensitiveContains(searchText))
        }
    }

    var body: some View {
        List {
            // Clear option
            if !selectedID.isEmpty {
                Button(role: .destructive) {
                    selectedID = ""
                    dismiss()
                } label: {
                    Label("Remove", systemImage: "minus.circle")
                }
            }

            // Macros
            if !availableMacros.isEmpty {
                Section("Macros") {
                    ForEach(availableMacros, id: \.rawValue) { macro in
                        Button {
                            selectedID = macro.rawValue
                            dismiss()
                        } label: {
                            HStack {
                                Circle()
                                    .fill(macro.color)
                                    .frame(width: 10, height: 10)
                                Text(macro.label)
                                Spacer()
                                if macro.rawValue == selectedID {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        .tint(.primary)
                    }
                }
            }

            // Micros by category
            ForEach(KnownMicronutrient.Category.allCases, id: \.self) { category in
                let nutrients = availableMicros.filter { $0.category == category }
                if !nutrients.isEmpty {
                    Section(category.rawValue) {
                        ForEach(nutrients) { nutrient in
                            Button {
                                selectedID = nutrient.id
                                dismiss()
                            } label: {
                                HStack {
                                    Text(nutrient.name)
                                    Spacer()
                                    Text("\(nutrient.dailyValue, specifier: "%.0f") \(nutrient.unit)/day")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if nutrient.id == selectedID {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.blue)
                                    }
                                }
                            }
                            .tint(.primary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Choose Nutrient")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search nutrients")
    }
}

#Preview {
    MacroSummaryBar(log: DailyLog.preview, goals: UserGoals())
        .padding()
}
