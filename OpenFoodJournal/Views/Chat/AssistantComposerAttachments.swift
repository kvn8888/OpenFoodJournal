// OpenFoodJournal — Assistant composer attachments and scan suggestions
// AGPL-3.0 License

import SwiftUI
import UIKit

enum AssistantComposerAttachmentMetrics {
    static let tileSize: CGFloat = 64
    static let cornerRadius = OFJRadius.control
    static let removeGlyphSize: CGFloat = 22
    /// Room above/right of each tile for the remove badge, which sits on the
    /// corner and would otherwise be clipped by the horizontal scroll view.
    static let badgeOverhang: CGFloat = 7
}

/// Staged attachments above the Assistant text field.
///
/// Identity is the attachment's UUID (minted once when it was staged), so
/// insert/remove animations and the shared-element target never confuse two
/// photos even when their bytes are identical.
struct AssistantComposerAttachmentStrip: View {
    let attachments: [ChatDraftAttachment]
    let scanContext: AssistantComposerScanContext?
    let transition: AssistantAttachmentTransitionCoordinator
    let onRemove: (ChatDraftAttachment) -> Void

    private var imageIDs: [UUID] {
        attachments.filter(\.isImage).map(\.id)
    }

    var body: some View {
        let imageIDs = imageIDs
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: OFJSpace.s8) {
                ForEach(attachments) { attachment in
                    AssistantComposerAttachmentTile(
                        attachment: attachment,
                        imagePosition: imageIDs.firstIndex(of: attachment.id).map { $0 + 1 },
                        imageCount: imageIDs.count,
                        scanSource: scanContext?.attachmentIDs.contains(attachment.id) == true
                            ? scanContext?.source : nil,
                        isConcealed: transition.concealedAttachmentID == attachment.id,
                        transition: transition,
                        onRemove: { onRemove(attachment) }
                    )
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
            }
            .padding(.top, AssistantComposerAttachmentMetrics.badgeOverhang)
            .padding(.trailing, AssistantComposerAttachmentMetrics.badgeOverhang)
        }
        .scrollClipDisabled()
        .accessibilityIdentifier("assistant.attachments")
    }
}

private struct AssistantComposerAttachmentTile: View {
    let attachment: ChatDraftAttachment
    let imagePosition: Int?
    let imageCount: Int
    let scanSource: AssistantScanHandoffSource?
    let isConcealed: Bool
    let transition: AssistantAttachmentTransitionCoordinator
    let onRemove: () -> Void

    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: UIImage?

    private typealias Metrics = AssistantComposerAttachmentMetrics

    var body: some View {
        tileContent
            .frame(width: Metrics.tileSize, height: Metrics.tileSize)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .overlay(alignment: .bottomLeading) {
                if let scanSource {
                    Image(systemName: scanSource.symbol)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(OFJSpace.s4)
                        .background(.black.opacity(0.45), in: .circle)
                        .padding(OFJSpace.s4)
                        .accessibilityHidden(true)
                }
            }
            // Conceal before attaching the anchor so the UIKit probe keeps a
            // valid frame while the tile itself is invisible.
            .opacity(isConcealed ? 0 : 1)
            .background {
                if attachment.isImage {
                    AssistantTransitionAnchor(key: .composerAttachment(attachment.id), coordinator: transition)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(attachment.isImage ? .isImage : [])
            .accessibilityAction(named: "Remove", onRemove)
            .overlay(alignment: .topTrailing) {
                removeButton
                    .offset(x: Metrics.badgeOverhang, y: -Metrics.badgeOverhang)
                    .opacity(isConcealed ? 0 : 1)
            }
            .task(id: attachment.id) {
                await loadThumbnail()
            }
    }

    @ViewBuilder
    private var tileContent: some View {
        if attachment.isImage {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay { ProgressView().controlSize(.small) }
            }
        } else {
            VStack(spacing: OFJSpace.s4) {
                Image(systemName: "doc.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(attachment.filename)
                    .font(.caption2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding(OFJSpace.s4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassEffect(in: .rect(cornerRadius: Metrics.cornerRadius))
        }
    }

    private var removeButton: some View {
        Button(action: onRemove) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: Metrics.removeGlyphSize, height: Metrics.removeGlyphSize)
                .glassEffect(.regular.interactive(), in: .circle)
                // Visual badge stays small; the tap target meets 44 pt.
                .frame(width: OFJLayout.minimumHitTarget, height: OFJLayout.minimumHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: Metrics.removeGlyphSize, height: Metrics.removeGlyphSize)
        .accessibilityLabel(removeLabel)
        .accessibilityIdentifier("assistant.attachment.remove")
    }

    private var accessibilityLabel: String {
        guard attachment.isImage else { return "PDF, \(attachment.filename)" }
        var label = if let imagePosition {
            "Photo \(imagePosition) of \(imageCount)"
        } else {
            "Photo"
        }
        if let scanSource {
            label += ", from \(scanSource.title)"
        }
        return label
    }

    private var removeLabel: String {
        guard attachment.isImage else { return "Remove \(attachment.filename)" }
        return imagePosition.map { "Remove photo \($0)" } ?? "Remove photo"
    }

    private func loadThumbnail() async {
        guard attachment.isImage, thumbnail == nil, let image = UIImage(data: attachment.data) else { return }
        let pixels = Metrics.tileSize * max(displayScale, 1)
        let size = image.size
        let largest = max(size.width, size.height)
        guard largest > 0 else { return }
        // Fill the square tile: scale so the shorter side covers it.
        let shortest = min(size.width, size.height)
        let factor = pixels / max(shortest, 1)
        let target = CGSize(width: size.width * factor, height: size.height * factor)
        thumbnail = await image.byPreparingThumbnail(ofSize: target) ?? image
    }
}

// MARK: - Scan suggestions

/// Contextual starters for photos that arrived from a Journal scan. Each chip
/// fills the draft for review; none of them send.
struct AssistantScanSuggestionTray: View {
    let context: AssistantComposerScanContext
    let imageLimit: Int
    let onSelect: (AssistantComposerSuggestion) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: OFJSpace.s6) {
            HStack(spacing: OFJSpace.s6) {
                Label("From \(context.source.title)", systemImage: context.source.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if context.droppedCount > 0 {
                    Text("· \(context.droppedCount) not added (limit \(imageLimit))")
                        .font(.caption2)
                        .foregroundStyle(OFJColor.estimateConfidence)
                }
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: OFJLayout.minimumHitTarget, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide scan suggestions")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                GlassEffectContainer(spacing: OFJSpace.s8) {
                    HStack(spacing: OFJSpace.s8) {
                        ForEach(context.suggestions) { suggestion in
                            Button {
                                onSelect(suggestion)
                            } label: {
                                Label(suggestion.title, systemImage: suggestion.symbol)
                                    .font(.subheadline)
                                    .padding(.horizontal, OFJSpace.s14)
                                    .padding(.vertical, OFJSpace.s8)
                            }
                            .buttonStyle(.glass)
                            .accessibilityHint("Adds this request to your message. Nothing is sent until you tap Send.")
                            .accessibilityIdentifier("assistant.scan-suggestion.\(suggestion.id)")
                        }
                    }
                }
            }
            .scrollClipDisabled()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("assistant.scan-suggestions")
    }
}
