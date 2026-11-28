// OpenFoodJournal — Scan → Assistant composer handoff
// AGPL-3.0 License
//
// Value types and pure rules for moving Journal scan photos into the
// Assistant composer. Nothing in this file sends a request, writes to the
// journal, or touches SwiftData: the handoff only stages draft attachments
// that the user reviews and sends themselves.

import Foundation
import UIKit

// MARK: - Feature gate

/// The scan → Assistant handoff ships to the isolated Preview (UAT) lane
/// first. Debug keeps it on so unit tests and `OFJ Dev` can exercise the same
/// code; Release keeps the legacy one-tap Gemini scan path untouched.
enum AssistantScanHandoffFeature {
    static func isEnabled(in environment: OFJBuildEnvironment? = nil) -> Bool {
        (environment ?? .current) != .release
    }
}

// MARK: - Handoff payload

/// Which scan mode produced the photos. Barcode is intentionally absent: it
/// keeps its direct Open Food Facts lookup and never reaches the Assistant.
enum AssistantScanHandoffSource: String, Sendable, Equatable, CaseIterable {
    case foodPhoto
    case nutritionLabel

    init?(scanMode: ScanMode) {
        switch scanMode {
        case .foodPhoto: self = .foodPhoto
        case .label: self = .nutritionLabel
        case .barcode, .manual: return nil
        }
    }

    var title: String {
        switch self {
        case .foodPhoto: "Scan Food"
        case .nutritionLabel: "Food Label"
        }
    }

    var symbol: String {
        switch self {
        case .foodPhoto: "viewfinder"
        case .nutritionLabel: "doc.text.viewfinder"
        }
    }
}

/// A tappable starter prompt shown above the composer after a scan handoff.
/// Tapping one only fills the draft; it never sends.
struct AssistantComposerSuggestion: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let prompt: String
    let symbol: String
}

/// One scan's worth of photos on its way to the Assistant composer.
struct AssistantPhotoHandoff: Identifiable, Sendable {
    let id: UUID
    let source: AssistantScanHandoffSource
    /// Already downscaled to the Assistant's upload policy. Attachment IDs are
    /// minted once here and stay stable through staging, the transition, and
    /// the composer so duplicate delivery can be detected by identity.
    let attachments: [ChatDraftAttachment]
    /// The attachment the shared-element transition lands on (the photo the
    /// user was looking at when they tapped Ask Assistant).
    let leadAttachmentID: UUID?
    /// The Journal day the scan was opened from, so prompts can say which
    /// day the user is planning for when it is not today.
    let logDate: Date
    /// Optional free text typed on the scan review screen ("walnut shrimp").
    let userContext: String?
    let suggestions: [AssistantComposerSuggestion]

    init(
        id: UUID = UUID(),
        source: AssistantScanHandoffSource,
        attachments: [ChatDraftAttachment],
        leadAttachmentID: UUID? = nil,
        logDate: Date,
        userContext: String?,
        now: Date = .now,
        calendar: Calendar = .current
    ) {
        let trimmedContext = userContext?.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = (trimmedContext?.isEmpty ?? true) ? nil : trimmedContext
        self.id = id
        self.source = source
        self.attachments = attachments
        self.leadAttachmentID = leadAttachmentID.flatMap { lead in
            attachments.contains { $0.id == lead } ? lead : nil
        } ?? attachments.first?.id
        self.logDate = logDate
        self.userContext = context
        self.suggestions = AssistantScanSuggestionCatalog.suggestions(
            for: source,
            userContext: context,
            logDate: logDate,
            now: now,
            calendar: calendar
        )
    }

    var attachmentIDs: [UUID] { attachments.map(\.id) }
}

