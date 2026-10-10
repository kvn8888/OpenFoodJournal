// Macros — Food Journaling App
// AGPL-3.0 License

import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
final class UserGoals {
    // @AppStorage conflicts with @Observable — must be @ObservationIgnored
    @ObservationIgnored @AppStorage("goals.calories") var dailyCalories: Double = 2000
    @ObservationIgnored @AppStorage("goals.protein") var dailyProtein: Double = 150
    @ObservationIgnored @AppStorage("goals.carbs") var dailyCarbs: Double = 200
    @ObservationIgnored @AppStorage("goals.fat") var dailyFat: Double = 65

    /// Deliberately not @AppStorage. These are edited on one screen and read on
    /// several others, so they have to notify observers; an @ObservationIgnored
    /// property would leave every ring and progress row showing the old target
    /// until its view happened to rebuild for another reason.
    var micronutrientOverrides: [String: Double] {
        didSet { MicronutrientGoalSettings.write(micronutrientOverrides, to: defaults) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // didSet does not fire during init, so this loads without rewriting.
        self.micronutrientOverrides = MicronutrientGoalSettings.overrides(in: defaults)
    }

    /// The daily target for a nutrient: the user's own, or the FDA Daily Value.
    func dailyValue(for nutrient: KnownMicronutrient) -> Double {
        MicronutrientGoalSettings.dailyValue(for: nutrient, overrides: micronutrientOverrides)
    }

    func isOverridden(_ nutrient: KnownMicronutrient) -> Bool {
        MicronutrientGoalSettings.isOverridden(nutrient, overrides: micronutrientOverrides)
    }

    func setDailyValue(_ value: Double?, for nutrient: KnownMicronutrient) {
        var next = micronutrientOverrides
        if let value, value.isFinite, value > 0 {
            next[nutrient.id] = value
        } else {
            next.removeValue(forKey: nutrient.id)
        }
        micronutrientOverrides = next
    }

    func resetAllMicronutrientGoals() {
        micronutrientOverrides = [:]
    }
}
