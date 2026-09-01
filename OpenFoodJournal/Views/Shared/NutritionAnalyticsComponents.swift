import SwiftUI
import SwiftData
import Charts

struct NutritionLogQuery<Content: View>: View {
    @Query private var logs: [DailyLog]
    let foodName: String?
    let content: (NutritionAnalytics) -> Content

    init(from: Date, through: Date, foodName: String? = nil,
         @ViewBuilder content: @escaping (NutritionAnalytics) -> Content) {
        let start = Calendar.current.startOfDay(for: from)
        let end = NutritionDateRange.offset(through, days: 1)
        _logs = Query(filter: #Predicate<DailyLog> { $0.date >= start && $0.date < end }, sort: \DailyLog.date)
        self.foodName = foodName
        self.content = content
    }
    var body: some View { content(NutritionAnalytics(logs: logs, foodName: foodName)) }
}

extension NutritionMetric {
    var identityColor: Color {
        switch macro {
        case .protein: .blue
        case .carbs: .green
        case .fat: Color(red: 0.9, green: 0.75, blue: 0)
        default: .primary
        }
    }
    func color(for value: Double?) -> Color {
        guard let value, goal > 0 else { return identityColor }
        if let macro, macro != .calories {
            return value > goal ? OFJColor.calendarOverGoalRGB.color : identityColor
        }
        return OFJColor.journalCalorieState(for: value / goal).ringColor
    }
    func valueText(_ value: Double?) -> String {
        let amount = value.map(NutritionFormat.number) ?? "—"
        guard goal > 0 else { return "\(amount) \(unit)" }
        let percentage = value.map { " (\(Int(($0 / goal * 100).rounded()))%)" } ?? ""
        return "\(amount) / \(NutritionFormat.number(goal)) \(unit)\(percentage)"
    }
}

enum NutritionFormat {
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return value.formatted(.number.precision(.fractionLength(value > 0 && value < 10 ? 1 : 0)))
    }
}

struct NutritionSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

struct NutritionRangeArrows: ToolbarContent {
    @Binding var date: Date
    let days: Int
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("Previous period", systemImage: "chevron.left") {
                date = NutritionDateRange.next(date, direction: -1, days: days)
            }.labelStyle(.iconOnly)
            Button("Next period", systemImage: "chevron.right") {
                date = NutritionDateRange.next(date, direction: 1, days: days)
            }.labelStyle(.iconOnly)
                .disabled(Calendar.current.startOfDay(for: date) >= Calendar.current.startOfDay(for: AppPresentationDate.now))
        }
    }
}

struct NutritionRangeControl: View {
    @Binding var date: Date
    let days: Int
    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                arrow("chevron.left", direction: -1)
                let rangeLabel = NutritionDateRange.label(ending: date, days: days)
                Text(rangeLabel)
                    .font(.subheadline.weight(.semibold))
                    .ofjNumericTextTransition(value: date.timeIntervalSinceReferenceDate, trigger: rangeLabel)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .glassEffect(.regular, in: .capsule)
                arrow("chevron.right", direction: 1)
            }
        }
    }
    private func arrow(_ symbol: String, direction: Int) -> some View {
        Button { date = NutritionDateRange.next(date, direction: direction, days: days) } label: {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                .frame(width: 44, height: 44).contentShape(.circle)
        }.buttonStyle(.plain).glassEffect(.regular.interactive(), in: .circle)
            .disabled(direction > 0 && Calendar.current.startOfDay(for: date) >= Calendar.current.startOfDay(for: AppPresentationDate.now))
            .accessibilityLabel(direction > 0 ? "Next date range" : "Previous date range")
    }
}

struct NutritionProgressRow: View {
    let metric: NutritionMetric
    let value: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(metric.name).font(.subheadline)
                Spacer(minLength: 6)
                Text(metric.valueText(value)).font(.caption).monospacedDigit()
                    .foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    .ofjNumericTextTransition(value: value ?? 0)
            }
            if metric.goal > 0 {
                GeometryReader { geometry in
                    Capsule().fill(.quaternary).overlay(alignment: .leading) {
                        Capsule().fill(metric.color(for: value))
                            .frame(width: geometry.size.width * min(max((value ?? 0) / metric.goal, 0), 1))
                    }
                }.frame(height: 6)
            }
        }.padding(.vertical, 2).accessibilityElement(children: .combine)
    }
}

