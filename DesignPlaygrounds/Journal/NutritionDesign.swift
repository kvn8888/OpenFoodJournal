// Standalone Nutrition visual scratchpad. Fictional data; no app services.
// Concept: calorie ring + macro bars, owner reference, 2026-08-30.
// The reference-aligned layout remains in design/nutrition/reference-aligned-v1.
// Grouped section wrappers approximate iOS .insetGrouped; a native Mac List
// renders in a normal window but crashes this Xcode beta's Canvas outline host.
// Edit NutritionStyle, not the real app. System chrome/section metrics remain approximate.
// Color/navigation source: OFJDesignSystem.swift and NutritionDetailView.swift.
// Native soft-edge boundary investigation is deferred in GitHub issue #77.
import SwiftUI
import Charts

enum NutritionStyle {
    static let width: CGFloat = 393
    static let height: CGFloat = 852
    static let inset: CGFloat = 16
    static let groupedInset: CGFloat = 20
    static let sectionTopSpacing: CGFloat = 20
    static let groupedRadius: CGFloat = 10
    static let titleSize: CGFloat = 34
    static let ringDiameter: CGFloat = 104
    static let ringStroke: CGFloat = 10
    static let ringTrackOpacity: Double = 0.15
    static let valueSize: CGFloat = 24
    static let summaryCardPadding: CGFloat = 16
    static let summaryCardRadius: CGFloat = 20
    static let summaryColumnGap: CGFloat = 18
    static let macroBarHeight: CGFloat = 5
    static let macroRowGap: CGFloat = 12
    static let summaryTextSize: CGFloat = 13
    static let nutrientNameSize: CGFloat = 15 // iPhone .subheadline
    static let captionSize: CGFloat = 12
    static let smallCaptionSize: CGFloat = 11
    static let nutrientBarHeight: CGFloat = 6
    static let nutrientContentGap: CGFloat = 6
    static let nutrientVerticalPadding: CGFloat = 2
    static let accent = Color.blue
    static let overTarget = Color(red: 0xD8 / 255.0, green: 0x66 / 255.0, blue: 0x69 / 255.0)
    static let navigationHeight: CGFloat = 44
    static let trendHeight: CGFloat = 140
    // Copied from OFJColor.journalCalorieState / JournalCalorieState.ringColor.
    // Keep the 80/95/105% boundaries in sync when transferring this concept.
    static func goalColor(_ ratio: Double) -> Color {
        switch ratio {
        case ..<0.80: .primary
        case 0.80..<0.95: .green.opacity(0.5)
        case 0.95..<1.05: .green
        default: overTarget
        }
    }
    // Approximate iOS grouped backgrounds; native Mac section chrome still differs.
    static let lightBackground = Color(red: 0.97, green: 0.965, blue: 0.955)
    static let darkBackground = Color.black
}

struct NutritionDesign: View {
    var missingData = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var period = NutritionSamplePeriod.daily
    @State private var showMore = false
    @State private var selectedNutrient: NutritionSampleValue?
    @State private var selectedDate = NutritionFixture.today
    @Environment(\.openWindow) private var openWindow

