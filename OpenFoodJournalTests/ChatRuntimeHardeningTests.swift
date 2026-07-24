// OpenFoodJournal — Build 7 Assistant runtime hardening contracts

import Foundation
import SwiftData
import Testing
@testable import OpenFoodJournal

@MainActor
private final class ManualChatClock: ChatMonotonicClock {
    var now: TimeInterval = 0

    func sleep(for seconds: TimeInterval) async throws {
        now += max(0, seconds)
        try Task.checkCancellation()
    }

    func advance(_ seconds: TimeInterval) {
        now += seconds
    }
}

@MainActor
struct ChatRuntimeHardeningTests {
    @Test func fastPolicyLocksTheShortBuildSevenDeadlines() {
        let policy = ChatDeadlinePolicy.fast
        #expect(policy.localRead == 1)
        #expect(policy.healthRead == 3)
        #expect(policy.webSearch == 10)
        #expect(policy.fetch == 15)
        #expect(policy.firstProviderEvent == 10)
        #expect(policy.idleProviderStream == 8)
        #expect(policy.modelTurn == 90)
        #expect(policy.activeRun == 180)
        #expect(policy.stillWaitingAfter == 3)
        #expect(ChatRetryPolicy.fast.maximumAutomaticRetries == 1)
        #expect(ChatRetryPolicy.fast.backoff(jitterUnit: -1) == 0.2)
        #expect(ChatRetryPolicy.fast.backoff(jitterUnit: 1) == 0.3)
        #expect(ChatRetryPolicy.fast.maximumAutomaticRetryAfter == 5)
    }

    @Test func deadlineMonitorCountsOnlyRealProviderEventsAndResetsIdleBoundary() {
        let clock = ManualChatClock()
        let monitor = ChatProviderDeadlineMonitor(clock: clock)

        monitor.receive(.encodingStarted)
        clock.advance(2)
        monitor.receive(.requestEncoded(byteCount: 100))
        monitor.receive(.responseHeaders(statusCode: 200, requestID: "request-1", retryAfter: nil))
        #expect(monitor.providerEventCount == 0)
        #expect(monitor.encodingMs == 2_000)

        clock.advance(3)
        monitor.receive(.providerEvent(kind: "delta"))
        #expect(monitor.providerEventCount == 1)
        #expect(monitor.firstProviderEventMs == 5_000)
        let firstIdleBoundary = monitor.latestEventAt

        clock.advance(7.5)
        monitor.receive(.usage(ChatTokenUsage(input: 10, output: 2)))
        #expect(monitor.providerEventCount == 2)
        #expect((monitor.latestEventAt ?? 0) > (firstIdleBoundary ?? 0))

        clock.advance(1)
        monitor.receive(.reasoningSummary("Documented summary"))
        clock.advance(1)
        monitor.receive(.visibleText("Visible"))
        #expect(monitor.providerEventCount == 4)
        #expect(monitor.firstVisibleTextMs == 14_500)
    }

    @Test func submitPersistsAcknowledgementAndQueuedRunBeforeProviderWork() async throws {
        let harness = try ChatTestHarness()
        harness.proxy.enqueue(ChatModelTurn(text: "Late response"))
        harness.proxy.nextTurnDelayNanoseconds = 30_000_000_000
        let thread = harness.makeThread()

        let result = harness.service.submit("Persist me immediately", in: thread)

        guard case .accepted(let runID, let messageID) = result else {
            Issue.record("Expected the synchronous send gate to accept the message")
            return
        }
        let persistedMessages = try harness.context.fetch(FetchDescriptor<ChatMessage>())
        let persistedRuns = try harness.context.fetch(FetchDescriptor<ChatAgentRun>())
        #expect(persistedMessages.contains { $0.id == messageID && $0.text == "Persist me immediately" })
        #expect(persistedRuns.contains { $0.id == runID })
        #expect(harness.service.activeRunID == runID)
        #expect(harness.service.isStreaming)

        harness.service.cancelCurrentRun()
        await waitUntilIdle(harness.service)
    }

