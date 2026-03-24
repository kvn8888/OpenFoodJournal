// Macros — Food Journaling App
// AGPL-3.0 License
//
// Preferences — SwiftData model for persisting user customization choices.
// Singleton pattern: exactly one row exists in the store. Use
// Preferences.current(in:) to get-or-create it.

import SwiftData
import Foundation

@Model
final class Preferences {
    // ── Summary Bar Ring Slots ────────────────────────────────────
    // Each slot stores a nutrient ID string:
    //   - Macros: "macro_protein", "macro_carbs", "macro_fat", "macro_calories"
    //   - Micros: any KnownMicronutrient ID like "sodium", "fiber"
    //   - Empty string = unassigned (shows + button)
    var ringSlot1: String = "macro_protein"
    var ringSlot2: String = "macro_carbs"
    var ringSlot3: String = "macro_fat"
    var ringSlot4: String = ""
    var ringSlot5: String = ""

    // ── Timestamps ────────────────────────────────────────────────
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init() {}

    // MARK: - Singleton Access

    /// Fetches the single Preferences row, creating one with defaults if none exists.
    @MainActor
    static func current(in context: ModelContext) -> Preferences {
        let descriptor = FetchDescriptor<Preferences>()
        if let existing = try? context.fetch(descriptor).first {
            return existing
        }
        let prefs = Preferences()
        context.insert(prefs)
        return prefs
    }
}
