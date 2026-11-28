// OpenFoodJournal — Scan → Assistant composer handoff contracts
// AGPL-3.0 License
//
// Fixture-only: generated images, no provider calls, no SwiftData, no
// journal entries. The handoff must never send, scan, or log on its own.

import Foundation
import Testing
import UIKit
@testable import OpenFoodJournal

@MainActor
struct AssistantScanHandoffTests {
    // MARK: Fixtures

    nonisolated private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    nonisolated private static let today = Date(timeIntervalSince1970: 1_795_000_000)
    nonisolated private static let yesterday = today.addingTimeInterval(-86_400)

    nonisolated private static func image(_ name: String = "fixture") -> ChatDraftAttachment {
        ChatDraftAttachment(data: Data(name.utf8), mimeType: "image/jpeg", filename: "\(name).jpg")
    }

    nonisolated private static func pdf(_ name: String = "menu") -> ChatDraftAttachment {
        ChatDraftAttachment(data: Data(name.utf8), mimeType: "application/pdf", filename: "\(name).pdf")
    }

    private static func handoff(
        source: AssistantScanHandoffSource = .foodPhoto,
        attachments: [ChatDraftAttachment] = [image("a"), image("b")],
        lead: UUID? = nil,
        logDate: Date = today,
        context: String? = nil
    ) -> AssistantPhotoHandoff {
        AssistantPhotoHandoff(
            source: source,
            attachments: attachments,
            leadAttachmentID: lead,
            logDate: logDate,
            userContext: context,
            now: today,
            calendar: calendar
        )
    }

    // MARK: Gate and sources

    @Test("handoff ships to Preview and Debug only; Release keeps the legacy scan")
    func featureGate() {
        #expect(AssistantScanHandoffFeature.isEnabled(in: .preview))
        #expect(AssistantScanHandoffFeature.isEnabled(in: .debug))
        #expect(!AssistantScanHandoffFeature.isEnabled(in: .release))
    }

    @Test("only Scan Food and Food Label reach the Assistant; barcode stays on Open Food Facts")
    func sourceMapping() {
        #expect(AssistantScanHandoffSource(scanMode: .foodPhoto) == .foodPhoto)
        #expect(AssistantScanHandoffSource(scanMode: .label) == .nutritionLabel)
        #expect(AssistantScanHandoffSource(scanMode: .barcode) == nil)
        #expect(AssistantScanHandoffSource(scanMode: .manual) == nil)
    }

    // MARK: Suggestions

    @Test("food photo suggestions lead with macros and micronutrients")
    func foodSuggestions() {
        let suggestions = Self.handoff(source: .foodPhoto).suggestions
        #expect(suggestions.first?.prompt == "Find macros and micronutrients for this food.")
        #expect(Set(suggestions.map(\.id)).count == suggestions.count)
        #expect(suggestions.allSatisfy { !$0.prompt.contains("journal on") })
    }

    @Test("label suggestions lead with nutrition facts extraction")
    func labelSuggestions() {
        let suggestions = Self.handoff(source: .nutritionLabel).suggestions
        #expect(suggestions.first?.prompt == "Extract nutrition facts from this label.")
        #expect(suggestions.contains { $0.id == "label.micros" })
    }

    @Test("scan context text and a non-today journal date carry into prompts")
    func contextAndDateCarryThrough() {
        let handoff = Self.handoff(logDate: Self.yesterday, context: "  walnut shrimp \n")
        #expect(handoff.userContext == "walnut shrimp")
        let first = handoff.suggestions.first
        #expect(first?.prompt.contains("(walnut shrimp)") == true)
        #expect(first?.prompt.contains("This is for my journal on") == true)
        #expect(handoff.suggestions.last?.prompt.contains("today") == false)
    }

    @Test("blank scan context is dropped instead of producing empty parentheses")
    func blankContext() {
        let handoff = Self.handoff(context: "   ")
        #expect(handoff.userContext == nil)
        #expect(handoff.suggestions.allSatisfy { !$0.prompt.contains("()") })
    }

