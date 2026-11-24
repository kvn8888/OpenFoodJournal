// AGPL-3.0 License

import AppIntents
import Foundation
import SwiftData
import UIKit

@MainActor
final class SiriAppRuntime {
    let foodLogging: SiriFoodLoggingService
    let navigation: AppNavigationRouter

    init(foodLogging: SiriFoodLoggingService, navigation: AppNavigationRouter) {
        self.foodLogging = foodLogging
        self.navigation = navigation
    }

    static func refreshShortcutParameters() {
        guard UIApplication.shared.isProtectedDataAvailable else { return }
        OpenFoodJournalShortcuts.updateAppShortcutParameters()
    }

    static func foodBankWasSaved(_ notification: Notification) -> Bool {
        let keys: [ModelContext.NotificationKey] = [.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers]
        return keys.contains { key in
            let identifiers = notification.userInfo?[key.rawValue] as? [PersistentIdentifier] ?? []
            return identifiers.contains { $0.entityName == Schema.entityName(for: SavedFood.self) }
        }
    }
}
