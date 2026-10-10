// OpenFoodJournal — Assistant compaction support
// Bounded, portable checkpoint-summary input and context-fitting helpers.
// Provider continuation items and raw attachment bytes never leave the
// original transcript; summaries see visible text and compact references.
// AGPL-3.0 License

import Foundation

nonisolated struct ChatSummaryBudget: Equatable, Sendable {
    /// Tokens available for one chunk of rendered exchanges.
    let inputTokens: Int
    /// Tokens reserved for the summary response.
    let outputTokens: Int
    /// Upper bound for the resulting checkpoint prompt text.
    let checkpointTokens: Int
}

nonisolated struct ChatSummaryChunk: Equatable, Sendable {
    let blocks: [ChatContextBlock]
    let text: String
}

nonisolated enum ChatCompactionSupport {
    /// Paid summary requests allowed for one checkpoint. Older chunks beyond
    /// this bound are condensed locally and marked as incomplete evidence.
    static let maximumSummaryRequests = 4
    /// A failed summary for the same thread, model, and starting boundary is
    /// not paid for again until this interval passes.
    static let failedSummaryCooldown: TimeInterval = 600
    static let toolTextCharacterLimit = 1_200
    private static let framingTokens = 64

    static func checkpointTokenLimit(selectedLimit: Int) -> Int {
        min(8_000, max(256, selectedLimit / 8))
    }

    /// Budgets the whole summary request: instructions, the running
    /// checkpoint replayed with each chunk, the chunk, and the response.
    static func summaryBudget(
        selectedLimit: Int,
        maximumOutputTokens: Int,
        instructions: String
    ) -> ChatSummaryBudget? {
        let checkpointTokens = checkpointTokenLimit(selectedLimit: selectedLimit)
        let outputTokens = min(max(1, maximumOutputTokens), checkpointTokens)
        let inputTokens = selectedLimit
            - outputTokens
            - checkpointTokens
            - ChatContextAccumulator.estimate(text: instructions)
            - framingTokens
        guard inputTokens >= 256 else { return nil }
        return ChatSummaryBudget(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            checkpointTokens: checkpointTokens
        )
    }

    /// Renders one complete exchange as portable text. Opaque provider state
    /// is valid only for verbatim same-provider replay, so it is omitted.
    static func portableText(for block: ChatContextBlock, characterLimit: Int) -> String {
        let toolLimit = min(toolTextCharacterLimit, characterLimit)
        var lines = [
            "Exchange \(block.startMessageID.uuidString) through \(block.boundaryMessageID.uuidString):"
        ]
        for message in block.messages {
            let speaker = message.role == .user ? "User" : "Assistant"
            for part in message.parts {
                switch part {
                case .text(let text):
                    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty else { continue }
                    lines.append("\(speaker): \(clipped(value, limit: characterLimit))")
                case .attachment(let attachment):
                    lines.append(
                        "\(speaker) attached \(attachment.filename) (\(attachment.mimeType), \(attachment.data.count) bytes; content not included)"
                    )
                case .providerContinuation:
                    continue
                case .functionCall(let call):
                    lines.append(
                        "Tool call \(call.name) [\(call.callID)]: \(clipped(call.args.jsonString, limit: toolLimit))"
                    )
                case .functionResponse(let response):
                    lines.append(
                        "Tool result \(response.name) [\(response.callID)]: \(clipped(response.response.jsonString, limit: toolLimit))"
                    )
                }
            }
        }
        if !block.sourceIDs.isEmpty {
            lines.append("Source IDs: " + block.sourceIDs.map(\.uuidString).joined(separator: ", "))
        }
        if !block.attachmentIDs.isEmpty {
            lines.append("Attachment IDs: " + block.attachmentIDs.map(\.uuidString).joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    /// Packs complete exchanges, oldest first, into chunks that each fit the
    /// summary input budget. An exchange is never split across chunks; an
    /// exchange that alone exceeds the budget is clipped with a visible marker.
    static func chunks(_ blocks: [ChatContextBlock], inputTokens: Int) -> [ChatSummaryChunk] {
        let characterLimit = max(200, inputTokens * 3 / 2)
        var result: [ChatSummaryChunk] = []
        var pending: [ChatContextBlock] = []
        var pendingTexts: [String] = []
        var pendingTokens = 0
        for block in blocks {
            let text = fitted(
                portableText(for: block, characterLimit: characterLimit),
                tokens: max(1, inputTokens - 2)
            )
            let tokens = ChatContextAccumulator.estimate(text: text) + 2
            if !pending.isEmpty, pendingTokens + tokens > inputTokens {
                result.append(ChatSummaryChunk(
                    blocks: pending,
                    text: pendingTexts.joined(separator: "\n\n")
                ))
                pending = []
                pendingTexts = []
                pendingTokens = 0
            }
            pending.append(block)
            pendingTexts.append(text)
            pendingTokens += tokens
        }
        if !pending.isEmpty {
            result.append(ChatSummaryChunk(blocks: pending, text: pendingTexts.joined(separator: "\n\n")))
        }
        return result
    }

    static func fitted(_ text: String, tokens: Int) -> String {
        guard ChatContextAccumulator.estimate(text: text) > tokens else { return text }
        var limit = max(1, tokens * 3)
        var result = clipped(text, limit: limit)
        while ChatContextAccumulator.estimate(text: result) > tokens, limit > 1 {
            limit = limit * 3 / 4
            result = clipped(text, limit: limit)
        }
        return result
    }

    static func clipped(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        let omitted = value.count - limit
        return String(value.prefix(limit))
            + " … [\(omitted) characters omitted; the original remains in this conversation]"
    }

    /// Replaces oversized tool results with a bounded projection. The call ID
    /// and tool name are preserved so the exchange stays a valid pair; the
    /// complete result remains in the persisted transcript.
    static func projectingOversizedToolResults(
        in block: ChatContextBlock,
        maximumTokens: Int
    ) -> ChatContextBlock {
        var changed = false
        let messages = block.messages.map { message -> ChatModelMessage in
            let parts = message.parts.map { part -> ChatModelPart in
                guard case .functionResponse(let response) = part else { return part }
                let json = response.response.jsonString
                let tokens = ChatContextAccumulator.estimate(text: json)
                guard tokens > maximumTokens else { return part }
                changed = true
                return .functionResponse(ChatModelResponse(
                    callID: response.callID,
                    name: response.name,
                    response: .object([
                        "context_projection": .string(
                            "This result was shortened to fit the selected context limit. The complete result remains in this conversation; reread durable evidence with read_conversation_source using a listed source ID."
                        ),
                        "original_estimated_tokens": .number(Double(tokens)),
                        "preview": .string(clipped(json, limit: max(64, maximumTokens * 3 / 2))),
                        "source_ids": .array(block.sourceIDs.map { JSONValue.string($0.uuidString) }),
                    ])
                ))
            }
            return ChatModelMessage(role: message.role, parts: parts)
        }
        guard changed else { return block }
        return ChatContextBlock(
            startMessageID: block.startMessageID,
            startTimestamp: block.startTimestamp,
            boundaryMessageID: block.boundaryMessageID,
            boundaryTimestamp: block.boundaryTimestamp,
            messages: messages,
            sourceIDs: block.sourceIDs,
            attachmentIDs: block.attachmentIDs
        )
    }

    /// Trims a checkpoint to its token budget. Lossy history is removed
    /// first (oldest item of the longest list); open work and user
    /// constraints go last. Omissions are disclosed in the checkpoint itself.
    static func fitted(
        _ payload: ChatCheckpointPayload,
        maximumTokens: Int
    ) -> ChatCheckpointPayload {
        var result = payload
        var omitted = 0
        while ChatContextAccumulator.estimate(text: result.promptText) > maximumTokens,
              dropOldestItem(from: &result, protectingLastUnresolved: false) {
            omitted += 1
        }
        guard omitted > 0 else { return result }
        result.unresolvedTasks.append(
            "\(omitted) older checkpoint items were omitted to fit the context limit; the original messages remain in this conversation."
        )
        while ChatContextAccumulator.estimate(text: result.promptText) > maximumTokens,
              dropOldestItem(from: &result, protectingLastUnresolved: true) {}
        return result
    }

    private static func dropOldestItem(
        from payload: inout ChatCheckpointPayload,
        protectingLastUnresolved: Bool
    ) -> Bool {
        let tiers: [[WritableKeyPath<ChatCheckpointPayload, [String]>]] = [
            [\.journalFacts, \.toolOutcomes, \.conversationDecisions],
            [\.goals, \.unresolvedTasks],
        ]
        for tier in tiers {
            var chosen: WritableKeyPath<ChatCheckpointPayload, [String]>?
            var chosenCount = 0
            for path in tier {
                let minimum = protectingLastUnresolved && path == \.unresolvedTasks ? 1 : 0
                let count = payload[keyPath: path].count - minimum
                if count > chosenCount {
                    chosen = path
                    chosenCount = count
                }
            }
            if let chosen {
                payload[keyPath: chosen].removeFirst()
                return true
            }
        }
        return false
    }
}
