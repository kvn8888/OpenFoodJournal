import Foundation
import CryptoKit

/// Stores only hashes and counts, never another copy of conversation content.
/// A matching prefix lets reported input usage replace its heuristic estimate.
/// Newly appended content remains estimated; previous output is reserved as an
/// upper bound because opaque reasoning can't be measured from ciphertext.
nonisolated struct ChatUsageAnchor: Codable, Equatable, Sendable {
    let requestFingerprint: String
    let messageCount: Int
    let reportedInput: Int
    let reportedOutput: Int

    init(request: ChatModelRequest, selection: AssistantModelSelection, usage: ChatTokenUsage) {
        requestFingerprint = Self.fingerprint(request: request, selection: selection)
        messageCount = request.messages.count
        reportedInput = max(0, usage.input)
        reportedOutput = max(0, usage.output) + (
            selection.provider == .gemini || selection.provider == .openRouter ? max(0, usage.thinking) : 0
        )
    }

    func estimate(request: ChatModelRequest, selection: AssistantModelSelection) -> Int? {
        guard reportedInput > 0, request.messages.count >= messageCount else { return nil }
        let prefix = ChatModelRequest(systemPrompt: request.systemPrompt,
            messages: Array(request.messages.prefix(messageCount)), tools: request.tools)
        guard Self.fingerprint(request: prefix, selection: selection) == requestFingerprint else { return nil }
        let tail = request.messages.dropFirst(messageCount)
        // This intentionally over-reserves output rather than inventing an
        // exact token count for encrypted state. The next real usage reanchors.
        return reportedInput + tail.reduce(0) { $0 + ChatContextAccumulator.estimate(message: $1) }
            + (tail.isEmpty ? 0 : reportedOutput)
    }

    private static func fingerprint(request: ChatModelRequest, selection: AssistantModelSelection) -> String {
        var hasher = SHA256()
        func add(_ text: String) {
            let bytes = Data(text.utf8)
            hasher.update(data: Data("\(bytes.count):".utf8))
            hasher.update(data: bytes)
        }
        add(selection.provider.rawValue)
        add(selection.descriptor.baseModelID)
        add(selection.descriptor.deploymentIdentifier)
        add(selection.endpoint?.absoluteString ?? "")
        add(selection.routingMode.rawValue)
        add(request.systemPrompt)
        add(String(request.tools.count))
        for tool in request.tools {
            add(tool.name); add(tool.description); add(tool.parameters?.jsonString ?? "")
        }
        add(String(request.messages.count))
        for message in request.messages {
            add(message.role == .user ? "user" : "model")
            add(String(message.parts.count))
            for part in message.parts {
                switch part {
                case .text(let value): add("text"); add(value)
                case .attachment(let value):
                    add("attachment"); add(value.mimeType); add(value.filename)
                    add(SHA256.hash(data: value.data).map { String(format: "%02x", $0) }.joined())
                case .functionCall(let value):
                    add("call"); add(value.callID); add(value.name); add(value.args.jsonString)
                    add(value.thoughtSignature ?? ""); add(value.modelTurnID); add(String(value.modelTurnIndex))
                case .functionResponse(let value):
                    add("result"); add(value.callID); add(value.name); add(value.response.jsonString)
                case .providerContinuation(let value):
                    add("continuation"); add(value.providerID); add(value.kind); add(value.payload.jsonString)
                }
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
