// History visual concept — fictional fixtures, never the shipping app or its store.
// Structure: month calendar → selected-day detail link → range → nutrient trend.
// Adapted from HistoryView/CalendarGridView; cell geometry/colors from WeeklyCalendarStrip.
// Only the presentation is explored here. Keep real query-backed totals when porting.
import SwiftUI
import Charts

// MARK: 1. Edit here (points) — keep Journal palette and calendar geometry shared
enum HistoryStyle {
    static let width: CGFloat = 393
    static let height: CGFloat = 852
    static let inset: CGFloat = 16
    static let gap: CGFloat = 20
    static let cardRadius: CGFloat = 20
    static let ringSize: CGFloat = 36 //40
    static let ringStroke: CGFloat = 2.5 //3
    static let daySize: CGFloat = 16 //20
    static let weekdaySize = JournalStyle.weekdaySize //12
    static let dayTarget: CGFloat = 46
    static let microColumnWidth: CGFloat = 112
    static let microRowHeight: CGFloat = 44
    static let microGap: CGFloat = 6
    static let chartHeight: CGFloat = 150
    static let accent = JournalStyle.accent
    static func progressColor(_ ratio: Double) -> Color { JournalStyle.calendarColor(progress: ratio) }
}

// MARK: 2. Screen — local presentation state only
struct HistoryDesign: View {
    var empty = false
    var initialDetail = false
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedDay = HistoryFixture.today
    @State private var period = HistoryPeriod.week
    @State private var rangeEnd = HistoryFixture.today
    @State private var selectedNutrient = HistoryNutrient.calories
    @State private var showingDay = false
    private var days: Int { period.days }
    private var rangeStart: Date { HistoryFixture.offset(rangeEnd, days: 1 - days) }

    var body: some View {
        ZStack {
            // Keep overview alive so returning from detail retains scroll and selection.
            overview.opacity(showingDay ? 0 : 1)
                .allowsHitTesting(!showingDay).accessibilityHidden(showingDay)
            if showingDay {
                HistoryDayDetail(date: $selectedDay, empty: empty) { showingDay = false }
            }
        }
        .tint(HistoryStyle.accent)
        .frame(width: HistoryStyle.width, height: HistoryStyle.height)
        .background(colorScheme == .dark ? JournalStyle.darkBackground : Color(red: 0.97, green: 0.97, blue: 0.975))
        .compositingGroup().clipShape(.rect(cornerRadius: 32))
        .onAppear { showingDay = initialDetail }
    }

    private var overview: some View {
        ScrollView {
            VStack(spacing: HistoryStyle.gap) {
                HistoryMonthCalendar(selectedDay: $selectedDay, empty: empty)
                Button { showingDay = true } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(HistoryFixture.label(selectedDay, .dateTime.weekday(.wide).month(.abbreviated).day()))
                                .font(.system(size: 17, weight: .semibold))
                            if let calories = HistoryFixture.amount(.calories, on: selectedDay, empty: empty) {
                                Text("\(HistoryFixture.number(calories)) kcal · \(Int((calories / 2500 * 100).rounded()))% of goal · 5 entries")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            } else {
                                Text("No entries recorded").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }.padding(16).contentShape(.rect)
                }.buttonStyle(.plain).modifier(HistoryCard())
                HistoryPeriodControl(selection: $period)

                VStack(alignment: .leading, spacing: 16) {
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            HistoryArrow(symbol: "chevron.left", label: "Previous date range",
                                         enabled: HistoryFixture.offset(rangeStart, days: -days) >= HistoryFixture.firstDay) {
                                moveRange(-1)
                            }
                            Text(HistoryFixture.rangeLabel(rangeStart, rangeEnd))
                                .font(.system(size: 14, weight: .semibold))
                                .frame(maxWidth: .infinity).frame(height: 44)
                                .glassEffect(.regular, in: .capsule)
                                .accessibilityLabel("Date range, \(HistoryFixture.rangeLabel(rangeStart, rangeEnd))")
                            HistoryArrow(symbol: "chevron.right", label: "Next date range", enabled: rangeEnd < HistoryFixture.today) {
                                moveRange(1)
                            }
                        }
                    }
                    HistoryNutrientSelector(selection: $selectedNutrient)
                    HistoryTrend(nutrient: selectedNutrient, end: rangeEnd, days: days, empty: empty)
                }.padding(16).modifier(HistoryCard())

            }.padding(HistoryStyle.inset)
        }
        .scrollIndicators(.hidden)
        .safeAreaBar(edge: .top, spacing: 0) {
            Text("History").font(.system(size: 34, weight: .bold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, HistoryStyle.inset).padding(.top, 20).padding(.bottom, 12)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .onChange(of: selectedDay) { _, day in
            rangeEnd = day
        }
    }

    private func moveRange(_ direction: Int) {
        let count = days
        let proposed = HistoryFixture.offset(rangeEnd, days: direction * count)
        let end = min(HistoryFixture.today, max(HistoryFixture.offset(HistoryFixture.firstDay, days: count - 1), proposed))
        rangeEnd = end
    }
}

