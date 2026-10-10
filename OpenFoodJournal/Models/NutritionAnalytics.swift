// Read-only presentation snapshots. No persisted models or schema changes.
import Foundation
import SwiftData

struct NutritionMetric: Identifiable, Hashable {
    let id: String
    let name: String
    let unit: String
    let goal: Double
    var macro: NutrientKind.MacroType? = nil

    /// `overrides` carries the user's own daily targets; an absent entry keeps
    /// the FDA Daily Value.
    static func known(_ nutrient: KnownMicronutrient, overrides: [String: Double] = [:]) -> Self {
        Self(id: nutrient.id, name: nutrient.name, unit: nutrient.unit,
             goal: MicronutrientGoalSettings.dailyValue(for: nutrient, overrides: overrides))
    }

    static func macros(goals: UserGoals) -> [Self] {
        [Self(id: "macro:calories", name: "Calories", unit: "kcal", goal: goals.dailyCalories, macro: .calories),
         Self(id: "macro:protein", name: "Protein", unit: "g", goal: goals.dailyProtein, macro: .protein),
         Self(id: "macro:carbs", name: "Carbs", unit: "g", goal: goals.dailyCarbs, macro: .carbs),
         Self(id: "macro:fat", name: "Fat", unit: "g", goal: goals.dailyFat, macro: .fat)]
    }
}

struct NutritionTrendPoint: Identifiable {
    let date: Date
    let value: Double?
    var id: Date { date }
}

struct NutritionFoodContribution: Identifiable {
    let foodName: String
    let value: Double
    var id: String { foodName }
}

enum NutritionDateRange {
    static func count(_ period: NutritionStore.TimePeriod) -> Int {
        switch period { case .daily: 1; case .weekly: 7; case .monthly: 30 }
    }
    static func offset(_ date: Date, days: Int, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: date)) ?? date
    }
    static func start(ending date: Date, days: Int, calendar: Calendar = .current) -> Date {
        offset(date, days: 1 - max(1, days), calendar: calendar)
    }
    static func next(_ date: Date, direction: Int, days: Int, today: Date = .now, calendar: Calendar = .current) -> Date {
        min(calendar.startOfDay(for: today), offset(date, days: direction * days, calendar: calendar))
    }
    static func label(ending date: Date, days: Int) -> String {
        if days == 1 {
            if Calendar.current.isDateInToday(date) { return "Today" }
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return "\(start(ending: date, days: days).formatted(.dateTime.month(.abbreviated).day())) – \(date.formatted(.dateTime.month(.abbreviated).day()))"
    }
}

/// Views reconstruct this from @Query each render, so edits and CloudKit inserts
/// affect calendar cells, totals, charts and drill-downs through one data path.
struct NutritionAnalytics {
    let calendar: Calendar
    let entriesByDate: [Date: [NutritionEntry]]
    let valuesByDate: [Date: [String: Double]]
    let trackedMicros: [NutritionMetric]

    init(logs: [DailyLog], calendar: Calendar = .current, foodName: String? = nil,
         micronutrientGoals: [String: Double] = [:]) {
        self.calendar = calendar
        let preferred = JournalDayData.preferredLogs(from: logs, calendar: calendar)
        var days: [Date: [NutritionEntry]] = [:]
        var totals: [Date: [String: Double]] = [:]
        var metrics: [String: NutritionMetric] = [:]
        for (date, log) in preferred {
            // A mirrored/merged relationship must not count one UUID twice.
            var seen = Set<UUID>()
            let entries = log.safeEntries.filter {
                (foodName == nil || $0.name == foodName) && seen.insert($0.id).inserted
            }
            days[date] = entries
            var values: [String: Double] = [:]
            for entry in entries {
                for (id, value) in [("macro:calories", entry.calories), ("macro:protein", entry.protein),
                                    ("macro:carbs", entry.carbs), ("macro:fat", entry.fat)] where value.isFinite && value >= 0 {
                    values[id, default: 0] += value
                }
                for (metric, value) in Self.micros(in: entry, overrides: micronutrientGoals) {
                    metrics[metric.id] = metric
                    values[metric.id, default: 0] += value
                }
            }
            totals[date] = values
        }
        entriesByDate = days
        valuesByDate = totals
        trackedMicros = metrics.values.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }

    func entries(on date: Date) -> [NutritionEntry] {
        entriesByDate[calendar.startOfDay(for: date)] ?? []
    }

    func series(_ metric: NutritionMetric, ending date: Date, days: Int) -> [NutritionTrendPoint] {
        (0..<max(1, days)).map { slot in
            let day = NutritionDateRange.offset(date, days: slot + 1 - max(1, days), calendar: calendar)
            return NutritionTrendPoint(date: day, value: valuesByDate[day]?[metric.id])
        }
    }

    /// Missing days/nutrients are unknown, not zero intake. Recorded zero stays
    /// in the denominator. The UI displays coverage beside each average.
    static func average(_ points: [NutritionTrendPoint]) -> Double? {
        let values = points.compactMap(\.value)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    func contributions(_ metric: NutritionMetric, ending date: Date, days: Int) -> [NutritionFoodContribution] {
        let series = series(metric, ending: date, days: days)
        let denominator = series.compactMap(\.value).count
        guard denominator > 0 else { return [] }
        var grouped: [String: Double] = [:]
        for point in series {
            for entry in entries(on: point.date) {
                let value: Double?
                if let macro = metric.macro { value = macro.value(from: entry) }
                else { value = Self.micros(in: entry).first { $0.0.id == metric.id }?.1 }
                if let value, value.isFinite, value > 0 { grouped[entry.name, default: 0] += value }
            }
        }
        return grouped.map { NutritionFoodContribution(foodName: $0.key, value: $0.value / Double(denominator)) }
            .sorted { $0.value == $1.value ? $0.foodName < $1.foodName : $0.value > $1.value }
    }

    static func micros(in entry: NutritionEntry, overrides: [String: Double] = [:]) -> [(NutritionMetric, Double)] {
        var result: [(NutritionMetric, Double)] = []
        var seen = Set<String>()
        // Prefer exact canonical keys over display-name aliases within one entry.
        let keys = entry.micronutrients.keys.sorted {
            let a = KnownMicronutrients.normalize($0) == $0
            let b = KnownMicronutrients.normalize($1) == $1
            return a == b ? $0 < $1 : a
        }
        for key in keys {
            guard let raw = entry.micronutrients[key], raw.value.isFinite, raw.value >= 0 else { continue }
            let id = KnownMicronutrients.normalize(key)
            let known = KnownMicronutrients.nutrient(forID: id)
            let rawUnit = normalizedUnit(raw.unit)
            let targetUnit = known.map { normalizedUnit($0.unit) } ?? rawUnit
            let converted = convert(raw.value, from: rawUnit, to: targetUnit)
            let metric: NutritionMetric
            let value: Double
            if let known, let converted {
                metric = .known(known, overrides: overrides)
                value = converted
            } else {
                // Never sum incompatible units (e.g. IU and mcg), or invent a
                // goal for a custom nutrient. Keep the actual unit visible.
                metric = NutritionMetric(id: "custom:\(id)|\(rawUnit)",
                                         name: known.map { "\($0.name) (\(raw.unit))" } ?? key.replacingOccurrences(of: "_", with: " ").capitalized,
                                         unit: raw.unit, goal: 0)
                value = raw.value
            }
            guard value.isFinite, seen.insert(metric.id).inserted else { continue }
            result.append((metric, value))
        }
        return result
    }

    static func normalizedUnit(_ unit: String) -> String {
        let value = unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["µg", "μg", "ug"].contains(value) ? "mcg" : value
    }
    static func convert(_ value: Double, from: String, to: String) -> Double? {
        if from == to { return value }
        let mass = ["g": 1.0, "mg": 0.001, "mcg": 0.000001]
        guard let source = mass[from], let target = mass[to] else { return nil }
        return value * source / target
    }
}
