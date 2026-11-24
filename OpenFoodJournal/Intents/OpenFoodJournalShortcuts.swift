// AGPL-3.0 License

import AppIntents

nonisolated struct OpenFoodJournalShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LogFoodBankItemIntent(),
            phrases: [
                "Log \(\.$food) in \(.applicationName)",
                "Add \(\.$food) to \(.applicationName)"
            ],
            shortTitle: "Log Food Bank Item",
            systemImageName: "refrigerator"
        )
        AppShortcut(
            intent: LogFoodWithSiriIntent(),
            phrases: [
                "Log food in \(.applicationName)",
                "Log a meal in \(.applicationName)",
                "Track food in \(.applicationName)"
            ],
            shortTitle: "Log Food",
            systemImageName: "fork.knife"
        )
        AppShortcut(
            intent: OpenAssistantFoodLogIntent(),
            phrases: ["Ask \(.applicationName) Assistant to log food"],
            shortTitle: "Ask Assistant to Log",
            systemImageName: "sparkles"
        )
    }
}