private struct HistoryCard: ViewModifier {
    func body(content: Content) -> some View {
        content.glassEffect(.regular, in: .rect(cornerRadius: HistoryStyle.cardRadius))
    }
}

// Mac's segmented Picker includes desktop label/width metrics. This presentation
// copy keeps the full-width Week/Month hierarchy at phone-sized metrics.
private struct HistoryPeriodControl: View {
    @Binding var selection: HistoryPeriod
    var body: some View {
        HStack(spacing: 2) {
            ForEach(HistoryPeriod.allCases) { period in
                Button { selection = period } label: {
                    Text(period.rawValue).font(.system(size: 14, weight: selection == period ? .semibold : .regular))
                        .foregroundStyle(selection == period ? HistoryStyle.accent : .secondary)
                        .frame(maxWidth: .infinity).frame(height: 40)
                        .background(.primary.opacity(selection == period ? 0.06 : 0), in: .rect(cornerRadius: 10))
                        .contentShape(.rect)
                }.buttonStyle(.plain).accessibilityAddTraits(selection == period ? .isSelected : [])
            }
        }.padding(2).glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
}

private struct HistoryArrow: View {
    let symbol: String
    let label: String
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(HistoryStyle.accent)
                .frame(width: 44, height: 44).contentShape(.circle)
        }.buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .opacity(enabled ? 1 : 0.35).disabled(!enabled)
            .accessibilityLabel(label)
    }
}

// MARK: 3. Monthly calendar — app layout, weekly-strip cell treatment
private struct HistoryMonthCalendar: View {
    @Binding var selectedDay: Date
    let empty: Bool
    @State private var month = HistoryFixture.monthStart(HistoryFixture.today)
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    var body: some View {
        VStack(spacing: 10) {
            GlassEffectContainer(spacing: 8) {
                HStack {
                    HistoryArrow(symbol: "chevron.left", label: "Previous month", enabled: month > HistoryFixture.monthStart(HistoryFixture.firstDay)) {
                        month = HistoryFixture.calendar.date(byAdding: .month, value: -1, to: month) ?? month
                    }
                    Text(HistoryFixture.label(month, .dateTime.month(.wide).year()))
                        .font(.system(size: 18, weight: .semibold)).frame(maxWidth: .infinity)
                    HistoryArrow(symbol: "chevron.right", label: "Next month", enabled: month < HistoryFixture.monthStart(HistoryFixture.today)) {
                        month = HistoryFixture.calendar.date(byAdding: .month, value: 1, to: month) ?? month
                    }
                }
            }
            LazyVGrid(columns: columns, spacing: 5) {
                ForEach(Array(["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"].enumerated()), id: \.offset) { _, day in
                    Text(day).font(.system(size: HistoryStyle.weekdaySize, weight: .semibold))
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.bottom, 4)
                }
                // CalendarGridView's stable six-row grid; blank slots are never buttons.
                ForEach(HistoryFixture.monthCells(month)) { cell in
                    if let date = cell.date {
                        HistoryCalendarDay(date: date, selected: selectedDay == date,
                                           amount: HistoryFixture.amount(.calories, on: date, empty: empty)) {
                            selectedDay = date
                        }
                    } else { Color.clear.frame(height: HistoryStyle.dayTarget) }
                }
            }
            Divider()
            HStack(spacing: 10) {
                legend("Below", color: .primary)
                legend("Near", color: .green.opacity(0.5))
                legend("Met", color: .green)
                legend("Over", color: JournalStyle.overGoal)
                legend("No log", color: .secondary.opacity(0.25))
            }.padding(.vertical, 3)
        }.padding(12).modifier(HistoryCard())
            .onChange(of: selectedDay) { _, date in month = HistoryFixture.monthStart(date) }
    }

    private func legend(_ text: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text).font(.system(size: 10))
        }.foregroundStyle(.secondary)
    }
}