    private var dateLabel: String {
        NutritionFixture.dateLabel(ending: selectedDate, days: period.days)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
          if let selectedNutrient {
            NutritionNutrientDetail(value: selectedNutrient, period: period,
                                    date: $selectedDate, missingData: missingData) {
                self.selectedNutrient = nil
            }
          } else {
            ScrollView {
              VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 9) {
                    NutritionPeriodTabs(selection: $period)
                    Text(period == .daily ? "\(dateLabel) · \(missingData ? 0 : 5) entries" : dateLabel)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }

                NutritionSummaryDesign(missingData: missingData, period: period, date: selectedDate) { selectedNutrient = $0 }
                    .padding(.top, 14)

                // Match KnownMicronutrient.Category.allCases and the full common-row density.
                NutritionDesignSection("Vitamins") {
                    ForEach(NutritionSampleValue.nutrients.filter { $0.category == .vitamins && $0.common }) { value in
                        nutrientLink(value)
                    }
                }
                NutritionDesignSection("Minerals") {
                    ForEach(NutritionSampleValue.nutrients.filter { $0.category == .minerals && $0.common }) { value in
                        nutrientLink(value)
                    }
                }
                NutritionDesignSection("Other Nutrients") {
                    ForEach(NutritionSampleValue.nutrients.filter { $0.category == .other && $0.common }) { value in
                        nutrientLink(value)
                    }
                }

                NutritionDesignSection(nil) {
                    DisclosureGroup("More Nutrients", isExpanded: $showMore) {
                        // A single expanded row avoids Mac outline-list flattening
                        // of mixed category headers and nested ForEach children.
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(NutritionSampleCategory.allCases) { category in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(category.rawValue).font(.system(size: NutritionStyle.captionSize, weight: .semibold))
                                        .foregroundStyle(.secondary).padding(.top, 4)
                                    ForEach(NutritionSampleValue.nutrients.filter { $0.category == category && !$0.common }) { value in
                                        nutrientLink(value)
                                    }
                                }
                            }
                        }
                    }
                    .font(.system(size: NutritionStyle.nutrientNameSize))
                    .padding(16)
                }

                NutritionDesignSection(nil, surface: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "info.circle")
                            Text("Daily values based on a 2,000-calorie diet.")
                        }
                        Link("FDA Daily Value Guidelines", destination: URL(string: "https://www.fda.gov/food/nutrition-facts-label/daily-value-nutrition-and-supplement-facts-labels")!)
                        Text("AI-estimated values are approximations.")
                    }
                    .font(.system(size: NutritionStyle.smallCaptionSize)).foregroundStyle(.secondary)
                    .padding(16)
                }
              }
              .padding(.horizontal, NutritionStyle.groupedInset)
              .padding(.bottom, 20)
            }
            .scrollIndicators(.hidden)
            // A bar reserves the header's initial space while allowing scrolled
            // content behind it. SwiftUI owns the soft edge blur, not a solid fill.
            .safeAreaBar(edge: .top, spacing: 0) {
                NutritionPinnedHeader(title: "Nutrition", backTitle: "Journal", period: period,
                                      date: $selectedDate) { openWindow(id: "journal-design") }
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: period)
          }
        }
        .tint(NutritionStyle.accent)
        .frame(width: NutritionStyle.width, height: NutritionStyle.height)
        .background(colorScheme == .dark ? NutritionStyle.darkBackground : NutritionStyle.lightBackground)
        .compositingGroup().clipShape(.rect(cornerRadius: 32))
    }

    private func nutrientLink(_ value: NutritionSampleValue) -> some View {
        // The real app uses a NavigationLink. Keep only its label/chevron here.
        Button { selectedNutrient = value } label: {
            HStack {
                NutritionProgressDesign(value: NutritionFixture.average(value, ending: selectedDate,
                                                                         days: period.days, missing: missingData))
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .contentShape(.rect)
        }.buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            if value.id != NutritionSampleValue.nutrients.last(where: {
                $0.category == value.category && $0.common == value.common
            })?.id {
                Divider().padding(.leading, 16)
            }
        }
    }
}

private struct NutritionPinnedHeader: View {
    let title: String
    let backTitle: String
    let period: NutritionSamplePeriod
    @Binding var date: Date
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Mac-sized stand-in for native iOS navigation; no app routing/services.
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button(action: back) {
                        Label(backTitle, systemImage: "chevron.left")
                            .font(.system(size: 15, weight: .semibold))
                            .padding(.horizontal, 14).frame(height: NutritionStyle.navigationHeight)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .accessibilityLabel("Back to \(backTitle)")
                    Spacer()
                    dateButton(direction: -1, symbol: "chevron.left")
                    dateButton(direction: 1, symbol: "chevron.right")
                }
                .foregroundStyle(NutritionStyle.accent)
            }
            .padding(.horizontal, NutritionStyle.inset).padding(.vertical, 8)
            Text(title).font(.system(size: NutritionStyle.titleSize, weight: .bold))
                .padding(.horizontal, NutritionStyle.inset).padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dateButton(direction: Int, symbol: String) -> some View {
        Button {
            date = min(NutritionFixture.today, NutritionFixture.offset(date, days: direction * period.days))
        } label: {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
                .frame(width: NutritionStyle.navigationHeight, height: NutritionStyle.navigationHeight)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .disabled(direction > 0 && date >= NutritionFixture.today)
        .accessibilityLabel("\(direction < 0 ? "Previous" : "Next") \(period.tabTitle.lowercased())")
    }
}

