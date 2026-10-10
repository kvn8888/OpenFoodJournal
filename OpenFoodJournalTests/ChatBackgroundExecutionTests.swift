import Foundation
import Testing
@testable import OpenFoodJournal

@MainActor
private final class FakeBackgroundTask: ChatBackgroundTaskHandling {
    var completions: [Bool] = []
    var subtitles: [String] = []
    var events: [Int] = []
    func update(subtitle: String, completedEvents: Int) { subtitles.append(subtitle); events.append(completedEvents) }
    func complete(success: Bool) { completions.append(success) }
}

@MainActor
private final class FakeBackgroundScheduler: ChatBackgroundScheduling {
    var reject = false
    var starts: [UUID: @MainActor (any ChatBackgroundTaskHandling) -> Void] = [:]
    var expirations: [UUID: @MainActor () -> Void] = [:]
    var cancellations: [UUID] = []
    func submit(runID: UUID, onStart: @escaping @MainActor (any ChatBackgroundTaskHandling) -> Void,
                onExpiration: @escaping @MainActor () -> Void) throws {
        if reject { throw CocoaError(.featureUnsupported) }
        starts[runID] = onStart
        expirations[runID] = onExpiration
    }
    func cancel(runID: UUID) { cancellations.append(runID) }
}

@MainActor
struct ChatBackgroundExecutionTests {
    @Test func interruptedPartialToolStreamMustNotExecuteItsPendingCall() async throws {
        let harness = try ChatTestHarness()
        let thread = harness.makeThread()
        _ = harness.insertMessage(.user, text: "Set goal", into: thread)
        let run = ChatAgentRun(providerID: "gemini", modelID: "test-primary")
        run.state = .interrupted
        run.pendingCallsPayload = try JSONEncoder().encode([ChatModelCall(callID: "partial", thoughtSignature: nil, modelTurnID: "unfinished-turn", modelTurnIndex: 0, name: "update_goals", args: .object(["calories": .number(2300)]))])
        run.modelTurnID = nil
        run.thread = thread
        harness.context.insert(run)
        thread.agentRuns?.append(run)
        try harness.context.save()
        harness.proxy.enqueue(ChatModelTurn(text: "Recovered from the last complete boundary"))
        await harness.service.resumeInterruptedRun(in: thread)
        #expect(harness.goals.dailyCalories == 2000)
        #expect(harness.permissions.requests.isEmpty)
        #expect(run.pendingCallsPayload == nil)
        #expect(harness.proxy.turns.count == 1)
    }

    @Test func admittedRunContinuesUntilSystemExpiryThenSavesPartialAnswer() async throws {
        let harness = try ChatTestHarness()
        let scheduler = FakeBackgroundScheduler()
        harness.service.backgroundExecution = ChatBackgroundExecution(scheduler: scheduler)
        harness.proxy.enqueue(ChatModelTurn(text: "Never completes before expiry"))
        harness.proxy.preResultEvents = [.visibleText("Partial answer")]
        harness.proxy.nextTurnDelayNanoseconds = 30_000_000_000
        let thread = harness.makeThread()
        _ = harness.service.submit("Continue in background", in: thread)
        for _ in 0..<1_000 where harness.service.streamingText.isEmpty { try await Task.sleep(nanoseconds: 1_000_000) }
        let run = try #require(thread.agentRuns?.last)
        let task = FakeBackgroundTask()
        scheduler.starts[run.id]?(task)
        harness.service.applicationDidEnterBackground()
        #expect(harness.service.isStreaming)
        #expect(run.phase != .suspended)
        scheduler.expirations[run.id]?()
        for _ in 0..<1_000 where harness.service.isStreaming { try await Task.sleep(nanoseconds: 1_000_000) }
        #expect(run.phase == .suspended)
        #expect(run.partialVisibleAnswer == "Partial answer")
        #expect(harness.proxy.turns.count == 1)
        #expect(task.completions == [false])
    }