private struct HistoryCalendarDay: View {
    let date: Date
    let selected: Bool
    let amount: Double?
    let action: () -> Void
    @State private var hovering = false
    private var future: Bool { date > HistoryFixture.today }
    private var ratio: Double { (amount ?? 0) / 2500 }
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(.secondary.opacity(future ? 0.28 : 0.15),
                                style: StrokeStyle(lineWidth: HistoryStyle.ringStroke,
                                                   lineCap: .round, dash: future ? [2.5, 4] : []))
                if !future, amount != nil {
                    Circle().trim(from: 0, to: min(max(ratio, 0), 1))
                        .stroke(HistoryStyle.progressColor(ratio), style: StrokeStyle(lineWidth: HistoryStyle.ringStroke, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Text(HistoryFixture.label(date, .dateTime.day()))
                    .font(.system(size: HistoryStyle.daySize, weight: selected ? .bold : .regular))
                    .foregroundStyle(future ? Color.secondary.opacity(0.42) : selected ? .primary : .secondary)
                    .transaction { $0.animation = nil }
            }.frame(width: HistoryStyle.ringSize, height: HistoryStyle.ringSize)
                .frame(maxWidth: .infinity, minHeight: HistoryStyle.dayTarget)
                .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(HistoryDayButtonStyle(highlighted: selected || hovering))
        .disabled(future).onHover { hovering = $0 && !future }
        .accessibilityLabel(HistoryFixture.label(date, .dateTime.month(.wide).day()))
        .accessibilityValue(future ? "Future date, unavailable" : amount == nil ? "No entries" : "\(Int((ratio * 100).rounded())) percent of calorie goal")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct HistoryDayButtonStyle: ButtonStyle {
    let highlighted: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background {
            RoundedRectangle(cornerRadius: 12).fill(.regularMaterial)
                .overlay { RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.08)) }
                .opacity(highlighted || configuration.isPressed ? 1 : 0)
        }
    }
}