    // MARK: Payload identity

    @Test("lead attachment defaults to the first photo and rejects foreign IDs")
    func leadAttachment() {
        let a = Self.image("a")
        let b = Self.image("b")
        #expect(Self.handoff(attachments: [a, b]).leadAttachmentID == a.id)
        #expect(Self.handoff(attachments: [a, b], lead: b.id).leadAttachmentID == b.id)
        #expect(Self.handoff(attachments: [a, b], lead: UUID()).leadAttachmentID == a.id)
    }

    // MARK: Router

    @Test("photo handoffs are consume-once and independent of Siri text handoffs")
    func routerConsumeOnce() throws {
        let router = AppNavigationRouter()
        let handoff = Self.handoff()
        router.openAssistant(withPhotos: handoff, environment: .preview)
        #expect(router.pendingAssistantHandoff == nil)
        #expect(router.pendingAssistantPhotoHandoff?.id == handoff.id)

        let taken = try #require(router.takeAssistantPhotoHandoff())
        #expect(taken.attachmentIDs == handoff.attachmentIDs)
        #expect(router.takeAssistantPhotoHandoff() == nil)

        router.openAssistant(with: "Log a bowl of soup")
        #expect(router.pendingAssistantPhotoHandoff == nil)
        #expect(router.takeAssistantPrompt() == "Log a bowl of soup")
    }

    @Test("Release builds and empty payloads never stage a photo handoff")
    func routerRejectsReleaseAndEmpty() {
        let router = AppNavigationRouter()
        router.openAssistant(withPhotos: Self.handoff(), environment: .release)
        #expect(router.pendingAssistantPhotoHandoff == nil)
        router.openAssistant(withPhotos: Self.handoff(attachments: []), environment: .preview)
        #expect(router.pendingAssistantPhotoHandoff == nil)
    }

    // MARK: Composer rules

    @Test("an active run, unsent draft, or empty thread keeps the current composer")
    func placement() {
        typealias R = AssistantComposerHandoffReducer
        #expect(R.placement(isStreaming: true, threadHasMessages: true, composerHasContent: false) == .currentComposer)
        #expect(R.placement(isStreaming: false, threadHasMessages: false, composerHasContent: false) == .currentComposer)
        #expect(R.placement(isStreaming: false, threadHasMessages: true, composerHasContent: true) == .currentComposer)
        #expect(R.placement(isStreaming: false, threadHasMessages: true, composerHasContent: false) == .startNewThread)
    }

    @Test("merge appends after existing attachments and skips duplicate IDs")
    func mergeDeduplicates() {
        let existing = Self.image("existing")
        let incoming = Self.image("scan")
        let first = AssistantComposerHandoffReducer.merge([incoming], into: [existing], maximumImages: 4)
        #expect(first.attachments.map(\.id) == [existing.id, incoming.id])
        #expect(first.addedIDs == [incoming.id])

        let replay = AssistantComposerHandoffReducer.merge([incoming], into: first.attachments, maximumImages: 4)
        #expect(replay.attachments.map(\.id) == [existing.id, incoming.id])
        #expect(replay.addedIDs.isEmpty)
        #expect(replay.droppedCount == 0)
    }

    @Test("merge honours the image limit without counting PDFs")
    func mergeLimit() {
        let staged = [Self.pdf(), Self.image("1"), Self.image("2"), Self.image("3")]
        let incoming = [Self.image("4"), Self.image("5"), Self.image("6")]
        let result = AssistantComposerHandoffReducer.merge(incoming, into: staged, maximumImages: 4)
        #expect(result.addedIDs == [incoming[0].id])
        #expect(result.droppedCount == 2)
        #expect(result.attachments.filter(\.isImage).count == 4)
        #expect(result.attachments.count == 5)
    }

