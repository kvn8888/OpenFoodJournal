import SwiftUI

struct NutritionNutrientDetailView: View {
    let metric: NutritionMetric
    let period: NutritionStore.TimePeriod
    @State private var date: Date
    @State private var chartDays = 7
    @Environment(UserGoals.self) private var goals
    init(metric: NutritionMetric, referenceDate: Date, period: NutritionStore.TimePeriod) {
        self.metric = metric
        self.period = period
        _date = State(initialValue: Calendar.current.startOfDay(for: referenceDate))
    }
    private var days: Int { NutritionDateRange.count(period) }
    private var currentMetric: NutritionMetric {
        NutritionMetric.macros(goals: goals).first { $0.id == metric.id } ?? metric
    }

    var body: some View {
        NutritionLogQuery(from: NutritionDateRange.start(ending: date, days: max(days, chartDays)), through: date) { analytics in
            let value = NutritionAnalytics.average(analytics.series(currentMetric, ending: date, days: days))
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(NutritionDateRange.label(ending: date, days: days)).font(.caption).foregroundStyle(.secondary)
                    NutritionGoalCard(metric: currentMetric, value: value, dailyAverage: days > 1)
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Last \(chartDays) days").font(.headline)
                            Spacer()
                            Picker("Chart range", selection: $chartDays) {
                                Text("7 days").tag(7)
                                Text("30 days").tag(30)
                            }.labelsHidden().pickerStyle(.menu)
                        }
                        NutritionTrendCard(analytics: analytics, metric: currentMetric, date: date, days: chartDays)
                    }.padding(18).modifier(NutritionSurface())
                    let contributions = analytics.contributions(currentMetric, ending: date, days: days)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Where it came from").font(.headline)
                        if contributions.isEmpty {
                            Text("No food contributions recorded.").foregroundStyle(.secondary)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(contributions) { item in
                                    NavigationLink {
                                        FoodNutrientBreakdownView(foodName: item.foodName, period: period, referenceDate: date)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            HStack {
                                                Text(item.foodName).font(.subheadline.weight(.medium))
                                                Spacer(minLength: 8)
                                                Text("\(NutritionFormat.number(item.value)) \(metric.unit)\(days > 1 ? "/day" : "")")
                                                    .font(.caption).foregroundStyle(.secondary)
                                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                            }
                                            let share = value.map { $0 > 0 ? item.value / $0 : 0 } ?? 0
                                            Text("\(Int((share * 100).rounded()))% of recorded total").font(.caption2).foregroundStyle(.secondary)
                                            GeometryReader { geometry in
                                                Capsule().fill(.quaternary).overlay(alignment: .leading) {
                                                    Capsule().fill(metric.identityColor).frame(width: geometry.size.width * min(max(share, 0), 1))
                                                }
                                            }.frame(height: 4)
                                        }.padding(16).contentShape(.rect)
                                    }.buttonStyle(.plain)
                                    if item.id != contributions.last?.id { Divider().padding(.horizontal, 16) }
                                }
                            }.modifier(NutritionSurface())
                        }
                    }
                    NutritionCitation()
                }.padding(16)
            }
        }
        .navigationTitle(metric.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar { NutritionRangeArrows(date: $date, days: days) }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }
}

struct NutritionGoalCard: View {
    let metric: NutritionMetric
    let value: Double?
    let dailyAverage: Bool
    private var status: String {
        guard let value else { return "No recorded value in this period." }
        guard metric.goal > 0 else { return "No daily goal set." }
        if abs(value - metric.goal) < 0.05 { return "At goal" }
        return "\(NutritionFormat.number(abs(value - metric.goal))) \(metric.unit) \(value > metric.goal ? "above" : "below") goal"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value.map(NutritionFormat.number) ?? "—").font(.system(size: 36, weight: .bold, design: .rounded))
                    .ofjNumericTextTransition(value: value ?? 0)
                Text((metric.goal > 0 ? "of \(NutritionFormat.number(metric.goal)) " : "") + "\(metric.unit)\(dailyAverage ? "/day" : "")")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Text(status).font(.caption).foregroundStyle(.secondary)
            if metric.goal > 0 {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary).frame(height: 6)
                        Capsule().fill(.green.opacity(0.2)).frame(width: geometry.size.width * 0.05, height: 12)
                            .offset(x: geometry.size.width * 0.475)
                        if let value {
                            Circle().fill(OFJColor.journalCalorieState(for: value / metric.goal).ringColor)
                                .frame(width: 16, height: 16)
                                .offset(x: (geometry.size.width - 16) * min(max(value / metric.goal / 2, 0), 1))
                        }
                    }.frame(height: 16)
                }.frame(height: 16)
                HStack { Text("0"); Spacer(); Text("Goal"); Spacer(); Text((value ?? 0) > metric.goal * 2 ? "2×+" : "2×") }
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18).modifier(NutritionSurface())
    }
}