// MARK: 4. Nutrient selection — four macros, one alphabetical row of tracked micros
private struct HistoryNutrientSelector: View {
    @Binding var selection: HistoryNutrient
    @State private var scroll = ScrollPosition(x: 0)
    @State private var edges = HistoryScrollEdges()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(HistoryNutrient.macros) { nutrient in chip(nutrient).frame(maxWidth: .infinity) }
                }
            }
            HStack {
                Text("Micronutrients").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(HistoryNutrient.micros.count) tracked").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                scrollArrow(forward: false)
                ScrollView(.horizontal) {
                    GlassEffectContainer(spacing: HistoryStyle.microGap) {
                        LazyHStack(spacing: HistoryStyle.microGap) {
                            ForEach(HistoryNutrient.alphabeticalMicros) { nutrient in
                                chip(nutrient).frame(width: HistoryStyle.microColumnWidth)
                            }
                        }.padding(.vertical, 2)
                    }
                }
                .scrollIndicators(.hidden)
                .scrollPosition($scroll)
                .onScrollGeometryChange(for: HistoryScrollEdges.self) { geometry in
                    HistoryScrollEdges(left: geometry.contentOffset.x > 2,
                                       right: geometry.contentOffset.x + geometry.containerSize.width < geometry.contentSize.width - 2,
                                       column: Int(max(0, geometry.contentOffset.x) / (HistoryStyle.microColumnWidth + HistoryStyle.microGap)))
                } action: { _, value in edges = value }
                .frame(height: HistoryStyle.microRowHeight + 4)
                scrollArrow(forward: true)
            }
        }
    }

    private func chip(_ nutrient: HistoryNutrient) -> some View {
        Button { selection = nutrient } label: {
            Text(nutrient.shortName).font(.system(size: 12, weight: selection == nutrient ? .semibold : .regular))
                .lineLimit(2).multilineTextAlignment(.center).padding(.horizontal, 8)
                .frame(maxWidth: .infinity).frame(height: 40)
                .foregroundStyle(selection == nutrient ? HistoryStyle.accent : .primary)
                .contentShape(.capsule)
        }.buttonStyle(.plain)
            .glassEffect(.regular.tint(selection == nutrient ? HistoryStyle.accent.opacity(0.15) : .clear).interactive(), in: .capsule)
            .accessibilityLabel(nutrient.name)
            .accessibilityAddTraits(selection == nutrient ? .isSelected : [])
            .help(nutrient.name)
    }

    private func scrollArrow(forward: Bool) -> some View {
        let available = forward ? edges.right : edges.left
        return Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                let column = max(0, edges.column + (forward ? 2 : -2))
                scroll.scrollTo(x: CGFloat(column) * (HistoryStyle.microColumnWidth + HistoryStyle.microGap))
            }
        } label: {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .font(.system(size: 12, weight: .bold))
                .frame(width: 44, height: HistoryStyle.microRowHeight)
                .contentShape(.rect)
        }.buttonStyle(.plain).foregroundStyle(HistoryStyle.accent)
            .opacity(available ? 1 : 0).disabled(!available).accessibilityHidden(!available)
            .accessibilityLabel(forward ? "More micronutrients" : "Previous micronutrients")
    }
}

private struct HistoryScrollEdges: Equatable { var left = false; var right = false; var column = 0 }

private struct HistoryTrend: View {
    let nutrient: HistoryNutrient
    let end: Date
    let days: Int
    let empty: Bool
    private var points: [HistoryPoint] { HistoryFixture.points(nutrient, end: end, days: days, empty: empty) }
    private var mean: Double? { HistoryFixture.mean(points) }
    private var previousMean: Double? {
        HistoryFixture.mean(HistoryFixture.points(nutrient, end: HistoryFixture.offset(end, days: -days), days: days, empty: empty))
    }
    private var comparison: String {
        guard let mean, let previousMean, previousMean > 0 else { return "No prior comparison" }
        let delta = (mean / previousMean - 1) * 100
        return "\(delta >= 0 ? "+" : "")\(Int(delta.rounded()))% vs prior \(days) days"
    }
    private var goalLabel: String {
        guard let mean, nutrient.goal > 0 else { return "" }
        return "\(Int((mean / nutrient.goal * 100).rounded()))% of goal · "
    }
    private var tickSlots: [Double] {
        if days <= 7 { return (0..<days).map(Double.init) }
        // Include both boundaries without crowding adjacent dates at the end.
        return [0, 7, 14, 21, days - 1].map(Double.init)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(nutrient.name).font(.system(size: 15, weight: .semibold))
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(mean.map(HistoryFixture.number) ?? "—").font(.system(size: 32, weight: .bold, design: .rounded))
                    .modifier(HistoryNumberTransition(value: mean ?? 0))
                Text("\(nutrient.unit)/day avg").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Text(goalLabel + comparison)
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Text("\(points.compactMap(\.amount).count) of \(days) days recorded")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if mean != nil {
                Chart {
                    ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                        if let amount = point.amount {
                            // Explicit day slots avoid UTC fixtures being re-bucketed
                            // into the preceding local day. Every bar fits INSIDE its
                            // slot, including the first/last; missing days keep a gap.
                            RectangleMark(xStart: .value("Day slot", Double(index) - 0.34),
                                          xEnd: .value("Day slot", Double(index) + 0.34),
                                          yStart: .value(nutrient.unit, 0.0),
                                          yEnd: .value(nutrient.unit, amount))
                                .cornerRadius(3)
                                .foregroundStyle(nutrient.progressColor(amount))
                                .accessibilityLabel(HistoryFixture.label(point.date, .dateTime.month().day()))
                                .accessibilityValue("\(HistoryFixture.number(amount)) \(nutrient.unit)")
                        }
                    }
                    if nutrient.goal > 0 {
                        RuleMark(y: .value("Daily goal", nutrient.goal))
                            .foregroundStyle(.secondary.opacity(0.5)).lineStyle(StrokeStyle(dash: [4, 4]))
                    }
                }
                .chartXScale(domain: -0.5...(Double(days) - 0.5), range: .plotDimension(padding: 0))
                .chartYScale(domain: 0...max(nutrient.goal * 1.2, (points.compactMap(\.amount).max() ?? 1) * 1.1, 1))
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks(values: tickSlots) { tick in
                        if let slot = tick.as(Double.self) {
                            AxisValueLabel(anchor: slot == 0 ? .topLeading : slot == Double(days - 1) ? .topTrailing : .top,
                                           collisionResolution: .disabled) {
                                let date = HistoryFixture.offset(end, days: Int(slot) + 1 - days)
                                Text(HistoryFixture.label(date, days <= 7 ? .dateTime.weekday(.abbreviated) : .dateTime.month(.abbreviated).day()))
                            }
                        }
                    }
                }
                .chartPlotStyle { $0.clipped() }
                .frame(height: HistoryStyle.chartHeight)
                .accessibilityLabel("Daily \(nutrient.name)")
            } else {
                Text("No \(nutrient.name.lowercased()) recorded in this range.")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: HistoryStyle.chartHeight)
            }
        }
    }
}