struct NutritionSummaryCard: View {
    let analytics: NutritionAnalytics
    let metrics: [NutritionMetric]
    let date: Date
    let days: Int
    let select: (NutritionMetric) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var ringSize: CGFloat = 104
    private var calories: NutritionMetric { metrics[0] }
    private func amount(_ metric: NutritionMetric) -> Double? {
        NutritionAnalytics.average(analytics.series(metric, ending: date, days: days))
    }
    private var fact: String {
        guard let value = amount(calories) else { return "No entries recorded in this period." }
        let over = metrics.dropFirst().filter { $0.goal > 0 && (amount($0) ?? 0) > $0.goal }.map { $0.name.lowercased() }
        let prefix = calories.goal > 0 ? "\(Int((value / calories.goal * 100).rounded()))% of calorie goal." : "No calorie goal set."
        return over.isEmpty ? prefix : "\(prefix) Above target: \(over.joined(separator: ", "))."
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 18) { calorieRing; macroBars }
            } else {
                HStack(spacing: 18) { calorieRing; macroBars }
            }
            Divider()
            Text(fact).font(.caption).foregroundStyle(.secondary)
        }.padding(16).modifier(NutritionSurface())
    }
    private var calorieRing: some View {
        let value = amount(calories)
        let ratio = calories.goal > 0 ? (value ?? 0) / calories.goal : 0
        return Button { select(calories) } label: {
            ZStack {
                Circle().stroke(.primary.opacity(0.07), lineWidth: 10)
                Circle().trim(from: 0, to: min(max(ratio, 0), 1))
                    .stroke(calories.color(for: value), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 1) {
                    Text(value.map(NutritionFormat.number) ?? "—")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.65).ofjNumericTextTransition(value: value ?? 0)
                    Text(calories.goal > 0 ? "of \(NutritionFormat.number(calories.goal))" : "kcal")
                        .font(.caption2).foregroundStyle(.secondary)
                    if days > 1 { Text("kcal/day").font(.caption2).foregroundStyle(.secondary) }
                }.padding(10)
            }.frame(width: ringSize, height: ringSize).contentShape(.circle)
        }.buttonStyle(.plain).accessibilityLabel("Calories: \(calories.valueText(value))")
    }
    private var macroBars: some View {
        VStack(spacing: 12) {
            ForEach(Array(metrics.dropFirst())) { metric in
                Button { select(metric) } label: {
                    VStack(spacing: 5) {
                        HStack(spacing: 5) {
                            Text(metric.name).font(.subheadline)
                            Spacer(minLength: 0)
                            Text("\(amount(metric).map(NutritionFormat.number) ?? "—") \(metric.unit)")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(metric.color(for: amount(metric)))
                            if let value = amount(metric), metric.goal > 0 {
                                Text("\(Int((value / metric.goal * 100).rounded()))%")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        GeometryReader { geometry in
                            let ratio = metric.goal > 0 ? (amount(metric) ?? 0) / metric.goal : 0
                            Capsule().fill(.primary.opacity(0.06)).overlay(alignment: .leading) {
                                Capsule().fill(metric.color(for: amount(metric)))
                                    .frame(width: geometry.size.width * min(max(ratio, 0), 1))
                            }.overlay(alignment: .trailing) {
                                if ratio > 1 {
                                    NutritionOverflowHatch().stroke(.white.opacity(0.65), lineWidth: 2)
                                        .frame(width: geometry.size.width * min(ratio - 1, 0.5))
                                }
                            }
                            .clipShape(.capsule)
                            .compositingGroup()
                        }.frame(height: 5)
                    }.contentShape(.rect)
                }.buttonStyle(.plain).accessibilityLabel("\(metric.name): \(metric.valueText(amount(metric)))")
            }
        }.frame(maxWidth: .infinity)
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

/// Real dates remain the identity/accessibility value. Integer slots prevent
/// calendar bucketing or DST from shifting/clipping first and last bars.
struct NutritionTrendChart: View {
    let metric: NutritionMetric
    let points: [NutritionTrendPoint]
    private var ticks: [Double] {
        guard points.count > 7 else { return points.indices.map(Double.init) }
        return [0, 7, 14, 21, points.count - 1].filter { $0 < points.count }.map(Double.init)
    }
    var body: some View {
        Chart {
            ForEach(Array(points.enumerated()), id: \.element.id) { slot, point in
                if let value = point.value {
                    RectangleMark(xStart: .value("Day", Double(slot) - 0.34), xEnd: .value("Day", Double(slot) + 0.34),
                                  yStart: .value(metric.unit, 0.0), yEnd: .value(metric.unit, value))
                        .cornerRadius(3).foregroundStyle(metric.color(for: value))
                        .accessibilityLabel(point.date.formatted(.dateTime.month().day()))
                        .accessibilityValue("\(NutritionFormat.number(value)) \(metric.unit)")
                }
            }
            if metric.goal > 0 {
                RuleMark(y: .value("Daily goal", metric.goal)).foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(dash: [4, 4]))
            }
        }
        .chartXScale(domain: -0.5...(Double(max(1, points.count)) - 0.5), range: .plotDimension(padding: 0))
        .chartYScale(domain: 0...max(metric.goal * 1.2, (points.compactMap(\.value).max() ?? 1) * 1.1, 1))
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: ticks) { tick in
                if let slot = tick.as(Double.self), points.indices.contains(Int(slot)) {
                    AxisValueLabel(anchor: slot == 0 ? .topLeading : slot == Double(points.count - 1) ? .topTrailing : .top,
                                   collisionResolution: .disabled) {
                        Text(points[Int(slot)].date.formatted(points.count <= 7 ? .dateTime.weekday(.abbreviated) : .dateTime.month(.abbreviated).day()))
                    }
                }
            }
        }
        .chartPlotStyle { $0.clipped() }
        .frame(height: 150)
        .accessibilityLabel("Daily \(metric.name)")
    }
}

