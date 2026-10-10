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
