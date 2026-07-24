// OpenFoodJournal — Assistant runtime deadlines and deterministic timing
// AGPL-3.0 License

import Foundation

nonisolated struct ChatDeadlinePolicy: Equatable, Sendable {
    let localRead: TimeInterval
    let healthRead: TimeInterval
    let webSearch: TimeInterval
    let fetch: TimeInterval
    let firstProviderEvent: TimeInterval
    let idleProviderStream: TimeInterval
    let modelTurn: TimeInterval
    let activeRun: TimeInterval
    let stillWaitingAfter: TimeInterval

    static let fast = ChatDeadlinePolicy(
        localRead: 1,
        healthRead: 3,
        webSearch: 10,
        fetch: 15,
        firstProviderEvent: 10,
        idleProviderStream: 8,
        modelTurn: 90,
        activeRun: 180,
        stillWaitingAfter: 3
    )
}

nonisolated struct ChatRetryPolicy: Equatable, Sendable {
    let maximumAutomaticRetries: Int
    let baseBackoff: TimeInterval
    let jitterFraction: Double
    let maximumAutomaticRetryAfter: TimeInterval

    static let fast = ChatRetryPolicy(
        maximumAutomaticRetries: 1,
        baseBackoff: 0.250,
        jitterFraction: 0.20,
        maximumAutomaticRetryAfter: 5
    )

    func backoff(jitterUnit: Double) -> TimeInterval {
        let clamped = min(1, max(-1, jitterUnit))
        return baseBackoff * (1 + clamped * jitterFraction)
    }
}

/// Small injectable surface used by runtime tests. Wall dates remain separate
/// for persistence; every deadline and duration uses this monotonic clock.
@MainActor
protocol ChatMonotonicClock: AnyObject {
    var now: TimeInterval { get }
    func sleep(for seconds: TimeInterval) async throws
}

@MainActor
final class SystemChatMonotonicClock: ChatMonotonicClock {
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func sleep(for seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(for: .seconds(seconds))
    }
}

@MainActor
final class ChatProviderDeadlineMonitor {
    private(set) var providerEventCount = 0
    private(set) var firstProviderEventAt: TimeInterval?
    private(set) var firstVisibleTextAt: TimeInterval?
    private(set) var latestEventAt: TimeInterval?
    private(set) var retryAfter: TimeInterval?
    private(set) var requestID: String?
    private(set) var transportMetrics: ChatTransportMetrics?
    private(set) var encodingStartedAt: TimeInterval?
    private(set) var requestEncodedAt: TimeInterval?
    private(set) var responseHeadersAt: TimeInterval?
    private(set) var completedAt: TimeInterval?

    let startedAt: TimeInterval
    private let clock: any ChatMonotonicClock

    init(clock: any ChatMonotonicClock) {
        self.clock = clock
        startedAt = clock.now
    }

    func receive(_ event: ChatModelStreamEvent) {
        switch event {
        case .encodingStarted:
            encodingStartedAt = encodingStartedAt ?? clock.now
        case .requestEncoded:
            requestEncodedAt = clock.now
        case .responseHeaders(_, let requestID, let retryAfter):
            self.requestID = requestID ?? self.requestID
            self.retryAfter = retryAfter
            responseHeadersAt = clock.now
        case .providerEvent, .reasoningSummary, .visibleText, .functionCall, .usage:
            providerEventCount += 1
            firstProviderEventAt = firstProviderEventAt ?? clock.now
            latestEventAt = clock.now
            if case .visibleText = event {
                firstVisibleTextAt = firstVisibleTextAt ?? clock.now
            }
        case .transportMetrics(let metrics):
            transportMetrics = metrics
        case .completed:
            completedAt = clock.now
        }
    }

    var firstProviderEventMs: Int? {
        firstProviderEventAt.map { Int(max(0, $0 - startedAt) * 1_000) }
    }

    var firstVisibleTextMs: Int? {
        firstVisibleTextAt.map { Int(max(0, $0 - startedAt) * 1_000) }
    }

    var encodingMs: Int? {
        guard let start = encodingStartedAt, let end = requestEncodedAt else { return nil }
        return Int(max(0, end - start) * 1_000)
    }
}
