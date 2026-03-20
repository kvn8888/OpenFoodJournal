// Macros — Food Journaling App
// AGPL-3.0 License

import SwiftUI
import Charts

struct MacroChartView: View {
    let logs: [DailyLog]
    let goals: UserGoals

    enum ChartMacro: String, CaseIterable, Identifiable {
        case calories = "Calories"
        case protein = "Protein"
        case carbs = "Carbs"
        case fat = "Fat"
        var id: String { rawValue }
    }

    @State private var selectedMacro: ChartMacro = .calories

    private var chartColor: Color {
        switch selectedMacro {
        case .calories: .orange
        case .protein: .blue
        case .carbs: .green
        case .fat: .yellow
        }
    }

    private var goalValue: Double {
        switch selectedMacro {
        case .calories: goals.dailyCalories
        case .protein: goals.dailyProtein
        case .carbs: goals.dailyCarbs
        case .fat: goals.dailyFat
        }
    }

    private var unit: String {
        selectedMacro == .calories ? "kcal" : "g"
    }

    private func value(for log: DailyLog) -> Double {
        switch selectedMacro {
        case .calories: log.totalCalories
        case .protein: log.totalProtein
        case .carbs: log.totalCarbs
        case .fat: log.totalFat
        }
    }

    private var average: Double {
        guard !logs.isEmpty else { return 0 }
        return logs.map { value(for: $0) }.reduce(0, +) / Double(logs.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Macro picker
            Picker("Macro", selection: $selectedMacro) {
                ForEach(ChartMacro.allCases) { macro in
                    Text(macro.rawValue).tag(macro)
                }
            }
            .pickerStyle(.segmented)

            // Stats row
            HStack(spacing: 20) {
                StatPill(label: "Avg", value: average, unit: unit, color: chartColor)
                StatPill(label: "Goal", value: goalValue, unit: unit, color: .secondary)
                let pct = goalValue > 0 ? (average / goalValue) * 100 : 0
                StatPill(label: "vs Goal", value: pct, unit: "%", color: pct >= 90 && pct <= 110 ? .green : .orange)
            }

            // Bar chart
            Chart {
                // Goal rule
                RuleMark(y: .value("Goal", goalValue))
                    .foregroundStyle(chartColor.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("Goal")
                            .font(.caption2)
                            .foregroundStyle(chartColor.opacity(0.7))
                    }

                ForEach(logs.sorted(by: { $0.date < $1.date })) { log in
                    BarMark(
                        x: .value("Date", log.date, unit: .day),
                        y: .value(selectedMacro.rawValue, value(for: log))
                    )
                    .foregroundStyle(
                        value(for: log) > goalValue * 1.1 ? Color.orange : chartColor
                    )
                    .cornerRadius(4)
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { value in
                    AxisValueLabel(format: .dateTime.weekday(.narrow))
                        .font(.caption2)
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text("\(Int(v))")
                                .font(.caption2)
                        }
                    }
                }
            }
            .frame(height: 200)
            .accessibilityLabel("\(selectedMacro.rawValue) chart for the past week")
        }
        .padding()
        .glassEffect(in: .rect(cornerRadius: 20))
        .animation(.easeInOut, value: selectedMacro)
    }
}

private struct StatPill: View {
    let label: String
    let value: Double
    let unit: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value, format: .number.precision(.fractionLength(0)))
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .glassEffect(in: .rect(cornerRadius: 10))
    }
}

#Preview {
    MacroChartView(logs: DailyLog.weekSamples, goals: UserGoals())
        .padding()
}
