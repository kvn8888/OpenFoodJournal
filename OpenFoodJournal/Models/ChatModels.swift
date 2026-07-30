// OpenFoodJournal — Assistant Chat Models
// Persistent chat threads and messages for the AI Assistant tab.
// Synced across devices via CloudKit like all other SwiftData models.
// AGPL-3.0 License

import Foundation
import SwiftData

// MARK: - ChatThread

/// One conversation with the Assistant. Threads persist across sessions and
/// sync via CloudKit, so a conversation started on iPhone continues anywhere.
@Model
final class ChatThread {
    var id: UUID = UUID()

    /// Human-readable title shown in the thread list. Empty until the first
    /// exchange completes, then auto-generated from the opening message.
    var title: String = ""

    var createdAt: Date = Date()

    /// Bumped on every new message — the thread list sorts by this so the
    /// most recently active conversation is always on top.
    var updatedAt: Date = Date()

    // CloudKit note: relationships must be optional.
    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.thread)
    var messages: [ChatMessage]? = []

    @Relationship(deleteRule: .cascade, inverse: \ChatContextCheckpoint.thread)
    var contextCheckpoints: [ChatContextCheckpoint]? = []

    @Relationship(deleteRule: .cascade, inverse: \ChatSourceArtifact.thread)
    var sourceArtifacts: [ChatSourceArtifact]? = []

    @Relationship(deleteRule: .cascade, inverse: \ChatAgentRun.thread)
    var agentRuns: [ChatAgentRun]? = []

    @Relationship(deleteRule: .cascade, inverse: \ChatWriteExecutionRecord.thread)
    var writeExecutions: [ChatWriteExecutionRecord]? = []

    init(title: String = "") {
        self.id = UUID()
        self.title = title
        self.createdAt = Date()
        self.updatedAt = Date()
        self.messages = []
        self.contextCheckpoints = []
        self.sourceArtifacts = []
        self.agentRuns = []
        self.writeExecutions = []
    }

    /// Convenience accessor that unwraps the optional relationship.
    /// Messages are stored unordered by SwiftData. New records use a durable
    /// ordinal; legacy rows fall back to a stable timestamp/UUID ordering until
    /// ChatService repairs the thread after a CloudKit merge.
    var safeMessages: [ChatMessage] {
        (messages ?? []).sorted(by: ChatMessage.transcriptOrder)
    }

    /// Title to display when the auto-generated one hasn't been set yet.
    var displayTitle: String {
        title.isEmpty ? "New Conversation" : title
    }
}

// MARK: - ChatMessage

/// The author of a chat message. Stored as a raw string on the model
/// (CloudKit-safe) and surfaced through this enum for type safety.
enum ChatRole: String {
    case user
    case model
    /// Reserved for tool activity records (Phase 2+): read chips and
    /// write permission cards live in the transcript as messages.
    case tool
}

@Model
final class ChatMessage {
    var id: UUID = UUID()

    /// Stable transcript position. Zero identifies a legacy/unrepaired row.
    /// ChatService normalizes missing and duplicate values transactionally.
    var transcriptOrdinal: Int64 = 0

    /// The durable agent run that produced or consumed this message.
    var runID: UUID? = nil

    /// Raw value of `ChatRole`. Stored as String because CloudKit-backed
    /// SwiftData models handle primitive types most reliably.
    var roleRaw: String = ChatRole.user.rawValue

    /// The message text. For user/model roles this is the visible content.
    var text: String = ""

    /// Serialized `ChatToolRecord` for role == .tool. Nil for plain text.
    var toolPayload: Data? = nil

    /// Provider/model provenance and actual usage for diagnostics and context
    /// reconciliation. Optional fields keep existing CloudKit records valid.
    var providerID: String? = nil
    var modelID: String? = nil
    var providerRequestID: String? = nil
    var reportedInputTokens: Int? = nil
    var reportedCachedInputTokens: Int? = nil
    var reportedOutputTokens: Int? = nil
    var reportedThinkingTokens: Int? = nil
    /// When text accompanied function calls, this links the visible bubble to
    /// the same provider turn so replay does not split it into two model turns.
    var modelTurnID: String? = nil
    var modelTurnTextOrdinal: Int? = nil