struct NutritionTrendCard: View {
    let analytics: NutritionAnalytics
    let metric: NutritionMetric
    let date: Date
    let days: Int
    var comparePrevious = false
    private var points: [NutritionTrendPoint] { analytics.series(metric, ending: date, days: days) }
    private var average: Double? { NutritionAnalytics.average(points) }
    private var comparison: String? {
        guard comparePrevious, let average,
              let previous = NutritionAnalytics.average(analytics.series(metric, ending: NutritionDateRange.offset(date, days: -days), days: days)), previous > 0 else { return nil }
        let delta = Int(((average / previous - 1) * 100).rounded())
        return "\(delta > 0 ? "+" : "")\(delta)% vs prior \(days) days"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(metric.name).font(.subheadline.weight(.semibold))
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(average.map(NutritionFormat.number) ?? "—").font(.system(size: 32, weight: .bold, design: .rounded))
                    .ofjNumericTextTransition(value: average ?? 0)
                Text("\(metric.unit)/day avg").font(.subheadline).foregroundStyle(.secondary)
            }
            if let average, metric.goal > 0 {
                Text("\(Int((average / metric.goal * 100).rounded()))% of goal" + (comparison.map { " · \($0)" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            } else if let comparison { Text(comparison).font(.caption).foregroundStyle(.secondary) }
            Text("\(points.compactMap(\.value).count) of \(days) days recorded")
                .font(.caption2).foregroundStyle(.secondary)
            if average != nil { NutritionTrendChart(metric: metric, points: points) }
            else { Text("No \(metric.name.lowercased()) recorded in this range.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 150) }
        }.accessibilityHint("Average uses days with a recorded value. Missing values are not treated as zero.")
    }
}

struct NutritionMetricPicker: View {
    let macros: [NutritionMetric]
    let micros: [NutritionMetric]
    @Binding var selectedID: String
    @AppStorage(PinnedMicronutrientSettings.idsKey) private var pinnedIDsRaw = ""
    @Namespace private var glassNamespace

    private var pinnedIDs: [String] { PinnedMicronutrientSettings.decode(pinnedIDsRaw) }
    private var pinnedMicros: [NutritionMetric] {
        let lookup = Dictionary(micros.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return pinnedIDs.compactMap { lookup[$0] }
    }
    private var unpinnedMicros: [NutritionMetric] {
        let pinned = Set(pinnedIDs)
        return micros.filter { !pinned.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal) {
                GlassEffectContainer(spacing: 6) { HStack(spacing: 6) { ForEach(macros) { chip($0, allowsPinning: false) } } }
            }.scrollIndicators(.hidden)
            if !pinnedMicros.isEmpty {
                chipRow(title: "Pinned", accessory: "\(pinnedMicros.count) pinned", metrics: pinnedMicros)
            }
            // Each header counts only the row beneath it, so pinning everything
            // cannot leave a "Micronutrients" heading standing over empty space.
            if !unpinnedMicros.isEmpty {
                chipRow(title: "Micronutrients", accessory: "\(unpinnedMicros.count) tracked", metrics: unpinnedMicros)
            }
        }
        .sensoryFeedback(.impact(flexibility: .soft), trigger: pinnedIDsRaw)
        .onChange(of: (macros + micros).map(\.id), initial: true) { _, ids in
            if !ids.contains(selectedID), let first = macros.first { selectedID = first.id }
        }
    }

    @ViewBuilder
    private func chipRow(title: String, accessory: String, metrics: [NutritionMetric]) -> some View {
        HStack {
            Text(title).font(.caption.weight(.semibold))
            Spacer()
            Text(accessory).font(.caption2)
        }.foregroundStyle(.secondary)
        chipScroller(metrics)
    }

    private func chipScroller(_ metrics: [NutritionMetric]) -> some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 6) {
                // HStack, not LazyHStack: recycled lazy rows in a horizontal
                // scroller drop the long-press recognizer Menu needs.
                HStack(spacing: 6) { ForEach(metrics) { chip($0, allowsPinning: true).frame(width: 112) } }
                    .padding(.vertical, 2)
            }
        }.scrollIndicators(.hidden).frame(height: 52)
    }