    @Test("draft keeps user text and otherwise carries scan context")
    func draftRules() {
        #expect(AssistantComposerHandoffReducer.draft(existing: "half portion", userContext: "ramen") == "half portion")
        #expect(AssistantComposerHandoffReducer.draft(existing: "", userContext: "ramen") == "ramen")
        #expect(AssistantComposerHandoffReducer.draft(existing: "  ", userContext: nil) == "  ")
    }

    @Test("VoiceOver announcement reports added and dropped photos")
    func announcement() {
        let text = AssistantComposerHandoffReducer.announcement(addedCount: 2, droppedCount: 1)
        #expect(text.contains("2 photos added"))
        #expect(text.contains("1 not added"))
        #expect(!AssistantComposerHandoffReducer.announcement(addedCount: 1, droppedCount: 0).contains("not added"))
    }

    @Test("scan context is visible only while one of its photos is still staged")
    func contextVisibility() {
        let scan = Self.image("scan")
        let other = Self.image("other")
        let context = AssistantComposerScanContext(
            handoffID: UUID(), source: .foodPhoto, attachmentIDs: [scan.id], suggestions: [], droppedCount: 0
        )
        #expect(context.isVisible(with: [other, scan]))
        #expect(!context.isVisible(with: [other]))
    }

    // MARK: Encoding

    @Test("encoder produces upright, capped JPEG uploads with stable lead identity")
    func encoder() async throws {
        let large = AssistantScanHandoffFixture.image(seed: 0, size: CGSize(width: 2400, height: 1800))
        let small = AssistantScanHandoffFixture.image(seed: 1)
        let payload = await AssistantPhotoHandoffEncoder.prepare(images: [small, large], leadIndex: 1)

        #expect(payload.attachments.count == 2)
        #expect(payload.attachments.allSatisfy { $0.mimeType == "image/jpeg" && $0.isImage })
        #expect(payload.leadAttachmentID == payload.attachments[1].id)
        #expect(payload.transitionSnapshot != nil)

        let decoded = try #require(UIImage(data: payload.attachments[1].data)?.cgImage)
        #expect(max(decoded.width, decoded.height) == Int(AssistantPhotoHandoffEncoder.maxUploadDimension))
        let snapshot = try #require(payload.transitionSnapshot?.cgImage)
        #expect(max(snapshot.width, snapshot.height) <= Int(AssistantPhotoHandoffEncoder.snapshotDimension))
    }

    // MARK: Transition plan

    @Test("Reduce Motion and unusable geometry fall back to a direct reveal")
    func flightFallbacks() {
        let screen = CGRect(x: 0, y: 0, width: 402, height: 874)
        let source = CGRect(x: 40, y: 200, width: 320, height: 240)
        let target = CGRect(x: 16, y: 700, width: 64, height: 64)
        typealias Plan = AssistantAttachmentFlightPlan

        #expect(Plan.make(source: source, target: target, container: screen, reduceMotion: true).style == .crossfade)
        #expect(Plan.make(source: source, target: nil, container: screen, reduceMotion: false).style == .crossfade)
        #expect(Plan.make(source: nil, target: target, container: screen, reduceMotion: false).style == .crossfade)
        #expect(Plan.make(source: source, target: .zero, container: screen, reduceMotion: false).style == .crossfade)
        let offscreen = target.offsetBy(dx: 0, dy: 2_000)
        #expect(Plan.make(source: source, target: offscreen, container: screen, reduceMotion: false).style == .crossfade)
        let nanRect = CGRect(x: CGFloat.nan, y: 0, width: 64, height: 64)
        #expect(Plan.make(source: source, target: nanRect, container: screen, reduceMotion: false).style == .crossfade)
    }