    /// Opaque stateless-provider items and normalized citations attached to a
    /// text-only model turn. Tool turns carry continuation state in their
    /// `ChatToolRecord` so parallel calls remain one replayable group.
    var continuationPayload: Data? = nil
    var citationPayload: Data? = nil

    var timestamp: Date = Date()

    // CloudKit note: inverse relationships must be optional.
    var thread: ChatThread? = nil

    /// Files attached to this message: user uploads (images/PDFs) or
    /// documents downloaded by the fetch_url tool. Replayed into the model's
    /// context on every request so it can keep referencing them.
    @Relationship(deleteRule: .cascade, inverse: \ChatAttachment.message)
    var attachments: [ChatAttachment]? = []

    init(role: ChatRole, text: String, timestamp: Date = Date()) {
        self.id = UUID()
        self.roleRaw = role.rawValue
        self.text = text
        self.timestamp = timestamp
        self.attachments = []
    }

    var role: ChatRole {
        ChatRole(rawValue: roleRaw) ?? .user
    }

    var safeAttachments: [ChatAttachment] {
        (attachments ?? []).sorted { $0.createdAt < $1.createdAt }
    }

    nonisolated static func transcriptOrder(_ lhs: ChatMessage, _ rhs: ChatMessage) -> Bool {
        if lhs.transcriptOrdinal > 0,
           rhs.transcriptOrdinal > 0,
           lhs.transcriptOrdinal != rhs.transcriptOrdinal {
            return lhs.transcriptOrdinal < rhs.transcriptOrdinal
        }
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// Decoded tool record for role == .tool messages.
    var toolRecord: ChatToolRecord? {
        guard let toolPayload else { return nil }
        return try? JSONDecoder().decode(ChatToolRecord.self, from: toolPayload)
    }

    func setToolRecord(_ record: ChatToolRecord) {
        toolPayload = try? JSONEncoder().encode(record)
    }

    var providerContinuations: [ChatProviderContinuation] {
        guard let continuationPayload else { return [] }
        return (try? JSONDecoder().decode([ChatProviderContinuation].self, from: continuationPayload)) ?? []
    }

    func setProviderContinuations(_ continuations: [ChatProviderContinuation]) {
        continuationPayload = continuations.isEmpty ? nil : try? JSONEncoder().encode(continuations)
    }

    var sourceCitations: [ChatSourceCitation] {
        guard let citationPayload else { return [] }
        return (try? JSONDecoder().decode([ChatSourceCitation].self, from: citationPayload)) ?? []
    }

    func setSourceCitations(_ citations: [ChatSourceCitation]) {
        citationPayload = citations.isEmpty ? nil : try? JSONEncoder().encode(citations)
    }
}

// MARK: - ChatAttachment

/// Binary content riding with a chat message: user-attached images/PDFs or
/// documents the fetch_url tool downloaded. Data uses external storage so
/// CloudKit sync stays efficient for multi-MB PDFs.
@Model
final class ChatAttachment {
    var id: UUID = UUID()

    @Attribute(.externalStorage)
    var data: Data = Data()

    var mimeType: String = "application/octet-stream"
    var filename: String = ""
    var createdAt: Date = Date()

    // CloudKit note: inverse relationships must be optional.
    var message: ChatMessage? = nil

    init(data: Data, mimeType: String, filename: String) {
        self.id = UUID()
        self.data = data
        self.mimeType = mimeType
        self.filename = filename
        self.createdAt = Date()
    }

