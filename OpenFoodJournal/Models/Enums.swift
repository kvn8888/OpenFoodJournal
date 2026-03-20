// Macros — Food Journaling App
// AGPL-3.0 License

import Foundation

// MARK: - MealType

enum MealType: String, Codable, CaseIterable, Identifiable {
    case breakfast = "Breakfast"
    case lunch = "Lunch"
    case dinner = "Dinner"
    case snack = "Snack"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .breakfast: "sunrise"
        case .lunch: "sun.max"
        case .dinner: "moon.stars"
        case .snack: "leaf"
        }
    }
}

// MARK: - ScanMode

enum ScanMode: String, Codable, CaseIterable {
    case label = "Label Scan"
    case foodPhoto = "Food Photo"
    case manual = "Manual"

    var isEstimate: Bool {
        self == .foodPhoto
    }
}
