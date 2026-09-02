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
        case .protein: OFJColor.protein
        case .carbs: OFJColor.carbohydrates
        case .fat: OFJColor.fat
        case .calories: OFJColor.calories
        }
    }
}

/// Glass card showing daily calorie headline + up to 5 configurable nutrient rings.
/// Each slot can hold a macro (protein/carbs/fat/calories) or a micronutrient.
/// Long-press → context menu → edit sheet to reconfigure all slots.
struct MacroSummaryBar: View {
    private let log: DailyLog?
    private let suppliedTotals: JournalDayTotals?
    let goals: UserGoals

    /// History and standalone previews may still supply a live SwiftData log.
    init(log: DailyLog?, goals: UserGoals) {
        self.log = log
        self.suppliedTotals = nil
        self.goals = goals
    }

    /// Journal uses the exact snapshot that also feeds its calendar rings.
    init(totals: JournalDayTotals, goals: UserGoals) {
        self.log = nil
        self.suppliedTotals = totals
        self.goals = goals
    }

    // ── Preferences (SwiftData singleton) ─────────────────────────
    // Ring slot configuration persisted in the Preferences model.
    // Fetched via @Query; exactly one row should exist.
    @Query private var allPrefs: [Preferences]
    private var prefs: Preferences? { allPrefs.first }

    // ── State ─────────────────────────────────────────────────────
    @State private var editingSlot: Int? = nil    // Which slot index is being picked (1–5)
    @State private var showEditSheet = false       // Context menu edit mode

    // ── Computed ──────────────────────────────────────────────────
    private var resolvedTotals: JournalDayTotals {
        suppliedTotals ?? JournalDayTotals(entries: log?.safeEntries ?? [])
    }

    /// All 5 slot IDs read from Preferences (or defaults)
    private var slotIDs: [String] {
        guard let p = prefs else {
            return [MacroNutrientID.protein.rawValue, MacroNutrientID.carbs.rawValue,
                    MacroNutrientID.fat.rawValue, "", ""]
        }
        return [p.ringSlot1, p.ringSlot2, p.ringSlot3, p.ringSlot4, p.ringSlot5]
    }