    @Test("a real flight arcs inside the screen within the motion budget")
    func flightPlan() {
        let screen = CGRect(x: 0, y: 0, width: 402, height: 874)
        let source = CGRect(x: 40, y: 200, width: 320, height: 240)
        let target = CGRect(x: 16, y: 700, width: 64, height: 64)
        let plan = AssistantAttachmentFlightPlan.make(source: source, target: target, container: screen, reduceMotion: false)

        #expect(plan.style == .flight)
        #expect(plan.target == target)
        #expect(screen.contains(plan.arcControlPoint))
        #expect(plan.duration >= AssistantAttachmentFlightPlan.minimumDuration)
        #expect(plan.duration <= AssistantAttachmentFlightPlan.maximumDuration)
        // The arc bows off the straight line rather than sliding along it.
        let mid = CGPoint(x: (source.midX + target.midX) / 2, y: (source.midY + target.midY) / 2)
        #expect(hypot(plan.arcControlPoint.x - mid.x, plan.arcControlPoint.y - mid.y) > 20)
    }

    @Test("target frames must repeat before the flight starts")
    func frameStability() {
        let rect = CGRect(x: 16, y: 700, width: 64, height: 64)
        #expect(AssistantAttachmentFlightPlan.isStable(rect, rect.offsetBy(dx: 0.2, dy: 0)))
        #expect(!AssistantAttachmentFlightPlan.isStable(rect, rect.offsetBy(dx: 0, dy: 12)))
        #expect(!AssistantAttachmentFlightPlan.isStable(nil, rect))
        #expect(!AssistantAttachmentFlightPlan.isStable(.zero, .zero))
    }

    // MARK: Coordinator state

    @Test("without a staged flight the composer tile is never concealed")
    func coordinatorWithoutStage() {
        let coordinator = AssistantAttachmentTransitionCoordinator()
        coordinator.land(handoffID: UUID(), on: UUID())
        #expect(coordinator.concealedAttachmentID == nil)
        #expect(coordinator.phase == .idle)
    }

    @Test("Reduce Motion or a missing source anchor reveals the tile immediately")
    func coordinatorFallbackReveal() {
        let coordinator = AssistantAttachmentTransitionCoordinator()
        coordinator.reduceMotion = { true }
        let handoffID = UUID()
        coordinator.stage(handoffID: handoffID, snapshot: AssistantScanHandoffFixture.image(seed: 0), cornerRadius: 16)
        #expect(coordinator.phase == .staged(handoffID: handoffID))

        coordinator.land(handoffID: UUID(), on: UUID())
        #expect(coordinator.phase == .staged(handoffID: handoffID), "a different handoff must not consume this stage")

        coordinator.land(handoffID: handoffID, on: UUID())
        #expect(coordinator.concealedAttachmentID == nil)
        #expect(coordinator.phase == .idle)
    }

    @Test("cancel always returns to idle with nothing concealed")
    func coordinatorCancel() {
        let coordinator = AssistantAttachmentTransitionCoordinator()
        coordinator.reduceMotion = { false }
        let handoffID = UUID()
        coordinator.stage(handoffID: handoffID, snapshot: nil, cornerRadius: 16)
        coordinator.cancel()
        #expect(coordinator.phase == .idle)
        #expect(coordinator.concealedAttachmentID == nil)
        coordinator.cancel()
        #expect(coordinator.phase == .idle)
    }

    // MARK: Debug fixture

    @Test("debug launch fixture parses its source and builds a two-photo handoff")
    func debugFixture() {
        #expect(AssistantScanHandoffFixture.requestedSource(arguments: ["app"]) == nil)
        #expect(AssistantScanHandoffFixture.requestedSource(arguments: ["app", "-ofj-fixture-scan-handoff"]) == .foodPhoto)
        #expect(AssistantScanHandoffFixture.requestedSource(arguments: ["app", "-ofj-fixture-scan-handoff", "label"]) == .nutritionLabel)
        let handoff = AssistantScanHandoffFixture.handoff(source: .nutritionLabel)
        #expect(handoff.attachments.count == 2)
        #expect(handoff.source == .nutritionLabel)
    }
}
