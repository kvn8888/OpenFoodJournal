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
}
