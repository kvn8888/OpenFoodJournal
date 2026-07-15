// OpenFoodJournal — Shelf recommendation preferences.

import SwiftData
import SwiftUI

struct ShelfRecommendationSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(TursoMirrorService.self) private var tursoMirror
    @Bindable var preferences: Preferences

    var body: some View {
        Form {
            Section {
                Toggle("Recommendations", isOn: enabledBinding)

                Stepper(value: suggestionCountBinding, in: 1...5) {
                    LabeledContent(
                        "Number of suggestions",
                        value: preferences.clampedShelfSuggestionCount.formatted()
                    )
                }

                Picker("Show recommendations after", selection: triggerBinding) {
                    Text("25% of calorie goal").tag(0.25)
                    Text("50% of calorie goal").tag(0.5)
                    Text("75% of calorie goal").tag(0.75)
                    Text("100% of calorie goal").tag(1.0)
                }

                Picker("Incomplete nutrition", selection: incompletePolicyBinding) {
                    ForEach(ShelfIncompleteNutritionPolicy.allCases) { policy in
                        Text(policy.label).tag(policy)
                    }
                }
            } header: {
                Text("Shelf Recommendations")
            } footer: {
                Text("Good Fits appear above the Food Bank after the selected day's calories reach this point. The default is three suggestions at 50%.")
            }

            Section {
                Picker("Energy intent", selection: energyIntentBinding) {
                    ForEach(ShelfEnergyIntent.allCases) { intent in
                        Text(intent.label).tag(intent)
                    }
                }

                Text(preferences.shelfEnergyIntent.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Nutrition emphasis", selection: nutritionEmphasisBinding) {
                    ForEach(ShelfNutritionEmphasis.allCases) { emphasis in
                        Text(emphasis.label).tag(emphasis)
                    }
                }
            } header: {
                Text("Intent")
            } footer: {
                Text("Energy intent and nutrition emphasis are scored separately. These are soft preferences unless you turn on a hard cap below.")
            }

            if preferences.shelfEnergyIntent == .custom {
                Section {
                    Picker("Calories policy", selection: policyBinding(for: .calories)) {
                        ForEach(ShelfNutrientPolicy.allCases) { policy in
                            Text(policy.label).tag(policy)
                        }
                    }

                    Picker("Calories strength", selection: strengthBinding(for: .calories)) {
                        ForEach(ShelfPolicyStrength.allCases) { strength in
                            Text(strength.label).tag(strength)
                        }
                    }
                } header: {
                    Text("Custom Energy")
                } footer: {
                    Text("Reach fills a shortfall, Stay Near balances under and over, Try to Avoid favors less added energy, and Ignore removes calories from ranking.")
                }
            }

            if preferences.shelfNutritionEmphasis == .custom {
                Section {
                    ForEach(ShelfNutrient.nutritionCases) { nutrient in
                        ShelfCustomNutrientPolicyRow(
                            nutrient: nutrient,
                            policy: policyBinding(for: nutrient),
                            strength: strengthBinding(for: nutrient)
                        )
                    }
                } header: {
                    Text("Custom Nutrition")
                } footer: {
                    Text("Choose plain-language behavior and strength for each nutrient. No raw scoring weights are exposed.")
                }
            }

            Section {
                Toggle("Use rolling 7-day calorie pace", isOn: rollingWeekBinding)
            } header: {
                Text("Weekly Context")
            } footer: {
                Text("Used only when at least five of the six prior days have food logs. Any daily adjustment is limited to 300 kcal or 15% of your goal, whichever is smaller. It never changes the selected-day trigger.")
            }

            Section {
                Toggle("Hard cap calories at goal", isOn: hardCapCaloriesBinding)
                Toggle("Hard cap sodium at Daily Value", isOn: hardCapSodiumBinding)
            } header: {
                Text("Optional Hard Caps")
            } footer: {
                Text("Off by default. When enabled, servings that cross the configured calorie goal or sodium Daily Value are excluded. Leave these off to keep every constraint soft.")
            }

            Section {
                Label(
                    "Suggestions are deterministic convenience guidance, not medical advice.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Shelf Recommendations")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var enabledBinding: Binding<Bool> {
        persistedBinding(
            get: { preferences.shelfRecommendationsEnabled },
            set: { preferences.shelfRecommendationsEnabled = $0 },
            reason: "shelf_recommendations_enabled_changed"
        )
    }

    private var suggestionCountBinding: Binding<Int> {
        persistedBinding(
            get: { preferences.clampedShelfSuggestionCount },
            set: { preferences.shelfSuggestionCount = min(max($0, 1), 5) },
            reason: "shelf_suggestion_count_changed"
        )
    }

    private var triggerBinding: Binding<Double> {
        persistedBinding(
            get: { preferences.shelfTriggerFraction },
            set: { preferences.shelfTriggerFraction = min(max($0, 0), 1) },
            reason: "shelf_trigger_changed"
        )
    }

    private var incompletePolicyBinding: Binding<ShelfIncompleteNutritionPolicy> {
        persistedBinding(
            get: { preferences.shelfIncompleteNutritionPolicy },
            set: { preferences.shelfIncompleteNutritionPolicy = $0 },
            reason: "shelf_incomplete_policy_changed"
        )
    }

    private var energyIntentBinding: Binding<ShelfEnergyIntent> {
        persistedBinding(
            get: { preferences.shelfEnergyIntent },
            set: { preferences.shelfEnergyIntent = $0 },
            reason: "shelf_energy_intent_changed"
        )
    }

    private var nutritionEmphasisBinding: Binding<ShelfNutritionEmphasis> {
        persistedBinding(
            get: { preferences.shelfNutritionEmphasis },
            set: { preferences.shelfNutritionEmphasis = $0 },
            reason: "shelf_nutrition_emphasis_changed"
        )
    }

    private var rollingWeekBinding: Binding<Bool> {
        persistedBinding(
            get: { preferences.shelfUseRollingWeekContext },
            set: { preferences.shelfUseRollingWeekContext = $0 },
            reason: "shelf_rolling_week_changed"
        )
    }

    private var hardCapCaloriesBinding: Binding<Bool> {
        persistedBinding(
            get: { preferences.shelfHardCapCalories },
            set: { preferences.shelfHardCapCalories = $0 },
            reason: "shelf_calorie_hard_cap_changed"
        )
    }

    private var hardCapSodiumBinding: Binding<Bool> {
        persistedBinding(
            get: { preferences.shelfHardCapSodium },
            set: { preferences.shelfHardCapSodium = $0 },
            reason: "shelf_sodium_hard_cap_changed"
        )
    }

    private func policyBinding(for nutrient: ShelfNutrient) -> Binding<ShelfNutrientPolicy> {
        persistedBinding(
            get: { preferences.shelfPolicy(for: nutrient) },
            set: { preferences.setShelfPolicy($0, for: nutrient) },
            reason: "shelf_custom_policy_changed"
        )
    }

    private func strengthBinding(for nutrient: ShelfNutrient) -> Binding<ShelfPolicyStrength> {
        persistedBinding(
            get: { preferences.shelfStrength(for: nutrient) },
            set: { preferences.setShelfStrength($0, for: nutrient) },
            reason: "shelf_custom_strength_changed"
        )
    }

    private func persistedBinding<Value>(
        get: @escaping () -> Value,
        set: @escaping (Value) -> Void,
        reason: String
    ) -> Binding<Value> {
        Binding(get: get) { value in
            set(value)
            persist(reason: reason)
        }
    }

    private func persist(reason: String) {
        preferences.updatedAt = .now
        try? modelContext.save()
        tursoMirror.scheduleMirror(reason: reason)
    }
}

private struct ShelfCustomNutrientPolicyRow: View {
    let nutrient: ShelfNutrient
    @Binding var policy: ShelfNutrientPolicy
    @Binding var strength: ShelfPolicyStrength

    var body: some View {
        DisclosureGroup(nutrient.label) {
            Picker("Policy", selection: $policy) {
                ForEach(ShelfNutrientPolicy.allCases) { policy in
                    Text(policy.label).tag(policy)
                }
            }

            Picker("Strength", selection: $strength) {
                ForEach(ShelfPolicyStrength.allCases) { strength in
                    Text(strength.label).tag(strength)
                }
            }
            .disabled(policy == .ignore)
        }
    }
}
