// Deliberately not the OpenFoodJournal app: no services, stores, or entitlements.
import SwiftUI

@main
struct JournalPlaygroundApp: App {
    var body: some Scene {
        Window("Journal Design Playground — Sample Data", id: "journal-design") {
            JournalWorkbench()
        }
        .defaultSize(width: 580, height: 960)
        .windowResizability(.contentMinSize)
    }
}
