// AGPL-3.0 License

import Foundation
import Observation

@MainActor
@Observable
final class AppNavigationRouter {
    struct AssistantHandoff: Equatable {
        let id = UUID()
        let prompt: String
    }

    private(set) var pendingAssistantHandoff: AssistantHandoff?

    func openAssistant(with prompt: String) {
        pendingAssistantHandoff = AssistantHandoff(prompt: prompt)
    }

    func takeAssistantPrompt() -> String? {
        let prompt = pendingAssistantHandoff?.prompt
        pendingAssistantHandoff = nil
        return prompt
    }
}
