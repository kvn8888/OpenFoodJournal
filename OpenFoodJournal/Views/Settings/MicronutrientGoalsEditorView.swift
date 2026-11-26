// OpenFoodJournal — Micronutrient goal editor
// AGPL-3.0 License

import SwiftUI

/// Per-nutrient daily targets. An empty field means "use the FDA Daily Value",
/// so the placeholder shows that number and clearing a field restores it.
///
/// Unlike `GoalsEditorView` there is no Save button: this is a 37-row list, and
/// a single confirmation for the whole thing makes it easy to lose edits made
/// several screens of scrolling ago. Each row commits when it loses focus.
struct MicronutrientGoalsEditorView: View {
    @Environment(UserGoals.self) private var goals
    @State private var searchText = ""
    @State private var showResetConfirmation = false

    private var overrideCount: Int { goals.micronutrientOverrides.count }

    private func nutrients(in category: KnownMicronutrient.Category) -> [KnownMicronutrient] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return KnownMicronutrients.all.filter { nutrient in
            nutrient.category == category
                && (query.isEmpty || nutrient.name.lowercased().contains(query))
        }
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Custom targets")
                    Spacer()
                    Text("\(overrideCount)")
                        .foregroundStyle(.secondary)
                        .ofjNumericTextTransition(value: overrideCount)
                }
                Button("Reset All to FDA Values", role: .destructive) {
                    showResetConfirmation = true
                }
                .disabled(overrideCount == 0)
            } footer: {
                Text("Targets default to the FDA Daily Value for a 2,000 calorie diet. Setting your own replaces it everywhere a percentage of the daily value is shown. These are general reference values — consult a healthcare professional for personalized guidance.")
            }

            ForEach(KnownMicronutrient.Category.allCases, id: \.self) { category in
                let matches = nutrients(in: category)
                if !matches.isEmpty {
                    Section(category.rawValue) {
                        ForEach(matches) { nutrient in
                            MicronutrientGoalRow(nutrient: nutrient)
                        }
                    }
                }
            }
        }
        .navigationTitle("Micronutrient Goals")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search nutrients")
        .confirmationDialog("Reset all micronutrient targets?",
                            isPresented: $showResetConfirmation,
                            titleVisibility: .visible) {
            Button("Reset All", role: .destructive) { goals.resetAllMicronutrientGoals() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every nutrient returns to its FDA Daily Value. Your logged entries are not affected.")
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                    to: nil, from: nil, for: nil)
                }
            }
        }
    }
}

private struct MicronutrientGoalRow: View {
    @Environment(UserGoals.self) private var goals
    let nutrient: KnownMicronutrient

    @State private var text = ""
    @FocusState private var isFocused: Bool

    private var isOverridden: Bool { goals.isOverridden(nutrient) }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(nutrient.name)
                if isOverridden {
                    Text("FDA \(MicronutrientGoalsFormat.number(nutrient.dailyValue)) \(nutrient.unit)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            TextField(MicronutrientGoalsFormat.number(nutrient.dailyValue), text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .focused($isFocused)
                .frame(width: 84)
                .onChange(of: isFocused) { _, focused in
                    if !focused { commit() }
                }
                .onSubmit { commit() }
            Text(nutrient.unit)
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
        }
        .onAppear { text = isOverridden ? MicronutrientGoalsFormat.number(goals.dailyValue(for: nutrient)) : "" }
        .swipeActions(edge: .trailing) {
            if isOverridden {
                Button("Reset", role: .destructive) {
                    goals.setDailyValue(nil, for: nutrient)
                    text = ""
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(nutrient.name) daily target")
        .accessibilityValue(isOverridden
            ? "\(MicronutrientGoalsFormat.number(goals.dailyValue(for: nutrient))) \(nutrient.unit)"
            : "FDA default, \(MicronutrientGoalsFormat.number(nutrient.dailyValue)) \(nutrient.unit)")
    }

    /// Blank, zero or unparseable input clears the override rather than storing
    /// a zero target, which would render as "No DV" and look like a bug.
    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        goals.setDailyValue(trimmed.isEmpty ? nil : Double(trimmed), for: nutrient)
        text = goals.isOverridden(nutrient)
            ? MicronutrientGoalsFormat.number(goals.dailyValue(for: nutrient))
            : ""
    }
}

enum MicronutrientGoalsFormat {
    /// Grouping is off on purpose: the same string goes back into a decimal-pad
    /// field, and "4,700" does not parse.
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        return value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never))
    }
}

#Preview {
    NavigationStack {
        MicronutrientGoalsEditorView()
            .environment(UserGoals())
    }
}