// MARK: 5. Selected day — goals and meals using the shared Journal food rows
private struct HistoryDayDetail: View {
    @Binding var date: Date
    let empty: Bool
    let back: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    private var calories: Double? { HistoryFixture.amount(.calories, on: date, empty: empty) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(calories.map(HistoryFixture.number) ?? "—")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .modifier(HistoryNumberTransition(value: calories ?? 0))
                        Text("/ 2,500 kcal").font(.system(size: 15)).foregroundStyle(.secondary)
                    }
                    if let calories {
                        Text("\(HistoryFixture.number(abs(2500 - calories))) kcal \(calories <= 2500 ? "remaining" : "above goal")")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    ForEach(HistoryNutrient.macros + Array(HistoryNutrient.micros.prefix(3))) { nutrient in
                        HistoryDetailProgress(nutrient: nutrient, amount: HistoryFixture.amount(nutrient, on: date, empty: empty))
                    }
                }.padding(18).modifier(HistoryCard())
                if calories != nil {
                    ForEach(["Lunch", "Dinner", "Snack"], id: \.self) { meal in
                        VStack(spacing: 0) {
                            HStack {
                                Text(meal.uppercased()).font(.system(size: 12, weight: .semibold))
                                Spacer()
                                Text("\(HistoryFixture.number(HistoryFixture.foods.filter { $0.meal == meal }.reduce(0) { $0 + $1.calories } * HistoryFixture.factor(date))) kcal")
                                    .font(.system(size: 12))
                            }.foregroundStyle(.secondary).padding(16)
                            ForEach(HistoryFixture.foods.filter { $0.meal == meal }) { food in
                                Divider()
                                JournalFoodRow(food: food.journalRowFood(on: date))
                                    .padding(.horizontal, 16)
                            }
                        }.modifier(HistoryCard())
                    }
                } else { Text("No meals recorded for this date.").foregroundStyle(.secondary) }
            }.padding(HistoryStyle.inset)
        }
        .background(colorScheme == .dark ? JournalStyle.darkBackground : Color(red: 0.97, green: 0.97, blue: 0.975))
        .scrollIndicators(.hidden)
        .safeAreaBar(edge: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        Button(action: back) {
                            Label("History", systemImage: "chevron.left").font(.system(size: 15, weight: .semibold))
                                .padding(.horizontal, 14).frame(height: 44)
                        }.buttonStyle(.plain).glassEffect(.regular.interactive(), in: .capsule)
                        Spacer()
                        HistoryArrow(symbol: "chevron.left", label: "Previous day", enabled: date > HistoryFixture.firstDay) {
                            date = HistoryFixture.offset(date, days: -1)
                        }
                        HistoryArrow(symbol: "chevron.right", label: "Next day", enabled: date < HistoryFixture.today) {
                            date = HistoryFixture.offset(date, days: 1)
                        }
                    }.foregroundStyle(HistoryStyle.accent)
                }
                Text(HistoryFixture.label(date, .dateTime.weekday(.wide).month(.abbreviated).day()))
                    .font(.system(size: 28, weight: .bold))
            }.padding(HistoryStyle.inset)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }
}