    var body: some View {
        let totals = resolvedTotals
        VStack(spacing: OFJSpace.s12) {
            // Calorie headline
            HStack(alignment: .firstTextBaseline, spacing: OFJSpace.s4) {
                Text(totals.calories, format: .number.precision(.fractionLength(0)))
                    .font(OFJType.nutritionDisplay)
                    .ofjNumericTextTransition(value: totals.calories)
                Text("/ \(Int(goals.dailyCalories)) kcal")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .ofjNumericTextTransition(value: goals.dailyCalories)
                Spacer()
            }

            // Ring row: all 5 configurable slots
            GlassEffectContainer(spacing: OFJSpace.s12) {
                // Spacer(minLength: 8) between each ring instead of fixed spacing
                // so they distribute evenly across whatever width is available —
                // works on iPhone SE, Pro Max, and everything in between.
                HStack(alignment: .top, spacing: 0) {
                    ForEach(0..<5, id: \.self) { slotIdx in
                        if slotIdx > 0 {
                            Spacer(minLength: OFJSpace.s8)
                        }
                        slotView(slotID: slotIDs[slotIdx], slotIndex: slotIdx + 1, totals: totals)
                    }
                }
                .padding(.horizontal, OFJSpace.s4)
            }
        }
        .padding(OFJSpace.s16)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: OFJRadius.card))
        .contextMenu {
            Button {
                showEditSheet = true
            } label: {
                Label("Edit Tracked Nutrients", systemImage: "slider.horizontal.3")
            }
        }
        .sheet(isPresented: $showEditSheet) {
            if let p = prefs {
                SlotEditSheet(preferences: p, allSlotIDs: slotIDs)
                    .presentationDetents([.medium, .large])
            }
        }
        .sheet(item: $editingSlot) { slot in
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
    private func slotView(slotID: String, slotIndex: Int, totals: JournalDayTotals) -> some View {
        if let macroID = MacroNutrientID(rawValue: slotID) {
            // Macro slot — pull value/goal from DailyLog totals + UserGoals
            let (value, goal) = macroValueAndGoal(for: macroID, totals: totals)
            MacroRingView(
                value: value,
                goal: goal,
                color: macroID.color,
                label: macroID.label,
                unit: macroID.unit,
                usesJournalStyle: true
            )
        } else if let nutrient = KnownMicronutrients.nutrient(forID: slotID) {
            let value = totals.micronutrients[nutrient.id] ?? 0
            MacroRingView(
                value: value,
                goal: goals.dailyValue(for: nutrient),
                color: colorForSlot(slotIndex),
                label: nutrient.name,
                unit: nutrient.unit,
                usesJournalStyle: true
            )
        } else {
            // Empty slot — show + button
            Button {
                editingSlot = slotIndex
            } label: {
                VStack(spacing: OFJSpace.s4) {
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
    private func macroValueAndGoal(for macro: MacroNutrientID, totals: JournalDayTotals) -> (Double, Double) {
        switch macro {
        case .protein:  (totals.protein, goals.dailyProtein)
        case .carbs:    (totals.carbs, goals.dailyCarbs)
        case .fat:      (totals.fat, goals.dailyFat)
        case .calories: (totals.calories, goals.dailyCalories)
        }
    }

    /// Assigns a color to a slot based on its position (for micro slots only)
    private func colorForSlot(_ index: Int) -> Color {
        let colors: [Color] = [.blue, .green, .yellow, .primary, .primary]
        return colors[(index - 1) % colors.count]
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
    @Environment(UserGoals.self) private var goals
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
                                        Text(nutrientDailyValueText(nutrient, goal: goals.dailyValue(for: nutrient)))
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
/// Each row navigates to an inline picker. Supports drag-to-reorder.
/// Writes directly to Preferences model.
private struct SlotEditSheet: View {
    @Bindable var preferences: Preferences
    let allSlotIDs: [String]
    @Environment(\.dismiss) private var dismiss

    /// Local mutable copy of slot IDs for reordering. Synced back to Preferences on change.
    @State private var slots: [String] = []

    var body: some View {
        NavigationStack {
            List {
                Section("Ring Slots") {
                    ForEach(Array(slots.enumerated()), id: \.offset) { index, value in
                        let otherIDs = slots.enumerated()
                            .filter { $0.offset != index }
                            .map { $0.element }

                        NavigationLink {
                            InlineNutrientPicker(
                                preferences: preferences,
                                slotIndex: index,
                                slots: $slots,
                                otherSlotIDs: otherIDs
                            )
                        } label: {
                            HStack {
                                Image(systemName: "\(index + 1).circle.fill")
                                    .foregroundStyle(colorForEditSlot(index + 1))

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
                                        slots[index] = ""
                                        writeBack()
                                    }
                                    .font(.caption)
                                    .tint(.red)
                                }
                            }
                        }
                    }
                    .onMove { from, to in
                        slots.move(fromOffsets: from, toOffset: to)
                        writeBack()
                    }
                }

                Section {
                    Button(role: .destructive) {
                        slots = [
                            MacroNutrientID.protein.rawValue,
                            MacroNutrientID.carbs.rawValue,
                            MacroNutrientID.fat.rawValue,
                            "",
                            ""
                        ]
                        writeBack()
                    } label: {
                        Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Edit Summary Bar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                slots = [
                    preferences.ringSlot1,
                    preferences.ringSlot2,
                    preferences.ringSlot3,
                    preferences.ringSlot4,
                    preferences.ringSlot5
                ]
            }
        }
    }

    /// Writes the local slots array back to the Preferences model.
    private func writeBack() {
        preferences.ringSlot1 = slots[0]
        preferences.ringSlot2 = slots[1]
        preferences.ringSlot3 = slots[2]
        preferences.ringSlot4 = slots[3]
        preferences.ringSlot5 = slots[4]
        preferences.updatedAt = Date()
    }

    private func colorForEditSlot(_ index: Int) -> Color {
        let colors: [Color] = [.blue, .green, .yellow, .teal, .purple]
        return colors[(index - 1) % colors.count]
    }
}

// MARK: - Inline Nutrient Picker (for Edit Sheet navigation)

/// Nutrient picker embedded inside the SlotEditSheet's NavigationStack.
/// Writes to the slots binding array and syncs to Preferences. Auto-pops on selection.
private struct InlineNutrientPicker: View {
    @Bindable var preferences: Preferences
    let slotIndex: Int
    @Binding var slots: [String]
    let otherSlotIDs: [String]
    @Environment(\.dismiss) private var dismiss
    @Environment(UserGoals.self) private var goals
    @State private var searchText = ""

    private var currentID: String { slots[slotIndex] }

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
        slots[slotIndex] = value
        preferences.ringSlot1 = slots[0]
        preferences.ringSlot2 = slots[1]
        preferences.ringSlot3 = slots[2]
        preferences.ringSlot4 = slots[3]
        preferences.ringSlot5 = slots[4]
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
                                    Text(nutrientDailyValueText(nutrient, goal: goals.dailyValue(for: nutrient)))
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

private func nutrientDailyValueText(_ nutrient: KnownMicronutrient, goal: Double) -> String {
    guard goal > 0 else { return "No DV" }
    let suffix = goal == nutrient.dailyValue ? "" : " (yours)"
    return "\(goal.formatted(.number.precision(.fractionLength(0)))) \(nutrient.unit)/day\(suffix)"
}

#Preview {
    MacroSummaryBar(log: DailyLog.preview, goals: UserGoals())
        .padding()
}