    var isImage: Bool { mimeType.hasPrefix("image/") }
    var isPDF: Bool { mimeType == "application/pdf" }
}

// MARK: - Portable context and source persistence

nonisolated enum ChatSourceKind: String, Codable, Sendable {
    case userAttachment
    case webCitation
    case fetchedText
    case fetchedPDF
    case fetchedImage
    case unknown
}

nonisolated struct ChatCheckpointPayload: Codable, Equatable, Sendable {
    var conversationDecisions: [String]
    var userConstraints: [String]
    var goals: [String]
    var unresolvedTasks: [String]
    var toolOutcomes: [String]
    var journalFacts: [String]
    var sourceIDs: [UUID]
    var attachmentIDs: [UUID]
    var transcriptBoundaryMessageID: UUID
    var transcriptBoundaryTimestamp: Date
    /// Optional only for decoding checkpoints created before exact range
    /// boundaries were introduced.
    var transcriptStartMessageID: UUID?
    var transcriptStartTimestamp: Date?

    init(
        conversationDecisions: [String],
        userConstraints: [String],
        goals: [String],
        unresolvedTasks: [String],
        toolOutcomes: [String],
        journalFacts: [String],
        sourceIDs: [UUID],
        attachmentIDs: [UUID],
        transcriptBoundaryMessageID: UUID,
        transcriptBoundaryTimestamp: Date,
        transcriptStartMessageID: UUID? = nil,
        transcriptStartTimestamp: Date? = nil
    ) {
        self.conversationDecisions = conversationDecisions
        self.userConstraints = userConstraints
        self.goals = goals
        self.unresolvedTasks = unresolvedTasks
        self.toolOutcomes = toolOutcomes
        self.journalFacts = journalFacts
        self.sourceIDs = sourceIDs
        self.attachmentIDs = attachmentIDs
        self.transcriptBoundaryMessageID = transcriptBoundaryMessageID
        self.transcriptBoundaryTimestamp = transcriptBoundaryTimestamp
        self.transcriptStartMessageID = transcriptStartMessageID
        self.transcriptStartTimestamp = transcriptStartTimestamp
    }

    var isStructurallyValid: Bool {
        guard transcriptBoundaryTimestamp.timeIntervalSince1970 > 0 else { return false }
        switch (transcriptStartMessageID, transcriptStartTimestamp) {
        case (nil, nil):
            return true
        case (.some, .some(let start)):
            return start.timeIntervalSince1970 > 0 && start <= transcriptBoundaryTimestamp
        default:
            return false
        }
    }

    var promptText: String {
        func section(_ title: String, _ values: [String]) -> String {
            guard !values.isEmpty else { return "\(title): none recorded" }
            return "\(title):\n" + values.map { "- \($0)" }.joined(separator: "\n")
        }
        let boundaryDescription = transcriptStartMessageID.map {
            "Portable conversation checkpoint from message \($0.uuidString) through message \(transcriptBoundaryMessageID.uuidString):"
        } ?? "Portable conversation checkpoint through message \(transcriptBoundaryMessageID.uuidString):"
        return [
            boundaryDescription,
            section("Decisions", conversationDecisions),
            section("User constraints", userConstraints),
            section("Goals", goals),
            section("Unresolved tasks", unresolvedTasks),
            section("Tool outcomes", toolOutcomes),
            section("Journal facts", journalFacts),
            "Durable source IDs: \(sourceIDs.map(\.uuidString).joined(separator: ", "))",
            "Attachment IDs: \(attachmentIDs.map(\.uuidString).joined(separator: ", "))",
        ].joined(separator: "\n\n")
    }
}

@Model
final class ChatContextCheckpoint {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var boundaryMessageID: UUID = UUID()
    var boundaryTimestamp: Date = Date()
    var startBoundaryMessageID: UUID? = nil
    var startBoundaryTimestamp: Date? = nil
    var estimatedTokens: Int = 0
    var providerID: String? = nil
    var modelID: String? = nil
    var wasDeterministicFallback: Bool = false
    var validationStatusRaw: String = "validated"
    var payload: Data = Data()
    var thread: ChatThread? = nil