private struct HistoryDetailProgress: View {
    let nutrient: HistoryNutrient
    let amount: Double?
    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(nutrient.name).font(.system(size: 14, weight: .medium))
                Spacer()
                Text((amount.map(HistoryFixture.number) ?? "—") + (nutrient.goal > 0 ? " / \(HistoryFixture.number(nutrient.goal))" : "") + " \(nutrient.unit)")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if nutrient.goal > 0 {
                GeometryReader { geometry in
                    Capsule().fill(.primary.opacity(0.07)).overlay(alignment: .leading) {
                        Capsule().fill(nutrient.progressColor(amount ?? 0))
                            .frame(width: geometry.size.width * min(max((amount ?? 0) / nutrient.goal, 0), 1))
                    }
                }.frame(height: 5)
            }
        }
    }
}

private struct HistoryNumberTransition: ViewModifier {
    let value: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.contentTransition(reduceMotion ? .identity : .numericText(value: value))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: value)
    }
}

// MARK: 6. Editable fixtures — independent of SwiftData and user data
private enum HistoryPeriod: String, CaseIterable, Identifiable {
    case week = "Week", month = "Month"
    var id: String { rawValue }
    var days: Int { self == .week ? 7 : 30 }
}

private struct HistoryNutrient: Identifiable, Hashable {
    let name: String
    let unit: String
    let goal: Double
    var base: Double = 0
    var id: String { name }
    var shortName: String { name == "Dietary Fiber" ? "Fiber" : name }
    var color: Color {
        switch name { case "Protein": .blue; case "Carbs": .green; case "Fat": Color(red: 0.9, green: 0.75, blue: 0); default: .primary }
    }
    func progressColor(_ amount: Double) -> Color {
        guard goal > 0 else { return color }
        if Self.macros.dropFirst().contains(self) { return amount > goal ? JournalStyle.overGoal : color }
        return HistoryStyle.progressColor(amount / goal)
    }
    static let calories = Self(name: "Calories", unit: "kcal", goal: 2500, base: 2308)
    static let fat = Self(name: "Fat", unit: "g", goal: 70, base: 94)
    static let macros = [calories, Self(name: "Protein", unit: "g", goal: 150, base: 117),
                         Self(name: "Carbs", unit: "g", goal: 250, base: 244), fat]
    // Names, units and goals copied from KnownMicronutrients, not the reference image.
    // All are "tracked" in this fictional dense fixture; shipping must derive this
    // collection from recorded nutrient IDs, including any custom nutrient keys.
    static let micros: [Self] = [
        .init(name: "Dietary Fiber", unit: "g", goal: 28, base: 16),
        .init(name: "Sodium", unit: "mg", goal: 2300, base: 2980),
        .init(name: "Added Sugars", unit: "g", goal: 50, base: 15),
        .init(name: "Vitamin A", unit: "mcg", goal: 900, base: 620),
        .init(name: "Vitamin C", unit: "mg", goal: 90, base: 65),
        .init(name: "Vitamin D", unit: "mcg", goal: 20, base: 12),
        .init(name: "Vitamin E", unit: "mg", goal: 15, base: 9),
        .init(name: "Vitamin K", unit: "mcg", goal: 120, base: 100),
        .init(name: "Thiamin (B1)", unit: "mg", goal: 1.2, base: 0.8),
        .init(name: "Riboflavin (B2)", unit: "mg", goal: 1.3, base: 1.1),
        .init(name: "Niacin (B3)", unit: "mg", goal: 16, base: 14),
        .init(name: "Pantothenic Acid (B5)", unit: "mg", goal: 5, base: 3),
        .init(name: "Vitamin B6", unit: "mg", goal: 1.7, base: 1.4),
        .init(name: "Biotin (B7)", unit: "mcg", goal: 30, base: 21),
        .init(name: "Folate (B9)", unit: "mcg", goal: 400, base: 280),
        .init(name: "Vitamin B12", unit: "mcg", goal: 2.4, base: 1.8),
        .init(name: "Calcium", unit: "mg", goal: 1300, base: 720),
        .init(name: "Iron", unit: "mg", goal: 18, base: 12),
        .init(name: "Magnesium", unit: "mg", goal: 420, base: 300),
        .init(name: "Phosphorus", unit: "mg", goal: 1250, base: 1100),
        .init(name: "Potassium", unit: "mg", goal: 4700, base: 3100),
        .init(name: "Zinc", unit: "mg", goal: 11, base: 8),
        .init(name: "Copper", unit: "mg", goal: 0.9, base: 0.7),
        .init(name: "Manganese", unit: "mg", goal: 2.3, base: 1.9),
        .init(name: "Selenium", unit: "mcg", goal: 55, base: 48),
        .init(name: "Chromium", unit: "mcg", goal: 35, base: 22),
        .init(name: "Molybdenum", unit: "mcg", goal: 45, base: 31),
        .init(name: "Iodine", unit: "mcg", goal: 150, base: 130),
        .init(name: "Chloride", unit: "mg", goal: 2300, base: 1800),
        .init(name: "Total Sugars", unit: "g", goal: 0, base: 30),
        .init(name: "Cholesterol", unit: "mg", goal: 300, base: 220),
        .init(name: "Saturated Fat", unit: "g", goal: 20, base: 18),
        .init(name: "Monounsaturated Fat", unit: "g", goal: 0, base: 20),
        .init(name: "Polyunsaturated Fat", unit: "g", goal: 0, base: 8),
        .init(name: "Trans Fat", unit: "g", goal: 0, base: 0),
        .init(name: "Water", unit: "mL", goal: 0, base: 1800),
        .init(name: "Caffeine", unit: "mg", goal: 0, base: 100)
    ]
    static let alphabeticalMicros = micros.sorted {
        $0.shortName.localizedStandardCompare($1.shortName) == .orderedAscending
    }
}

