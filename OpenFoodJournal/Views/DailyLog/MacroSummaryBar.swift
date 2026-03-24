// Macros — Food Journaling App
// AGPL-3.0 License

import SwiftUI

/// Glass card showing daily macro progress rings + up to 2 configurable micronutrient rings.
/// Layout: [Protein] [Carbs] [Fat] [Micro1 or +] [Micro2 or +]
/// Long-press opens an edit sheet to change which micronutrients are tracked.
struct MacroSummaryBar: View {
    let log: DailyLog?
    let goals: UserGoals

    // ── Persisted micronutrient slot selections ───────────────────
    // Two configurable slots stored as micronutrient IDs (e.g. "sodium", "fiber").
    // Empty string = slot is unassigned (shows + button).
    @AppStorage("summaryBar.microSlot1") private var microSlot1: String = ""
    @AppStorage("summaryBar.microSlot2") private var microSlot2: String = ""

    // ── State ─────────────────────────────────────────────────────
    @State private var editingSlot: Int? = nil    // Which slot is being picked (1 or 2)
    @State private var showEditSheet = false       // Long-press edit mode

    // ── Computed ──────────────────────────────────────────────────
    private var calories: Double { log?.totalCalories ?? 0 }
    private var protein: Double { log?.totalProtein ?? 0 }
    private var carbs: Double { log?.totalCarbs ?? 0 }
    private var fat: Double { log?.totalFat ?? 0 }

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

            // Ring row: macros + micro slots
            GlassEffectContainer(spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    // Fixed macro rings
                    MacroRingView(value: protein, goal: goals.dailyProtein, color: .blue, label: "Protein", unit: "g")
                    MacroRingView(value: carbs, goal: goals.dailyCarbs, color: .green, label: "Carbs", unit: "g")
                    MacroRingView(value: fat, goal: goals.dailyFat, color: .yellow, label: "Fat", unit: "g")

                    // Micronutrient slot 1
                    microSlotView(slotID: microSlot1, slotIndex: 1)

                    // Micronutrient slot 2
                    microSlotView(slotID: microSlot2, slotIndex: 2)
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
            MicroSlotEditSheet(
                slot1: $microSlot1,
                slot2: $microSlot2
            )
            .presentationDetents([.medium])
        }
        .sheet(item: $editingSlot) { slot in
            MicronutrientPickerSheet(
                selectedID: slot == 1 ? $microSlot1 : $microSlot2,
                otherSlotID: slot == 1 ? microSlot2 : microSlot1
            )
            .presentationDetents([.medium, .large])
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Daily macro summary")
    }

    // MARK: - Micro Slot View

    /// Shows either a micronutrient ring (if slot is assigned) or a + button (if empty)
    @ViewBuilder
    private func microSlotView(slotID: String, slotIndex: Int) -> some View {
        if let nutrient = KnownMicronutrients.nutrient(forID: slotID) {
            // Filled slot — show a ring with the micro's daily value as goal
            let value = microTotals[nutrient.id] ?? 0
            MacroRingView(
                value: value,
                goal: nutrient.dailyValue,
                color: colorForMicroSlot(slotIndex),
                label: nutrient.name,
                unit: nutrient.unit
            )
        } else {
            // Empty slot — show a + button to pick a micronutrient
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

    /// Distinct colors for micro slots so they don't clash with macro ring colors
    private func colorForMicroSlot(_ index: Int) -> Color {
        index == 1 ? .teal : .purple
    }
}

// MARK: - Int Identifiable (for sheet item binding)

extension Int: @retroactive Identifiable {
    public var id: Int { self }
}

// MARK: - Micronutrient Picker Sheet

/// Lets the user pick a micronutrient for one of the two configurable slots.
/// Shows all known micronutrients, excluding the one already in the other slot.
private struct MicronutrientPickerSheet: View {
    @Binding var selectedID: String
    let otherSlotID: String
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    /// All available micronutrients, excluding the one in the other slot
    private var availableNutrients: [KnownMicronutrient] {
        KnownMicronutrients.all.filter { nutrient in
            nutrient.id != otherSlotID &&
            (searchText.isEmpty || nutrient.name.localizedCaseInsensitiveContains(searchText))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // Option to clear the slot
                if !selectedID.isEmpty {
                    Button(role: .destructive) {
                        selectedID = ""
                        dismiss()
                    } label: {
                        Label("Remove", systemImage: "minus.circle")
                    }
                }

                // Grouped by category
                ForEach(KnownMicronutrient.Category.allCases, id: \.self) { category in
                    let nutrients = availableNutrients.filter { $0.category == category }
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

// MARK: - Micro Slot Edit Sheet (Long Press)

/// Edit sheet shown on long-press. Lets the user change both micro slots
/// and reorder them (swap positions).
private struct MicroSlotEditSheet: View {
    @Binding var slot1: String
    @Binding var slot2: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Tracked Micronutrients") {
                    // Slot 1
                    HStack {
                        Image(systemName: "1.circle.fill")
                            .foregroundStyle(.teal)
                        if let nutrient = KnownMicronutrients.nutrient(forID: slot1) {
                            Text(nutrient.name)
                        } else {
                            Text("Empty")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !slot1.isEmpty {
                            Button("Remove") { slot1 = "" }
                                .font(.caption)
                                .tint(.red)
                        }
                    }

                    // Slot 2
                    HStack {
                        Image(systemName: "2.circle.fill")
                            .foregroundStyle(.purple)
                        if let nutrient = KnownMicronutrients.nutrient(forID: slot2) {
                            Text(nutrient.name)
                        } else {
                            Text("Empty")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !slot2.isEmpty {
                            Button("Remove") { slot2 = "" }
                                .font(.caption)
                                .tint(.red)
                        }
                    }
                }

                // Swap button
                if !slot1.isEmpty && !slot2.isEmpty {
                    Section {
                        Button {
                            let temp = slot1
                            slot1 = slot2
                            slot2 = temp
                        } label: {
                            Label("Swap Positions", systemImage: "arrow.left.arrow.right")
                        }
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
}

#Preview {
    MacroSummaryBar(log: DailyLog.preview, goals: UserGoals())
        .padding()
}
