// Macros — Food Journaling App
// AGPL-3.0 License

import SwiftUI
import SwiftData

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
    @Environment(SyncService.self) private var syncService

    // ── Preferences (SwiftData singleton) ─────────────────────────
    // Ring slot configuration persisted in the Preferences model.
    // Fetched via @Query; exactly one row should exist.
    @Query private var allPrefs: [Preferences]
    private var prefs: Preferences? { allPrefs.first }

    // ── State ─────────────────────────────────────────────────────
    @State private var editingSlot: Int? = nil    // Which slot index is being picked (1–5)
    @State private var showEditSheet = false       // Context menu edit mode

    // ── Computed ──────────────────────────────────────────────────
    private var calories: Double { log?.totalCalories ?? 0 }
    private var protein: Double { log?.totalProtein ?? 0 }
    private var carbs: Double { log?.totalCarbs ?? 0 }
    private var fat: Double { log?.totalFat ?? 0 }

    /// All 5 slot IDs read from Preferences (or defaults)
    private var slotIDs: [String] {
        guard let p = prefs else {
            return [MacroNutrientID.protein.rawValue, MacroNutrientID.carbs.rawValue,
                    MacroNutrientID.fat.rawValue, "", ""]
        }
        return [p.ringSlot1, p.ringSlot2, p.ringSlot3, p.ringSlot4, p.ringSlot5]
    }

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
        .sheet(isPresented: $showEditSheet, onDismiss: syncPreferences) {
            if let p = prefs {
                SlotEditSheet(preferences: p, allSlotIDs: slotIDs)
                    .presentationDetents([.medium, .large])
            }
        }
        .sheet(item: $editingSlot, onDismiss: syncPreferences) { slot in
            if let p = prefs {
                NutrientPickerSheet(
                    preferences: p,
                    slotIndex: slot,
                    otherSlotIDs: slotIDs.enumerated()
                        .filter { $0.offset != slot - 1 }
                        .map { $0.element }
                )
                .presentationDetents([.medium, .large])
            }
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

    /// Fire-and-forget push of preferences to the server after sheet dismissal
    private func syncPreferences() {
        guard let p = prefs else { return }
        Task {
            try? await syncService.updatePreferences(p)
        }
    }

}

// MARK: - Int Identifiable (for sheet item binding)

extension Int: @retroactive Identifiable {
    public var id: Int { self }
}

// MARK: - Nutrient Picker Sheet (for + button taps)

/// Lets the user pick any nutrient (macro or micro) for a specific slot.
/// Writes directly to the Preferences model. Excludes nutrients in other slots.
private struct NutrientPickerSheet: View {
    @Bindable var preferences: Preferences
    let slotIndex: Int
    let otherSlotIDs: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    /// Current value for the slot being edited
    private var currentID: String {
        get { slotValue(for: slotIndex) }
    }

    private func slotValue(for index: Int) -> String {
        switch index {
        case 1: preferences.ringSlot1
        case 2: preferences.ringSlot2
        case 3: preferences.ringSlot3
        case 4: preferences.ringSlot4
        default: preferences.ringSlot5
        }
    }

    private func setSlot(_ value: String) {
        switch slotIndex {
        case 1: preferences.ringSlot1 = value
        case 2: preferences.ringSlot2 = value
        case 3: preferences.ringSlot3 = value
        case 4: preferences.ringSlot4 = value
        default: preferences.ringSlot5 = value
        }
        preferences.updatedAt = Date()
    }

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
        NavigationStack {
            List {
                if !currentID.isEmpty {
                    Button(role: .destructive) {
                        setSlot("")
                        dismiss()
                    } label: {
                        Label("Remove", systemImage: "minus.circle")
                    }
                }

                if !availableMacros.isEmpty {
                    Section("Macros") {
                        ForEach(availableMacros, id: \.rawValue) { macro in
                            Button {
                                setSlot(macro.rawValue)
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
                                    if macro.rawValue == currentID {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.blue)
                                    }
                                }
                            }
                            .tint(.primary)
                        }
                    }
                }

