// OpenFoodJournal — Assistant compaction tests
// Bounded portable summaries, honest small-window budgets, atomic checkpoint
// saves, and the single provider-overflow recovery attempt.

import Foundation
import SwiftData
import Testing
@testable import OpenFoodJournal

private struct CheckpointSaveFailure: Error {}

@MainActor
struct ChatCompactionTests {
    @Test func manualCompactionIsDeferredUntilTheNextUserSend() async throws {
        let harness = try ChatTestHarness()
        let thread = harness.makeThread()
        _ = harness.insertMessage(.user, text: String(repeating: "Earlier context. ", count: 200), into: thread)
        _ = harness.insertMessage(.model, text: "Earlier answer", into: thread)
        harness.service.requestCompaction(in: thread)
        #expect(harness.proxy.turns.isEmpty)
        #expect(harness.service.queuedCompactionThreadIDs.contains(thread.id))
        harness.proxy.enqueue(ChatModelTurn(text: Self.summaryJSON))
        harness.proxy.enqueue(ChatModelTurn(text: "Continued"))
        await harness.service.send("Continue", in: thread)
        #expect(harness.proxy.turns.count == 2)
        #expect(harness.proxy.turns.first?.request.maximumOutputTokens != nil)
        #expect(thread.contextCheckpoints?.isEmpty == false)
        #expect(!harness.service.queuedCompactionThreadIDs.contains(thread.id))
    }

    @Test func fittingNeverSilentlyDeletesSavedUserConstraints() {
        let constraint = String(repeating: "An important saved constraint. ", count: 200)
        let payload = ChatCheckpointPayload(conversationDecisions: [], userConstraints: [constraint], goals: [], unresolvedTasks: [], toolOutcomes: [], journalFacts: [], sourceIDs: [], attachmentIDs: [], transcriptBoundaryMessageID: UUID(), transcriptBoundaryTimestamp: .now)
        let fitted = ChatCompactionSupport.fitted(payload, maximumTokens: 256)
        #expect(fitted.userConstraints == [constraint])
        #expect(ChatContextAccumulator.estimate(text: fitted.promptText) > 256)
        // The coordinator rejects this oversized checkpoint rather than
        // activating it or discarding the constraint to make it fit.
    }

    private static let summaryJSON = #"{"conversationDecisions":["Use the saved plan"],"userConstraints":["No peanuts"],"goals":["Answer the latest question"],"unresolvedTasks":[],"toolOutcomes":[],"journalFacts":[]}"#

    private func descriptor(limit: Int) -> ChatModelDescriptor {
        ChatModelDescriptor(
            provider: .gemini,
            baseModelID: "tiny-test",
            deploymentIdentifier: "tiny-test",
            displayName: "Tiny",
            capabilities: ChatModelCapabilities(
                maximumInputTokens: limit,
                maximumOutputTokens: 4_096,
                supportsStreaming: true,
                supportsFunctions: true,
                supportsParallelCalls: true,
                supportsImages: false,
                supportsPDFs: false,
                supportsWebSearch: false,
                supportsNativeCompaction: false
            ),
            lastVerifiedAt: "2026-10-10"
        )
    }

    private func block(_ text: String, index: Int) -> ChatContextBlock {
        ChatContextBlock(
            boundaryMessageID: UUID(),
            boundaryTimestamp: Date(timeIntervalSince1970: Double(index + 1)),
            messages: [ChatModelMessage(role: .user, parts: [.text(text)])],
            sourceIDs: [],
            attachmentIDs: []
        )
    }

    private func seedLongHistory(_ harness: ChatTestHarness, in thread: ChatThread) {
        let base = Date(timeIntervalSince1970: 1_700_500_000)
        for index in 0..<14 {
            _ = harness.insertMessage(
                index.isMultiple(of: 2) ? .user : .model,
                text: "seed-\(index) " + String(repeating: "context ", count: 1_200),
                into: thread,
                timestamp: base.addingTimeInterval(Double(index))
            )
        }
    }

    // MARK: Budgets

