// OpenFoodJournal — Assistant behavior and provider-adapter contract tests

import Foundation
import SwiftData
import Testing
import UIKit
@testable import OpenFoodJournal

@MainActor
struct ChatFeatureTests {
    @Test func textConversationUsesSharedProxyContractAndPersistsReply() async throws {
        let harness = try ChatTestHarness()
        harness.proxy.enqueue(ChatModelTurn(
            text: "You have 640 calories remaining.",
            usage: ChatTokenUsage(input: 120, output: 18, thinking: 4)
        ))
        let thread = harness.makeThread()

        await harness.service.send("How am I doing today?", in: thread)

        let turn = try #require(harness.proxy.turns.first)
        #expect(turn.model == "test-primary")
        #expect(turn.apiKey == "test-api-key")
        #expect(turn.request.tools.map(\.name) == ChatToolRegistry.all.map(\.name))
        #expect(turn.request.tools.count == 20)
        #expect(turn.request.systemPrompt.contains("OpenFoodJournal Assistant"))
        #expect(turn.request.messages == [
            ChatModelMessage(role: .user, parts: [.text("How am I doing today?")])
        ])
        #expect(thread.safeMessages.map(\.role) == [.user, .model])
        #expect(thread.safeMessages.last?.text == "You have 640 calories remaining.")
        #expect(thread.title == "How am I doing today?")
        #expect(harness.service.lastError == nil)
        #expect(harness.service.contextUsage?.reportedInputTokens == 120)
        #expect(harness.service.contextUsage?.isReported == true)
        #expect(harness.service.contextUsage?.displayedTokens == harness.service.contextUsage?.estimatedInputTokens)
        #expect((harness.service.contextUsage?.estimatedInputTokens ?? 0) > 120)
    }

    @Test func editingUserMessageReplacesItsBranchAndReplaysEditedAttachments() async throws {
        let harness = try ChatTestHarness()
        let thread = harness.makeThread(title: "Old title")
        let user = harness.insertMessage(.user, text: "Old prompt", into: thread)
        let oldAttachment = ChatAttachment(
            data: Data([0x01]),
            mimeType: "image/jpeg",
            filename: "old.jpg"
        )
        oldAttachment.message = user
        harness.context.insert(oldAttachment)
        user.attachments?.append(oldAttachment)
        _ = harness.insertMessage(.model, text: "Old answer", into: thread)
        harness.proxy.enqueue(ChatModelTurn(text: "Replacement answer"))
        let replacement = ChatDraftAttachment(
            data: Data([0x02, 0x03]),
            mimeType: "image/jpeg",
            filename: "replacement.jpg"
        )

        let result = harness.service.submitEdit(
            "Edited prompt",
            attachments: [replacement],
            replacing: user,
            in: thread
        )
        guard case .accepted(_, let messageID) = result else {
            Issue.record("Expected edited message to be accepted")
            return
        }
        for _ in 0..<500 where harness.service.isStreaming { await Task.yield() }

        #expect(messageID == user.id)
        #expect(thread.safeMessages.map(\.role) == [.user, .model])
        #expect(thread.safeMessages.first?.text == "Edited prompt")
        #expect(thread.safeMessages.first?.safeAttachments.map(\.filename) == ["replacement.jpg"])
        #expect(thread.safeMessages.last?.text == "Replacement answer")
        let request = try #require(harness.proxy.turns.first?.request)
        #expect(request.messages.first?.parts.contains(.text("Edited prompt")) == true)
        #expect(request.messages.first?.parts.contains(.attachment(ChatModelAttachment(
            data: replacement.data,
            mimeType: replacement.mimeType,
            filename: replacement.filename
        ))) == true)
        #expect(request.messages.description.contains("Old answer") == false)
    }

    @Test func conversationTitleIsGeneratedByTheConfiguredModel() async throws {
        let harness = try ChatTestHarness(automaticallyGeneratesTitles: true)
        harness.proxy.enqueue(ChatModelTurn(text: "Your protein is on track."))
        harness.proxy.enqueue(ChatModelTurn(
            text: "**Protein Progress Plan!**",
            usage: ChatTokenUsage(input: 36, output: 5, thinking: 0),
            providerRequestID: "title-request"
        ))
        let thread = harness.makeThread()

        await harness.service.send("How can I hit my protein goal?", in: thread)
        for _ in 0..<500 where thread.title.isEmpty { await Task.yield() }

        #expect(thread.title == "Protein Progress Plan")
        #expect(harness.proxy.turns.count == 2)
        let titleRequest = harness.proxy.turns[1].request
        #expect(titleRequest.tools.isEmpty)
        #expect(titleRequest.systemPrompt.contains("2 to 6 words"))
        #expect(titleRequest.messages.allSatisfy { message in
            message.parts.allSatisfy { part in
                if case .attachment = part { return false }
                return true
            }
        })
        let aggregate = try #require(
            harness.context.fetch(FetchDescriptor<ChatUsageDailyAggregate>()).first
        )
        #expect(aggregate.requestCount >= 2)
    }

    @Test func titleRegenerationKeepsOnlyACompactPlainTitle() async throws {
        let harness = try ChatTestHarness()
        let thread = harness.makeThread(title: "Previous title")
        _ = harness.insertMessage(.user, text: "Review my sodium today", into: thread)
        _ = harness.insertMessage(.model, text: "Your sodium is elevated.", into: thread)
        harness.proxy.enqueue(ChatModelTurn(text: "\"Daily Sodium Review.\""))

        await harness.service.regenerateTitle(in: thread)

        #expect(thread.title == "Daily Sodium Review")
        #expect(harness.service.titleGenerationThreadIDs.isEmpty)
        #expect(ChatService.sanitizedGeneratedTitle("# Weekly Fiber Plan!!!") == "Weekly Fiber Plan")
    }

    @Test func azureUsageAggregatesTokensAndDatedDollarEstimate() async throws {
        let harness = try ChatTestHarness(
            provider: .azureOpenAI,
            primary: AzureAssistantModel.terra.rawValue
        )
        harness.proxy.enqueue(ChatModelTurn(
            text: String(repeating: "Current context remains visible. ", count: 80),
            usage: ChatTokenUsage(input: 6_125, cachedInput: 1_000, output: 840, thinking: 210)
        ))
        let thread = harness.makeThread()

        await harness.service.send("Explain my current context", in: thread)

        let accumulator = GeminiCostAccumulator.current(in: harness.context)
        #expect(accumulator.totalInputTokens == 6_125)
        #expect(accumulator.totalCachedInputTokens == 1_000)
        #expect(accumulator.totalOutputTokens == 840)
        #expect(accumulator.totalThinkingTokens == 210)
        #expect(abs(accumulator.totalEstimatedTokenCostUSD - 0.0256625) < 0.0000001)
        #expect(accumulator.lastPricingModel?.contains("GPT-5.6 public standard") == true)
        #expect(harness.service.contextUsage?.reportedInputTokens == 6_125)
        #expect(harness.service.contextUsage?.displayedTokens == harness.service.contextUsage?.estimatedInputTokens)
        #expect((harness.service.contextUsage?.estimatedInputTokens ?? 0) > 0)
        #expect(thread.safeMessages.last?.reportedCachedInputTokens == 1_000)
    }

    @Test func assistantCallsExportToRedactedAILogs() async throws {
        let harness = try ChatTestHarness(
            provider: .azureOpenAI,
            primary: AzureAssistantModel.terra.rawValue
        )
        harness.proxy.enqueue(ChatModelTurn(
            text: "A private answer that belongs only in chat history.",
            usage: ChatTokenUsage(input: 420, cachedInput: 120, output: 55, thinking: 12),
            providerRequestID: "azure-request-123"
        ))
        let thread = harness.makeThread()

        await harness.service.send("Sensitive journal question that must not enter diagnostics", in: thread)

        let log = try #require(
            harness.diagnostics.events.first(where: { $0.eventType == "ai_request" })
        )

        #expect(log.operation == GeminiScanLogOperation.assistantChat.rawValue)
        #expect(log.status == GeminiScanLogStatus.success.rawValue)
        #expect(log.providerID == AssistantProvider.azureOpenAI.rawValue)
        #expect(log.deploymentID == AzureAssistantModel.terra.rawValue)
        #expect(log.inputTokens == 420)
        #expect(log.cachedInputTokens == 120)
        #expect(log.outputTokens == 55)
        #expect(log.reasoningTokens == 12)
        #expect(log.providerRequestID == "azure-request-123")
        #expect(log.payloadJSON?.contains("assistant_model_turn") == true)
        #expect(log.payloadJSON?.contains("Sensitive journal question") == false)
        #expect(log.payloadJSON?.contains("private answer") == false)
        #expect(try harness.context.fetch(FetchDescriptor<GeminiScanLog>()).isEmpty)
        #expect(try harness.context.fetch(FetchDescriptor<ChatDiagnosticSpan>()).isEmpty)
    }

    @Test func aiDiagnosticLogsRetainOnlyTheLastTwoWeeks() throws {
        let harness = try ChatTestHarness()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expired = GeminiScanLog(
            createdAt: now.addingTimeInterval(-15 * 24 * 60 * 60),
            operation: .assistantChat,
            status: .success
        )
        let retained = GeminiScanLog(
            createdAt: now.addingTimeInterval(-13 * 24 * 60 * 60),
            operation: .scan,
            status: .success
        )
        harness.context.insert(expired)
        harness.context.insert(retained)
        try harness.context.save()

        let deletedCount = GeminiScanLog.pruneExpired(in: harness.context, now: now)
        try harness.context.save()
        let remaining = try harness.context.fetch(FetchDescriptor<GeminiScanLog>())
        let csv = GeminiScanLog.exportCSV(from: harness.context, now: now)

        #expect(GeminiScanLog.retentionDays == 14)
        #expect(deletedCount == 1)
        #expect(remaining.map(\.id) == [retained.id])
        #expect(csv.contains(retained.id.uuidString))
        #expect(csv.contains(expired.id.uuidString) == false)
    }

    @Test func azurePricingCatalogAppliesSolAndTerraRatesAndLongContextMultiplier() throws {
        let terra = AssistantModelSelection(
            descriptor: ChatModelCatalog.azureDescriptor(model: .terra, deployment: "custom-terra"),
            endpoint: URL(string: "https://sample.openai.azure.com/openai/v1"),
            routingMode: .automatic
        )
        let sol = AssistantModelSelection(
            descriptor: ChatModelCatalog.azureDescriptor(model: .sol, deployment: "custom-sol"),
            endpoint: URL(string: "https://sample.openai.azure.com/openai/v1"),
            routingMode: .automatic
        )
        let terraPricing = try #require(ChatPricingCatalog.pricing(for: terra))
        let solPricing = try #require(ChatPricingCatalog.pricing(for: sol))

        #expect(abs(terraPricing.estimatedCost(for: ChatTokenUsage(
            input: 1_000_000,
            cachedInput: 100_000,
            output: 100_000,
            thinking: 50_000
        )) - 6.80) < 0.000001)
        #expect(abs(solPricing.estimatedCost(for: ChatTokenUsage(
            input: 10_000,
            output: 1_000,
            thinking: 400
        )) - 0.08) < 0.000001)
    }

    @Test func imageAndPDFInputsCrossTheSameAttachmentInterface() async throws {
        let harness = try ChatTestHarness(provider: .openRouter)
        harness.proxy.enqueue(ChatModelTurn(text: "I can read both files."))
        let thread = harness.makeThread()
        let image = ChatDraftAttachment(data: Data([0xFF, 0xD8, 0xFF]), mimeType: "image/jpeg", filename: "meal.jpg")
        let pdf = ChatDraftAttachment(data: Data("%PDF-test".utf8), mimeType: "application/pdf", filename: "menu.pdf")

        await harness.service.send("Analyze these", attachments: [image, pdf], in: thread)

        let request = try #require(harness.proxy.turns.first?.request)
        let parts = try #require(request.messages.first?.parts)
        #expect(parts.contains(.text("Analyze these")))
        #expect(parts.contains(.attachment(ChatModelAttachment(data: image.data, mimeType: image.mimeType, filename: image.filename))))
        #expect(parts.contains(.attachment(ChatModelAttachment(data: pdf.data, mimeType: pdf.mimeType, filename: pdf.filename))))
        #expect(thread.safeMessages.first?.safeAttachments.map(\.filename) == ["meal.jpg", "menu.pdf"])
        let sources = try #require(thread.sourceArtifacts)
        #expect(sources.count == 2)
        #expect(sources.allSatisfy { $0.kind == .userAttachment })
        let block = try #require(harness.service.contextBlocks(for: thread, afterMessageID: nil).first)
        #expect(Set(block.sourceIDs) == Set(sources.map(\.id)))
    }

    @Test func cameraCapturedPhotoUsesTheSharedDownscaledJPEGPipeline() throws {
        let sourceFormat = UIGraphicsImageRendererFormat.default()
        sourceFormat.scale = 1
        let sourceImage = UIGraphicsImageRenderer(
            size: CGSize(width: 2_000, height: 1_000),
            format: sourceFormat
        ).image { context in
            UIColor.systemGreen.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 2_000, height: 1_000))
        }
        let sourceData = try #require(sourceImage.pngData())

        let jpeg = try #require(
            ChatService.downscaledJPEG(
                from: sourceData,
                maxDimension: 1_200,
                quality: 0.8
            )
        )
        let decoded = try #require(UIImage(data: jpeg))

        #expect(decoded.size.width == 1_200)
        #expect(decoded.size.height == 600)
        #expect(jpeg.starts(with: [0xFF, 0xD8]))
    }

    @Test func plainConversationPairsRemainCompleteContextBlocksWithExactBoundaries() throws {
        let harness = try ChatTestHarness()
        let thread = harness.makeThread()
        let base = Date(timeIntervalSince1970: 1_700_200_000)
        let firstUser = harness.insertMessage(.user, text: "first user", into: thread, timestamp: base)
        let firstModel = harness.insertMessage(.model, text: "first model", into: thread, timestamp: base.addingTimeInterval(1))
        _ = harness.insertMessage(.user, text: "second user", into: thread, timestamp: base.addingTimeInterval(2))
        _ = harness.insertMessage(.model, text: "second model", into: thread, timestamp: base.addingTimeInterval(3))

        let blocks = harness.service.contextBlocks(for: thread, afterMessageID: nil)
        #expect(blocks.count == 2)
        #expect(blocks[0].boundaryMessageID == firstModel.id)
        #expect(blocks[0].messages == [
            ChatModelMessage(role: .user, parts: [.text("first user")]),
            ChatModelMessage(role: .model, parts: [.text("first model")]),
        ])
        #expect(firstUser.id != blocks[0].boundaryMessageID)

        let afterBoundary = harness.service.contextBlocks(
            for: thread,
            afterMessageID: blocks[0].boundaryMessageID
        )
        #expect(afterBoundary.count == 1)
        #expect(afterBoundary[0].messages == [
            ChatModelMessage(role: .user, parts: [.text("second user")]),
            ChatModelMessage(role: .model, parts: [.text("second model")]),
        ])
    }

    @Test func contextAccumulatorCompactsAtEightyPercentWithoutSplittingBlocks() throws {
        let descriptor = ChatModelCatalog.azureDescriptor(model: .sol, deployment: "sol-test")
        let largeBlocks = (0..<5).map { index in
            ChatContextBlock(
                boundaryMessageID: UUID(),
                boundaryTimestamp: Date(timeIntervalSince1970: Double(index)),
                messages: [ChatModelMessage(
                    role: .user,
                    parts: [.text("block-\(index) " + String(repeating: "x", count: 30_000))]
                )],
                sourceIDs: [],
                attachmentIDs: []
            )
        }
        let plan = ChatContextAccumulator.plan(
            systemPrompt: "system",
            tools: [],
            checkpointText: nil,
            blocks: largeBlocks,
            descriptor: descriptor,
            budget: .efficient
        )

        #expect(plan.selectedLimit == 50_000)
        #expect(plan.compactionTrigger == 40_000)
        #expect(plan.estimatedInputTokens >= plan.compactionTrigger)
        #expect(plan.requiresCompaction)
        #expect(plan.compactThroughBlockIndex != nil)
        #expect(try #require(plan.compactThroughBlockIndex) < largeBlocks.count - 2)

        let smallPlan = ChatContextAccumulator.plan(
            systemPrompt: "system",
            tools: [],
            checkpointText: nil,
            blocks: Array(largeBlocks.prefix(2)).map { block in
                ChatContextBlock(
                    boundaryMessageID: block.boundaryMessageID,
                    boundaryTimestamp: block.boundaryTimestamp,
                    messages: [ChatModelMessage(role: .user, parts: [.text("small")])],
                    sourceIDs: [],
                    attachmentIDs: []
                )
            },
            descriptor: descriptor,
            budget: .efficient
        )
        #expect(!smallPlan.requiresCompaction)
        #expect(smallPlan.compactThroughBlockIndex == nil)
    }

    @Test func providerCitationsBecomeDurableVersionedSourceArtifacts() async throws {
        let harness = try ChatTestHarness(provider: .azureOpenAI)
        harness.proxy.enqueue(ChatModelTurn(
            text: "A cited answer.",
            citations: [ChatSourceCitation(
                url: "https://example.com/research",
                title: "Research",
                startIndex: 2,
                endIndex: 8
            )]
        ))
        let thread = harness.makeThread()

        await harness.service.send("Research this", in: thread)

        let source = try #require(thread.sourceArtifacts?.first)
        #expect(source.kind == .webCitation)
        #expect(source.providerID == AssistantProvider.azureOpenAI.rawValue)
        #expect(source.modelID == "test-primary")
        #expect(source.citationStartIndex == 2)
        #expect(source.citationEndIndex == 8)
        #expect(source.originatingMessageID == thread.safeMessages.last?.id)
        let block = try #require(harness.service.contextBlocks(for: thread, afterMessageID: nil).first)
        #expect(block.sourceIDs == [source.id])
    }

    @Test func parallelCallsReplayAsOneModelTurnWithIDsAndSignatureUnchanged() async throws {
        let harness = try ChatTestHarness()
        let calls = [
            ChatModelCall(
                callID: "call-goals",
                thoughtSignature: "opaque-signature==",
                modelTurnID: "turn-42",
                modelTurnIndex: 0,
                name: "get_goals",
                args: .object([:])
            ),
            ChatModelCall(
                callID: "call-energy",
                thoughtSignature: nil,
                modelTurnID: "turn-42",
                modelTurnIndex: 1,
                name: "get_active_energy",
                args: .object(["date": .string("2026-07-20")])
            ),
        ]
        harness.proxy.enqueue(ChatModelTurn(calls: calls))
        harness.proxy.enqueue(ChatModelTurn(text: "Goals and activity checked."))
        let thread = harness.makeThread()

        await harness.service.send("Check both", in: thread)

        #expect(harness.proxy.turns.count == 2)
        let replay = harness.proxy.turns[1].request.messages
        let callMessage = try #require(replay.first(where: { message in
            message.parts.contains { if case .functionCall = $0 { true } else { false } }
        }))
        let responseMessage = try #require(replay.first(where: { message in
            message.parts.contains { if case .functionResponse = $0 { true } else { false } }
        }))
        #expect(callMessage.role == .model)
        #expect(callMessage.parts.count == 2)
        #expect(callMessage.parts == calls.map(ChatModelPart.functionCall))
        #expect(responseMessage.role == .user)
        #expect(responseMessage.parts.count == 2)

        let records = thread.safeMessages.compactMap(\.toolRecord)
        #expect(records.map(\.callID) == ["call-goals", "call-energy"])
        #expect(records.map(\.modelTurnID) == ["turn-42", "turn-42"])
        #expect(records.map(\.modelTurnIndex) == [0, 1])
        #expect(records.first?.thoughtSignature == "opaque-signature==")
    }

    @Test func azureContinuationReplaysBeforeItsParallelFunctionCalls() async throws {
        let harness = try ChatTestHarness(provider: .azureOpenAI)
        let continuation = ChatProviderContinuation(
            providerID: AssistantProvider.azureOpenAI.rawValue,
            modelTurnID: "resp-azure",
            ordinal: 0,
            kind: "reasoning.encrypted_content",
            payload: .object([
                "type": .string("reasoning"),
                "id": .string("reasoning-azure"),
                "encrypted_content": .string("opaque-azure=="),
            ])
        )
        let calls = [
            ChatModelCall(callID: "azure-1", thoughtSignature: nil, modelTurnID: "resp-azure", modelTurnIndex: 1, name: "get_goals", args: .object([:])),
            ChatModelCall(callID: "azure-2", thoughtSignature: nil, modelTurnID: "resp-azure", modelTurnIndex: 2, name: "get_active_energy", args: .object([:])),
        ]
        harness.proxy.enqueue(ChatModelTurn(
            calls: calls,
            continuations: [continuation],
            providerRequestID: "request-azure"
        ))
        harness.proxy.enqueue(ChatModelTurn(text: "Done"))
        let thread = harness.makeThread()

        await harness.service.send("Check both", in: thread)

        let replay = try #require(harness.proxy.turns.dropFirst().first?.request.messages)
        let modelTurn = try #require(replay.first(where: { message in
            message.parts.contains { if case .providerContinuation = $0 { true } else { false } }
        }))
        #expect(modelTurn.parts == [.providerContinuation(continuation)] + calls.map(ChatModelPart.functionCall))
        let records = thread.safeMessages.compactMap(\.toolRecord)
        #expect(records.count == 2)
        #expect(records.first?.providerContinuations == [continuation])
        #expect(records.first?.providerRequestID == "request-azure")
        #expect(records.map(\.callID) == ["azure-1", "azure-2"])
    }

    @Test func azureFinalTextAndContinuationReplayInOriginalOutputOrder() async throws {
        let harness = try ChatTestHarness(provider: .azureOpenAI)
        let continuation = ChatProviderContinuation(
            providerID: AssistantProvider.azureOpenAI.rawValue,
            modelTurnID: "azure-final-turn",
            ordinal: 1,
            kind: "reasoning.encrypted_content",
            payload: .object([
                "type": .string("reasoning"),
                "id": .string("reasoning-final"),
                "encrypted_content": .string("opaque-final=="),
            ])
        )
        harness.proxy.enqueue(ChatModelTurn(
            text: "First answer.",
            textOrdinal: 0,
            continuations: [continuation]
        ))
        harness.proxy.enqueue(ChatModelTurn(text: "Second answer."))
        let thread = harness.makeThread()

        await harness.service.send("First", in: thread)
        await harness.service.send("Second", in: thread)

        let replay = try #require(harness.proxy.turns.last?.request.messages)
        let priorModel = try #require(replay.first { message in
            message.parts.contains(.text("First answer."))
        })
        #expect(priorModel.parts == [
            .text("First answer."),
            .providerContinuation(continuation),
        ])
        let saved = try #require(thread.safeMessages.first { $0.text == "First answer." })
        #expect(saved.modelTurnID == "azure-final-turn")
        #expect(saved.modelTurnTextOrdinal == 0)
        #expect(saved.providerContinuations == [continuation])
    }

    @Test func textReasoningAndParallelCallsReplayAsOneOrderedModelTurn() async throws {
        let harness = try ChatTestHarness(provider: .azureOpenAI)
        let continuation = ChatProviderContinuation(
            providerID: AssistantProvider.azureOpenAI.rawValue,
            modelTurnID: "ordered-turn",
            ordinal: 0,
            kind: "reasoning.encrypted_content",
            payload: .object([
                "type": .string("reasoning"),
                "id": .string("ordered-reasoning"),
                "encrypted_content": .string("ordered-opaque=="),
            ])
        )
        let calls = [
            ChatModelCall(callID: "ordered-a", thoughtSignature: nil, modelTurnID: "ordered-turn", modelTurnIndex: 1, name: "get_goals", args: .object([:])),
            ChatModelCall(callID: "ordered-b", thoughtSignature: nil, modelTurnID: "ordered-turn", modelTurnIndex: 2, name: "get_active_energy", args: .object([:])),
        ]
        harness.proxy.enqueue(ChatModelTurn(
            text: "I’ll check both sources.",
            textOrdinal: 3,
            calls: calls,
            continuations: [continuation]
        ))
        harness.proxy.enqueue(ChatModelTurn(text: "Both checks are complete."))
        let thread = harness.makeThread()

        await harness.service.send("Check both", in: thread)

        let request = try #require(harness.proxy.turns.dropFirst().first?.request)
        let reconstructed = request.messages.filter { message in
            message.parts.contains { if case .functionCall = $0 { true } else { false } }
        }
        #expect(reconstructed.count == 1)
        #expect(reconstructed.first?.parts == [
            .providerContinuation(continuation),
            .functionCall(calls[0]),
            .functionCall(calls[1]),
            .text("I’ll check both sources."),
        ])
        let prelude = try #require(thread.safeMessages.first(where: {
            $0.role == .model && $0.text == "I’ll check both sources."
        }))
        #expect(prelude.modelTurnID == "ordered-turn")
        #expect(prelude.modelTurnTextOrdinal == 3)
    }

    @Test func providerSwitchReplaysPortableGeminiToolHistoryThroughAzureContract() async throws {
        let harness = try ChatTestHarness(provider: .azureOpenAI)
        let thread = harness.makeThread()
        _ = harness.insertMessage(
            .user,
            text: "What are my goals?",
            into: thread,
            timestamp: Date(timeIntervalSince1970: 1)
        )
        let toolMessage = harness.insertMessage(
            .tool,
            text: "Read goals",
            into: thread,
            timestamp: Date(timeIntervalSince1970: 2)
        )
        toolMessage.setToolRecord(ChatToolRecord(
            callID: "gemini-history-call",
            thoughtSignature: "gemini-history-signature",
            modelTurnID: "gemini-history-turn",
            modelTurnIndex: 0,
            providerID: AssistantProvider.gemini.rawValue,
            modelID: "gemini-pro-latest",
            name: "get_goals",
            argsJSON: "{}",
            resultJSON: #"{"goals":{"calories":2000}}"#,
            status: .completed,
            summary: "Read goals"
        ))
        harness.proxy.enqueue(ChatModelTurn(text: "Azure continued from the saved history."))

        await harness.service.send("Continue with Azure", in: thread)

        let request = try #require(harness.proxy.turns.first?.request)
        let call = try #require(request.messages.compactMap { message in
            message.parts.compactMap { part -> ChatModelCall? in
                if case .functionCall(let call) = part { return call }
                return nil
            }.first
        }.first)
        #expect(call.callID == "gemini-history-call")
        #expect(call.thoughtSignature == "gemini-history-signature")
        let response = try #require(request.messages.compactMap { message in
            message.parts.compactMap { part -> ChatModelResponse? in
                if case .functionResponse(let response) = part { return response }
                return nil
            }.first
        }.first)
        #expect(response.callID == "gemini-history-call")
        #expect(thread.safeMessages.last?.providerID == AssistantProvider.azureOpenAI.rawValue)
    }

    @Test func transientPrimaryFailureRetriesFallbackThroughSameProxy() async throws {
        let harness = try ChatTestHarness(primary: "primary-model", fallback: "fallback-model")
        harness.proxy.enqueue(error: ChatError.serverError(503, "busy"))
        harness.proxy.enqueue(error: ChatError.serverError(503, "still busy"))
        harness.proxy.enqueue(ChatModelTurn(text: "Fallback worked."))
        let thread = harness.makeThread()

        await harness.service.send("Hello", in: thread)

        #expect(harness.proxy.turns.map(\.model) == [
            "primary-model",
            "primary-model",
            "fallback-model",
        ])
        #expect(thread.safeMessages.last?.text == "Fallback worked.")
        #expect(harness.service.lastError == nil)
    }

    @Test func missingKeyAndEmptyResponseSurfaceStableChatErrors() async throws {
        let noKey = try ChatTestHarness(apiKey: nil)
        await noKey.service.send("Hello", in: noKey.makeThread())
        #expect(noKey.proxy.turns.isEmpty)
        if case .noAPIKey("Gemini")? = noKey.service.lastError {
            // Expected.
        } else {
            Issue.record("Expected Gemini no-API-key error")
        }

        let empty = try ChatTestHarness()
        empty.proxy.enqueue(ChatModelTurn())
        await empty.service.send("Hello", in: empty.makeThread())
        if case .emptyResponse? = empty.service.lastError {
            // Expected.
        } else {
            Issue.record("Expected empty-response error")
        }
    }

    @Test func retryAndRegenerateDoNotDuplicateTheUserTurn() async throws {
        let retryHarness = try ChatTestHarness()
        let retryThread = retryHarness.makeThread()
        _ = retryHarness.insertMessage(.user, text: "Retry me", into: retryThread)
        retryHarness.proxy.enqueue(ChatModelTurn(text: "Retried"))
        await retryHarness.service.retry(in: retryThread)
        #expect(retryThread.safeMessages.map(\.role) == [.user, .model])

        let regenerateHarness = try ChatTestHarness()
        let regenerateThread = regenerateHarness.makeThread()
        let user = regenerateHarness.insertMessage(.user, text: "Try another answer", into: regenerateThread, timestamp: Date(timeIntervalSince1970: 1))
        _ = regenerateHarness.insertMessage(.model, text: "Old answer", into: regenerateThread, timestamp: Date(timeIntervalSince1970: 2))
        regenerateHarness.proxy.enqueue(ChatModelTurn(text: "New answer"))
        await regenerateHarness.service.regenerate(in: regenerateThread, using: .smart)
        #expect(regenerateThread.safeMessages.filter { $0 === user }.count == 1)
        #expect(regenerateThread.safeMessages.filter { $0.role == .model }.map(\.text) == ["New answer"])
    }

    @Test func deniedWriteIsPersistedAndDoesNotMutateData() async throws {
        let harness = try ChatTestHarness()
        let args: JSONValue = .object([
            "name": .string("Denied Toast"),
            "calories": .number(100),
            "protein": .number(3),
            "carbs": .number(18),
            "fat": .number(2),
            "meal": .string("Breakfast"),
        ])

        let record = try #require(await harness.runTool("log_entry", args: args, permission: .denied))

        #expect(record.status == .denied)
        #expect(record.resultJSON.contains("denied"))
        #expect(harness.permissions.requests.first?.toolName == "log_entry")
        #expect(harness.nutritionStore.fetchAllEntries().isEmpty)
    }

    @Test func webSearchUsesIndependentResearchProviderAndReplaysAnswer() async throws {
        let harness = try ChatTestHarness()
        harness.research.enqueue(ChatWebSearchResult(
            text: "FDA source: https://www.fda.gov/example",
            usage: nil,
            citations: [ChatSourceCitation(
                url: "https://www.fda.gov/example",
                title: "FDA",
                startIndex: 12,
                endIndex: 39
            )],
            providerRequestID: "tavily-tool-request",
            providerID: AssistantResearchProvider.tavily.rawValue,
            modelID: "search-fast",
            durationMs: 135,
            creditsUsed: 1,
            sources: [ChatWebSearchSource(
                url: "https://www.fda.gov/example",
                title: "FDA",
                content: "FDA sodium evidence",
                score: 0.98
            )]
        ))
        harness.enqueueToolCall("web_search", args: .object(["query": .string("FDA sodium daily value")]))
        let thread = harness.makeThread()

        await harness.service.send("Search it", in: thread)

        let search = try #require(harness.research.searches.first)
        #expect(search.query == "FDA sodium daily value")
        #expect(search.request.searchQueries == ["FDA sodium daily value"])
        let record = try #require(thread.safeMessages.compactMap(\.toolRecord).first)
        #expect(record.status == .completed)
        let resultData = try #require(record.resultJSON.data(using: .utf8))
        let result = try #require(JSONSerialization.jsonObject(with: resultData) as? [String: Any])
        let sources = try #require(result["sources"] as? [[String: Any]])
        #expect(sources.first?["url"] as? String == "https://www.fda.gov/example")
        #expect(record.sourceArtifactIDs?.count == 1)
        #expect(thread.sourceArtifacts?.first?.title == "FDA")
        #expect(thread.sourceArtifacts?.first?.providerID == AssistantResearchProvider.tavily.rawValue)
        #expect(thread.sourceArtifacts?.first?.extractedText == "FDA sodium evidence")
        let tavilyLog = try #require(harness.diagnostics.events.first(where: {
            $0.providerID == AssistantResearchProvider.tavily.rawValue
        }))
        #expect(tavilyLog.durationMs == 135)
        #expect(tavilyLog.providerRequestID == "tavily-tool-request")
        #expect(tavilyLog.payloadJSON?.contains("credits_used") == true)
        #expect(try harness.context.fetch(FetchDescriptor<GeminiScanLog>()).isEmpty)
        #expect(harness.proxy.turns.count == 2)
    }

    @Test func tavilySearchEncodesFastProviderNeutralRequestAndDecodesSources() async throws {
        let payload = #"""
        {
          "query": "FDA sodium daily value",
          "answer": null,
          "results": [
            {
              "title": "Daily Value on Nutrition Facts Labels",
              "url": "https://www.fda.gov/example",
              "content": "The Daily Value for sodium is listed on the label.",
              "score": 0.97
            },
            {
              "title": "Sodium guidance",
              "url": "https://www.cdc.gov/example",
              "content": "Guidance about dietary sodium.",
              "score": 0.81
            }
          ],
          "response_time": 0.123,
          "usage": {"credits": 1},
          "request_id": "tavily-request-1"
        }
        """#.data(using: .utf8)!
        StubChatURLProtocol.handler = { request in
            #expect(request.url == TavilyChatWebSearchProvider.searchURL)
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-tavily-key")
            let body = try #require(StubChatURLProtocol.bodyData(for: request))
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["query"] as? String == "FDA sodium daily value")
            #expect(json["search_depth"] as? String == "fast")
            #expect(json["include_answer"] as? Bool == false)
            #expect(json["include_raw_content"] as? Bool == false)
            #expect(json["max_results"] as? Int == 5)
            #expect(String(data: body, encoding: .utf8)?.contains("test-tavily-key") == false)
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                payload
            )
        }
        defer { StubChatURLProtocol.handler = nil }
        let provider = TavilyChatWebSearchProvider(
            apiKey: "test-tavily-key",
            depth: .fast,
            session: StubChatURLProtocol.session()
        )

        let result = try await provider.search(query: "FDA sodium daily value")

        #expect(result.providerID == AssistantResearchProvider.tavily.rawValue)
        #expect(result.modelID == "search-fast")
        #expect(result.providerRequestID == "tavily-request-1")
        #expect(result.durationMs == 123)
        #expect(result.creditsUsed == 1)
        #expect(result.usage == nil)
        #expect(result.sources.map(\.url) == [
            "https://www.fda.gov/example",
            "https://www.cdc.gov/example",
        ])
        #expect(result.text.contains("Daily Value on Nutrition Facts Labels"))
        #expect(result.text.contains("The Daily Value for sodium"))
    }

    @Test func tavilyConnectionUsesUsageEndpointAndSurfacesAuthenticationFailure() async throws {
        StubChatURLProtocol.handler = { request in
            #expect(request.url == TavilyChatWebSearchProvider.usageURL)
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer invalid-test-key")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"detail":"Invalid API key"}"#.utf8)
            )
        }
        defer { StubChatURLProtocol.handler = nil }
        let provider = TavilyChatWebSearchProvider(
            apiKey: "invalid-test-key",
            session: StubChatURLProtocol.session()
        )

        do {
            try await provider.testConnection()
            Issue.record("Expected authentication failure")
        } catch let ChatError.serverError(code, message) {
            #expect(code == 401)
            #expect(message == "Invalid API key")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func exaSearchEncodesProviderNeutralRequestAndDecodesSources() async throws {
        let payload = #"""
        {
          "requestId":"exa-request-1",
          "searchTime":0.08,
          "costDollars":{"total":0.004},
          "results":[{
            "title":"FDA Nutrition Facts",
            "url":"https://www.fda.gov/example",
            "text":"Official sodium guidance.",
            "highlights":["Sodium guidance"],
            "score":0.98
          }]
        }
        """#.data(using: .utf8)!
        StubChatURLProtocol.handler = { request in
            #expect(request.url == ExaChatWebSearchProvider.searchURL)
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-exa-key")
            let body = try #require(StubChatURLProtocol.bodyData(for: request))
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["type"] as? String == "auto")
            #expect(json["numResults"] as? Int == 5)
            #expect((json["query"] as? String)?.contains("FDA sodium") == true)
            #expect(String(data: body, encoding: .utf8)?.contains("test-exa-key") == false)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                payload
            )
        }
        defer { StubChatURLProtocol.handler = nil }

        let result = try await ExaChatWebSearchProvider(
            apiKey: "test-exa-key",
            session: StubChatURLProtocol.session()
        ).search(request: ChatWebSearchRequest(
            objective: "FDA sodium guidance",
            searchQueries: ["FDA sodium"]
        ))

        #expect(result.providerID == AssistantResearchProvider.exa.rawValue)
        #expect(result.providerRequestID == "exa-request-1")
        #expect(result.sources.first?.content == "Official sodium guidance.")
        #expect(result.citations.first?.url == "https://www.fda.gov/example")
        #expect(result.estimatedCostUSD == 0.004)
    }

    @Test func parallelSearchEncodesObjectiveQueriesModeAndDecodesExcerpts() async throws {
        let payload = #"""
        {
          "search_id": "search-parallel-1",
          "results": [
            {
              "url": "https://www.fda.gov/food/nutrition-facts-label",
              "title": "Nutrition Facts Label",
              "publish_date": "2026-07-01",
              "excerpts": [
                "Sodium appears on the Nutrition Facts label.",
                "Daily Values help consumers compare foods."
              ]
            },
            {
              "url": "https://www.cdc.gov/salt",
              "title": "About Sodium",
              "publish_date": null,
              "excerpts": ["Most dietary sodium comes from packaged foods."]
            }
          ],
          "session_id": "ofj-agent-run-123",
          "usage": [{"name":"search","count":1}]
        }
        """#.data(using: .utf8)!
        StubChatURLProtocol.handler = { request in
            #expect(request.url == ParallelChatWebSearchProvider.searchURL)
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-parallel-key")
            let body = try #require(StubChatURLProtocol.bodyData(for: request))
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["objective"] as? String == "Find current FDA sodium guidance")
            #expect(json["search_queries"] as? [String] == [
                "FDA sodium daily value",
                "CDC dietary sodium guidance",
            ])
            #expect(json["mode"] as? String == "basic")
            #expect(json["max_chars_total"] as? Int == 12_000)
            #expect(json["session_id"] as? String == "ofj-agent-run-123")
            #expect(json["client_model"] as? String == "gpt-5.6-terra")
            #expect(String(data: body, encoding: .utf8)?.contains("test-parallel-key") == false)
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                payload
            )
        }
        defer { StubChatURLProtocol.handler = nil }
        let provider = ParallelChatWebSearchProvider(
            apiKey: "test-parallel-key",
            mode: .basic,
            session: StubChatURLProtocol.session()
        )

        let result = try await provider.search(request: ChatWebSearchRequest(
            objective: "Find current FDA sodium guidance",
            searchQueries: ["FDA sodium daily value", "CDC dietary sodium guidance"],
            sessionID: "ofj-agent-run-123",
            clientModel: "gpt-5.6-terra"
        ))

        #expect(result.providerID == AssistantResearchProvider.parallel.rawValue)
        #expect(result.modelID == "search-basic")
        #expect(result.providerRequestID == "search-parallel-1")
        #expect(result.usage == nil)
        #expect(result.sources.count == 2)
        #expect(result.sources.first?.content?.contains("Daily Values") == true)
        #expect(result.text.contains("Published: 2026-07-01"))
        #expect(result.estimatedCostUSD == 0.005)
        #expect(result.pricingSource?.contains("2026-07-21") == true)
    }

    @Test func parallelSearchSurfacesProviderAuthenticationError() async throws {
        StubChatURLProtocol.handler = { request in
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"type":"error","error":{"ref_id":"ref-1","message":"Unauthorized: invalid credentials"}}"#.utf8)
            )
        }
        defer { StubChatURLProtocol.handler = nil }
        let provider = ParallelChatWebSearchProvider(
            apiKey: "invalid-parallel-key",
            session: StubChatURLProtocol.session()
        )

        do {
            _ = try await provider.search(query: "connection test")
            Issue.record("Expected authentication failure")
        } catch let ChatError.serverError(code, message) {
            #expect(code == 401)
            #expect(message == "Unauthorized: invalid credentials")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func parallelResearchPersistsProvenanceDiagnosticsAndDatedCost() async throws {
        let harness = try ChatTestHarness(provider: .azureOpenAI, primary: "terra-deployment")
        harness.research.enqueue(ChatWebSearchResult(
            text: "[1] FDA\nURL: https://www.fda.gov/example\nFocused evidence",
            usage: nil,
            citations: [ChatSourceCitation(
                url: "https://www.fda.gov/example",
                title: "FDA",
                startIndex: nil,
                endIndex: nil
            )],
            providerRequestID: "search-parallel-tool",
            providerID: AssistantResearchProvider.parallel.rawValue,
            modelID: "search-advanced",
            durationMs: 2_450,
            sources: [ChatWebSearchSource(
                url: "https://www.fda.gov/example",
                title: "FDA",
                content: "Focused evidence",
                score: nil
            )],
            estimatedCostUSD: 0.005,
            pricingSource: "Parallel Search public pricing verified 2026-07-21"
        ))
        harness.enqueueToolCall("web_search", args: .object([
            "query": .string("Find current FDA sodium guidance"),
            "search_queries": .array([
                .string("FDA sodium daily value"),
                .string("FDA nutrition label sodium"),
            ]),
        ]))
        let thread = harness.makeThread()

        await harness.service.send("Research sodium", in: thread)

        let search = try #require(harness.research.searches.first?.request)
        #expect(search.objective == "Find current FDA sodium guidance")
        #expect(search.searchQueries == ["FDA sodium daily value", "FDA nutrition label sodium"])
        #expect(search.clientModel == "terra-deployment")
        #expect(search.sessionID?.hasPrefix("ofj-agent-run-") == true)
        let source = try #require(thread.sourceArtifacts?.first)
        #expect(source.providerID == AssistantResearchProvider.parallel.rawValue)
        #expect(source.modelID == "search-advanced")
        #expect(source.extractedText == "Focused evidence")

        let log = try #require(harness.diagnostics.events.first(where: {
            $0.providerID == AssistantResearchProvider.parallel.rawValue
        }))
        #expect(log.durationMs == 2_450)
        #expect(log.estimatedCostUSD == 0.005)
        #expect(log.providerRequestID == "search-parallel-tool")
        #expect(log.payloadJSON?.contains("search-parallel-tool") == true)
        #expect(try harness.context.fetch(FetchDescriptor<GeminiScanLog>()).isEmpty)
        let accumulator = GeminiCostAccumulator.current(in: harness.context)
        #expect(abs(accumulator.totalEstimatedTokenCostUSD - 0.005) < 0.000_001)
    }

    @Test func fetchedHTMLIsExtractedAndFetchedPDFBecomesModelAttachment() async throws {
        let htmlHarness = try ChatTestHarness()
        let pageURL = URL(string: "https://example.com/nutrition")!
        htmlHarness.fetcher.register(
            url: pageURL,
            data: Data("<html><script>ignore()</script><body><h1>Nutrition Facts</h1><p>Protein 20g</p></body></html>".utf8),
            mimeType: "text/html"
        )
        let htmlRecord = try #require(await htmlHarness.runTool(
            "fetch_url",
            args: .object(["url": .string(pageURL.absoluteString)])
        ))
        #expect(htmlRecord.status == .completed)
        #expect(htmlRecord.resultJSON.contains("Nutrition Facts"))
        #expect(htmlRecord.resultJSON.contains("Protein 20g"))
        #expect(!htmlRecord.resultJSON.contains("ignore()"))

        let pdfHarness = try ChatTestHarness()
        let pdfURL = URL(string: "https://example.com/menu.pdf")!
        let pdfData = Data("%PDF-1.7 test menu".utf8)
        pdfHarness.fetcher.register(url: pdfURL, data: pdfData, mimeType: "application/pdf")
        pdfHarness.enqueueToolCall("fetch_url", args: .object(["url": .string(pdfURL.absoluteString)]))
        let pdfThread = pdfHarness.makeThread()
        await pdfHarness.service.send("Fetch the menu", in: pdfThread)

        let toolMessage = try #require(pdfThread.safeMessages.first(where: { $0.role == .tool }))
        let attachment = try #require(toolMessage.safeAttachments.first)
        #expect(attachment.data == pdfData)
        #expect(attachment.mimeType == "application/pdf")
        let secondRequest = try #require(pdfHarness.proxy.turns.dropFirst().first?.request)
        #expect(secondRequest.messages.contains { message in
            message.parts.contains(.attachment(ChatModelAttachment(
                data: pdfData,
                mimeType: "application/pdf",
                filename: "menu.pdf"
            )))
        })
    }

    @Test func durableSourceCanBeReadOnALaterTurn() async throws {
        let harness = try ChatTestHarness()
        let url = URL(string: "https://example.com/article")!
        harness.fetcher.register(
            url: url,
            data: Data("<html><title>Evidence</title><body>Persistent nutrition evidence</body></html>".utf8),
            mimeType: "text/html"
        )
        harness.enqueueToolCall("fetch_url", args: .object(["url": .string(url.absoluteString)]))
        let thread = harness.makeThread()
        await harness.service.send("Fetch it", in: thread)

        let source = try #require(thread.sourceArtifacts?.first)
        #expect(source.title == "Evidence")
        #expect(source.extractedText?.contains("Persistent nutrition evidence") == true)
        #expect(source.originatingMessageID != nil)

        let relaunchedWithOpenRouter = harness.replacementService(
            provider: .openRouter,
            primary: "openrouter-relaunch-model"
        )
        harness.enqueueToolCall(
            "read_conversation_source",
            args: .object(["source_id": .string(source.id.uuidString)])
        )
        await relaunchedWithOpenRouter.send("Read that source again", in: thread)

        let records = thread.safeMessages.compactMap(\.toolRecord)
        let readRecord = try #require(records.last)
        #expect(readRecord.name == "read_conversation_source")
        #expect(readRecord.resultJSON.contains("Persistent nutrition evidence"))
        #expect(harness.proxy.turns.last?.model == "openrouter-relaunch-model")
    }

    @Test func refetchingChangedURLCreatesLinkedSourceVersion() async throws {
        let harness = try ChatTestHarness()
        let url = URL(string: "https://example.com/changing")!
        let thread = harness.makeThread()
        harness.fetcher.register(
            url: url,
            data: Data("<html><body>Version one evidence</body></html>".utf8),
            mimeType: "text/html"
        )
        harness.enqueueToolCall("fetch_url", args: .object(["url": .string(url.absoluteString)]))
        await harness.service.send("Fetch version one", in: thread)
        let first = try #require(thread.sourceArtifacts?.first)

        harness.fetcher.register(
            url: url,
            data: Data("<html><body>Version two changed evidence</body></html>".utf8),
            mimeType: "text/html"
        )
        harness.enqueueToolCall("fetch_url", args: .object(["url": .string(url.absoluteString)]))
        await harness.service.send("Fetch it again", in: thread)

        let sources = try #require(thread.sourceArtifacts)
        #expect(sources.count == 2)
        let second = try #require(sources.first(where: { $0.id != first.id }))
        #expect(second.versionParentID == first.id)
        #expect(second.contentHash != first.contentHash)
        #expect(first.extractedText?.contains("Version one") == true)
        #expect(second.extractedText?.contains("Version two") == true)
    }

    @Test func sourceRemainsReadableBeyondThirtyMessagesAndAfterCompaction() async throws {
        let harness = try ChatTestHarness(contextBudget: .efficient)
        let url = URL(string: "https://example.com/durable-research")!
        harness.fetcher.register(
            url: url,
            data: Data("<html><title>Durable</title><body>Evidence survives compacted history.</body></html>".utf8),
            mimeType: "text/html"
        )
        harness.enqueueToolCall("fetch_url", args: .object(["url": .string(url.absoluteString)]))
        let thread = harness.makeThread()
        await harness.service.send("Fetch durable evidence", in: thread)
        let source = try #require(thread.sourceArtifacts?.first)

        let base = Date(timeIntervalSince1970: 1_700_400_000)
        for (index, message) in thread.safeMessages.enumerated() {
            message.timestamp = base.addingTimeInterval(Double(index))
        }
        for index in 0..<32 {
            let padding = String(repeating: "archived context ", count: 350)
            _ = harness.insertMessage(
                .user,
                text: "later-user-\(index) \(padding)",
                into: thread,
                timestamp: base.addingTimeInterval(Double(index * 2 + 10))
            )
            _ = harness.insertMessage(
                .model,
                text: "later-model-\(index) \(padding)",
                into: thread,
                timestamp: base.addingTimeInterval(Double(index * 2 + 11))
            )
        }

        harness.proxy.enqueue(ChatModelTurn(text: #"{"conversationDecisions":["Keep research durable"],"userConstraints":[],"goals":["Answer from saved evidence"],"unresolvedTasks":[],"toolOutcomes":[],"journalFacts":[]}"#))
        harness.proxy.enqueue(ChatModelTurn(calls: [ChatModelCall(
            callID: "read-old-source",
            thoughtSignature: "read-signature",
            modelTurnID: "read-turn",
            modelTurnIndex: 0,
            name: "read_conversation_source",
            args: .object(["source_id": .string(source.id.uuidString)])
        )]))
        harness.proxy.enqueue(ChatModelTurn(text: "The saved evidence is still available."))

        await harness.service.send("Use that old source", in: thread)

        let checkpoint = try #require(thread.contextCheckpoints?.last)
        #expect(checkpoint.decodedPayload?.sourceIDs.contains(source.id) == true)
        let readRecord = try #require(thread.safeMessages.compactMap(\.toolRecord).last)
        #expect(readRecord.name == "read_conversation_source")
        #expect(readRecord.resultJSON.contains("Evidence survives compacted history"))
        #expect(thread.safeMessages.count > 30)
        #expect(harness.service.contextUsage?.isCompacted == true)
    }

    @Test func automaticCompactionPersistsValidatedPortableCheckpointAndKeepsOriginalHistory() async throws {
        let harness = try ChatTestHarness(contextBudget: .efficient)
        let thread = harness.makeThread()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var firstMessageID: UUID?
        var firstMessageTimestamp: Date?
        for index in 0..<14 {
            let message = harness.insertMessage(
                index.isMultiple(of: 2) ? .user : .model,
                text: "turn-\(index) " + String(repeating: "context ", count: 1_200),
                into: thread,
                timestamp: base.addingTimeInterval(Double(index))
            )
            if index == 0 {
                firstMessageID = message.id
                firstMessageTimestamp = message.timestamp
            }
        }
        harness.proxy.enqueue(ChatModelTurn(text: #"{"conversationDecisions":["Use the saved plan"],"userConstraints":["Keep sources durable"],"goals":["Answer the latest question"],"unresolvedTasks":[],"toolOutcomes":[],"journalFacts":[]}"#))
        harness.proxy.enqueue(ChatModelTurn(text: "Compacted answer"))

        await harness.service.send("Continue", in: thread)

        #expect(harness.proxy.turns.count == 2)
        let checkpoint = try #require(thread.contextCheckpoints?.last)
        let payload = try #require(checkpoint.decodedPayload)
        #expect(payload.isStructurallyValid)
        #expect(payload.conversationDecisions == ["Use the saved plan"])
        #expect(checkpoint.wasDeterministicFallback == false)
        #expect(payload.transcriptStartMessageID == firstMessageID)
        #expect(payload.transcriptStartTimestamp == firstMessageTimestamp)
        #expect(checkpoint.startBoundaryMessageID == firstMessageID)
        #expect(checkpoint.validationStatusRaw == "validated")
        #expect(thread.safeMessages.count == 16)
        let finalRequest = harness.proxy.turns[1].request
        #expect(finalRequest.messages.first?.parts.contains(.text(payload.promptText)) == true)
        #expect(harness.service.contextUsage?.isCompacted == true)
        #expect(harness.service.contextUsage?.selectedLimit == 50_000)
    }

    @Test func failedCompactionUsesDeterministicCheckpointWithoutDeletingHistory() async throws {
        let harness = try ChatTestHarness(contextBudget: .efficient)
        let thread = harness.makeThread()
        let base = Date(timeIntervalSince1970: 1_700_100_000)
        for index in 0..<14 {
            _ = harness.insertMessage(
                index.isMultiple(of: 2) ? .user : .model,
                text: "fallback-turn-\(index) " + String(repeating: "evidence ", count: 1_200),
                into: thread,
                timestamp: base.addingTimeInterval(Double(index))
            )
        }
        harness.proxy.enqueue(error: ChatError.invalidResponse)
        harness.proxy.enqueue(ChatModelTurn(text: "Recovered from local checkpoint."))

        await harness.service.send("Continue safely", in: thread)

        let checkpoint = try #require(thread.contextCheckpoints?.last)
        #expect(checkpoint.wasDeterministicFallback)
        #expect(checkpoint.decodedPayload?.isStructurallyValid == true)
        #expect(thread.safeMessages.count == 16)
        #expect(harness.service.contextWarning?.contains("local fallback") == true)
        #expect(thread.safeMessages.last?.text == "Recovered from local checkpoint.")
    }

    @Test func checkpointWithMissingSourceReferenceIsIgnored() async throws {
        let harness = try ChatTestHarness()
        let thread = harness.makeThread()
        let base = Date(timeIntervalSince1970: 1_700_300_000)
        _ = harness.insertMessage(.user, text: "Keep this original request", into: thread, timestamp: base)
        let boundary = harness.insertMessage(
            .model,
            text: "Keep this original answer",
            into: thread,
            timestamp: base.addingTimeInterval(1)
        )
        let invalidPayload = ChatCheckpointPayload(
            conversationDecisions: ["Do not trust this checkpoint"],
            userConstraints: [],
            goals: [],
            unresolvedTasks: [],
            toolOutcomes: [],
            journalFacts: [],
            sourceIDs: [UUID()],
            attachmentIDs: [],
            transcriptBoundaryMessageID: boundary.id,
            transcriptBoundaryTimestamp: boundary.timestamp
        )
        let checkpoint = ChatContextCheckpoint(
            payload: invalidPayload,
            estimatedTokens: 10,
            providerID: "gemini",
            modelID: "test",
            wasDeterministicFallback: false
        )
        checkpoint.thread = thread
        harness.context.insert(checkpoint)
        thread.contextCheckpoints?.append(checkpoint)
        harness.proxy.enqueue(ChatModelTurn(text: "Used original history."))

        await harness.service.send("Continue", in: thread)

        let request = try #require(harness.proxy.turns.first?.request)
        #expect(request.messages.contains {
            $0.parts.contains(.text("Keep this original request"))
        })
        #expect(!request.messages.contains { message in
            message.parts.contains { part in
                if case .text(let text) = part {
                    return text.contains("Portable conversation checkpoint")
                }
                return false
            }
        })
    }

    @Test func hardContextCapRejectsOversizedAttachmentBeforeProviderRequest() async throws {
        let harness = try ChatTestHarness(contextBudget: .efficient)
        let thread = harness.makeThread()
        let oversizedPDF = ChatDraftAttachment(
            data: Data(repeating: 0x20, count: 220_000),
            mimeType: "application/pdf",
            filename: "oversized-context.pdf"
        )

        await harness.service.send("Read this", attachments: [oversizedPDF], in: thread)

        #expect(harness.proxy.turns.isEmpty)
        if case .contextLimit? = harness.service.lastError {
            // Expected.
        } else {
            Issue.record("Expected the selected hard context cap to reject the request")
        }
        #expect(harness.service.contextUsage?.selectedLimit == 50_000)
        #expect(harness.service.contextUsage?.isContextLimited == true)
    }
}

struct ChatProviderAdapterContractTests {
    private let image = ChatModelAttachment(data: Data([1, 2, 3]), mimeType: "image/png", filename: "label.png")
    private let pdf = ChatModelAttachment(data: Data("%PDF".utf8), mimeType: "application/pdf", filename: "menu.pdf")

    private var request: ChatModelRequest {
        let calls = [
            ChatModelCall(callID: "call-1", thoughtSignature: "signature", modelTurnID: "turn", modelTurnIndex: 0, name: "get_goals", args: .object([:])),
            ChatModelCall(callID: "call-2", thoughtSignature: nil, modelTurnID: "turn", modelTurnIndex: 1, name: "get_active_energy", args: .object(["date": .string("2026-07-20")]))
        ]
        return ChatModelRequest(
            systemPrompt: "System",
            messages: [
                ChatModelMessage(role: .user, parts: [.text("Files"), .attachment(image), .attachment(pdf)]),
                ChatModelMessage(role: .model, parts: calls.map(ChatModelPart.functionCall)),
                ChatModelMessage(role: .user, parts: [
                    .functionResponse(ChatModelResponse(callID: "call-1", name: "get_goals", response: .object(["ok": .bool(true)]))),
                    .functionResponse(ChatModelResponse(callID: "call-2", name: "get_active_energy", response: .object(["kcal": .number(432)]))),
                ]),
            ],
            tools: [ChatModelTool(name: "get_goals", description: "Goals", parameters: nil)]
        )
    }

    @MainActor
    @Test func geminiAdapterMapsGenericPartsAndReplayMetadata() throws {
        let data = try GeminiChatModelProxy.encodedTurnRequest(request)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let contents = try #require(root["contents"] as? [[String: Any]])
        let attachmentParts = try #require(contents[0]["parts"] as? [[String: Any]])
        #expect(attachmentParts.compactMap { $0["inlineData"] }.count == 2)

        let callParts = try #require(contents[1]["parts"] as? [[String: Any]])
        #expect(callParts.count == 2)
        #expect(callParts[0]["thoughtSignature"] as? String == "signature")
        #expect((callParts[0]["functionCall"] as? [String: Any])?["id"] as? String == "call-1")
        #expect((callParts[1]["functionCall"] as? [String: Any])?["id"] as? String == "call-2")

        let responses = try #require(contents[2]["parts"] as? [[String: Any]])
        #expect((responses[0]["functionResponse"] as? [String: Any])?["id"] as? String == "call-1")
        #expect((responses[1]["functionResponse"] as? [String: Any])?["id"] as? String == "call-2")
    }

    @MainActor
    @Test func openRouterAdapterMapsGenericAttachmentsAndParallelCalls() throws {
        let data = try OpenRouterChatModelProxy.encodedTurnRequest(
            model: "provider/model",
            request: request,
            routingMode: .requireGoogleVertex
        )
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(root["messages"] as? [[String: Any]])
        let fileParts = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(fileParts.map { $0["type"] as? String } == ["text", "image_url", "file"])

        let assistant = try #require(messages.first(where: { $0["role"] as? String == "assistant" }))
        let toolCalls = try #require(assistant["tool_calls"] as? [[String: Any]])
        #expect(toolCalls.count == 2)
        #expect(toolCalls.map { $0["id"] as? String } == ["call-1", "call-2"])
        let toolMessages = messages.filter { $0["role"] as? String == "tool" }
        #expect(toolMessages.map { $0["tool_call_id"] as? String } == ["call-1", "call-2"])
        let provider = try #require(root["provider"] as? [String: Any])
        #expect(provider["order"] as? [String] == [AIProviderSettings.googleVertexProviderSlug])
        #expect(provider["allow_fallbacks"] as? Bool == false)
    }

    @MainActor
    @Test func geminiAdapterDecodesThoughtSignatureAndProviderCallIDFromSSE() async throws {
        let payload = #"""
        data: {"modelVersion":"gemini-3.6-flash","candidates":[{"content":{"parts":[{"functionCall":{"id":"gemini-call","name":"get_goals","args":{}},"thoughtSignature":"opaque-signature=="}]}}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":2,"thoughtsTokenCount":3}}
        data: [DONE]

        """#.data(using: .utf8)!
        StubChatURLProtocol.handler = { request in
            #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "key")
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!,
                payload
            )
        }
        defer { StubChatURLProtocol.handler = nil }
        let proxy = GeminiChatModelProxy(
            configuration: ChatProxyConfiguration(
                descriptor: ChatModelCatalog.descriptor(provider: .gemini, model: "gemini-test"),
                apiKey: "key"
            ),
            session: StubChatURLProtocol.session()
        )

        let turn = try await proxy.streamTurn(
            request: request,
            onTextUpdate: { _ in }
        )

        let call = try #require(turn.calls.first)
        #expect(call.callID == "gemini-call")
        #expect(call.thoughtSignature == "opaque-signature==")
        #expect(call.name == "get_goals")
        #expect(turn.usage == ChatTokenUsage(input: 10, output: 2, thinking: 3))
        #expect(turn.resolvedModelID == "gemini-3.6-flash")
    }

    @MainActor
    @Test func openRouterAdapterAssemblesParallelStreamedToolCallsAndIDs() async throws {
        let payload = #"""
        data: {"model":"google/gemini-3.6-flash","choices":[{"delta":{"tool_calls":[{"index":0,"id":"or-call-1","function":{"name":"get_","arguments":"{"}},{"index":1,"id":"or-call-2","function":{"name":"get_active_energy","arguments":"{\"date\":"}}]}}]}
        data: {"model":"google/gemini-3.6-flash","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"goals","arguments":"}"}},{"index":1,"function":{"arguments":"\"2026-07-20\"}"}}]}}],"usage":{"prompt_tokens":20,"completion_tokens":5}}
        data: [DONE]

        """#.data(using: .utf8)!
        StubChatURLProtocol.handler = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer key")
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!,
                payload
            )
        }
        defer { StubChatURLProtocol.handler = nil }
        let proxy = OpenRouterChatModelProxy(
            configuration: ChatProxyConfiguration(
                descriptor: ChatModelCatalog.descriptor(provider: .openRouter, model: "provider/model"),
                apiKey: "key"
            ),
            session: StubChatURLProtocol.session()
        )

        let turn = try await proxy.streamTurn(
            request: request,
            onTextUpdate: { _ in }
        )

        #expect(turn.calls.map(\.callID) == ["or-call-1", "or-call-2"])
        #expect(turn.calls.map(\.name) == ["get_goals", "get_active_energy"])
        #expect(turn.calls[1].args["date"]?.stringValue == "2026-07-20")
        #expect(turn.usage == ChatTokenUsage(input: 20, output: 5, thinking: 0))
        #expect(turn.resolvedModelID == "google/gemini-3.6-flash")
    }

    @MainActor
    @Test func museSparkAdapterUsesMetaRuntimeSlugAndStandardToolCalls() async throws {
        let payload = #"""
        data: {"model":"muse-spark-1.2","choices":[{"delta":{"content":"Done.","tool_calls":[{"index":0,"id":"muse-call","function":{"name":"get_goals","arguments":"{}"}}]}}],"usage":{"prompt_tokens":30,"completion_tokens":6}}
        data: [DONE]

        """#.data(using: .utf8)!
        StubChatURLProtocol.handler = { request in
            #expect(request.url?.absoluteString == "https://api.meta.ai/v1/chat/completions")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer meta-key")
            let body = try #require(StubChatURLProtocol.bodyData(for: request))
            let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(root["model"] as? String == "muse-spark-1.2")
            #expect(root["provider"] == nil)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["x-request-id": "meta-request"])!,
                payload
            )
        }
        defer { StubChatURLProtocol.handler = nil }
        let proxy = MuseSparkChatModelProxy(
            configuration: ChatProxyConfiguration(
                descriptor: ChatModelCatalog.descriptor(provider: .museSpark, model: "muse-spark-1.2"),
                apiKey: "meta-key",
                endpoint: URL(string: "https://api.meta.ai/v1")
            ),
            session: StubChatURLProtocol.session()
        )

        let turn = try await proxy.streamTurn(request: request, onTextUpdate: { _ in })
        #expect(turn.text == "Done.")
        #expect(turn.calls.first?.callID == "muse-call")
        #expect(turn.calls.first?.name == "get_goals")
        #expect(turn.providerRequestID == "meta-request")
        #expect(turn.usage == ChatTokenUsage(input: 30, output: 6, thinking: 0))
    }

    @MainActor
    @Test func azureAdapterMapsStatelessResponsesAttachmentsContinuationsAndCallIDs() throws {
        let descriptor = ChatModelCatalog.azureDescriptor(model: .sol, deployment: "my-sol-deployment")
        let configuration = ChatProxyConfiguration(
            descriptor: descriptor,
            apiKey: "secret-not-in-body",
            endpoint: URL(string: "https://sample.openai.azure.com/openai/v1")
        )
        let continuation = ChatProviderContinuation(
            providerID: AssistantProvider.azureOpenAI.rawValue,
            modelTurnID: "response-1",
            ordinal: 0,
            kind: "reasoning.encrypted_content",
            payload: .object([
                "type": .string("reasoning"),
                "id": .string("reasoning-1"),
                "encrypted_content": .string("opaque=="),
            ])
        )
        var azureRequest = request
        azureRequest = ChatModelRequest(
            systemPrompt: azureRequest.systemPrompt,
            messages: [
                azureRequest.messages[0],
                ChatModelMessage(role: .model, parts: [
                    .providerContinuation(continuation),
                    .functionCall(ChatModelCall(
                        callID: "azure-call",
                        thoughtSignature: nil,
                        modelTurnID: "response-1",
                        modelTurnIndex: 1,
                        name: "get_goals",
                        args: .object([:])
                    )),
                ]),
                ChatModelMessage(role: .user, parts: [
                    .functionResponse(ChatModelResponse(
                        callID: "azure-call",
                        name: "get_goals",
                        response: .object(["ok": .bool(true)])
                    )),
                ]),
            ],
            tools: azureRequest.tools
        )

        let data = try AzureOpenAIChatModelProxy.encodedTurnRequest(
            configuration: configuration,
            request: azureRequest
        )
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["model"] as? String == "my-sol-deployment")
        #expect(root["store"] as? Bool == false)
        #expect(root["stream"] as? Bool == true)
        #expect(root["parallel_tool_calls"] as? Bool == true)
        #expect(root["previous_response_id"] == nil)
        #expect(String(data: data, encoding: .utf8)?.contains("secret-not-in-body") == false)
        #expect(root["include"] as? [String] == ["reasoning.encrypted_content"])

        let input = try #require(root["input"] as? [[String: Any]])
        let firstContent = try #require(input.first?["content"] as? [[String: Any]])
        #expect(firstContent.map { $0["type"] as? String } == ["input_text", "input_image", "input_file"])
        let reasoning = try #require(input.first(where: { $0["type"] as? String == "reasoning" }))
        #expect(reasoning["encrypted_content"] as? String == "opaque==")
        let call = try #require(input.first(where: { $0["type"] as? String == "function_call" }))
        #expect(call["call_id"] as? String == "azure-call")
        let output = try #require(input.first(where: { $0["type"] as? String == "function_call_output" }))
        #expect(output["call_id"] as? String == "azure-call")
    }

    @MainActor
    @Test func openAIAdapterUsesTheSamePortableResponsesContract() throws {
        let descriptor = ChatModelCatalog.openAIDescriptor(model: .terra, deployment: "gpt-5.6-terra")
        let continuation = ChatProviderContinuation(
            providerID: AssistantProvider.openAI.rawValue,
            modelTurnID: "response-openai",
            ordinal: 0,
            kind: "reasoning.encrypted_content",
            payload: .object([
                "type": .string("reasoning"),
                "id": .string("reasoning-openai"),
                "encrypted_content": .string("opaque-openai=="),
            ])
        )
        let openAIRequest = ChatModelRequest(
            systemPrompt: request.systemPrompt,
            messages: [
                ChatModelMessage(role: .model, parts: [
                    .providerContinuation(continuation),
                    .functionCall(ChatModelCall(
                        callID: "openai-call",
                        thoughtSignature: nil,
                        modelTurnID: "response-openai",
                        modelTurnIndex: 1,
                        name: "get_goals",
                        args: .object([:])
                    )),
                ]),
                ChatModelMessage(role: .user, parts: [
                    .functionResponse(ChatModelResponse(
                        callID: "openai-call",
                        name: "get_goals",
                        response: .object(["ok": .bool(true)])
                    )),
                ]),
            ],
            tools: request.tools
        )
        let data = try OpenAIResponsesChatModelProxy.encodedTurnRequest(
            configuration: ChatProxyConfiguration(
                descriptor: descriptor,
                apiKey: "not-in-body",
                endpoint: URL(string: "https://api.openai.com/v1")
            ),
            request: openAIRequest
        )
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["model"] as? String == "gpt-5.6-terra")
        #expect(root["store"] as? Bool == false)
        let input = try #require(root["input"] as? [[String: Any]])
        #expect(input.first?["encrypted_content"] as? String == "opaque-openai==")
        #expect(input.first(where: { $0["type"] as? String == "function_call" })?["call_id"] as? String == "openai-call")
        #expect(input.first(where: { $0["type"] as? String == "function_call_output" })?["call_id"] as? String == "openai-call")
    }

    @MainActor
    @Test func openAIAdapterUsesBearerAuthenticationAtResponsesEndpoint() async throws {
        let payload = #"""
        data: {"type":"response.output_text.delta","delta":"Hello"}
        data: {"type":"response.completed","response":{"id":"resp-openai","model":"gpt-5.6-terra","output":[{"type":"message","content":[{"type":"output_text","text":"Hello","annotations":[]}]}],"usage":{"input_tokens":12,"output_tokens":3}}}
        data: [DONE]

        """#.data(using: .utf8)!
        StubChatURLProtocol.handler = { request in
            #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer openai-key")
            #expect(request.value(forHTTPHeaderField: "api-key") == nil)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["x-request-id": "request-openai"])!,
                payload
            )
        }
        defer { StubChatURLProtocol.handler = nil }
        let proxy = OpenAIResponsesChatModelProxy(
            configuration: ChatProxyConfiguration(
                descriptor: ChatModelCatalog.openAIDescriptor(model: .terra, deployment: "gpt-5.6-terra"),
                apiKey: "openai-key",
                endpoint: URL(string: "https://api.openai.com/v1")
            ),
            session: StubChatURLProtocol.session()
        )

        let turn = try await proxy.streamTurn(request: request, onTextUpdate: { _ in })
        #expect(turn.text == "Hello")
        #expect(turn.providerRequestID == "request-openai")
        #expect(turn.providerID == AssistantProvider.openAI.rawValue)
        #expect(turn.usage == ChatTokenUsage(input: 12, output: 3, thinking: 0))
    }

    @MainActor
    @Test func anthropicAdapterReplaysSignedThinkingAndMatchingToolIDs() throws {
        let descriptor = ChatModelCatalog.descriptor(provider: .anthropic, model: "claude-sonnet-5")
        let continuation = ChatProviderContinuation(
            providerID: AssistantProvider.anthropic.rawValue,
            modelTurnID: "msg-1",
            ordinal: 0,
            kind: "thinking.signature",
            payload: .object([
                "type": .string("thinking"),
                "thinking": .string("opaque provider state"),
                "signature": .string("anthropic-signature=="),
            ])
        )
        let anthropicRequest = ChatModelRequest(
            systemPrompt: "System",
            messages: [
                ChatModelMessage(role: .model, parts: [
                    .providerContinuation(continuation),
                    .functionCall(ChatModelCall(
                        callID: "toolu_123",
                        thoughtSignature: nil,
                        modelTurnID: "msg-1",
                        modelTurnIndex: 1,
                        name: "get_goals",
                        args: .object([:])
                    )),
                ]),
                ChatModelMessage(role: .user, parts: [
                    .functionResponse(ChatModelResponse(
                        callID: "toolu_123",
                        name: "get_goals",
                        response: .object(["ok": .bool(true)])
                    )),
                ]),
            ],
            tools: request.tools
        )
        let data = try AnthropicChatModelProxy.encodedTurnRequest(
            configuration: ChatProxyConfiguration(
                descriptor: descriptor,
                apiKey: "not-in-body",
                endpoint: URL(string: "https://api.anthropic.com/v1")
            ),
            request: anthropicRequest
        )
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(root["messages"] as? [[String: Any]])
        let assistant = try #require(messages.first?["content"] as? [[String: Any]])
        #expect(assistant[0]["signature"] as? String == "anthropic-signature==")
        #expect(assistant[1]["id"] as? String == "toolu_123")
        let results = try #require(messages.last?["content"] as? [[String: Any]])
        #expect(results.first?["tool_use_id"] as? String == "toolu_123")
        #expect(String(data: data, encoding: .utf8)?.contains("not-in-body") == false)
    }

    @MainActor
    @Test func anthropicAdapterDecodesSignedThinkingUsageAndToolCall() async throws {
        let payload = #"""
        data: {"type":"message_start","message":{"id":"msg_42","model":"claude-sonnet-5","usage":{"input_tokens":10,"cache_read_input_tokens":4,"cache_creation_input_tokens":1}}}
        data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"opaque state","signature":""}}
        data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"signed=="}}
        data: {"type":"content_block_stop","index":0}
        data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":"Checking."}}
        data: {"type":"content_block_stop","index":1}
        data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_42","name":"get_goals","input":{}}}
        data: {"type":"content_block_stop","index":2}
        data: {"type":"message_delta","usage":{"output_tokens":8}}
        data: {"type":"message_stop"}

        """#.data(using: .utf8)!
        StubChatURLProtocol.handler = { request in
            #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "anthropic-key")
            #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["request-id": "request-42"])!,
                payload
            )
        }
        defer { StubChatURLProtocol.handler = nil }
        let proxy = AnthropicChatModelProxy(
            configuration: ChatProxyConfiguration(
                descriptor: ChatModelCatalog.descriptor(provider: .anthropic, model: "claude-sonnet-5"),
                apiKey: "anthropic-key",
                endpoint: URL(string: "https://api.anthropic.com/v1")
            ),
            session: StubChatURLProtocol.session()
        )

        let turn = try await proxy.streamTurn(request: request, onTextUpdate: { _ in })
        #expect(turn.text == "Checking.")
        #expect(turn.calls.first?.callID == "toolu_42")
        #expect(turn.calls.first?.modelTurnID == "msg_42")
        #expect(turn.continuations.first?.payload["signature"]?.stringValue == "signed==")
        #expect(turn.usage == ChatTokenUsage(input: 15, cachedInput: 5, output: 8, thinking: 0))
        #expect(turn.providerRequestID == "request-42")
    }

    @MainActor
    @Test func azureAdapterDecodesEncryptedReasoningParallelCallsCitationsAndUsage() async throws {
        let payload = #"""
        data: {"type":"response.output_text.delta","delta":"Found it."}
        data: {"type":"response.completed","response":{"id":"resp-42","model":"gpt-5.6-terra","output":[{"type":"reasoning","id":"rs-1","encrypted_content":"opaque=="},{"type":"function_call","call_id":"call-a","name":"get_goals","arguments":"{}"},{"type":"function_call","call_id":"call-b","name":"get_active_energy","arguments":"{\"date\":\"2026-07-20\"}"},{"type":"message","content":[{"type":"output_text","text":"Found it.","annotations":[{"type":"url_citation","url":"https://example.com/source","title":"Source","start_index":0,"end_index":8}]}]}],"usage":{"input_tokens":100,"input_tokens_details":{"cached_tokens":40},"output_tokens":20,"output_tokens_details":{"reasoning_tokens":7}}}}
        data: [DONE]

        """#.data(using: .utf8)!
        StubChatURLProtocol.handler = { request in
            #expect(request.value(forHTTPHeaderField: "api-key") == "azure-key")
            #expect(request.url?.absoluteString == "https://sample.openai.azure.com/openai/v1/responses")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/event-stream", "x-request-id": "request-42"]
                )!,
                payload
            )
        }
        defer { StubChatURLProtocol.handler = nil }
        let proxy = AzureOpenAIChatModelProxy(
            configuration: ChatProxyConfiguration(
                descriptor: ChatModelCatalog.azureDescriptor(model: .terra, deployment: "terra-deploy"),
                apiKey: "azure-key",
                endpoint: URL(string: "https://sample.openai.azure.com/openai/v1")
            ),
            session: StubChatURLProtocol.session()
        )

        let turn = try await proxy.streamTurn(request: request, onTextUpdate: { _ in })

        #expect(turn.text == "Found it.")
        #expect(turn.providerRequestID == "request-42")
        #expect(turn.calls.map(\.callID) == ["call-a", "call-b"])
        #expect(turn.calls.map(\.modelTurnID) == ["resp-42", "resp-42"])
        #expect(turn.calls.map(\.modelTurnIndex) == [1, 2])
        #expect(turn.calls[1].args["date"]?.stringValue == "2026-07-20")
        #expect(turn.continuations.first?.payload["encrypted_content"]?.stringValue == "opaque==")
        #expect(turn.continuations.first?.ordinal == 0)
        #expect(turn.citations.first?.url == "https://example.com/source")
        #expect(turn.usage == ChatTokenUsage(input: 100, cachedInput: 40, output: 20, thinking: 7))
        #expect(turn.resolvedModelID == "gpt-5.6-terra")
    }

    @Test func azureEndpointValidationAndCapabilityCatalogAreConservative() throws {
        let normalized = try AzureOpenAIEndpoint.normalizedBaseURL(
            from: " https://MyResource.openai.azure.com/openai/v1/ "
        )
        #expect(normalized.absoluteString == "https://myresource.openai.azure.com/openai/v1")
        #expect(throws: AzureOpenAIEndpoint.ValidationError.self) {
            try AzureOpenAIEndpoint.normalizedBaseURL(
                from: "https://sample.openai.azure.com/custom?ignored=true"
            )
        }
        #expect(throws: AzureOpenAIEndpoint.ValidationError.self) {
            try AzureOpenAIEndpoint.normalizedBaseURL(from: "http://sample.openai.azure.com")
        }
        #expect(throws: AzureOpenAIEndpoint.ValidationError.self) {
            try AzureOpenAIEndpoint.normalizedBaseURL(from: "https://key@example.com")
        }
        #expect(throws: AzureOpenAIEndpoint.ValidationError.self) {
            try AzureOpenAIEndpoint.normalizedBaseURL(from: "https://127.0.0.1")
        }

        let sol = ChatModelCatalog.azureDescriptor(model: .sol, deployment: "custom")
        #expect(sol.capabilities.maximumInputTokens == 922_000)
        #expect(sol.capabilities.maximumOutputTokens == 128_000)
        #expect(sol.capabilities.supportsParallelCalls)
        #expect(sol.capabilities.supportsImages)
        #expect(sol.capabilities.supportsPDFs)
        #expect(ChatContextBudget.efficient.inputLimit(for: sol) == 50_000)
        #expect(ChatContextBudget.balanced.inputLimit(for: sol) == 200_000)
        #expect(ChatContextBudget.maximum.inputLimit(for: sol) == 922_000)

        let unknown = ChatModelCatalog.descriptor(provider: .openRouter, model: "unknown/model")
        #expect(unknown.capabilities.maximumInputTokens == 50_000)
    }
}
