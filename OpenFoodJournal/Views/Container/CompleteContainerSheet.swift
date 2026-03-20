// OpenFoodJournal — CompleteContainerSheet
// Presented when the user taps "Weigh" on an active container.
// They enter the final weight, see the derived nutrition, and can log it.
// AGPL-3.0 License

import SwiftUI

struct CompleteContainerSheet: View {
    // ── Environment ───────────────────────────────────────────────
    @Environment(\.dismiss) private var dismiss
    @Environment(NutritionStore.self) private var nutritionStore

    // ── Input ─────────────────────────────────────────────────────
    @Bindable var container: TrackedContainer

    // ── State ─────────────────────────────────────────────────────
    @State private var finalWeightText = ""
    @State private var selectedMealType: MealType = .snack
    @State private var showResults = false
    @FocusState private var isWeightFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // ── Container Info ─────────────────────────────
                    containerHeader

                    Divider()

                    // ── Final Weight Input ─────────────────────────
                    weightInput

                    // ── Results (shown after entering weight) ──────
                    if showResults, let finalWeight = Double(finalWeightText) {
                        Divider()
                        resultsSection(finalWeight: finalWeight)
                    }
                }
                .padding()
            }
            .navigationTitle("Complete Container")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: - Container Header

    /// Shows what food is being tracked and the starting weight
    private var containerHeader: some View {
        VStack(spacing: 8) {
            Image(systemName: "scalemass.fill")
                .font(.largeTitle)
                .foregroundStyle(.teal)

            Text(container.foodName)
                .font(.title3)
                .fontWeight(.bold)

            if let brand = container.foodBrand {
                Text(brand)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                Label("Start: \(Int(container.startWeight))g", systemImage: "arrow.down.circle")
                Label("\(container.gramsPerServing, specifier: "%.0f")g/serving", systemImage: "equal.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Weight Input

    /// The text field for entering the final container weight
    private var weightInput: some View {
        VStack(spacing: 12) {
            Text("Enter the current weight of the container")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack {
                TextField("Weight", text: $finalWeightText)
                    .keyboardType(.decimalPad)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .focused($isWeightFocused)

                Text("g")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(.quaternary, in: .rect(cornerRadius: 12))

            // Calculate button — validates and shows results
            Button("Calculate") {
                guard let weight = Double(finalWeightText),
                      weight >= 0,
                      weight < container.startWeight else { return }
                withAnimation(.spring(duration: 0.3)) {
                    showResults = true
                }
            }
            .buttonStyle(.bordered)
            .disabled(Double(finalWeightText) == nil)
        }
        .onAppear { isWeightFocused = true }
    }

    // MARK: - Results Section

    /// Shows the calculated consumed nutrition after entering final weight
    private func resultsSection(finalWeight: Double) -> some View {
        let consumed = container.startWeight - finalWeight
        let servings = container.gramsPerServing > 0 ? consumed / container.gramsPerServing : 0

        return VStack(spacing: 16) {
            // Consumed weight summary
            VStack(spacing: 4) {
                Text("Consumed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(Int(consumed))g")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                Text("(\(servings, specifier: "%.1f") servings)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Macro grid
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ResultMacroCell(
                    label: "Calories",
                    value: container.caloriesPerServing * servings,
                    unit: "kcal",
                    color: .orange
                )
                ResultMacroCell(
                    label: "Protein",
                    value: container.proteinPerServing * servings,
                    unit: "g",
                    color: .blue
                )
                ResultMacroCell(
                    label: "Carbs",
                    value: container.carbsPerServing * servings,
                    unit: "g",
                    color: .green
                )
                ResultMacroCell(
                    label: "Fat",
                    value: container.fatPerServing * servings,
                    unit: "g",
                    color: .yellow
                )
            }

            Divider()

            // Meal type picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Log as")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Picker("Meal", selection: $selectedMealType) {
                    ForEach(MealType.allCases) { meal in
                        Text(meal.rawValue.capitalized).tag(meal)
                    }
                }
                .pickerStyle(.segmented)
            }

            // Log button — saves final weight and creates nutrition entry
            Button {
                // Save the final weight to the container
                container.finalWeight = finalWeight
                container.completedDate = .now

                // Create a NutritionEntry for the consumed amount and log it
                if let entry = container.toNutritionEntry(mealType: selectedMealType) {
                    nutritionStore.log(entry, to: .now)
                }

                dismiss()
            } label: {
                Text("Log to Journal")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

// MARK: - Result Macro Cell

/// Displays a calculated macro value in the results grid
private struct ResultMacroCell: View {
    let label: String
    let value: Double
    let unit: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text("\(Int(value))")
                .font(.title2)
                .fontWeight(.bold)
                .monospacedDigit()
            Text(unit)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(color.opacity(0.1), in: .rect(cornerRadius: 12))
    }
}