/// Flat grouped-list surface, not Liquid Glass. Only system controls use glass.
/// The actual app keeps its native List; this wrapper is a Canvas-only adaptation.
private struct NutritionDesignSection<Content: View>: View {
    let title: String?
    let surface: Bool
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var colorScheme

    init(_ title: String?, surface: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title
        self.surface = surface
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.system(size: 13)).foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    if surface {
                        RoundedRectangle(cornerRadius: NutritionStyle.groupedRadius)
                            .fill(colorScheme == .dark ? Color(red: 0.11, green: 0.11, blue: 0.12) : .white)
                    }
                }
        }.padding(.top, NutritionStyle.sectionTopSpacing)
    }
}

// The single summary card is the focal point; detail sections remain below it.
private struct NutritionSummaryDesign: View {
    let missingData: Bool
    let period: NutritionSamplePeriod
    let date: Date
    let select: (NutritionSampleValue) -> Void

    private var values: [NutritionSampleValue] {
        NutritionSampleValue.macros.map {
            NutritionFixture.average($0, ending: date, days: period.days, missing: missingData)
        }
    }
    private var calories: NutritionSampleValue { values[0] }
    private var summary: String {
        guard !missingData else { return "No entries in this sample period." }
        let macros = Array(values.dropFirst())
        let over = macros.filter { $0.ratio > 1 }.map { $0.name.lowercased() }.joined(separator: ", ")
        let closest = macros.min { abs($0.ratio - 1) < abs($1.ratio - 1) }?.name.lowercased() ?? "—"
        let first = "\(Int(calories.ratio * 100))% of calorie goal."
        return over.isEmpty ? "\(first) Closest to target: \(closest)."
            : "\(first) Above target: \(over). Closest to target: \(closest)."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: NutritionStyle.summaryColumnGap) {
                Button { select(NutritionSampleValue.macros[0]) } label: {
                    ZStack {
                        Circle().stroke(.primary.opacity(0.07), lineWidth: NutritionStyle.ringStroke)
                        Circle().trim(from: 0, to: min(calories.ratio, 1))
                            .stroke(NutritionStyle.goalColor(calories.ratio), style: StrokeStyle(lineWidth: NutritionStyle.ringStroke, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: 1) {
                            Text(calories.amount.map { Int($0.rounded()).formatted() } ?? "—")
                                .font(.system(size: NutritionStyle.valueSize, weight: .bold))
                                .foregroundStyle(.primary)
                                .modifier(NutritionNumberTransition(value: calories.amount ?? 0))
                            Text("of \(Int(calories.goal).formatted())")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            if period != .daily {
                                Text("kcal/day").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(width: NutritionStyle.ringDiameter, height: NutritionStyle.ringDiameter)
                    .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Calories: \(calories.amount.map(NutritionSampleValue.format) ?? "not recorded") of \(Int(calories.goal))")

                VStack(spacing: NutritionStyle.macroRowGap) {
                    ForEach(Array(values.dropFirst())) { value in
                        Button {
                            if let original = NutritionSampleValue.macros.first(where: { $0.id == value.id }) {
                                select(original)
                            }
                        } label: { NutritionMacroBar(value: value) }
                            .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            Divider()
            // Deterministic fixture summary, not an AI response or dietary advice.
            Text(summary)
                .font(.system(size: NutritionStyle.summaryTextSize))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(NutritionStyle.summaryCardPadding)
        .glassEffect(.regular, in: .rect(cornerRadius: NutritionStyle.summaryCardRadius))
    }
}

private struct NutritionMacroBar: View {
    let value: NutritionSampleValue
    private var barColor: Color {
        // Macro identity stays blue/green/gold until it exceeds its own goal.
        value.ratio > 1 ? NutritionStyle.overTarget : value.color
    }

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                Text(value.name).font(.system(size: 14))
                Spacer(minLength: 0)
                Text("\(value.amount.map { Int($0.rounded()).formatted() } ?? "—") \(value.unit)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(barColor)
                    .modifier(NutritionNumberTransition(value: value.amount ?? 0))
                Text(value.amount == nil ? "—" : "\(Int(value.ratio * 100))%")
                    .font(.system(size: 12))
                    .foregroundStyle(value.ratio > 1 ? NutritionStyle.overTarget : .secondary)
                    .modifier(NutritionNumberTransition(value: value.ratio))
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.06))
                    Capsule().fill(barColor)
                        .frame(width: geometry.size.width * min(value.ratio, 1))
                    if value.ratio > 1 {
                        NutritionOverflowHatch()
                            .stroke(.white.opacity(0.65), lineWidth: 2)
                            .frame(width: geometry.size.width * min(value.ratio - 1, 0.5))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .clipShape(.capsule)
            }.frame(height: NutritionStyle.macroBarHeight)
        }
        .foregroundStyle(.primary)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(value.amount == nil ? "\(value.name): not recorded"
                            : "\(value.name): \(NutritionSampleValue.format(value.amount ?? 0)) \(value.unit), \(Int(value.ratio * 100)) percent of target")
    }
}

// MARK: Nutrient drill-down — deterministic fixture data, never generated advice

private struct NutritionNutrientDetail: View {
    let value: NutritionSampleValue
    let period: NutritionSamplePeriod
    @Binding var date: Date
    let missingData: Bool
    let back: () -> Void

    private var displayed: NutritionSampleValue {
        NutritionFixture.average(value, ending: date, days: period.days, missing: missingData)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(NutritionFixture.dateLabel(ending: date, days: period.days))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                NutritionGoalDetail(value: displayed, dailyAverage: period != .daily)
                NutritionTrendDetail(value: value, date: date, missingData: missingData)
                NutritionSourcesDetail(value: displayed, dailyAverage: period != .daily)
                Text("SAMPLE DATA ONLY")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, NutritionStyle.groupedInset).padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .safeAreaBar(edge: .top, spacing: 0) {
            NutritionPinnedHeader(title: value.name, backTitle: "Nutrition", period: period,
                                  date: $date, back: back)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }
}

private struct NutritionGoalDetail: View {
    let value: NutritionSampleValue
    let dailyAverage: Bool
    private var color: Color { NutritionStyle.goalColor(value.ratio) }
    private var status: String {
        guard let amount = value.amount else { return "No recorded value in this sample period." }
        guard value.goal > 0 else { return "No daily goal set." }
        let difference = abs(amount - value.goal)
        if difference < 0.05 { return "At goal" }
        return "\(NutritionSampleValue.format(difference)) \(value.unit) \(amount > value.goal ? "above" : "below") goal"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value.amount.map(NutritionSampleValue.format) ?? "—")
                    .font(.system(size: 36, weight: .bold))
                    .modifier(NutritionNumberTransition(value: value.amount ?? 0))
                Text(value.goal > 0 ? "of \(NutritionSampleValue.format(value.goal)) \(value.unit)\(dailyAverage ? "/day" : "")"
                     : "\(value.unit)\(dailyAverage ? "/day" : "")")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            }
            Text(status).font(.system(size: 13)).foregroundStyle(.secondary)
            if value.goal > 0 {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.primary.opacity(0.07)).frame(height: 6)
                        // The calendar's 95–105% goal band, on a zero-to-2x scale.
                        Capsule().fill(.green.opacity(0.2))
                            .frame(width: geometry.size.width * 0.05, height: 12)
                            .offset(x: geometry.size.width * 0.475)
                        if value.amount != nil {
                            Circle().fill(color).frame(width: 16, height: 16)
                                .offset(x: (geometry.size.width - 16) * min(max(value.ratio / 2, 0), 1))
                        }
                    }.frame(height: 16)
                }.frame(height: 16)
                HStack {
                    Text("0")
                    Spacer()
                    Text("Goal")
                    Spacer()
                    Text(value.ratio > 2 ? "2×+" : "2×")
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: NutritionStyle.summaryCardRadius))
        .accessibilityElement(children: .combine)
    }
}