    init(
        payload value: ChatCheckpointPayload,
        estimatedTokens: Int,
        providerID: String?,
        modelID: String?,
        wasDeterministicFallback: Bool
    ) {
        id = UUID()
        createdAt = Date()
        boundaryMessageID = value.transcriptBoundaryMessageID
        boundaryTimestamp = value.transcriptBoundaryTimestamp
        startBoundaryMessageID = value.transcriptStartMessageID
        startBoundaryTimestamp = value.transcriptStartTimestamp
        self.estimatedTokens = estimatedTokens
        self.providerID = providerID
        self.modelID = modelID
        self.wasDeterministicFallback = wasDeterministicFallback
        validationStatusRaw = wasDeterministicFallback ? "deterministic_fallback" : "validated"
        payload = (try? JSONEncoder().encode(value)) ?? Data()
    }

    var decodedPayload: ChatCheckpointPayload? {
        try? JSONDecoder().decode(ChatCheckpointPayload.self, from: payload)
    }
}

@Model
final class ChatSourceArtifact {
    var id: UUID = UUID()
    var kindRaw: String = ChatSourceKind.unknown.rawValue
    var canonicalURL: String? = nil
    var finalURL: String? = nil
    var title: String? = nil
    var mimeType: String = "application/octet-stream"
    var fetchedAt: Date = Date()
    var contentHash: String = ""
    var extractedText: String? = nil
    @Attribute(.externalStorage) var rawData: Data? = nil
    var attachmentID: UUID? = nil
    var originatingMessageID: UUID? = nil
    var originatingToolName: String? = nil
    var providerID: String? = nil
    var modelID: String? = nil
    var citationStartIndex: Int? = nil
    var citationEndIndex: Int? = nil
    var versionParentID: UUID? = nil
    var thread: ChatThread? = nil

    init(
        id: UUID = UUID(),
        kind: ChatSourceKind = .unknown,
        canonicalURL: String?,
        finalURL: String?,
        title: String?,
        mimeType: String,
        contentHash: String,
        extractedText: String?,
        rawData: Data?,
        attachmentID: UUID?,
        originatingMessageID: UUID?,
        originatingToolName: String?,
        providerID: String? = nil,
        modelID: String? = nil,
        citationStartIndex: Int? = nil,
        citationEndIndex: Int? = nil,
        versionParentID: UUID?
    ) {
        self.id = id
        kindRaw = kind.rawValue
        self.canonicalURL = canonicalURL
        self.finalURL = finalURL
        self.title = title
        self.mimeType = mimeType
        fetchedAt = Date()
        self.contentHash = contentHash
        self.extractedText = extractedText
        self.rawData = rawData
        self.attachmentID = attachmentID
        self.originatingMessageID = originatingMessageID
        self.originatingToolName = originatingToolName
        self.providerID = providerID
        self.modelID = modelID
        self.citationStartIndex = citationStartIndex
        self.citationEndIndex = citationEndIndex
        self.versionParentID = versionParentID
    }

    var kind: ChatSourceKind {
        ChatSourceKind(rawValue: kindRaw) ?? .unknown
    }
}

// MARK: - Durable agent execution

nonisolated enum ChatRunPhase: String, Codable, CaseIterable, Sendable {
    case queued
    case preparing
    case waitingForProvider
    case executingTools
    case awaitingApproval
    case finalizing
    case completed
    case failed
    case cancelled
    case suspended

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        default: false
        }
    }
}

/// Compact per-round accounting retained after detailed diagnostic spans are
/// pruned. It intentionally contains no prompt, answer, URL, attachment, tool
/// arguments/results, or journal/HealthKit values.
nonisolated struct ChatModelRoundRecord: Codable, Equatable, Sendable {
    var turnIndex: Int
    var providerID: String
    var baseModelID: String
    var deploymentID: String
    var providerRequestID: String?
    var inputTokens: Int
    var cachedInputTokens: Int
    var outputTokens: Int
    var reasoningTokens: Int
    var estimatedCostUSD: Double?
    var pricingCatalogVersion: String?
    var pricingVerifiedAt: String?
    var retryCount: Int
    var firstProviderEventMs: Int?
    var firstVisibleTextMs: Int?
    var durationMs: Int
    var outcome: String
}

