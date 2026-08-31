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
        .commands { DesignWindowCommands() }

        Window("Nutrition Design Playground — Sample Data", id: "nutrition-design") {
            NutritionWorkbench()
        }
        .defaultSize(width: 580, height: 960)
        .windowResizability(.contentMinSize)

        Window("History Design Playground — Sample Data", id: "history-design") {
            HistoryWorkbench()
        }
        .defaultSize(width: 580, height: 960)
        .windowResizability(.contentMinSize)
    }
}

private struct DesignWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandMenu("Designs") {
            Button("Journal") { openWindow(id: "journal-design") }.keyboardShortcut("1", modifiers: [.command, .option])
            Button("Nutrition") { openWindow(id: "nutrition-design") }.keyboardShortcut("2", modifiers: [.command, .option])
            Button("History") { openWindow(id: "history-design") }.keyboardShortcut("3", modifiers: [.command, .option])
        }
    }
}