private struct NutritionTrendDetail: View {
    let value: NutritionSampleValue
    let date: Date
    let missingData: Bool
    @State private var days = 7

    private var points: [NutritionTrendPoint] {
        NutritionFixture.points(value, ending: date, days: days, missing: missingData)
    }
    private var average: Double? {
        let amounts = points.compactMap(\.amount)
        return amounts.isEmpty ? nil : amounts.reduce(0, +) / Double(amounts.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Last \(days) days").font(.system(size: 16, weight: .semibold))
                Spacer()
                Picker("Chart range", selection: $days) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                }.labelsHidden().pickerStyle(.menu).fixedSize()
            }
            if let average {
                Text("Average \(NutritionSampleValue.format(average)) \(value.unit)"
                     + (value.goal > 0 ? " · \(Int((average / value.goal * 100).rounded()))% of goal" : ""))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Chart {
                    ForEach(points) { point in
                        if let amount = point.amount {
                            BarMark(x: .value("Date", point.date, unit: .day),
                                    y: .value(value.unit, amount))
                                .cornerRadius(3)
                                .foregroundStyle(value.goal > 0 ? NutritionStyle.goalColor(amount / value.goal) : Color.primary)
                                .accessibilityLabel(point.date.formatted(.dateTime.month().day()))
                                .accessibilityValue("\(NutritionSampleValue.format(amount)) \(value.unit)")
                        }
                    }
                    if value.goal > 0 {
                        RuleMark(y: .value("Daily goal", value.goal))
                            .foregroundStyle(.secondary.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .annotation(position: .top, alignment: .trailing) {
                                Text("Goal \(NutritionSampleValue.format(value.goal))")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                    }
                }
                .chartYScale(domain: 0...max(value.goal * 1.25, (points.compactMap(\.amount).max() ?? 1) * 1.15, 1))
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: days == 7 ? 1 : 7)) {
                        AxisValueLabel(format: days == 7 ? .dateTime.weekday(.narrow) : .dateTime.month(.abbreviated).day())
                    }
                }
                .frame(height: NutritionStyle.trendHeight)
                .accessibilityLabel("\(value.name), last \(days) days")
            } else {
                Text("No recorded values for these dates.")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: NutritionStyle.trendHeight)
            }
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: NutritionStyle.summaryCardRadius))
    }
}