    @Test func tinyWindowReservesNeverExceedTheSelectedLimit() {
        let tiny = ChatContextAccumulator.plan(
            systemPrompt: "system",
            tools: [],
            checkpointText: nil,
            blocks: [],
            descriptor: descriptor(limit: 4_096),
            budget: .maximum
        )
        #expect(tiny.selectedLimit == 4_096)
        #expect(tiny.outputReserve + tiny.toolLoopReserve + tiny.historyAdmissionLimit == 4_096)
        #expect(tiny.historyAdmissionLimit > 0)

        // Windows of 32K and above keep the previous reserves exactly.
        let large = ChatContextAccumulator.plan(
            systemPrompt: "system",
            tools: [],
            checkpointText: nil,
            blocks: [],
            descriptor: ChatModelCatalog.azureDescriptor(model: .sol, deployment: "sol"),
            budget: .efficient
        )
        #expect(large.outputReserve == 5_000)
        #expect(large.toolLoopReserve == 5_000)
        #expect(large.historyAdmissionLimit == 40_000)

        let recovery = ChatContextAccumulator.plan(
            systemPrompt: "system",
            tools: [],
            checkpointText: nil,
            blocks: [],
            descriptor: ChatModelCatalog.azureDescriptor(model: .sol, deployment: "sol"),
            budget: .efficient,
            maximumInputTokens: 30_000
        )
        #expect(recovery.selectedLimit == 30_000)
    }

    @Test func opaqueContinuationIsNotCountedAsVisibleText() {
        let ciphertext = String(repeating: "A", count: 300_000)
        let continuation = ChatProviderContinuation(
            providerID: "azureOpenAI",
            modelTurnID: "turn",
            ordinal: 0,
            kind: "reasoning.encrypted_content",
            payload: .object([
                "type": .string("reasoning"),
                "encrypted_content": .string(ciphertext),
                "summary": .array([]),
            ])
        )
        let opaque = ChatContextAccumulator.estimate(message: ChatModelMessage(
            role: .model,
            parts: [.providerContinuation(continuation)]
        ))
        let visible = ChatContextAccumulator.estimate(message: ChatModelMessage(
            role: .model,
            parts: [.text(ciphertext)]
        ))
        #expect(opaque < 200)
        #expect(visible >= 100_000)
    }

    // MARK: Portable summary input

    @Test func portableSummaryInputOmitsOpaqueStateAndRawBytes() {
        let sourceID = UUID()
        let imageBytes = Data(repeating: 0x41, count: 1_000_000)
        let block = ChatContextBlock(
            boundaryMessageID: UUID(),
            boundaryTimestamp: Date(timeIntervalSince1970: 10),
            messages: [
                ChatModelMessage(role: .user, parts: [
                    .text("Log my lunch"),
                    .attachment(ChatModelAttachment(data: imageBytes, mimeType: "image/jpeg", filename: "lunch.jpg")),
                ]),
                ChatModelMessage(role: .model, parts: [
                    .providerContinuation(ChatProviderContinuation(
                        providerID: "azureOpenAI",
                        modelTurnID: "turn",
                        ordinal: 0,
                        kind: "reasoning.encrypted_content",
                        payload: .object(["encrypted_content": .string("CIPHERTEXT-" + String(repeating: "Z", count: 5_000))])
                    )),
                    .functionCall(ChatModelCall(
                        callID: "call-1",
                        thoughtSignature: "signature-secret",
                        modelTurnID: "turn",
                        modelTurnIndex: 0,
                        name: "query_entries",
                        args: .object(["day": .string("2026-10-10")])
                    )),
                ]),
                ChatModelMessage(role: .user, parts: [
                    .functionResponse(ChatModelResponse(
                        callID: "call-1",
                        name: "query_entries",
                        response: .object(["rows": .string(String(repeating: "row ", count: 10_000))])
                    )),
                ]),
            ],
            sourceIDs: [sourceID],
            attachmentIDs: []
        )

        let text = ChatCompactionSupport.portableText(for: block, characterLimit: 10_000)

        #expect(!text.contains("CIPHERTEXT"))
        #expect(!text.contains("signature-secret"))
        #expect(!text.contains("QUFBQUFB"))
        #expect(text.contains("lunch.jpg"))
        #expect(text.contains("query_entries [call-1]"))
        #expect(text.contains("characters omitted"))
        #expect(text.contains(sourceID.uuidString))
        #expect(text.count < 5_000)
    }