                ForEach(KnownMicronutrient.Category.allCases, id: \.self) { category in
                    let nutrients = availableMicros.filter { $0.category == category }
                    if !nutrients.isEmpty {
                        Section(category.rawValue) {
                            ForEach(nutrients) { nutrient in
                                Button {
                                    setSlot(nutrient.id)
                                    dismiss()
                                } label: {
                                    HStack {
                                        Text(nutrient.name)
                                        Spacer()
                                        Text("\(nutrient.dailyValue, specifier: "%.0f") \(nutrient.unit)/day")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        if nutrient.id == currentID {
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
/// Each row navigates to an inline picker. Writes directly to Preferences model.
private struct SlotEditSheet: View {
    @Bindable var preferences: Preferences
    let allSlotIDs: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Ring Slots") {
                    slotRow(index: 1, keyPath: \.ringSlot1)
                    slotRow(index: 2, keyPath: \.ringSlot2)
                    slotRow(index: 3, keyPath: \.ringSlot3)
                    slotRow(index: 4, keyPath: \.ringSlot4)
                    slotRow(index: 5, keyPath: \.ringSlot5)
                }

                Section {
                    Button(role: .destructive) {
                        preferences.ringSlot1 = MacroNutrientID.protein.rawValue
                        preferences.ringSlot2 = MacroNutrientID.carbs.rawValue
                        preferences.ringSlot3 = MacroNutrientID.fat.rawValue
                        preferences.ringSlot4 = ""
                        preferences.ringSlot5 = ""
                        preferences.updatedAt = Date()
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

    @ViewBuilder
    private func slotRow(index: Int, keyPath: ReferenceWritableKeyPath<Preferences, String>) -> some View {
        let otherIDs = allSlotIDs.enumerated()
            .filter { $0.offset != index - 1 }
            .map { $0.element }
        let value = preferences[keyPath: keyPath]

        NavigationLink {
            InlineNutrientPicker(
                preferences: preferences,
                keyPath: keyPath,
                otherSlotIDs: otherIDs
            )
        } label: {
            HStack {
                Image(systemName: "\(index).circle.fill")
                    .foregroundStyle(colorForEditSlot(index))

                if let macro = MacroNutrientID(rawValue: value) {
                    Text(macro.label)
                } else if let micro = KnownMicronutrients.nutrient(forID: value) {
                    Text(micro.name)
                } else {
                    Text("Empty — tap to add")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !value.isEmpty {
                    Button("Remove") {
                        preferences[keyPath: keyPath] = ""
                        preferences.updatedAt = Date()
                    }
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
/// Writes directly to the Preferences model via keyPath. Auto-pops on selection.
private struct InlineNutrientPicker: View {
    @Bindable var preferences: Preferences
    let keyPath: ReferenceWritableKeyPath<Preferences, String>
    let otherSlotIDs: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var currentID: String { preferences[keyPath: keyPath] }

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

    private func select(_ value: String) {
        preferences[keyPath: keyPath] = value
        preferences.updatedAt = Date()
        dismiss()
    }

    var body: some View {
        List {
            if !currentID.isEmpty {
                Button(role: .destructive) {
                    select("")
                } label: {
                    Label("Remove", systemImage: "minus.circle")
                }
            }

            if !availableMacros.isEmpty {
                Section("Macros") {
                    ForEach(availableMacros, id: \.rawValue) { macro in
                        Button {
                            select(macro.rawValue)
                        } label: {
                            HStack {
                                Circle()
                                    .fill(macro.color)
                                    .frame(width: 10, height: 10)
                                Text(macro.label)
                                Spacer()
                                if macro.rawValue == currentID {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        .tint(.primary)
                    }
                }
            }

            ForEach(KnownMicronutrient.Category.allCases, id: \.self) { category in
                let nutrients = availableMicros.filter { $0.category == category }
                if !nutrients.isEmpty {
                    Section(category.rawValue) {
                        ForEach(nutrients) { nutrient in
                            Button {
                                select(nutrient.id)
                            } label: {
                                HStack {
                                    Text(nutrient.name)
                                    Spacer()
                                    Text("\(nutrient.dailyValue, specifier: "%.0f") \(nutrient.unit)/day")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if nutrient.id == currentID {
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