private struct NutritionSourcesDetail: View {
    let value: NutritionSampleValue
    let dailyAverage: Bool
    // Explicit fictional contributions, not an inferred relationship to real foods.
    private let foods: [(name: String, meal: String, share: Double)] = [
        ("Organic Extra-Firm Tofu", "Dinner · 2 servings", 0.55),
        ("Enriched Hot Dog Buns", "Lunch · 1 serving", 0.30),
        ("Other sample foods", "Remaining entries", 0.15)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Where it came from").font(.system(size: 17, weight: .semibold))
            VStack(spacing: 0) {
                if let amount = value.amount, amount > 0 {
                    ForEach(foods, id: \.name) { food in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(food.name).font(.system(size: 15, weight: .medium))
                                Spacer(minLength: 8)
                                Text("\(NutritionSampleValue.format(amount * food.share)) \(value.unit)\(dailyAverage ? "/day" : "")")
                                    .font(.system(size: 13)).monospacedDigit()
                            }
                            HStack {
                                Text(food.meal)
                                Spacer()
                                Text("\(Int((food.share * 100).rounded()))%")
                            }.font(.system(size: 12)).foregroundStyle(.secondary)
                            GeometryReader { geometry in
                                Capsule().fill(.primary.opacity(0.07))
                                    .overlay(alignment: .leading) {
                                        // Contribution is a share, not progress toward a goal.
                                        Capsule().fill(value.name == "Calories" ? Color.primary : value.color)
                                            .frame(width: geometry.size.width * food.share)
                                    }
                            }.frame(height: 4)
                        }.padding(16)
                        if food.name != foods.last?.name { Divider().padding(.horizontal, 16) }
                    }
                } else {
                    Text("No food contributions recorded.").font(.system(size: 14))
                        .foregroundStyle(.secondary).padding(18)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: NutritionStyle.summaryCardRadius))
        }
    }
}