private struct HistoryPoint: Identifiable { let date: Date; let amount: Double?; var id: Date { date } }
private struct HistoryMonthCell: Identifiable { let id: Int; let date: Date? }
private struct HistoryFood: Identifiable {
    let name: String; let meal: String; let brand: String; let time: String
    let calories: Double; let protein: Double; let carbs: Double; let fat: Double
    var id: String { name }

    // Adapt the fixture's values, not its layout. The shared Journal row owns
    // its 51pt icon placeholder, food identity, and always-visible macro pill.
    func journalRowFood(on date: Date) -> SampleFood {
        let factor = HistoryFixture.factor(date)
        return SampleFood(name: name, brand: brand,
                          calories: Int((calories * factor).rounded()),
                          protein: Int((protein * factor).rounded()),
                          carbs: Int((carbs * factor).rounded()),
                          fat: Int((fat * factor).rounded()), time: time)
    }
}

private enum HistoryFixture {
    static let calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        value.firstWeekday = 1
        return value
    }()
    static let today = calendar.date(from: DateComponents(year: 2026, month: 8, day: 21))!
    static let firstDay = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
    static func offset(_ date: Date, days: Int) -> Date { calendar.date(byAdding: .day, value: days, to: date) ?? date }
    static func dayDistance(_ start: Date, _ end: Date) -> Int { calendar.dateComponents([.day], from: start, to: end).day ?? 0 }
    static func monthStart(_ date: Date) -> Date { calendar.date(from: calendar.dateComponents([.year, .month], from: date))! }
    static func label(_ date: Date, _ style: Date.FormatStyle) -> String {
        var format = style
        format.timeZone = calendar.timeZone
        return date.formatted(format)
    }
    static func rangeLabel(_ start: Date, _ end: Date) -> String {
        "\(label(start, .dateTime.month(.abbreviated).day())) – \(label(end, .dateTime.month(.abbreviated).day()))"
    }
    static func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(value > 0 && value < 10 ? 1 : 0))) }
    static func factor(_ date: Date) -> Double {
        [1.0, 0.78, 1.2, 1.07, 0.96, 0.60, 1.10, 0.85, 1.02][abs(dayDistance(date, today)) % 9]
    }
    static func amount(_ nutrient: HistoryNutrient, on date: Date, empty: Bool) -> Double? {
        let distance = abs(dayDistance(date, today))
        guard !empty, date >= firstDay, date <= today, distance % 13 != 6 else { return nil }
        // A few missing micro observations test the difference between zero and unknown.
        if !HistoryNutrient.macros.contains(nutrient), nutrient.name.hasPrefix("Vitamin"), distance % 5 == 2 { return nil }
        return nutrient.base * factor(date)
    }
    static func points(_ nutrient: HistoryNutrient, end: Date, days: Int, empty: Bool) -> [HistoryPoint] {
        (0..<days).map {
            let date = offset(end, days: $0 - days + 1)
            return HistoryPoint(date: date, amount: amount(nutrient, on: date, empty: empty))
        }
    }
    static func mean(_ points: [HistoryPoint]) -> Double? {
        let amounts = points.compactMap(\.amount)
        return amounts.isEmpty ? nil : amounts.reduce(0, +) / Double(amounts.count)
    }
    static func monthCells(_ date: Date) -> [HistoryMonthCell] {
        let start = monthStart(date)
        let count = calendar.range(of: .day, in: .month, for: start)?.count ?? 0
        let blanks = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        return (0..<42).map { index in
            HistoryMonthCell(id: index, date: index >= blanks && index < blanks + count ? offset(start, days: index - blanks) : nil)
        }
    }
    static let foods: [HistoryFood] = [
        .init(name: "Beef Franks", meal: "Lunch", brand: "Ball Park", time: "1:29 PM", calories: 510, protein: 18, carbs: 12, fat: 45),
        .init(name: "Enriched Hot Dog Buns", meal: "Lunch", brand: "Stroehmann", time: "1:29 PM", calories: 360, protein: 12, carbs: 69, fat: 4),
        .init(name: "Thin-Sliced Beef", meal: "Lunch", brand: "Costco", time: "5:15 PM", calories: 149, protein: 21, carbs: 0, fat: 6),
        .init(name: "Rice and Roasted Vegetables", meal: "Dinner", brand: "Homemade", time: "7:02 PM", calories: 1029, protein: 41, carbs: 140, fat: 29),
        .init(name: "Greek Yogurt", meal: "Snack", brand: "Plain", time: "8:20 PM", calories: 260, protein: 25, carbs: 23, fat: 10)
    ]
}

