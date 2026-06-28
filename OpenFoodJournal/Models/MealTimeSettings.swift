// OpenFoodJournal — Food Journaling App
// AGPL-3.0 License

import Foundation
import Observation
import SwiftUI

enum MealScheduleDefaults {
    nonisolated static let breakfastStartMinutes = 2 * 60
    nonisolated static let lunchStartMinutes = 12 * 60
    nonisolated static let dinnerStartMinutes = 18 * 60
    nonisolated static let minutesPerDay = 24 * 60
}

@Observable
@MainActor
final class MealTimeSettings {
    nonisolated static let defaultBreakfastStartMinutes = MealScheduleDefaults.breakfastStartMinutes
    nonisolated static let defaultLunchStartMinutes = MealScheduleDefaults.lunchStartMinutes
    nonisolated static let defaultDinnerStartMinutes = MealScheduleDefaults.dinnerStartMinutes
    nonisolated static let minutesPerDay = MealScheduleDefaults.minutesPerDay

    @ObservationIgnored @AppStorage("mealSchedule.breakfastStartMinutes")
    private var storedBreakfastStartMinutes: Int = MealTimeSettings.defaultBreakfastStartMinutes
    @ObservationIgnored @AppStorage("mealSchedule.lunchStartMinutes")
    private var storedLunchStartMinutes: Int = MealTimeSettings.defaultLunchStartMinutes
    @ObservationIgnored @AppStorage("mealSchedule.dinnerStartMinutes")
    private var storedDinnerStartMinutes: Int = MealTimeSettings.defaultDinnerStartMinutes

    private(set) var changeCount = 0

    var breakfastStartMinutes: Int {
        get {
            _ = changeCount
            return normalizedStarts.breakfast
        }
        set {
            let starts = normalizedStarts
            storedBreakfastStartMinutes = Self.clamp(newValue, min: 0, max: starts.lunch - 1)
            bump()
        }
    }

    var lunchStartMinutes: Int {
        get {
            _ = changeCount
            return normalizedStarts.lunch
        }
        set {
            let starts = normalizedStarts
            storedLunchStartMinutes = Self.clamp(newValue, min: starts.breakfast + 1, max: starts.dinner - 1)
            bump()
        }
    }

    var dinnerStartMinutes: Int {
        get {
            _ = changeCount
            return normalizedStarts.dinner
        }
        set {
            let starts = normalizedStarts
            storedDinnerStartMinutes = Self.clamp(newValue, min: starts.lunch + 1, max: Self.minutesPerDay - 1)
            bump()
        }
    }

    var isDefaultSchedule: Bool {
        _ = changeCount
        let starts = normalizedStarts
        return starts.breakfast == Self.defaultBreakfastStartMinutes &&
            starts.lunch == Self.defaultLunchStartMinutes &&
            starts.dinner == Self.defaultDinnerStartMinutes
    }

    private var normalizedStarts: (breakfast: Int, lunch: Int, dinner: Int) {
        let breakfast = Self.clamp(storedBreakfastStartMinutes, min: 0, max: Self.minutesPerDay - 3)
        let lunch = Self.clamp(storedLunchStartMinutes, min: breakfast + 1, max: Self.minutesPerDay - 2)
        let dinner = Self.clamp(storedDinnerStartMinutes, min: lunch + 1, max: Self.minutesPerDay - 1)
        return (breakfast, lunch, dinner)
    }

    func mealType(for date: Date = .now, calendar: Calendar = .autoupdatingCurrent) -> MealType {
        _ = changeCount
        return Self.mealType(
            forMinuteOfDay: minuteOfDay(from: date, calendar: calendar),
            breakfastStartMinutes: breakfastStartMinutes,
            lunchStartMinutes: lunchStartMinutes,
            dinnerStartMinutes: dinnerStartMinutes
        )
    }

    nonisolated static func mealType(
        forMinuteOfDay minute: Int,
        breakfastStartMinutes: Int = defaultBreakfastStartMinutes,
        lunchStartMinutes: Int = defaultLunchStartMinutes,
        dinnerStartMinutes: Int = defaultDinnerStartMinutes
    ) -> MealType {
        let minute = clamp(minute, min: 0, max: minutesPerDay - 1)

        if minute >= breakfastStartMinutes && minute < lunchStartMinutes {
            return .breakfast
        }

        if minute >= lunchStartMinutes && minute < dinnerStartMinutes {
            return .lunch
        }

        return .dinner
    }

    func resetToDefaults() {
        storedBreakfastStartMinutes = Self.defaultBreakfastStartMinutes
        storedLunchStartMinutes = Self.defaultLunchStartMinutes
        storedDinnerStartMinutes = Self.defaultDinnerStartMinutes
        bump()
    }

    func date(forMinuteOfDay minutes: Int, calendar: Calendar = .autoupdatingCurrent) -> Date {
        let minutes = Self.clamp(minutes, min: 0, max: Self.minutesPerDay - 1)
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = 2001
        components.month = 1
        components.day = 1
        components.hour = minutes / 60
        components.minute = minutes % 60
        components.second = 0
        return calendar.date(from: components) ?? Date(timeIntervalSinceReferenceDate: TimeInterval(minutes * 60))
    }

    func minuteOfDay(from date: Date, calendar: Calendar = .autoupdatingCurrent) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return Self.minuteOfDay(hour: components.hour ?? 0, minute: components.minute ?? 0)
    }

    func rangeText(for mealType: MealType) -> String {
        switch mealType {
        case .breakfast:
            "\(formattedTime(breakfastStartMinutes)) – \(formattedTime(lunchStartMinutes))"
        case .lunch:
            "\(formattedTime(lunchStartMinutes)) – \(formattedTime(dinnerStartMinutes))"
        case .dinner:
            "\(formattedTime(dinnerStartMinutes)) – \(formattedTime(breakfastStartMinutes))"
        case .snack:
            "Manual override"
        }
    }

    private func formattedTime(_ minutes: Int) -> String {
        date(forMinuteOfDay: minutes).formatted(date: .omitted, time: .shortened)
    }

    nonisolated private static func minuteOfDay(hour: Int, minute: Int) -> Int {
        clamp(hour, min: 0, max: 23) * 60 + clamp(minute, min: 0, max: 59)
    }

    nonisolated private static func clamp(_ value: Int, min minimum: Int, max maximum: Int) -> Int {
        Swift.min(Swift.max(value, minimum), maximum)
    }

    private func bump() {
        changeCount += 1
    }
}