    @ViewBuilder
    private func chip(_ metric: NutritionMetric, allowsPinning: Bool) -> some View {
        let pinned = allowsPinning && PinnedMicronutrientSettings.isPinned(metric.id, in: pinnedIDs)
        let selected = selectedID == metric.id
        let label = HStack(spacing: 4) {
            if pinned {
                Image(systemName: "pin.fill").font(.caption2)
            }
            Text(metric.name).font(.caption.weight(selected ? .semibold : .regular))
                .lineLimit(2).minimumScaleFactor(0.85).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 58, minHeight: 44).frame(maxWidth: .infinity)
        .foregroundStyle(selected ? Color.accentColor : .primary)
        .contentShape(.capsule)

        // Button + contextMenu inside a horizontal ScrollView never presents:
        // the scroller, the button highlight, and interactive Liquid Glass all
        // claim the press first. Menu(primaryAction:) is the control that
        // treats tap as select and hold as the pin/unpin menu.
        if allowsPinning {
            Menu {
                if pinned {
                    Button { unpin(metric.id) } label: { Label("Unpin", systemImage: "pin.slash") }
                } else {
                    Button { pin(metric.id) } label: { Label("Pin", systemImage: "pin") }
                }
            } label: {
                label
            } primaryAction: {
                selectedID = metric.id
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(selected ? Color.accentColor.opacity(0.15) : .clear), in: .capsule)
            .glassEffectID(metric.id, in: glassNamespace)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityHint(pinned ? "Pinned. Touch and hold to unpin." : "Touch and hold to pin.")
        } else {
            Button { selectedID = metric.id } label: { label }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(selected ? Color.accentColor.opacity(0.15) : .clear).interactive(), in: .capsule)
                .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }

    private func pin(_ id: String) {
        withAnimation(.spring(duration: 0.3)) {
            pinnedIDsRaw = PinnedMicronutrientSettings.encode(
                PinnedMicronutrientSettings.pin(id, in: pinnedIDs)
            )
        }
    }

    private func unpin(_ id: String) {
        withAnimation(.spring(duration: 0.3)) {
            pinnedIDsRaw = PinnedMicronutrientSettings.encode(
                PinnedMicronutrientSettings.unpin(id, from: pinnedIDs)
            )
        }
    }
}

struct NutritionCitation: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Daily values based on a 2,000-calorie diet.")
            Link("FDA Daily Value Guidelines", destination: URL(string: "https://www.fda.gov/food/nutrition-facts-label/daily-value-nutrition-and-supplement-facts-labels")!)
            Text("AI-estimated values are approximations.")
        }.font(.caption2).foregroundStyle(.secondary)
    }
}