// MARK: 7. Mac workbench and Canvas variants
struct HistoryWorkbench: View {
    @State private var dark = false
    @State private var empty = false
    @State private var zoom = 0.85
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("History").font(.headline)
                Spacer()
                Toggle("Empty", isOn: $empty)
                Toggle("Dark", isOn: $dark).toggleStyle(.switch)
                Slider(value: $zoom, in: 0.6...1.1).frame(width: 90).accessibilityLabel("Preview zoom")
            }.padding(12)
            ScrollView([.horizontal, .vertical]) {
                HistoryDesign(empty: empty).preferredColorScheme(dark ? .dark : .light)
                    .scaleEffect(zoom).frame(width: HistoryStyle.width * zoom, height: HistoryStyle.height * zoom).padding(24)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Text("SAMPLE DATA ONLY · HistoryDesign.swift · Native Mac preview")
                .font(.caption).foregroundStyle(.secondary).padding(8)
        }.frame(minWidth: 500, minHeight: 600)
    }
}

#Preview("History · Light") { HistoryDesign().preferredColorScheme(.light) }
#Preview("History · Dark") { HistoryDesign().preferredColorScheme(.dark) }
#Preview("History · Empty") { HistoryDesign(empty: true).preferredColorScheme(.light) }
#Preview("History · Day detail") { HistoryDesign(initialDetail: true).preferredColorScheme(.light) }
