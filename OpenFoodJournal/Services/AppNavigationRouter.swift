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

    /// Scan photos waiting for the Assistant composer. Kept separate from the
    /// text handoff on purpose: Siri prompts auto-submit, scan photos never do.
    private(set) var pendingAssistantPhotoHandoff: AssistantPhotoHandoff?

    /// Shared-element transition state for scan → composer handoffs. Lives on
    /// the router because both ends (the scan sheet and the Assistant tab)
    /// already receive the router through the environment.
    let attachmentTransition = AssistantAttachmentTransitionCoordinator()

    func openAssistant(with prompt: String) {
        pendingAssistantHandoff = AssistantHandoff(prompt: prompt)
    }

    func takeAssistantPrompt() -> String? {
        let prompt = pendingAssistantHandoff?.prompt
        pendingAssistantHandoff = nil
        return prompt
    }

    /// Stages scan photos for the composer. Release builds ignore the call so
    /// the legacy scan path remains the only production behavior.
    func openAssistant(
        withPhotos handoff: AssistantPhotoHandoff,
        environment: OFJBuildEnvironment? = nil
    ) {
        guard AssistantScanHandoffFeature.isEnabled(in: environment ?? .current),
              !handoff.attachments.isEmpty
        else { return }
        pendingAssistantPhotoHandoff = handoff
    }

    /// Consume-once: a second caller (tab re-selection, duplicate onChange)
    /// gets nil, so photos are never staged twice.
    func takeAssistantPhotoHandoff() -> AssistantPhotoHandoff? {
        let handoff = pendingAssistantPhotoHandoff
        pendingAssistantPhotoHandoff = nil
        return handoff
    }
}