@Model
final class ChatAgentRun {
    enum State: String, Codable {
        case running, awaitingApproval, completed, cancelled, interrupted, failed
    }

    var id: UUID = UUID()
    var stateRaw: String = State.running.rawValue
    var phaseRaw: String = ChatRunPhase.queued.rawValue
    var providerID: String = ""
    var modelID: String = ""
    var baseModelID: String = ""
    var triggerMessageID: UUID? = nil
    var lastSafeBoundaryMessageID: UUID? = nil
    var partialVisibleAnswer: String = ""
    var retryableFailure: Bool = false
    var retryableStep: String? = nil
    var modelTurnID: String? = nil
    var pendingCallsPayload: Data? = nil
    var pendingContinuationsPayload: Data? = nil
    var iteration: Int = 0
    var approvalState: String? = nil
    var terminalOutcome: String? = nil
    var selectedContextLimit: Int = 0
    var reportedInputTokens: Int = 0
    var reportedCachedInputTokens: Int = 0
    var reportedOutputTokens: Int = 0
    var reportedThinkingTokens: Int = 0
    var compactionCount: Int = 0
    var cumulativeToolLatencyMs: Int = 0
    var sourceCount: Int = 0
    var retryReason: String? = nil
    var providerRequestID: String? = nil
    var terminalErrorCode: String? = nil
    var roundRecordsPayload: Data? = nil
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var requestStartedAt: Date? = nil
    var requestCompletedAt: Date? = nil
    var queuedAt: Date? = nil
    var preparingAt: Date? = nil
    var waitingForProviderAt: Date? = nil
    var executingToolsAt: Date? = nil
    var awaitingApprovalAt: Date? = nil
    var finalizingAt: Date? = nil
    var completedAt: Date? = nil
    var failedAt: Date? = nil
    var cancelledAt: Date? = nil
    var suspendedAt: Date? = nil
    var thread: ChatThread? = nil

    init(providerID: String, modelID: String) {
        id = UUID()
        stateRaw = State.running.rawValue
        phaseRaw = ChatRunPhase.queued.rawValue
        self.providerID = providerID
        self.modelID = modelID
        self.baseModelID = modelID
        createdAt = Date()
        updatedAt = Date()
        queuedAt = createdAt
    }

    var state: State {
        get { State(rawValue: stateRaw) ?? .interrupted }
        set { stateRaw = newValue.rawValue; updatedAt = Date() }
    }

    var phase: ChatRunPhase {
        get { ChatRunPhase(rawValue: phaseRaw) ?? .suspended }
        set { setPhase(newValue) }
    }

    var roundRecords: [ChatModelRoundRecord] {
        get {
            guard let roundRecordsPayload else { return [] }
            return (try? JSONDecoder().decode([ChatModelRoundRecord].self, from: roundRecordsPayload)) ?? []
        }
        set {
            roundRecordsPayload = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue)
            updatedAt = Date()
        }
    }

    func setPhase(_ newPhase: ChatRunPhase, now: Date = .now) {
        phaseRaw = newPhase.rawValue
        updatedAt = now
        switch newPhase {
        case .queued: queuedAt = queuedAt ?? now
        case .preparing: preparingAt = preparingAt ?? now
        case .waitingForProvider: waitingForProviderAt = now
        case .executingTools: executingToolsAt = now
        case .awaitingApproval: awaitingApprovalAt = now
        case .finalizing: finalizingAt = now
        case .completed: completedAt = now
        case .failed: failedAt = now
        case .cancelled: cancelledAt = now
        case .suspended: suspendedAt = now
        }
    }
}

// MARK: - Redacted Assistant diagnostics and retained usage

