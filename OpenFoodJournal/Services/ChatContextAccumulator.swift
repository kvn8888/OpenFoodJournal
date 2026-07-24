// OpenFoodJournal — Portable Assistant context budgeting
// Conservative token estimates and complete-turn compaction planning shared by
// every provider adapter. Provider-reported usage is reconciled separately.
// AGPL-3.0 License

import Foundation

nonisolated struct ChatContextBlock: Equatable, Sendable {
    let startMessageID: UUID
    let startTimestamp: Date
    let boundaryMessageID: UUID
    let boundaryTimestamp: Date
    let messages: [ChatModelMessage]
    let sourceIDs: [UUID]
    let attachmentIDs: [UUID]

    init(
        startMessageID: UUID? = nil,
        startTimestamp: Date? = nil,
        boundaryMessageID: UUID,
        boundaryTimestamp: Date,
        messages: [ChatModelMessage],
        sourceIDs: [UUID],
        attachmentIDs: [UUID]
    ) {
        self.startMessageID = startMessageID ?? boundaryMessageID
        self.startTimestamp = startTimestamp ?? boundaryTimestamp
        self.boundaryMessageID = boundaryMessageID
        self.boundaryTimestamp = boundaryTimestamp
        self.messages = messages
        self.sourceIDs = sourceIDs
        self.attachmentIDs = attachmentIDs
    }
}

nonisolated struct ChatContextUsage: Equatable, Sendable {
    let estimatedInputTokens: Int
    let reportedInputTokens: Int?
    let reportedCachedInputTokens: Int?
    let selectedLimit: Int
    let reservedOutputTokens: Int
    let reservedToolTokens: Int
    let isCompacted: Bool
    let isContextLimited: Bool
    let explanation: String?
    let isEstimateFrozen: Bool

    init(
        estimatedInputTokens: Int,
        reportedInputTokens: Int?,
        reportedCachedInputTokens: Int? = nil,
        selectedLimit: Int,
        reservedOutputTokens: Int = 0,
        reservedToolTokens: Int = 0,
        isCompacted: Bool,
        isContextLimited: Bool,
        explanation: String? = nil,
        isEstimateFrozen: Bool = false
    ) {
        self.estimatedInputTokens = estimatedInputTokens
        self.reportedInputTokens = reportedInputTokens
        self.reportedCachedInputTokens = reportedCachedInputTokens
        self.selectedLimit = selectedLimit
        self.reservedOutputTokens = reservedOutputTokens
        self.reservedToolTokens = reservedToolTokens
        self.isCompacted = isCompacted
        self.isContextLimited = isContextLimited
        self.explanation = explanation
        self.isEstimateFrozen = isEstimateFrozen
    }

    /// The primary meter represents the context that would be sent on the
    /// next request. Provider-reported input usage belongs to the request that
    /// just finished, so replacing the estimate with that value makes the
    /// meter appear to lose context after every response.
    var displayedTokens: Int { estimatedInputTokens }
    var isReported: Bool { reportedInputTokens != nil }
    var totalReservedTokens: Int { reservedOutputTokens + reservedToolTokens }
}

nonisolated struct ChatContextPlan: Equatable, Sendable {
    let selectedLimit: Int
    let compactionTrigger: Int
    let outputReserve: Int
    let toolLoopReserve: Int
    let historyAdmissionLimit: Int
    let estimatedBaseTokens: Int
    let estimatedHistoryTokens: Int
    let estimatedInputTokens: Int
    let compactThroughBlockIndex: Int?
    let isHardLimitExceeded: Bool

    var requiresCompaction: Bool {
        estimatedInputTokens >= compactionTrigger && compactThroughBlockIndex != nil
    }
}

