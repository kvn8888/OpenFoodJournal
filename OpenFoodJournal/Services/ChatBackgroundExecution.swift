// User-started Assistant work may continue only while iOS grants execution.
// A Live Activity is system progress UI, not an unlimited keep-alive.
import Foundation
import Observation
import BackgroundTasks

@MainActor
protocol ChatBackgroundTaskHandling: AnyObject {
    func update(subtitle: String, completedEvents: Int)
    func complete(success: Bool)
}

@MainActor
protocol ChatBackgroundScheduling: AnyObject {
    func submit(
        runID: UUID,
        onStart: @escaping @MainActor (any ChatBackgroundTaskHandling) -> Void,
        onExpiration: @escaping @MainActor () -> Void
    ) throws
    func cancel(runID: UUID)
}

@MainActor
@Observable
final class ChatBackgroundExecution {
    enum State: Equatable { case idle, requesting, active, unavailable, expired }
    private(set) var state: State = .idle
    private(set) var runID: UUID?
    @ObservationIgnored private let scheduler: any ChatBackgroundScheduling
    @ObservationIgnored private var handle: (any ChatBackgroundTaskHandling)?
    @ObservationIgnored private var completedEvents = 0

    init(scheduler: any ChatBackgroundScheduling = AppleChatBackgroundScheduler()) {
        self.scheduler = scheduler
    }

    var canContinue: Bool { state == .active && handle != nil }

    func begin(runID: UUID, onExpiration: @escaping @MainActor () -> Void) {
        finish(success: false)
        self.runID = runID
        state = .requesting
        completedEvents = 0
        do {
            try scheduler.submit(runID: runID, onStart: { [weak self] task in
                guard let self, self.runID == runID, self.state == .requesting else {
                    task.complete(success: false)
                    return
                }
                self.handle = task
                self.state = .active
                task.update(subtitle: "Preparing response", completedEvents: 0)
            }, onExpiration: { [weak self] in
                guard let self, self.runID == runID else { return }
                self.state = .expired
                // Snapshot/cancel the run before relinquishing execution.
                onExpiration()
                self.finish(success: false)
            })
        } catch {
            state = .unavailable
        }
    }

    func update(phase: ChatRunPhase, completedEvents: Int) {
        guard canContinue else { return }
        self.completedEvents = max(self.completedEvents, completedEvents)
        let subtitle: String = switch phase {
        case .queued, .preparing: "Preparing response"
        case .waitingForProvider: "Waiting for response"
        case .executingTools: "Reading and processing results"
        case .awaitingApproval: "Open Assistant to review an action"
        case .finalizing: "Saving response"
        case .completed: "Response ready"
        case .failed: "Response interrupted"
        case .cancelled: "Stopped"
        case .suspended: "Open Assistant to continue"
        }
        handle?.update(subtitle: subtitle, completedEvents: self.completedEvents)
    }

    func finish(success: Bool) {
        let oldRunID = runID
        runID = nil
        handle?.complete(success: success)
        handle = nil
        state = .idle
        if let oldRunID { scheduler.cancel(runID: oldRunID) }
    }
}

@MainActor
private final class AppleChatBackgroundTask: ChatBackgroundTaskHandling {
    private let task: BGContinuedProcessingTask
    private var finished = false

    init(_ task: BGContinuedProcessingTask) { self.task = task }

    func update(subtitle: String, completedEvents: Int) {
        guard !finished else { return }
        // The total length of generation is unknowable. Foundation Progress
        // supports an indeterminate total; never turn an iteration cap into %.
        // iOS may expire work that appears stalled; normal recovery handles it.
        task.progress.totalUnitCount = -1
        task.progress.completedUnitCount = Int64(completedEvents)
        task.updateTitle("OpenFoodJournal Assistant", subtitle: subtitle)
    }

    func complete(success: Bool) {
        guard !finished else { return }
        finished = true
        if success {
            task.progress.totalUnitCount = max(1, task.progress.completedUnitCount)
            task.progress.completedUnitCount = task.progress.totalUnitCount
        }
        task.setTaskCompleted(success: success)
    }
}

@MainActor
final class AppleChatBackgroundScheduler: ChatBackgroundScheduling {
    private let scheduler = BGTaskScheduler.shared
    private let prefix = (Bundle.main.bundleIdentifier ?? "k3vnc.OpenFoodJournal") + ".assistantCompletion."

    func submit(
        runID: UUID,
        onStart: @escaping @MainActor (any ChatBackgroundTaskHandling) -> Void,
        onExpiration: @escaping @MainActor () -> Void
    ) throws {
        let identifier = prefix + runID.uuidString
        // Continued-processing registration is allowed after launch. A unique
        // run identifier prevents a late OS callback attaching to a newer run.
        let registered = scheduler.register(forTaskWithIdentifier: identifier, using: .main) { task in
            MainActor.assumeIsolated {
                guard let continued = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                continued.expirationHandler = {
                    Task { @MainActor in onExpiration() }
                }
                onStart(AppleChatBackgroundTask(continued))
            }
        }
        guard registered else { throw CocoaError(.featureUnsupported) }
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier, title: "OpenFoodJournal Assistant", subtitle: "Preparing response"
        )
        // Don't queue a second delayed billable run. Foreground execution stays
        // usable if admission fails; backgrounding then saves and suspends it.
        request.strategy = .fail
        try scheduler.submit(request)
    }

    func cancel(runID: UUID) {
        scheduler.cancel(taskRequestWithIdentifier: prefix + runID.uuidString)
    }
}