@Model
final class ChatDiagnosticSpan {
    var id: UUID = UUID()
    var runID: UUID = UUID()
    var threadID: UUID? = nil
    var turnID: String? = nil
    var callID: String? = nil
    var kind: String = ""
    var providerID: String = ""
    var baseModelID: String = ""
    var deploymentID: String = ""
    var startedAt: Date = Date()
    var endedAt: Date = Date()
    var durationMs: Int = 0
    var outcome: String = ""
    var timeoutKind: String? = nil
    var retryReason: String? = nil
    var providerRequestID: String? = nil
    var dnsMs: Int? = nil
    var connectionMs: Int? = nil
    var tlsMs: Int? = nil
    var uploadMs: Int? = nil
    var serverWaitMs: Int? = nil

    init(
        runID: UUID,
        threadID: UUID?,
        turnID: String? = nil,
        callID: String? = nil,
        kind: String,
        providerID: String,
        baseModelID: String,
        deploymentID: String,
        startedAt: Date,
        endedAt: Date,
        durationMs: Int,
        outcome: String,
        timeoutKind: String? = nil,
        retryReason: String? = nil,
        providerRequestID: String? = nil
    ) {
        id = UUID()
        self.runID = runID
        self.threadID = threadID
        self.turnID = turnID
        self.callID = callID
        self.kind = kind
        self.providerID = providerID
        self.baseModelID = baseModelID
        self.deploymentID = deploymentID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationMs = durationMs
        self.outcome = outcome
        self.timeoutKind = timeoutKind
        self.retryReason = retryReason
        self.providerRequestID = providerRequestID
    }
}

@Model
final class ChatUsageDailyAggregate {
    var id: UUID = UUID()
    var day: Date = Date()
    var providerID: String = ""
    var baseModelID: String = ""
    var deploymentID: String = ""
    var requestCount: Int = 0
    var retryCount: Int = 0
    var inputTokens: Int = 0
    var cachedInputTokens: Int = 0
    var outputTokens: Int = 0
    var reasoningTokens: Int = 0
    var estimatedCostUSD: Double = 0
    var pricedRequestCount: Int = 0
    var unpricedRequestCount: Int = 0
    var pricingCatalogVersion: String? = nil
    var pricingVerifiedAt: String? = nil
    var updatedAt: Date = Date()

    init(day: Date, providerID: String, baseModelID: String, deploymentID: String) {
        id = UUID()
        self.day = day
        self.providerID = providerID
        self.baseModelID = baseModelID
        self.deploymentID = deploymentID
        updatedAt = Date()
    }
}

extension ChatDiagnosticSpan {
    static let retentionDays = 14

