//
//  OpenFoodJournalApp.swift
//  OpenFoodJournal
//
//  Created by Kevin Chen on 3/19/26.
//

import SwiftUI
import CoreData

@main
struct OpenFoodJournalApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