private struct NutritionOverflowHatch: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        var path = Path()
        for x in stride(from: -rect.height, through: rect.width + rect.height, by: 5) {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
        }
        return path
    }
}

private struct NutritionPeriodTabs: View {
    @Binding var selection: NutritionSamplePeriod
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 0) {
            ForEach(NutritionSamplePeriod.allCases) { period in
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { selection = period }
                } label: {
                    Text(period.tabTitle).font(.system(size: 14, weight: selection == period ? .semibold : .regular))
                        .foregroundStyle(selection == period ? .primary : .secondary)
                        .frame(maxWidth: .infinity).frame(height: 32)
                        .background {
                            if selection == period {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(colorScheme == .dark ? Color.white.opacity(0.12) : .white)
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == period ? .isSelected : [])
                .accessibilityLabel(period.tabTitle)
            }
        }
        .padding(2)
        .background(.primary.opacity(0.06), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Period")
    }
}

private struct NutritionProgressDesign: View {
    let value: NutritionSampleValue
    var body: some View {
        VStack(alignment: .leading, spacing: NutritionStyle.nutrientContentGap) {
            HStack {
                Text(value.name).font(.system(size: NutritionStyle.nutrientNameSize))
                Spacer()
                Text(value.displayText).font(.system(size: NutritionStyle.captionSize))
                    .monospacedDigit().foregroundStyle(.secondary)
                    .modifier(NutritionNumberTransition(value: value.amount ?? 0))
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(NutritionStyle.goalColor(value.ratio))
                        .frame(width: min(geometry.size.width, geometry.size.width * value.ratio))
                }
            }.frame(height: NutritionStyle.nutrientBarHeight)
        }.padding(.vertical, NutritionStyle.nutrientVerticalPadding)
    }
}

private struct NutritionNumberTransition: ViewModifier {
    let value: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.contentTransition(reduceMotion ? .identity : .numericText(value: value))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: value)
    }
}

private enum NutritionSamplePeriod: String, CaseIterable, Identifiable {
    case daily = "Daily", weekly = "Weekly", monthly = "Monthly"
    var id: String { rawValue }
    var days: Int {
        switch self { case .daily: 1; case .weekly: 7; case .monthly: 30 }
    }
    var tabTitle: String {
        switch self {
        case .daily: "Day"
        case .weekly: "Week"
        case .monthly: "Month"
        }
    }
}

private enum NutritionSampleCategory: String, CaseIterable, Identifiable {
    case vitamins = "Vitamins", minerals = "Minerals", other = "Other Nutrients"
    var id: String { rawValue }
}

private struct NutritionTrendPoint: Identifiable {
    let date: Date
    let amount: Double?
    var id: Date { date }
}