    @MainActor
    static func pruneExpired(
        in modelContext: ModelContext,
        days: Int = retentionDays,
        now: Date = .now
    ) -> Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        let expired = (try? modelContext.fetch(FetchDescriptor<ChatDiagnosticSpan>(
            predicate: #Predicate { $0.startedAt < cutoff }
        ))) ?? []
        for span in expired { modelContext.delete(span) }
        return expired.count
    }

    @MainActor
    static func exportCSV(
        from modelContext: ModelContext,
        days: Int = retentionDays,
        now: Date = .now
    ) -> String {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        let spans = (try? modelContext.fetch(FetchDescriptor<ChatDiagnosticSpan>(
            predicate: #Predicate { $0.startedAt >= cutoff },
            sortBy: [SortDescriptor(\.startedAt)]
        ))) ?? []
        guard !spans.isEmpty else { return "" }
        func csv(_ value: String) -> String {
            "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        let header = [
            "Span ID", "Started At", "Ended At", "Kind", "Outcome", "Run ID",
            "Thread ID", "Turn ID", "Call ID", "Provider", "Base Model", "Deployment",
            "Duration Ms", "Timeout", "Retry Reason", "Provider Request ID",
            "DNS Ms", "Connection Ms", "TLS Ms", "Upload Ms", "Server Wait Ms",
        ]
        let formatter = ISO8601DateFormatter()
        var rows = [header.map(csv).joined(separator: ",")]
        for span in spans {
            let columns: [String] = [
                span.id.uuidString,
                formatter.string(from: span.startedAt),
                formatter.string(from: span.endedAt),
                span.kind,
                span.outcome,
                span.runID.uuidString,
                span.threadID?.uuidString ?? "",
                span.turnID ?? "",
                span.callID ?? "",
                span.providerID,
                span.baseModelID,
                span.deploymentID,
                String(span.durationMs),
                span.timeoutKind ?? "",
                span.retryReason ?? "",
                span.providerRequestID ?? "",
                span.dnsMs.map(String.init) ?? "",
                span.connectionMs.map(String.init) ?? "",
                span.tlsMs.map(String.init) ?? "",
                span.uploadMs.map(String.init) ?? "",
                span.serverWaitMs.map(String.init) ?? "",
            ]
            rows.append(columns.map(csv).joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }
}

@Model
final class ChatWriteExecutionRecord {
    enum Status: String, Codable {
        case awaitingApproval
        case executing
        case completed
        case denied
        case failed
        case interrupted
    }

    var id: UUID = UUID()
    var runID: UUID = UUID()
    var providerCallID: String = ""
    var toolName: String = ""
    var idempotencyKey: String = ""
    var statusRaw: String = Status.awaitingApproval.rawValue
    var resultJSON: String? = nil
    var approvalState: String? = nil
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var thread: ChatThread? = nil

    init(
        runID: UUID,
        providerCallID: String,
        toolName: String,
        idempotencyKey: String
    ) {
        id = UUID()
        self.runID = runID
        self.providerCallID = providerCallID
        self.toolName = toolName
        self.idempotencyKey = idempotencyKey
        createdAt = Date()
        updatedAt = Date()
    }

    var status: Status {
        get { Status(rawValue: statusRaw) ?? .interrupted }
        set { statusRaw = newValue.rawValue; updatedAt = Date() }
    }
}

// MARK: - ChatToolRecord

/// The persisted trace of one tool invocation, stored on a
/// `ChatMessage(role: .tool)` via `toolPayload`. Enough to render an activity
/// chip and to rebuild the provider transcript (functionCall/functionResponse
/// turns) when a thread is resumed.
nonisolated struct ChatToolRecord: Codable, Sendable {
    enum Status: String, Codable {
        case queued
        case running
        case interrupted
        case cancelled
        case completed
        case denied
        case failed
    }

    /// Provider call ID. Gemini 3 and OpenRouter both require the matching ID
    /// to be returned with the tool result.
    var callID: String
    /// Opaque Gemini reasoning state attached to the function-call part.
    /// It must be replayed byte-for-byte; nil for providers/older records that
    /// did not supply one.
    var thoughtSignature: String? = nil
    /// All calls emitted by one provider response share this identifier. It
    /// lets transcript reconstruction keep parallel calls in one model turn.
    var modelTurnID: String? = nil
    /// Original zero-based position within that model turn. SwiftData
    /// relationships are unordered, so this keeps the signature on the exact
    /// parallel-call part where Gemini returned it.
    var modelTurnIndex: Int? = nil
    /// Opaque provider items emitted in the same model turn. Optional for
    /// backward-compatible decoding of Gemini-era records.
    var providerContinuations: [ChatProviderContinuation]? = nil
    var providerID: String? = nil
    var modelID: String? = nil
    var providerRequestID: String? = nil
    var sourceArtifactIDs: [UUID]? = nil
    var runID: UUID? = nil
    var queuedAt: Date? = nil
    var startedAt: Date? = nil
    var completedAt: Date? = nil
    var name: String
    /// JSON string of the arguments the model passed.
    var argsJSON: String
    /// JSON string of the result fed back to the model (or error/denial info).
    var resultJSON: String
    var status: Status
    /// Human-readable chip label, e.g. "Read journal: Jul 12–18".
    var summary: String
}
