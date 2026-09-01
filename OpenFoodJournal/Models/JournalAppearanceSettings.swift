import Foundation

/// Display-only preference. Showing existing images never opts into generation.
enum JournalAppearanceSettings {
    static let showFoodImagesKey = "journal.showFoodImages"
    static let defaultShowFoodImages = true

    static func showFoodImages(in defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: showFoodImagesKey) as? Bool) ?? defaultShowFoodImages
    }
}
