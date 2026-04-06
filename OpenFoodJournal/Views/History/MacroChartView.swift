// Macros — Food Journaling App
// AGPL-3.0 License

import SwiftUI
import Charts

struct MacroChartView: View {
    let logs: [DailyLog]
    let goals: UserGoals

    // MARK: - Chart Mode (Macros vs Micros)

    enum ChartMode: String, CaseIterable {
        case macros = "Macros"
        case micros = "Micros"
    }

    enum ChartMacro: String, CaseIterable, Identifiable {
        case calories = "Calories"
        case protein = "Protein"
        case carbs = "Carbs"
        case fat = "Fat"
        var id: String { rawValue }
    }

    @State private var chartMode: ChartMode = .macros
    @State private var selectedMacro: ChartMacro = .calories
    @State private var selectedMicroID: String = KnownMicronutrients.common.first?.id ?? ""

    /// Micronutrients that actually appear in the current logs (no point charting zeros)
    private var availableMicros: [KnownMicronutrient] {
        let loggedIDs = Set(logs.flatMap { log in
            log.safeEntries.flatMap { $0.micronutrients.keys }
        })
        return KnownMicronutrients.all.filter { loggedIDs.contains($0.id) }
    }

    private var selectedMicro: KnownMicronutrient? {
        KnownMicronutrients.all.first { $0.id == selectedMicroID }
    }

    // MARK: - Macro helpers

    private var macroChartColor: Color {
        switch selectedMacro {
        case .calories: .orange
        case .protein: .blue
        case .carbs: .green
        case .fat: .yellow
        }
    }

    private var macroGoalValue: Double {
        switch selectedMacro {
        case .calories: goals.dailyCalories
        case .protein: goals.dailyProtein
        case .carbs: goals.dailyCarbs
        case .fat: goals.dailyFat
        }
    }

    private var macroUnit: String {
        selectedMacro == .calories ? "kcal" : "g"
    }

    private func macroValue(for log: DailyLog) -> Double {
        switch selectedMacro {
        case .calories: log.totalCalories
        case .protein: log.totalProtein
        case .carbs: log.totalCarbs
        case .fat: log.totalFat
        }
    }

    private var macroAverage: Double {
        guard !logs.isEmpty else { return 0 }
        return logs.map { macroValue(for: $0) }.reduce(0, +) / Double(logs.count)
    }

    // MARK: - Micro helpers

    private var microChartColor: Color {
        guard let micro = selectedMicro else { return .teal }
        switch micro.category {
        case .vitamin: return .orange
        case .mineral: return .teal
        case .other: return .purple
        }
    }

    private var microGoalValue: Double {
        selectedMicro?.dailyValue ?? 0
    }

    private var microUnit: String {
        selectedMicro?.unit ?? ""
    }

    private func microValue(for log: DailyLog) -> Double {
        log.totalMicronutrient(id: selectedMicroID)
    }

    private var microAverage: Double {
        guard !logs.isEmpty else { return 0 }
        return logs.map { microValue(for: $0) }.reduce(0, +) / Double(logs.count)
    }

    // MARK: - Unified accessors

    private var chartColor: Color { chartMode == .macros ? macroChartColor : microChartColor }
    private var goalValue: Double { chartMode == .macros ? macroGoalValue : microGoalValue }
    private var unit: String { chartMode == .macros ? macroUnit : microUnit }
    private var average: Double { chartMode == .macros ? macroAverage : microAverage }

    private func chartValue(for log: DailyLog) -> Double {
        chartMode == .macros ? macroValue(for: log) : microValue(for: log)
    }

    /// Swipe index for navigating macro/micro options
    private var swipeIndex: Int {
        if chartMode == .macros {
            return ChartMacro.allCases.firstIndex(of: selectedMacro) ?? 0
        } else {
            return availableMicros.firstIndex(where: { $0.id == selectedMicroID }) ?? 0
        }
    }