    @Test func appWideSendGateRejectsDuplicateWithoutCreatingAnotherBubble() async throws {
        let harness = try ChatTestHarness()
        harness.proxy.enqueue(ChatModelTurn(text: "Only one"))
        harness.proxy.nextTurnDelayNanoseconds = 30_000_000_000
        let firstThread = harness.makeThread()
        let secondThread = harness.makeThread()

        guard case .accepted = harness.service.submit("First", in: firstThread) else {
            Issue.record("First send should be accepted")
            return
        }
        #expect(harness.service.submit("Duplicate", in: secondThread) == .rejectedBusy)
        #expect(firstThread.safeMessages.map(\.text) == ["First"])
        #expect(secondThread.safeMessages.isEmpty)

        harness.service.cancelCurrentRun()
        await waitUntilIdle(harness.service)
    }

    @Test func missingCredentialKeepsUserTranscriptAndPersistsFailedPhase() async throws {
        let harness = try ChatTestHarness(apiKey: nil)
        let thread = harness.makeThread()

        guard case .accepted = harness.service.submit("Keep this bubble", in: thread) else {
            Issue.record("Configuration is checked only after persistence")
            return
        }
        await waitUntilIdle(harness.service)

        #expect(thread.safeMessages.map(\.text) == ["Keep this bubble"])
        let run = try #require(thread.agentRuns?.last)
        #expect(run.phase == .failed)
        #expect(run.retryableStep == "provider_configuration")
        if case .noAPIKey? = harness.service.lastError {
            // Expected.
        } else {
            Issue.record("Expected missing-key failure after persistence")
        }
    }

    @Test func submitRepairsMissingAndDuplicateLegacyOrdinalsDeterministically() async throws {
        let harness = try ChatTestHarness()
        harness.proxy.enqueue(ChatModelTurn(text: "Ordered"))
        let thread = harness.makeThread()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let second = harness.insertMessage(.model, text: "second", into: thread, timestamp: base.addingTimeInterval(1))
        let first = harness.insertMessage(.user, text: "first", into: thread, timestamp: base)
        first.transcriptOrdinal = 0
        second.transcriptOrdinal = 0

        await harness.service.send("third", in: thread)

        #expect(Array(thread.safeMessages.prefix(3)).map(\.text) == ["first", "second", "third"])
        #expect(thread.safeMessages.map(\.transcriptOrdinal) == Array(1...thread.safeMessages.count).map(Int64.init))
    }

    @Test func backgroundingSnapshotsPartialAnswerAndRequiresExplicitContinue() async throws {
        let harness = try ChatTestHarness()
        harness.proxy.enqueue(ChatModelTurn(text: "Final text must not arrive"))
        harness.proxy.preResultEvents = [
            .providerEvent(kind: "partial"),
            .visibleText("Saved partial answer"),
        ]
        harness.proxy.nextTurnDelayNanoseconds = 30_000_000_000
        let thread = harness.makeThread()
        _ = harness.service.submit("Start then background", in: thread)

        for _ in 0..<200 where harness.service.streamingText.isEmpty { await Task.yield() }
        #expect(harness.service.streamingText == "Saved partial answer")
        harness.service.suspendForBackgrounding()
        await waitUntilIdle(harness.service)

        let run = try #require(thread.agentRuns?.last)
        #expect(run.phase == .suspended)
        #expect(run.partialVisibleAnswer == "Saved partial answer")
        #expect(harness.service.interruptedThreadIDs.contains(thread.id))
        #expect(harness.proxy.turns.count == 1)
    }