private enum NutritionFixture {
    // Fixed at noon in UTC: the mock never rolls to another date with the clock.
    static let calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }()
    static let today = calendar.date(from: DateComponents(year: 2026, month: 8, day: 21, hour: 12))!
    static let factors = [1.0, 0.72, 1.12, 0.98, 0.85, 1.03, 0.60]

    static func offset(_ date: Date, days: Int) -> Date {
        calendar.date(byAdding: .day, value: days, to: date) ?? date
    }

    static func points(_ value: NutritionSampleValue, ending date: Date, days: Int, missing: Bool) -> [NutritionTrendPoint] {
        (0..<days).map { index in
            let day = offset(date, days: index - days + 1)
            let distance = calendar.dateComponents([.day], from: day, to: today).day ?? 0
            let amount = missing ? nil : value.amount.map { $0 * factors[abs(distance) % factors.count] }
            return NutritionTrendPoint(date: day, amount: amount)
        }
    }

    static func average(_ value: NutritionSampleValue, ending date: Date, days: Int, missing: Bool) -> NutritionSampleValue {
        let amounts = points(value, ending: date, days: days, missing: missing).compactMap(\.amount)
        return value.withAmount(amounts.isEmpty ? nil : amounts.reduce(0, +) / Double(amounts.count))
    }

    // Same trailing windows as NutritionDetailView; no separate averages banner.
    static func dateLabel(ending date: Date, days: Int) -> String {
        if days == 1 && calendar.isDate(date, inSameDayAs: today) { return "Today" }
        var format = Date.FormatStyle.dateTime.month(.abbreviated).day()
        format.timeZone = calendar.timeZone
        if days == 1 { return date.formatted(format) }
        return "\(offset(date, days: 1 - days).formatted(format)) – \(date.formatted(format))"
    }
}

private struct NutritionSampleValue: Identifiable {
    let name: String
    var amount: Double?
    let goal: Double
    let unit: String
    var color: Color = .green
    var category: NutritionSampleCategory = .other
    var common = true
    var id: String { name }
    var ratio: Double { goal > 0 ? (amount ?? 0) / goal : 0 }

    var displayText: String {
        let goalText = goal == 0 ? "—" : Self.format(goal)
        guard let amount else { return "— / \(goalText) \(unit)" }
        let percentage = goal > 0 ? String(format: " (%.0f%%)", ratio * 100) : ""
        return "\(Self.format(amount)) / \(goalText) \(unit)\(percentage)"
    }
    static func format(_ value: Double) -> String {
        if value < 1 && value > 0 { return String(format: "%.1f", value) }
        if value >= 1000 || value == floor(value) { return String(format: "%.0f", value) }
        return String(format: "%.1f", value)
    }
    func withAmount(_ amount: Double?) -> Self {
        var copy = self
        copy.amount = amount
        return copy
    }