extension AssistantPhotoHandoff: Equatable {
    /// Identity equality keeps `onChange` cheap and avoids comparing image
    /// payloads byte-for-byte.
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

// MARK: - Suggestions

enum AssistantScanSuggestionCatalog {
    static func suggestions(
        for source: AssistantScanHandoffSource,
        userContext: String?,
        logDate: Date,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [AssistantComposerSuggestion] {
        let subject = userContext.map { " (\($0))" } ?? ""
        let isToday = calendar.isDate(logDate, inSameDayAs: now)
        let dayPhrase = isToday ? "today" : "on \(dayLabel(logDate))"
        // Only mention the day when it differs from today; otherwise the
        // extra sentence is noise in every prompt.
        let dayNote = isToday ? "" : " This is for my journal \(dayPhrase)."

        switch source {
        case .foodPhoto:
            return [
                AssistantComposerSuggestion(
                    id: "food.nutrients",
                    title: "Find macros & micronutrients",
                    prompt: "Find macros and micronutrients for this food\(subject).\(dayNote)",
                    symbol: "list.bullet.rectangle"
                ),
                AssistantComposerSuggestion(
                    id: "food.portion",
                    title: "Estimate the portion",
                    prompt: "Estimate the portion size and calories in this photo\(subject).\(dayNote)",
                    symbol: "scalemass"
                ),
                AssistantComposerSuggestion(
                    id: "food.goals",
                    title: "Fit with my goals",
                    prompt: "How would this food\(subject) fit my nutrition goals \(dayPhrase)?",
                    symbol: "target"
                ),
            ]
        case .nutritionLabel:
            return [
                AssistantComposerSuggestion(
                    id: "label.extract",
                    title: "Extract nutrition facts",
                    prompt: "Extract nutrition facts from this label\(subject).\(dayNote)",
                    symbol: "doc.text.magnifyingglass"
                ),
                AssistantComposerSuggestion(
                    id: "label.micros",
                    title: "List vitamins & minerals",
                    prompt: "List the vitamins and minerals on this label\(subject) with their % Daily Value.",
                    symbol: "leaf"
                ),
                AssistantComposerSuggestion(
                    id: "label.serving",
                    title: "One serving vs. my goals",
                    prompt: "How does one serving of this\(subject) fit my nutrition goals \(dayPhrase)?",
                    symbol: "target"
                ),
            ]
        }
    }

    static func dayLabel(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
}

// MARK: - Composer rules

enum AssistantPhotoHandoffPlacement: Equatable {
    /// The current conversation already has messages and the composer is
    /// empty, so the scan starts a fresh conversation.
    case startNewThread
    /// Stage into whatever composer is on screen — an in-flight run, an
    /// unsent draft, or an empty conversation must never be disturbed.
    case currentComposer
}

struct AssistantComposerMergeResult {
    let attachments: [ChatDraftAttachment]
    let addedIDs: [UUID]
    /// Photos that did not fit under the composer's image limit.
    let droppedCount: Int
}

enum AssistantComposerHandoffReducer {
    static func placement(
        isStreaming: Bool,
        threadHasMessages: Bool,
        composerHasContent: Bool
    ) -> AssistantPhotoHandoffPlacement {
        // Never start a new thread while a run is active: it would orphan the
        // live run card and the user's view of it.
        if isStreaming || !threadHasMessages || composerHasContent {
            return .currentComposer
        }
        return .startNewThread
    }

    /// Appends incoming photos after any attachments the user already
    /// staged, skipping duplicates by attachment ID and honouring the image
    /// limit (PDFs do not count toward it).
    static func merge(
        _ incoming: [ChatDraftAttachment],
        into existing: [ChatDraftAttachment],
        maximumImages: Int
    ) -> AssistantComposerMergeResult {
        var result = existing
        var knownIDs = Set(existing.map(\.id))
        var imageCount = existing.lazy.filter(\.isImage).count
        var added: [UUID] = []
        var dropped = 0

        for attachment in incoming {
            guard !knownIDs.contains(attachment.id) else { continue }
            if attachment.isImage {
                guard imageCount < maximumImages else {
                    dropped += 1
                    continue
                }
                imageCount += 1
            }
            knownIDs.insert(attachment.id)
            result.append(attachment)
            added.append(attachment.id)
        }
        return AssistantComposerMergeResult(attachments: result, addedIDs: added, droppedCount: dropped)
    }

    /// Keeps whatever the user already typed; otherwise carries the scan's
    /// optional context text so it is not silently lost.
    static func draft(existing: String, userContext: String?) -> String {
        guard existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return existing }
        return userContext ?? existing
    }

    static func announcement(addedCount: Int, droppedCount: Int) -> String {
        let added = addedCount == 1 ? "1 photo" : "\(addedCount) photos"
        var text = "\(added) added to the Assistant message. Review before sending."
        if droppedCount > 0 {
            text += " \(droppedCount) not added because of the photo limit."
        }
        return text
    }
}

/// Composer-side record of where staged photos came from. Lives in ChatView
/// state and disappears once the photos are sent or removed.
struct AssistantComposerScanContext: Equatable {
    let handoffID: UUID
    let source: AssistantScanHandoffSource
    let attachmentIDs: Set<UUID>
    let suggestions: [AssistantComposerSuggestion]
    let droppedCount: Int