    @Test func parallelReadGroupUsesAtMostThreeWorkersAndPreservesProviderOrder() async throws {
        let deadlines = ChatDeadlinePolicy(
            localRead: 1,
            healthRead: 1,
            webSearch: 1,
            fetch: 1,
            firstProviderEvent: 1,
            idleProviderStream: 1,
            modelTurn: 5,
            activeRun: 10,
            stillWaitingAfter: 0.1
        )
        let harness = try ChatTestHarness(deadlinePolicy: deadlines)
        harness.health.delayNanoseconds = 100_000_000
        let calls = (0..<4).map { index in
            ChatModelCall(
                callID: "parallel-\(index)",
                thoughtSignature: nil,
                modelTurnID: "parallel-turn",
                modelTurnIndex: index,
                name: "get_active_energy",
                args: .object(["date": .string("2026-07-\(20 + index)")])
            )
        }
        harness.proxy.enqueue(ChatModelTurn(calls: calls))
        harness.proxy.enqueue(ChatModelTurn(text: "Parallel reads complete"))
        let thread = harness.makeThread()
        let started = ContinuousClock.now

        await harness.service.send("Read four days", in: thread)
        let elapsed = started.duration(to: .now)
        let records = thread.safeMessages.compactMap(\.toolRecord)

        #expect(harness.health.maximumConcurrentRequests == 3)
        #expect(elapsed < .milliseconds(350))
        #expect(records.map(\.callID) == calls.map(\.callID))
        #expect(records.allSatisfy { $0.status == .completed })
    }

    @Test func retryAfterLongerThanFiveSecondsBecomesManualRateLimit() async throws {
        let harness = try ChatTestHarness()
        harness.proxy.nextResponseHeaders = (429, "rate-request", 6)
        harness.proxy.enqueue(error: ChatError.serverError(429, "slow down"))
        harness.proxy.enqueue(ChatModelTurn(text: "Must not retry automatically"))
        let thread = harness.makeThread()

        await harness.service.send("Rate limited request", in: thread)

        #expect(harness.proxy.turns.count == 1)
        if case .rateLimited(let retryAt, _)? = harness.service.lastError {
            #expect(retryAt != nil)
        } else {
            Issue.record("Expected a manual rate-limit state")
        }
    }

    @Test func detailedSpansPruneAtFourteenDaysButUsageAggregatesRemain() throws {
        let harness = try ChatTestHarness()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = ChatDiagnosticSpan(
            runID: UUID(),
            threadID: nil,
            kind: "old",
            providerID: "azureOpenAI",
            baseModelID: "gpt-5.6-terra",
            deploymentID: "terra",
            startedAt: now.addingTimeInterval(-15 * 86_400),
            endedAt: now.addingTimeInterval(-15 * 86_400),
            durationMs: 1,
            outcome: "completed"
        )
        let recent = ChatDiagnosticSpan(
            runID: UUID(),
            threadID: nil,
            kind: "recent",
            providerID: "azureOpenAI",
            baseModelID: "gpt-5.6-terra",
            deploymentID: "terra",
            startedAt: now.addingTimeInterval(-13 * 86_400),
            endedAt: now.addingTimeInterval(-13 * 86_400),
            durationMs: 1,
            outcome: "completed"
        )
        let aggregate = ChatUsageDailyAggregate(
            day: now.addingTimeInterval(-30 * 86_400),
            providerID: "azureOpenAI",
            baseModelID: "gpt-5.6-terra",
            deploymentID: "terra"
        )
        harness.context.insert(old)
        harness.context.insert(recent)
        harness.context.insert(aggregate)
        try harness.context.save()

        #expect(ChatDiagnosticSpan.pruneExpired(in: harness.context, now: now) == 1)
        try harness.context.save()
        #expect(try harness.context.fetch(FetchDescriptor<ChatDiagnosticSpan>()).map(\.id) == [recent.id])
        #expect(try harness.context.fetch(FetchDescriptor<ChatUsageDailyAggregate>()).map(\.id) == [aggregate.id])
        let csv = ChatDiagnosticSpan.exportCSV(from: harness.context, now: now)
        #expect(csv.contains("recent"))
        #expect(csv.contains("old") == false)
    }

    private func waitUntilIdle(_ service: ChatService) async {
        for _ in 0..<2_000 where service.isStreaming {
            await Task.yield()
        }
    }
}