    static let macros: [Self] = [
        .init(name: "Calories", amount: 2308, goal: 2500, unit: "kcal", color: .orange),
        .init(name: "Protein", amount: 117, goal: 150, unit: "g", color: .blue),
        .init(name: "Carbs", amount: 244, goal: 250, unit: "g", color: .green),
        .init(name: "Fat", amount: 94, goal: 70, unit: "g", color: Color(red: 0.9, green: 0.75, blue: 0))
    ]
    // Reference metadata mirrors KnownMicronutrients.all; amounts remain fictional.
    // nil means missing data, not zero. Full row counts preserve screen density.
    static let nutrients: [Self] = [
        .init(name: "Vitamin A", amount: nil, goal: 900, unit: "mcg", category: .vitamins),
        .init(name: "Vitamin C", amount: 65, goal: 90, unit: "mg", category: .vitamins),
        .init(name: "Vitamin D", amount: nil, goal: 20, unit: "mcg", category: .vitamins),
        .init(name: "Vitamin E", amount: nil, goal: 15, unit: "mg", category: .vitamins, common: false),
        .init(name: "Vitamin K", amount: nil, goal: 120, unit: "mcg", category: .vitamins, common: false),
        .init(name: "Thiamin (B1)", amount: nil, goal: 1.2, unit: "mg", category: .vitamins, common: false),
        .init(name: "Riboflavin (B2)", amount: nil, goal: 1.3, unit: "mg", category: .vitamins, common: false),
        .init(name: "Niacin (B3)", amount: nil, goal: 16, unit: "mg", category: .vitamins, common: false),
        .init(name: "Pantothenic Acid (B5)", amount: nil, goal: 5, unit: "mg", category: .vitamins, common: false),
        .init(name: "Vitamin B6", amount: nil, goal: 1.7, unit: "mg", category: .vitamins, common: false),
        .init(name: "Biotin (B7)", amount: nil, goal: 30, unit: "mcg", category: .vitamins, common: false),
        .init(name: "Folate (B9)", amount: nil, goal: 400, unit: "mcg", category: .vitamins, common: false),
        .init(name: "Vitamin B12", amount: 1.8, goal: 2.4, unit: "mcg", category: .vitamins, common: false),
        .init(name: "Calcium", amount: 720, goal: 1300, unit: "mg", category: .minerals),
        .init(name: "Iron", amount: nil, goal: 18, unit: "mg", category: .minerals),
        .init(name: "Magnesium", amount: nil, goal: 420, unit: "mg", category: .minerals, common: false),
        .init(name: "Phosphorus", amount: nil, goal: 1250, unit: "mg", category: .minerals, common: false),
        .init(name: "Potassium", amount: nil, goal: 4700, unit: "mg", category: .minerals),
        .init(name: "Sodium", amount: 2980, goal: 2300, unit: "mg", category: .minerals),
        .init(name: "Zinc", amount: nil, goal: 11, unit: "mg", category: .minerals, common: false),
        .init(name: "Copper", amount: nil, goal: 0.9, unit: "mg", category: .minerals, common: false),
        .init(name: "Manganese", amount: nil, goal: 2.3, unit: "mg", category: .minerals, common: false),
        .init(name: "Selenium", amount: nil, goal: 55, unit: "mcg", category: .minerals, common: false),
        .init(name: "Chromium", amount: nil, goal: 35, unit: "mcg", category: .minerals, common: false),
        .init(name: "Molybdenum", amount: nil, goal: 45, unit: "mcg", category: .minerals, common: false),
        .init(name: "Iodine", amount: nil, goal: 150, unit: "mcg", category: .minerals, common: false),
        .init(name: "Chloride", amount: nil, goal: 2300, unit: "mg", category: .minerals, common: false),
        .init(name: "Dietary Fiber", amount: 16, goal: 28, unit: "g"),
        .init(name: "Total Sugars", amount: 30, goal: 0, unit: "g"),
        .init(name: "Added Sugars", amount: 15, goal: 50, unit: "g"),
        .init(name: "Cholesterol", amount: nil, goal: 300, unit: "mg"),
        .init(name: "Saturated Fat", amount: nil, goal: 20, unit: "g"),
        .init(name: "Monounsaturated Fat", amount: nil, goal: 0, unit: "g", common: false),
        .init(name: "Polyunsaturated Fat", amount: nil, goal: 0, unit: "g", common: false),
        .init(name: "Trans Fat", amount: nil, goal: 0, unit: "g"),
        .init(name: "Water", amount: nil, goal: 0, unit: "mL", common: false),
        .init(name: "Caffeine", amount: nil, goal: 0, unit: "mg", common: false)
    ]
}

struct NutritionWorkbench: View {
    @State private var dark = false
    @State private var missing = false
    @State private var zoom = 0.85
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Nutrition").font(.headline)
                Spacer()
                Toggle("Missing data", isOn: $missing)
                Toggle("Dark", isOn: $dark).toggleStyle(.switch)
                Slider(value: $zoom, in: 0.6...1.1).frame(width: 90).accessibilityLabel("Preview zoom")
            }.padding(12)
            ScrollView([.horizontal, .vertical]) {
                NutritionDesign(missingData: missing).preferredColorScheme(dark ? .dark : .light)
                    .scaleEffect(zoom)
                    .frame(width: NutritionStyle.width * zoom, height: NutritionStyle.height * zoom)
                    .padding(24)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Text("SAMPLE DATA ONLY · Grouped chrome approximates iOS")
                .font(.caption).foregroundStyle(.secondary).padding(8)
        }.frame(minWidth: 500, minHeight: 600)
    }
}

#Preview("Nutrition · Light") { NutritionDesign().preferredColorScheme(.light) }
#Preview("Nutrition · Dark") { NutritionDesign().preferredColorScheme(.dark) }
#Preview("Nutrition · Missing Data") { NutritionDesign(missingData: true).preferredColorScheme(.light) }
