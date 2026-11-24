// AGPL-3.0 License

import AppIntents
import Foundation
import SwiftData
import UIKit

@MainActor
final class SiriAppRuntime {
    let foodLogging: SiriFoodLoggingService
    let journalData: SiriJournalData
    let navigation: AppNavigationRouter
    let healthKit: HealthKitService

    init(foodLogging: SiriFoodLoggingService, journalData: SiriJournalData, navigation: AppNavigationRouter,
         healthKit: HealthKitService) {
        self.foodLogging = foodLogging
        self.journalData = journalData
        self.navigation = navigation
        self.healthKit = healthKit
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
