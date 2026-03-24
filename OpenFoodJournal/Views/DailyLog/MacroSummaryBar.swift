// Macros — Food Journaling App
// AGPL-3.0 License

import SwiftUI

/// Glass card showing daily macro progress vs. goals.
struct MacroSummaryBar: View {
    let log: DailyLog?
    let goals: UserGoals

    private var calories: Double { log?.totalCalories ?? 0 }
    private var protein: Double { log?.totalProtein ?? 0 }
    private var carbs: Double { log?.totalCarbs ?? 0 }
    private var fat: Double { log?.totalFat ?? 0 }

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

            // Macro rings
            GlassEffectContainer(spacing: 20) {
                HStack(spacing: 20) {
                    MacroRingView(value: protein, goal: goals.dailyProtein, color: .blue, label: "Protein", unit: "g")
                    MacroRingView(value: carbs, goal: goals.dailyCarbs, color: .green, label: "Carbs", unit: "g")
                    MacroRingView(value: fat, goal: goals.dailyFat, color: .yellow, label: "Fat", unit: "g")
                }
                .padding(.horizontal, 4)
            }
        }
        .padding()
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Daily macro summary")
    }
}

#Preview {
    MacroSummaryBar(log: DailyLog.preview, goals: UserGoals())
        .padding()
}