    @Test func summaryChunksKeepWholeExchangesWithinBudget() {
        let blocks = (0..<10).map { index in
            block("exchange-\(index) " + String(repeating: "word ", count: 1_800), index: index)
        }
        let chunks = ChatCompactionSupport.chunks(blocks, inputTokens: 7_000)
        #expect(chunks.count > 1)
        #expect(chunks.flatMap(\.blocks) == blocks)
        for chunk in chunks {
            #expect(ChatContextAccumulator.estimate(text: chunk.text) <= 7_000)
        }

        let huge = ChatCompactionSupport.chunks(
            [block(String(repeating: "x", count: 90_000), index: 99)],
            inputTokens: 2_000
        )
        #expect(huge.count == 1)
        #expect(ChatContextAccumulator.estimate(text: huge[0].text) <= 2_000)
        #expect(huge[0].text.contains("characters omitted"))
    }

    @Test func oversizedToolResultProjectionKeepsCallIdentity() throws {
        let sourceID = UUID()
        let original = ChatContextBlock(
            boundaryMessageID: UUID(),
            boundaryTimestamp: Date(timeIntervalSince1970: 20),
            messages: [
                ChatModelMessage(role: .model, parts: [
                    .functionCall(ChatModelCall(
                        callID: "big", thoughtSignature: "sig", modelTurnID: "t", modelTurnIndex: 0,
                        name: "fetch_url", args: .object([:])
                    )),
                    .functionCall(ChatModelCall(
                        callID: "small", thoughtSignature: nil, modelTurnID: "t", modelTurnIndex: 1,
                        name: "get_goals", args: .object([:])
                    )),
                ]),
                ChatModelMessage(role: .user, parts: [
                    .functionResponse(ChatModelResponse(
                        callID: "big", name: "fetch_url",
                        response: .object(["text": .string(String(repeating: "page ", count: 20_000))])
                    )),
                    .functionResponse(ChatModelResponse(
                        callID: "small", name: "get_goals",
                        response: .object(["calories": .number(2_000)])
                    )),
                ]),
            ],
            sourceIDs: [sourceID],
            attachmentIDs: []
        )

        let projected = ChatCompactionSupport.projectingOversizedToolResults(in: original, maximumTokens: 500)

        #expect(projected.messages[0] == original.messages[0])
        let responses = projected.messages[1].parts.compactMap { part -> ChatModelResponse? in
            if case .functionResponse(let response) = part { return response }
            return nil
        }
        #expect(responses.map(\.callID) == ["big", "small"])
        #expect(responses[0].name == "fetch_url")
        #expect(responses[0].response.jsonString.contains("context_projection"))
        #expect(responses[0].response.jsonString.contains(sourceID.uuidString))
        #expect(responses[1] == ChatModelResponse(
            callID: "small", name: "get_goals", response: .object(["calories": .number(2_000)])
        ))
        #expect(ChatContextAccumulator.estimate(block: projected) < 1_500)
        #expect(ChatCompactionSupport.projectingOversizedToolResults(in: projected, maximumTokens: 500000) == projected)
    }

    @Test func checkpointFittingKeepsConstraintsAndDisclosesOmissions() {
        let payload = ChatCheckpointPayload(
            conversationDecisions: (0..<60).map { "decision \($0) " + String(repeating: "d", count: 400) },
            userConstraints: ["No peanuts"],
            goals: [],
            unresolvedTasks: [],
            toolOutcomes: (0..<60).map { "outcome \($0) " + String(repeating: "o", count: 400) },
            journalFacts: [],
            sourceIDs: [],
            attachmentIDs: [],
            transcriptBoundaryMessageID: UUID(),
            transcriptBoundaryTimestamp: Date(timeIntervalSince1970: 100)
        )
        let fitted = ChatCompactionSupport.fitted(payload, maximumTokens: 512)
        #expect(ChatContextAccumulator.estimate(text: fitted.promptText) <= 512)
        #expect(fitted.userConstraints == ["No peanuts"])
        #expect(fitted.unresolvedTasks.last?.contains("omitted") == true)
        // Newest lossy items survive longest.
        #expect(fitted.conversationDecisions.allSatisfy { !$0.hasPrefix("decision 0 ") })
    }

    // MARK: Service behavior

    @Test func summaryRequestIsPortableAndBounded() async throws {
        let harness = try ChatTestHarness(contextBudget: .efficient)
        let thread = harness.makeThread()
        seedLongHistory(harness, in: thread)
        harness.proxy.enqueue(ChatModelTurn(text: Self.summaryJSON))
        harness.proxy.enqueue(ChatModelTurn(text: "Compacted answer"))

        await harness.service.send("Continue", in: thread)

        #expect(harness.proxy.turns.count == 2)
        let summaryRequest = harness.proxy.turns[0].request
        #expect(summaryRequest.tools.isEmpty)
        #expect(summaryRequest.messages.count == 1)
        #expect(summaryRequest.messages.allSatisfy { message in
            message.parts.allSatisfy { part in
                if case .text = part { return true }
                return false
            }
        })
        #expect(ChatContextAccumulator.estimate(request: summaryRequest) < 50_000)
        let checkpoint = try #require(thread.contextCheckpoints?.last)
        #expect(checkpoint.wasDeterministicFallback == false)
        #expect(checkpoint.decodedPayload?.userConstraints == ["No peanuts"])
    }

    @Test func checkpointSaveFailureWithdrawsOnlyThatCheckpointAndSurfacesError() async throws {
        let harness = try ChatTestHarness(contextBudget: .efficient)
        let thread = harness.makeThread()
        seedLongHistory(harness, in: thread)
        harness.service.checkpointSaveHandler = { _ in throw CheckpointSaveFailure() }
        harness.proxy.enqueue(ChatModelTurn(text: Self.summaryJSON))

        await harness.service.send("Continue", in: thread)

        // Only the summary was requested; no model turn ran on unsaved state.
        #expect(harness.proxy.turns.count == 1)
        #expect(thread.contextCheckpoints?.isEmpty ?? true)
        #expect(try harness.context.fetch(FetchDescriptor<ChatContextCheckpoint>()).isEmpty)
        #expect(thread.safeMessages.count >= 15)
        if case .contextLimit(let message)? = harness.service.lastError {
            #expect(message.contains("checkpoint"))
        } else {
            Issue.record("Expected a checkpoint save error, got \(String(describing: harness.service.lastError))")
        }
    }

    @Test func failedSummaryIsNotBilledAgainForTheSameStartingBoundary() async throws {
        let harness = try ChatTestHarness(contextBudget: .efficient)
        let thread = harness.makeThread()
        seedLongHistory(harness, in: thread)
        harness.service.checkpointSaveHandler = { _ in throw CheckpointSaveFailure() }
        harness.proxy.enqueue(error: ChatError.invalidResponse)

        await harness.service.send("Continue", in: thread)
        #expect(harness.proxy.turns.count == 1)

        harness.service.checkpointSaveHandler = nil
        harness.proxy.enqueue(ChatModelTurn(text: "Recovered locally."))
        await harness.service.send("Continue again", in: thread)

        // The second send condensed locally instead of paying for a summary.
        #expect(harness.proxy.turns.count == 2)
        let checkpoint = try #require(thread.contextCheckpoints?.last)
        #expect(checkpoint.wasDeterministicFallback)
        #expect(checkpoint.decodedPayload?.unresolvedTasks.contains {
            $0.hasPrefix("Evidence incomplete")
        } == true)
        #expect(thread.safeMessages.last?.text == "Recovered locally.")
    }

    @Test func overflowWithoutReducibleHistoryFailsWithoutRetryLoop() async throws {
        let harness = try ChatTestHarness(contextBudget: .efficient)
        let thread = harness.makeThread()
        harness.proxy.enqueue(error: ChatError.serverError(
            400,
            "This model's maximum context length was exceeded (context_length_exceeded)."
        ))

        await harness.service.send("Hello", in: thread)

        #expect(harness.proxy.turns.count == 1)
        if case .contextLimit? = harness.service.lastError {
        } else {
            Issue.record("Expected a context-limit error, got \(String(describing: harness.service.lastError))")
        }
    }

    @Test func unrelatedBadRequestDoesNotTriggerOverflowRecovery() async throws {
        let harness = try ChatTestHarness(contextBudget: .efficient)
        let thread = harness.makeThread()
        harness.proxy.enqueue(error: ChatError.serverError(
            400,
            "Function tools with reasoning_effort are not supported in /v1/chat/completions."
        ))

        await harness.service.send("Hello", in: thread)

        #expect(harness.proxy.turns.count == 1)
        if case .serverError(400, _)? = harness.service.lastError {
        } else {
            Issue.record("Expected the original 400, got \(String(describing: harness.service.lastError))")
        }
    }
}