    @Test func backgroundingAnApprovalNeverPersistsAUserDenialOrExecutesWrite() async throws {
        let harness = try ChatTestHarness(automaticallyDecidesPermissions: false)
        let call = ChatModelCall(callID: "pending-write", thoughtSignature: nil, modelTurnID: "turn", modelTurnIndex: 0, name: "update_goals", args: .object(["calories": .number(2300)]))
        harness.proxy.enqueue(ChatModelTurn(calls: [call]))
        let thread = harness.makeThread()
        _ = harness.service.submit("Update goal", in: thread)
        for _ in 0..<1_000 where harness.service.pendingPermission == nil { try await Task.sleep(nanoseconds: 1_000_000) }
        #expect(harness.service.pendingPermission != nil)
        harness.service.applicationDidEnterBackground()
        for _ in 0..<1_000 where harness.service.isStreaming { try await Task.sleep(nanoseconds: 1_000_000) }
        #expect(harness.goals.dailyCalories == 2000)
        #expect(thread.writeExecutions?.contains(where: { $0.status == .denied }) == false)
        #expect(thread.safeMessages.compactMap(\.toolRecord).allSatisfy { $0.status != .denied })
        #expect(thread.agentRuns?.last?.phase == .suspended)
    }

    @Test func ledgerSaveFailurePreventsAnyWriteOrApproval() async throws {
        let harness = try ChatTestHarness()
        harness.service.writeLedgerSaveHandler = { _ in throw CocoaError(.fileWriteUnknown) }
        harness.proxy.enqueue(ChatModelTurn(calls: [ChatModelCall(callID: "unsafe-write", thoughtSignature: nil, modelTurnID: "turn", modelTurnIndex: 0, name: "update_goals", args: .object(["calories": .number(2300)]))]))
        let thread = harness.makeThread()
        await harness.service.send("Update goal", in: thread)
        #expect(harness.goals.dailyCalories == 2000)
        #expect(harness.permissions.requests.isEmpty)
        #expect(harness.service.lastError != nil)
    }

    @Test func executionRequiresActualAdmissionAndExpiresThroughRecovery() {
        let scheduler = FakeBackgroundScheduler()
        let subject = ChatBackgroundExecution(scheduler: scheduler)
        let run = UUID()
        var expirations = 0
        subject.begin(runID: run) { expirations += 1 }
        #expect(!subject.canContinue)
        let task = FakeBackgroundTask()
        scheduler.starts[run]?(task)
        #expect(subject.canContinue)
        subject.update(phase: .waitingForProvider, completedEvents: 3)
        #expect(task.subtitles.last == "Waiting for response")
        #expect(task.events.last == 3)
        scheduler.expirations[run]?()
        #expect(expirations == 1)
        #expect(!subject.canContinue)
        #expect(task.completions == [false])
        scheduler.expirations[run]?()
        #expect(expirations == 1)
    }

    @Test func rejectionKeepsForegroundFallbackAndLateCallbacksCannotReviveOldRun() {
        let scheduler = FakeBackgroundScheduler()
        let subject = ChatBackgroundExecution(scheduler: scheduler)
        scheduler.reject = true
        subject.begin(runID: UUID()) {}
        #expect(subject.state == .unavailable)
        #expect(!subject.canContinue)
        scheduler.reject = false
        let old = UUID(), current = UUID()
        subject.begin(runID: old) { Issue.record("Expired obsolete run") }
        subject.begin(runID: current) {}
        let stale = FakeBackgroundTask()
        scheduler.starts[old]?(stale)
        scheduler.expirations[old]?()
        #expect(stale.completions == [false])
        #expect(subject.runID == current)
        #expect(!subject.canContinue)
        let active = FakeBackgroundTask()
        scheduler.starts[current]?(active)
        subject.finish(success: true)
        subject.finish(success: true)
        #expect(active.completions == [true])
        #expect(scheduler.cancellations.contains(current))
    }
}