nonisolated enum ChatContextAccumulator {
    /// Three UTF-8 bytes per token deliberately overestimates normal English
    /// and JSON. Attachments receive additional modality-specific headroom.
    private static let charactersPerToken = 3

    static func plan(
        systemPrompt: String,
        tools: [ChatModelTool],
        checkpointText: String?,
        blocks: [ChatContextBlock],
        descriptor: ChatModelDescriptor,
        budget: ChatContextBudget
    ) -> ChatContextPlan {
        let selectedLimit = budget.inputLimit(for: descriptor)
        let outputReserve = min(
            descriptor.capabilities.maximumOutputTokens,
            max(2_048, selectedLimit / 10)
        )
        let toolLoopReserve = min(20_000, max(4_000, selectedLimit / 10))
        let historyAdmissionLimit = max(4_096, selectedLimit - outputReserve - toolLoopReserve)
        let base = estimate(text: systemPrompt)
            + tools.reduce(0, { $0 + estimate(tool: $1) })
            + (checkpointText.map { estimate(text: $0) } ?? 0)
        let blockCosts = blocks.map(estimate(block:))
        let history = blockCosts.reduce(0, +)
        let total = base + history
        let trigger = Int(Double(selectedLimit) * 0.8)

        var compactThrough: Int?
        if total >= trigger, blocks.count > 2 {
            // Leave a generous recent tail and never split a block (a block is
            // either one plain turn or a complete parallel tool exchange).
            let targetAfterCompaction = min(
                Int(Double(historyAdmissionLimit) * 0.65),
                Int(Double(trigger) * 0.60)
            )
            var remaining = total
            for index in 0..<(blocks.count - 2) {
                remaining -= blockCosts[index]
                compactThrough = index
                if remaining <= targetAfterCompaction { break }
            }
        }

        return ChatContextPlan(
            selectedLimit: selectedLimit,
            compactionTrigger: trigger,
            outputReserve: outputReserve,
            toolLoopReserve: toolLoopReserve,
            historyAdmissionLimit: historyAdmissionLimit,
            estimatedBaseTokens: base,
            estimatedHistoryTokens: history,
            estimatedInputTokens: total,
            compactThroughBlockIndex: compactThrough,
            isHardLimitExceeded: total > historyAdmissionLimit
        )
    }

    static func estimate(request: ChatModelRequest) -> Int {
        estimate(text: request.systemPrompt)
            + request.tools.reduce(0, { $0 + estimate(tool: $1) })
            + request.messages.reduce(0, { $0 + estimate(message: $1) })
    }

    static func estimate(text: String) -> Int {
        max(1, (text.utf8.count + charactersPerToken - 1) / charactersPerToken)
    }

    static func estimate(block: ChatContextBlock) -> Int {
        block.messages.reduce(0) { $0 + estimate(message: $1) }
    }

    static func estimate(message: ChatModelMessage) -> Int {
        6 + message.parts.reduce(0) { partial, part in
            partial + estimate(part: part)
        }
    }

    private static func estimate(tool: ChatModelTool) -> Int {
        12
            + estimate(text: tool.name)
            + estimate(text: tool.description)
            + (tool.parameters.map { estimate(text: $0.jsonString) } ?? 0)
    }

    private static func estimate(part: ChatModelPart) -> Int {
        switch part {
        case .text(let text):
            return estimate(text: text)
        case .attachment(let attachment):
            if attachment.mimeType.hasPrefix("image/") {
                return 1_500 + attachment.data.count / 1_024
            }
            if attachment.mimeType == "application/pdf" {
                // PDF APIs may inject extracted text plus page images.
                return 2_000 + attachment.data.count / 4
            }
            return 500 + attachment.data.count / charactersPerToken
        case .providerContinuation(let continuation):
            return 8 + estimate(text: continuation.payload.jsonString)
        case .functionCall(let call):
            return 12 + estimate(text: call.name) + estimate(text: call.args.jsonString)
        case .functionResponse(let response):
            return 12 + estimate(text: response.name) + estimate(text: response.response.jsonString)
        }
    }
}