    private var swipeCount: Int {
        chartMode == .macros ? ChartMacro.allCases.count : availableMicros.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Mode picker: Macros / Micros
            Picker("Mode", selection: $chartMode) {
                ForEach(ChartMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            // Nutrient selector — macro segmented or micro menu
            if chartMode == .macros {
                Picker("Macro", selection: $selectedMacro) {
                    ForEach(ChartMacro.allCases) { macro in
                        Text(macro.rawValue).tag(macro)
                    }
                }
                .pickerStyle(.segmented)
            } else {
                microPicker
            }

            // Stats row
            HStack(spacing: 20) {
                StatPill(label: "Avg", value: average, unit: unit, color: chartColor)
                if goalValue > 0 {
                    StatPill(label: "Goal", value: goalValue, unit: unit, color: .secondary)
                    let pct = goalValue > 0 ? (average / goalValue) * 100 : 0
                    StatPill(label: "vs Goal", value: pct, unit: "%", color: pct >= 90 && pct <= 110 ? .green : .orange)
                }
            }

            // Bar chart
            Chart {
                if goalValue > 0 {
                    RuleMark(y: .value("Goal", goalValue))
                        .foregroundStyle(chartColor.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        .annotation(position: .top, alignment: .trailing) {
                            Text("Goal")
                                .font(.caption2)
                                .foregroundStyle(chartColor.opacity(0.7))
                        }
                }

                ForEach(logs.sorted(by: { $0.date < $1.date })) { log in
                    BarMark(
                        x: .value("Date", log.date, unit: .day),
                        y: .value("Value", chartValue(for: log))
                    )
                    .foregroundStyle(chartColor)
                    .opacity(goalValue > 0 && chartValue(for: log) > goalValue * 1.1 ? 0.5 : 1.0)
                    .cornerRadius(4)
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow))
                        .font(.caption2)
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(formatAxisValue(v))
                                .font(.caption2)
                        }
                    }
                }
            }
            .frame(height: 200)
        }
        .padding()
        .glassEffect(in: .rect(cornerRadius: 20))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    let horizontal = value.translation.width
                    guard abs(horizontal) > abs(value.translation.height) else { return }

                    if chartMode == .macros {
                        let allCases = ChartMacro.allCases
                        if horizontal < 0, swipeIndex < allCases.count - 1 {
                            withAnimation { selectedMacro = allCases[swipeIndex + 1] }
                        } else if horizontal > 0, swipeIndex > 0 {
                            withAnimation { selectedMacro = allCases[swipeIndex - 1] }
                        }
                    } else {
                        let micros = availableMicros
                        if horizontal < 0, swipeIndex < micros.count - 1 {
                            withAnimation { selectedMicroID = micros[swipeIndex + 1].id }
                        } else if horizontal > 0, swipeIndex > 0 {
                            withAnimation { selectedMicroID = micros[swipeIndex - 1].id }
                        }
                    }
                }
        )
        .animation(.easeInOut, value: selectedMacro)
        .animation(.easeInOut, value: selectedMicroID)
        .animation(.easeInOut, value: chartMode)
    }

    // MARK: - Micro Picker

    private var microPicker: some View {
        HStack {
            Menu {
                ForEach(KnownMicronutrient.Category.allCases, id: \.self) { category in
                    let micros = availableMicros.filter { $0.category == category }
                    if !micros.isEmpty {
                        Section(category.rawValue) {
                            ForEach(micros, id: \.id) { micro in
                                Button {
                                    withAnimation { selectedMicroID = micro.id }
                                } label: {
                                    HStack {
                                        Text(micro.name)
                                        if micro.id == selectedMicroID {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(selectedMicro?.name ?? "Select Nutrient")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .glassEffect(in: .capsule)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Helpers

    private func formatAxisValue(_ value: Double) -> String {
        if value >= 1000 {
            return String(format: "%.0f", value)
        } else if value < 1 && value > 0 {
            return String(format: "%.1f", value)
        }
        return String(format: "%.0f", value)
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
                Text(value, format: .number.precision(.fractionLength(value < 10 ? 1 : 0)))
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