    func isVisible(with attachments: [ChatDraftAttachment]) -> Bool {
        attachments.contains { attachmentIDs.contains($0.id) }
    }
}

// MARK: - Encoding

/// Prepared payload from the scan screen: upload-ready JPEGs plus an upright
/// thumbnail for the shared-element layer (CALayer ignores UIImage
/// orientation, so camera photos must be redrawn before use).
struct AssistantPhotoHandoffPayload: Sendable {
    let attachments: [ChatDraftAttachment]
    let leadAttachmentID: UUID?
    let transitionSnapshot: UIImage?
}

nonisolated enum AssistantPhotoHandoffEncoder {
    /// Mirrors `ChatService.downscaledJPEG` defaults so scan handoffs upload
    /// exactly what a photo attached from inside the Assistant would.
    static let maxUploadDimension: CGFloat = 1200
    static let uploadQuality: CGFloat = 0.8
    static let snapshotDimension: CGFloat = 640

    /// Encodes off the main actor so a four-photo handoff does not stall the
    /// review screen. Drawing through UIGraphicsImageRenderer bakes in the
    /// EXIF orientation, so uploads and the snapshot are both upright.
    static func prepare(images: [UIImage], leadIndex: Int) async -> AssistantPhotoHandoffPayload {
        await Task.detached(priority: .userInitiated) {
            var attachments: [ChatDraftAttachment] = []
            var leadID: UUID?
            var snapshot: UIImage?
            for (index, image) in images.enumerated() {
                guard let jpeg = jpegData(for: image) else { continue }
                let attachment = ChatDraftAttachment(
                    data: jpeg,
                    mimeType: "image/jpeg",
                    filename: "scan-photo-\(index + 1).jpg"
                )
                attachments.append(attachment)
                if index == leadIndex {
                    leadID = attachment.id
                    snapshot = redraw(image, maxDimension: snapshotDimension)
                }
            }
            return AssistantPhotoHandoffPayload(
                attachments: attachments,
                leadAttachmentID: leadID ?? attachments.first?.id,
                transitionSnapshot: snapshot
            )
        }.value
    }

    static func jpegData(for image: UIImage) -> Data? {
        redraw(image, maxDimension: maxUploadDimension)?.jpegData(compressionQuality: uploadQuality)
    }

    static func redraw(_ image: UIImage, maxDimension: CGFloat) -> UIImage? {
        let size = image.size
        let largest = max(size.width, size.height)
        guard largest > 0, size.width.isFinite, size.height.isFinite else { return nil }
        let scale = min(1, maxDimension / largest)
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        // Pixel-exact output: inheriting the 3x display scale would triple the
        // upload past the model's pixel budget.
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

#if DEBUG
// MARK: - Debug fixture

/// Launch with `-ofj-fixture-scan-handoff food|label` in OFJ Dev to exercise
/// the composer handoff without a camera, Photos access, or real meals.
/// The fixture is a generated gradient; no journal data is read.
enum AssistantScanHandoffFixture {
    static let launchArgument = "-ofj-fixture-scan-handoff"

    static func requestedSource(arguments: [String] = ProcessInfo.processInfo.arguments) -> AssistantScanHandoffSource? {
        guard let index = arguments.firstIndex(of: launchArgument) else { return nil }
        let value = arguments.indices.contains(index + 1) ? arguments[index + 1] : "food"
        return value == "label" ? .nutritionLabel : .foodPhoto
    }

    static func handoff(source: AssistantScanHandoffSource, logDate: Date = .now) -> AssistantPhotoHandoff {
        let attachments = (0..<2).compactMap { index -> ChatDraftAttachment? in
            guard let data = image(seed: index).jpegData(compressionQuality: 0.8) else { return nil }
            return ChatDraftAttachment(data: data, mimeType: "image/jpeg", filename: "fixture-\(index + 1).jpg")
        }
        return AssistantPhotoHandoff(
            source: source,
            attachments: attachments,
            logDate: logDate,
            userContext: source == .foodPhoto ? "fixture bowl" : nil
        )
    }

    static func image(seed: Int, size: CGSize = CGSize(width: 96, height: 128)) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let colors: [UIColor] = seed.isMultiple(of: 2) ? [.systemOrange, .systemGreen] : [.systemBlue, .systemYellow]
            colors[0].setFill()
            context.fill(CGRect(origin: .zero, size: size))
            colors[1].setFill()
            context.fill(CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2))
        }
    }
}
#endif
