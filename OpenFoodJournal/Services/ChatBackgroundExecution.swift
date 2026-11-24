// User-started Assistant work may continue only while iOS grants execution.
// A Live Activity is system progress UI, not an unlimited keep-alive.
import Foundation
import Observation
import BackgroundTasks
import UIKit

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
protocol ChatBackgroundTransitionAssertion: AnyObject {
    func end()
}

@MainActor
protocol ChatBackgroundTransitionAsserting: AnyObject {
    func begin(
        name: String,
        onExpiration: @escaping @MainActor () -> Void
    ) -> (any ChatBackgroundTransitionAssertion)?
}

@MainActor
@Observable
final class ChatBackgroundExecution {
    enum State: Equatable { case idle, requesting, active, unavailable, expired }
    private(set) var state: State = .idle
    private(set) var runID: UUID?
    @ObservationIgnored private let scheduler: any ChatBackgroundScheduling
    @ObservationIgnored private let transitionAsserter: any ChatBackgroundTransitionAsserting
    @ObservationIgnored private let admissionGraceDuration: Duration
    @ObservationIgnored private var handle: (any ChatBackgroundTaskHandling)?
    @ObservationIgnored private var transitionAssertion: (any ChatBackgroundTransitionAssertion)?
    @ObservationIgnored private var admissionTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var expirationHandler: (@MainActor () -> Void)?
    @ObservationIgnored private var latestPhase: ChatRunPhase = .preparing
    @ObservationIgnored private var completedEvents = 0
    @ObservationIgnored private var attemptID: UUID?

    init(
        scheduler: (any ChatBackgroundScheduling)? = nil,
        transitionAsserter: (any ChatBackgroundTransitionAsserting)? = nil,
        admissionGraceDuration: Duration = .seconds(3)
    ) {
        self.scheduler = scheduler ?? AppleChatBackgroundScheduler()
        self.transitionAsserter = transitionAsserter ?? UIApplicationBackgroundTransitionAsserter()
        self.admissionGraceDuration = admissionGraceDuration
    }

    var canContinue: Bool { state == .active && handle != nil }
    var isAwaitingAdmission: Bool { state == .requesting }

    func begin(runID: UUID, onExpiration: @escaping @MainActor () -> Void) {
        finish(success: false)
        self.runID = runID
        let attemptID = UUID()
        self.attemptID = attemptID
        self.expirationHandler = onExpiration
        state = .requesting
        latestPhase = .preparing
        completedEvents = 0
        do {
            try scheduler.submit(runID: runID, onStart: { [weak self] task in
                guard let self, self.attemptID == attemptID, self.state == .requesting else {
                    task.complete(success: false)
                    return
                }
                self.handle = task
                self.state = .active
                self.releaseAdmissionBridge()
                task.update(
                    subtitle: Self.subtitle(for: self.latestPhase),
                    completedEvents: self.completedEvents
                )
            }, onExpiration: { [weak self] in
                guard let self, self.attemptID == attemptID else { return }
                self.expireCurrentAttempt()
            })
        } catch {
            expirationHandler = nil
            state = .unavailable
        }
    }

    /// Returns `true` when background execution can safely proceed: either
    /// iOS already delivered the `BGContinuedProcessingTask`, or submission
    /// succeeded and a bounded UIKit background assertion bridges the brief
    /// window while iOS delivers `onStart` on the main queue.
    func beginBackgroundTransition() -> Bool {
        if canContinue { return true }
        guard state == .requesting, let attemptID else { return false }
        if transitionAssertion != nil { return true }

        guard let assertion = transitionAsserter.begin(
            name: "OpenFoodJournal.AssistantBackgroundAdmission",
            onExpiration: { [weak self] in
                guard let self, self.attemptID == attemptID, self.state == .requesting else { return }
                self.expireCurrentAttempt()
            }
        ) else {
            return false
        }

        transitionAssertion = assertion
        let graceDuration = admissionGraceDuration
        admissionTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: graceDuration)
            guard !Task.isCancelled,
                  let self,
                  self.attemptID == attemptID,
                  self.state == .requesting else { return }
            self.expireCurrentAttempt()
        }
        return true
    }

    func endBackgroundTransition() {
        releaseAdmissionBridge()
    }

    func update(phase: ChatRunPhase, completedEvents: Int) {
        latestPhase = phase
        self.completedEvents = max(self.completedEvents, completedEvents)
        guard canContinue else { return }
        handle?.update(subtitle: Self.subtitle(for: phase), completedEvents: self.completedEvents)
    }

    func finish(success: Bool) {
        let oldRunID = runID
        runID = nil
        attemptID = nil
        expirationHandler = nil
        releaseAdmissionBridge()
        handle?.complete(success: success)
        handle = nil
        latestPhase = .preparing
        completedEvents = 0
        state = .idle
        if let oldRunID { scheduler.cancel(runID: oldRunID) }
    }

    private func expireCurrentAttempt() {
        let handler = expirationHandler
        expirationHandler = nil
        releaseAdmissionBridge()
        state = .expired
        // Snapshot/cancel the run before relinquishing execution.
        handler?()
        finish(success: false)
    }

    private func releaseAdmissionBridge() {
        admissionTimeoutTask?.cancel()
        admissionTimeoutTask = nil
        transitionAssertion?.end()
        transitionAssertion = nil
    }

    private static func subtitle(for phase: ChatRunPhase) -> String {
        switch phase {
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
    }
}

@MainActor
private final class UIApplicationBackgroundTransitionAssertion: ChatBackgroundTransitionAssertion {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var expired = false

    func start(
        name: String,
        onExpiration: @escaping @MainActor () -> Void
    ) -> Bool {
        let taskID = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.expired, self.identifier != .invalid else { return }
                self.expired = true
                onExpiration()
                self.end()
            }
        }
        guard taskID != .invalid else { return false }
        identifier = taskID
        return true
    }

    func end() {
        guard identifier != .invalid else { return }
        let ended = identifier
        identifier = .invalid
        UIApplication.shared.endBackgroundTask(ended)
    }
}

@MainActor
final class UIApplicationBackgroundTransitionAsserter: ChatBackgroundTransitionAsserting {
    func begin(
        name: String,
        onExpiration: @escaping @MainActor () -> Void
    ) -> (any ChatBackgroundTransitionAssertion)? {
        let assertion = UIApplicationBackgroundTransitionAssertion()
        return assertion.start(name: name, onExpiration: onExpiration) ? assertion : nil
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
    private var identifiers: [UUID: String] = [:]

    func submit(
        runID: UUID,
        onStart: @escaping @MainActor (any ChatBackgroundTaskHandling) -> Void,
        onExpiration: @escaping @MainActor () -> Void
    ) throws {
        let identifier = prefix + UUID().uuidString
        identifiers[runID] = identifier
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
        if let identifier = identifiers.removeValue(forKey: runID) {
            scheduler.cancel(taskRequestWithIdentifier: identifier)
        }
    }
}
