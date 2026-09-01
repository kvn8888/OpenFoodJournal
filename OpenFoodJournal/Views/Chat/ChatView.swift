// OpenFoodJournal — Assistant Chat View
// The Assistant tab: an agentic AI conversation over the user's nutrition
// data. Renders streaming replies, tool activity chips, write-permission
// cards, attachments (images/PDFs), and message regeneration. Threads
// persist in SwiftData and sync via CloudKit.
// AGPL-3.0 License

import SwiftUI
import SwiftData
import PhotosUI
import UIKit
import UniformTypeIdentifiers

struct ChatView: View {
    private static let maximumImageAttachments = 4

    @Environment(ChatService.self) private var chatService
    @Environment(\.modelContext) private var modelContext

    // Most recently active thread first — the tab always resumes the latest.
    @Query(sort: \ChatThread.updatedAt, order: .reverse)
    private var threads: [ChatThread]
    @State private var activeThread: ChatThread?
    @State private var draft = ""
    @State private var showThreadList = false
    @State private var editingMessageID: UUID?
    @FocusState private var inputFocused: Bool

    // Attachment staging
    @State private var pendingAttachments: [ChatDraftAttachment] = []
    @State private var showPhotoPicker = false
    @State private var showCameraPicker = false
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var showFileImporter = false

    // Calculator review flow (create/update_calculator permission cards)
    @State private var calculatorReview: CalculatorReviewSession?
    @State private var calculatorResolved = false

    /// Identifiable wrapper so the review sheet can use .sheet(item:).
    private struct CalculatorReviewSession: Identifiable {
        let id = UUID()
        let draft: CalculatorReviewDraft
    }

    /// The thread on screen: explicitly selected, else the most recent.
    private var currentThread: ChatThread? {
        activeThread ?? threads.first
    }

    private var messages: [ChatMessage] {
        currentThread?.safeMessages ?? []
    }

    var body: some View {
        NavigationStack {
            conversation
            .navigationTitle(currentThread?.displayTitle ?? "Assistant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showThreadList = true
                    } label: {
                        Label("Conversations", systemImage: "clock.arrow.circlepath")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        startNewThread()
                    } label: {
                        Label("New Conversation", systemImage: "square.and.pencil")
                    }
                    .disabled(chatService.isStreaming || messages.isEmpty)
                }
            }
            .sheet(isPresented: $showThreadList) {
                ChatThreadListView(activeThread: $activeThread)
            }
            .sheet(item: $calculatorReview, onDismiss: {
                // Cancelled review = denial; the editor's onSaved already
                // resolved the permission when the user actually saved.
                if !calculatorResolved {
                    chatService.resolvePermission(.calculatorCancelled)
                }
                calculatorResolved = false
            }) { session in
                NutritionCalculatorEditorView(
                    calculator: existingCalculator(for: session.draft),
                    prefillName: session.draft.name,
                    prefillBrand: session.draft.brand,
                    prefillIngredients: session.draft.ingredients,
                    onSaved: { saved in
                        calculatorResolved = true
                        chatService.resolvePermission(.calculatorSaved(
                            id: saved.id,
                            name: saved.name,
                            ingredientCount: saved.calculatorIngredients.count
                        ))
                    }
                )
            }
            .photosPicker(
                isPresented: $showPhotoPicker,
                selection: $photoPickerItems,
                maxSelectionCount: max(1, remainingImageAttachmentSlots),
                matching: .images
            )
            .onChange(of: photoPickerItems) {
                loadPickedPhotos()
            }
            .fullScreenCover(isPresented: $showCameraPicker) {
                AssistantCameraPicker(
                    onCapture: attachCapturedPhoto,
                    onCancel: { showCameraPicker = false }
                )
                .ignoresSafeArea()
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.pdf]
            ) { result in
                importPDF(result)
            }
        }
    }

    // MARK: - Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if !chatService.hasAPIKey {
                        missingKeyBanner
                    }

                    if messages.isEmpty && !chatService.isStreaming {
                        emptyState
                    }

                    if let thread = currentThread {
                        ScopedChatTranscript(
                            thread: thread,
                            onEdit: beginEditing
                        )
                    }

                    if chatService.activeThreadID == currentThread?.id,
                       chatService.activeRunID != nil {
                        liveRunCard
                            .id("active-run")
                    }

                    if let permission = chatService.pendingPermission {
                        permissionCard(permission)
                            .id("permission")
                    }

                    if let thread = currentThread,
                       chatService.interruptedThreadIDs.contains(thread.id),
                       !chatService.isStreaming {
                        interruptedRunCard(thread)
                            .id("interrupted-run")
                    }

                    if let error = chatService.lastError {
                        errorBanner(error)
                    }

                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                Task { @MainActor in
                    await Task.yield()
                    scrollToBottom(proxy)
                }
            }
            .onChange(of: messages.count) {
                scrollToBottom(proxy)
            }
            .onChange(of: chatService.streamingText) {
                scrollToBottom(proxy)
            }
            .onChange(of: chatService.pendingPermission?.id) {
                scrollToBottom(proxy)
            }
            .onChange(of: currentThread?.id) {
                cancelEditing()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                inputBar
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if chatService.pendingPermission != nil {
                proxy.scrollTo("permission", anchor: .bottom)
            } else if chatService.isStreaming {
                proxy.scrollTo("active-run", anchor: .bottom)
            } else if let thread = currentThread,
                      chatService.interruptedThreadIDs.contains(thread.id) {
                proxy.scrollTo("interrupted-run", anchor: .bottom)
            } else if let last = messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    // MARK: - Live Run

    private var liveRunCard: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(chatService.activeStartedAt ?? timeline.date))
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(runStatus(at: timeline.date))
                            .font(.subheadline.weight(.semibold))
                        Text(elapsedLabel(elapsed))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .ofjNumericTextTransition(value: elapsed)
                    }
                    Spacer()
                    Button {
                        chatService.cancelCurrentRun()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.glass)
                }

                if !chatService.visibleReasoningSummary.isEmpty {
                    DisclosureGroup("Reasoning summary") {
                        Text(chatService.visibleReasoningSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                if !chatService.streamingText.isEmpty {
                    Text(ChatBubble.markdown(chatService.streamingText))
                        .font(.body)
                        .textSelection(.enabled)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(.blue.opacity(0.10)), in: .rect(cornerRadius: 20))
            .accessibilityIdentifier("assistant.run-card")
        }
    }

    private func runStatus(at date: Date) -> String {
        switch chatService.activePhase ?? .queued {
        case .queued, .preparing:
            return "Preparing…"
        case .waitingForProvider:
            let provider = chatService.activeProviderName ?? "provider"
            let phaseElapsed = date.timeIntervalSince(chatService.activePhaseStartedAt ?? date)
            return phaseElapsed >= 3
                ? "Still waiting for \(provider)…"
                : "Waiting for \(provider)…"
        case .executingTools:
            return "Running tools…"
        case .awaitingApproval:
            return "Waiting for approval"
        case .finalizing:
            return "Finalizing…"
        case .suspended:
            return "Suspended"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }

    private func elapsedLabel(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    // MARK: - Permission Card

    private func permissionCard(_ request: ChatPermissionRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(request.title, systemImage: ChatToolRegistry.icon(for: request.toolName))
                .font(.headline)

            ForEach(Array(request.detailLines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Deny") {
                    chatService.resolvePermission(.denied)
                }
                .buttonStyle(.glass)

                Spacer()

                if request.calculatorDraft != nil {
                    Button("Review & Save") {
                        openCalculatorReview(request)
                    }
                    .buttonStyle(.glassProminent)
                } else {
                    Button("Allow") {
                        chatService.resolvePermission(.approved)
                    }
                    .buttonStyle(.glassProminent)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(.orange.opacity(0.12)), in: .rect(cornerRadius: 20))
    }

    private func openCalculatorReview(_ request: ChatPermissionRequest) {
        guard let draft = request.calculatorDraft else { return }
        calculatorReview = CalculatorReviewSession(draft: draft)
    }

    private func existingCalculator(for draft: CalculatorReviewDraft) -> SavedFood? {
        guard let id = draft.existingID else { return nil }
        var descriptor = FetchDescriptor<SavedFood>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    // MARK: - Error Banner

    private func interruptedRunCard(_ thread: ChatThread) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Assistant run suspended")
                        .font(.subheadline.weight(.semibold))
                    Text("Continue from the last complete provider boundary. No request is sent automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Continue") {
                    Task { await chatService.resumeInterruptedRun(in: thread) }
                }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("assistant.continue")
            }
            if let partial = latestInterruptedRun(in: thread)?.partialVisibleAnswer,
               !partial.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Saved partial answer")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(ChatBubble.markdown(partial))
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(12)
        .glassEffect(.regular.tint(.orange.opacity(0.12)), in: .rect(cornerRadius: 14))
    }

    private func latestInterruptedRun(in thread: ChatThread) -> ChatAgentRun? {
        (thread.agentRuns ?? [])
            .filter { $0.state == .interrupted }
            .max { $0.updatedAt < $1.updatedAt }
    }

    private func errorBanner(_ error: ChatError) -> some View {
        VStack(spacing: 8) {
            Text(error.localizedDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let thread = currentThread, thread.safeMessages.last?.role != .model {
                HStack {
                    Button("Retry Step") {
                        Task { await chatService.retryFailedStep(in: thread) }
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.glassProminent)

                    Button("Retry Run") {
                        Task { await chatService.retry(in: thread) }
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.glass)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .glassEffect(.regular.tint(.red.opacity(0.12)), in: .rect(cornerRadius: 12))
    }

    // MARK: - Empty / Onboarding States

    private var emptyState: some View {
        VStack(spacing: 20) {
            ContentUnavailableView {
                Label("Ask the Assistant", systemImage: "sparkles")
            } description: {
                Text("It can read your journal, log foods (with your approval), search the web, and build nutrition calculators from menus or PDFs.")
            }

            VStack(spacing: 8) {
                suggestionChip("How am I doing today?")
                suggestionChip("What did I eat yesterday?")
                suggestionChip("Suggest a high-protein snack")
            }
        }
        .padding(.top, 40)
    }

    private func suggestionChip(_ prompt: String) -> some View {
        Button {
            sendMessage(prompt)
        } label: {
            Text(prompt)
                .font(.subheadline)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .buttonStyle(.glass)
    }

    private var missingKeyBanner: some View {
        Label {
            Text("Add your \(chatService.providerDisplayName) credentials in Settings. Messages remain visible if configuration fails.")
                .font(.caption)
        } icon: {
            Image(systemName: "key.fill")
        }
        .foregroundStyle(.secondary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(.orange.opacity(0.12)), in: .rect(cornerRadius: 14))
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        VStack(spacing: 6) {
            if editingMessageID != nil {
                HStack(spacing: OFJSpace.s8) {
                    Label("Editing message", systemImage: "pencil")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", action: cancelEditing)
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.glass)
                }
                .accessibilityIdentifier("assistant.editing-message")
            }

            if !pendingAttachments.isEmpty {
                pendingAttachmentsRow
            }

            GlassEffectContainer(spacing: 8) {
                HStack(alignment: .bottom, spacing: 8) {
                    Menu {
                        Button {
                            showCameraPicker = true
                        } label: {
                            Label("Take Photo", systemImage: "camera.fill")
                        }
                        .disabled(
                            remainingImageAttachmentSlots == 0
                                || !UIImagePickerController.isSourceTypeAvailable(.camera)
                        )

                        Button {
                            showPhotoPicker = true
                        } label: {
                            Label("Photo Library", systemImage: "photo.on.rectangle")
                        }
                        .disabled(remainingImageAttachmentSlots == 0)
                        Button {
                            showFileImporter = true
                        } label: {
                            Label("Attach PDF", systemImage: "doc.badge.plus")
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.body.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .frame(
                        width: OFJLayout.assistantComposerRestingHeight,
                        height: OFJLayout.assistantComposerRestingHeight
                    )
                    .contentShape(Circle())
                    .glassEffect(.regular.interactive(), in: .circle)
                    .disabled(chatService.isStreaming)
                    .accessibilityLabel("Add attachment")

                    TextField("Ask about your nutrition…", text: $draft, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($inputFocused)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(minHeight: OFJLayout.assistantComposerRestingHeight)
                        .glassEffect(
                            .regular.interactive(),
                            in: .rect(cornerRadius: OFJLayout.assistantComposerRestingHeight / 2)
                        )
                        .accessibilityIdentifier("assistant.input")

                    if chatService.isStreaming {
                        Button {
                            chatService.cancelCurrentRun()
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .frame(
                            width: OFJLayout.assistantComposerRestingHeight,
                            height: OFJLayout.assistantComposerRestingHeight
                        )
                        .contentShape(Circle())
                        .glassEffect(.regular.interactive(), in: .circle)
                        .accessibilityLabel("Stop Assistant")
                        .accessibilityIdentifier("assistant.stop")
                    } else {
                        Button {
                            sendMessage(draft)
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(.body.weight(.bold))
                        }
                        .buttonStyle(.plain)
                        .frame(
                            width: OFJLayout.assistantComposerRestingHeight,
                            height: OFJLayout.assistantComposerRestingHeight
                        )
                        .contentShape(Circle())
                        .glassEffect(
                            .regular.tint(Color.accentColor.opacity(0.35)).interactive(),
                            in: .circle
                        )
                        .disabled(sendDisabled)
                        .opacity(sendDisabled ? 0.5 : 1)
                        .accessibilityIdentifier("assistant.send")
                    }
                }
            }

            // App Store 1.4.1: health content requires visible sourcing and
            // disclaimers — keep this footer on screen at all times.
            NavigationLink {
                HealthDisclaimerView()
            } label: {
                Text("AI-generated — not medical advice")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .underline()
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var pendingAttachmentsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingAttachments) { attachment in
                    HStack(spacing: 6) {
                        if attachment.isImage, let image = UIImage(data: attachment.data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 28, height: 28)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        } else {
                            Image(systemName: "doc.fill")
                                .foregroundStyle(.secondary)
                        }
                        Text(attachment.isImage ? "Photo" : attachment.filename)
                            .font(.caption)
                            .lineLimit(1)
                        Button {
                            pendingAttachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .glassEffect(in: .capsule)
                }
            }
        }
    }

    private var sendDisabled: Bool {
        chatService.isStreaming
            || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingAttachments.isEmpty)
    }

    private var remainingImageAttachmentSlots: Int {
        max(
            0,
            Self.maximumImageAttachments
                - pendingAttachments.lazy.filter(\.isImage).count
        )
    }

    // MARK: - Attachment Loading

    private func loadPickedPhotos() {
        let items = photoPickerItems
        guard !items.isEmpty else { return }
        photoPickerItems = []
        Task {
            for item in items {
                guard remainingImageAttachmentSlots > 0 else { break }
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let jpeg = ChatService.downscaledJPEG(from: data)
                else { continue }
                pendingAttachments.append(ChatDraftAttachment(
                    data: jpeg,
                    mimeType: "image/jpeg",
                    filename: "photo.jpg"
                ))
            }
        }
    }

    private func attachCapturedPhoto(_ image: UIImage) {
        defer { showCameraPicker = false }
        guard remainingImageAttachmentSlots > 0,
              let sourceData = image.jpegData(compressionQuality: 0.9),
              let jpeg = ChatService.downscaledJPEG(from: sourceData)
        else { return }

        pendingAttachments.append(ChatDraftAttachment(
            data: jpeg,
            mimeType: "image/jpeg",
            filename: "camera-photo.jpg"
        ))
    }

    private func importPDF(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        guard let data = try? Data(contentsOf: url) else { return }
        guard data.count <= 15 * 1024 * 1024 else { return }
        pendingAttachments.append(ChatDraftAttachment(
            data: data,
            mimeType: "application/pdf",
            filename: url.lastPathComponent
        ))
    }

    // MARK: - Actions

    private func sendMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !pendingAttachments.isEmpty, !chatService.isStreaming else { return }

        let thread: ChatThread
        if let current = currentThread {
            thread = current
        } else {
            thread = ChatThread()
            modelContext.insert(thread)
            activeThread = thread
        }

        let attachments = pendingAttachments
        let result: ChatSubmissionResult
        if let editingMessageID,
           let message = thread.safeMessages.first(where: { $0.id == editingMessageID }) {
            result = chatService.submitEdit(
                trimmed,
                attachments: attachments,
                replacing: message,
                in: thread
            )
        } else {
            result = chatService.submit(trimmed, attachments: attachments, in: thread)
        }

        if case .accepted = result {
            pendingAttachments = []
            draft = ""
            self.editingMessageID = nil
        }
    }

    private func beginEditing(_ message: ChatMessage) {
        guard message.role == .user, !chatService.isStreaming else { return }
        editingMessageID = message.id
        draft = message.text
        pendingAttachments = message.safeAttachments.map {
            ChatDraftAttachment(data: $0.data, mimeType: $0.mimeType, filename: $0.filename)
        }
        inputFocused = true
    }

    private func cancelEditing() {
        guard editingMessageID != nil else { return }
        editingMessageID = nil
        draft = ""
        pendingAttachments = []
        inputFocused = false
    }

    private func startNewThread() {
        cancelEditing()
        let thread = ChatThread()
        modelContext.insert(thread)
        activeThread = thread
    }
}

// MARK: - Direct transcript observation

/// SwiftData observes the active thread at the message-model level. This is
/// intentionally not derived from `ChatThread.messages`: CloudKit relationship
/// merges may arrive after the inserted message itself, which previously made
/// a sent bubble appear only after navigating away and back.
private struct ScopedChatTranscript: View {
    @Environment(ChatService.self) private var chatService
    let thread: ChatThread
    let onEdit: (ChatMessage) -> Void

    @Query private var messages: [ChatMessage]
    @Query private var runs: [ChatAgentRun]
    @State private var infoMessage: ChatMessage?

    init(thread: ChatThread, onEdit: @escaping (ChatMessage) -> Void) {
        self.thread = thread
        self.onEdit = onEdit
        let threadID = thread.id
        _messages = Query(
            filter: #Predicate<ChatMessage> { message in
                message.thread?.id == threadID
            },
            sort: [
                SortDescriptor(\ChatMessage.transcriptOrdinal),
                SortDescriptor(\ChatMessage.timestamp),
                SortDescriptor(\ChatMessage.id)
            ]
        )
        _runs = Query(
            filter: #Predicate<ChatAgentRun> { run in
                run.thread?.id == threadID
            },
            sort: [SortDescriptor(\ChatAgentRun.createdAt, order: .reverse)]
        )
    }

    var body: some View {
        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
            if message.role == .tool {
                if isFirstToolInGroup(at: index) {
                    let group = toolGroup(startingAt: index)
                    if group.count > 1 {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Parallel tools", systemImage: "square.3.layers.3d")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                            ForEach(group) { ToolChipView(message: $0) }
                        }
                        .padding(10)
                        .glassEffect(.regular.tint(.blue.opacity(0.06)), in: .rect(cornerRadius: 14))
                    } else {
                        ToolChipView(message: message)
                    }
                }
            } else {
                chatMessageRow(message)
            }
        }
        .onAppear { chatService.repairTranscriptOrdering(in: thread) }
        .onChange(of: messages.map(\.transcriptOrdinal)) {
            chatService.repairTranscriptOrdering(in: thread)
        }
        .sheet(item: $infoMessage) { message in
            NavigationStack {
                ChatResponseInfoView(
                    message: message,
                    run: message.runID.flatMap { runID in
                        runs.first { $0.id == runID }
                    },
                    contextUsage: chatService.contextUsage,
                    contextWarning: chatService.contextWarning
                )
            }
        }
    }

    private func chatMessageRow(_ message: ChatMessage) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }

            ChatBubble(message: message)
                // Attach the menu to the visible bubble, not the full-width
                // alignment row. The latter made iOS preview an invisible
                // spacer as a large blank rectangle on long press.
                .contextMenu {
                    bubbleMenu(for: message)
                } preview: {
                    ChatBubble(message: message)
                        .frame(maxWidth: 320)
                }

            if message.role == .model { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity)
    }

    private func isFirstToolInGroup(at index: Int) -> Bool {
        guard index > 0,
              let record = messages[index].toolRecord,
              let previous = messages[index - 1].toolRecord else { return true }
        return record.modelTurnID == nil || previous.modelTurnID != record.modelTurnID
    }

    private func toolGroup(startingAt index: Int) -> [ChatMessage] {
        guard let turnID = messages[index].toolRecord?.modelTurnID else { return [messages[index]] }
        var result: [ChatMessage] = []
        var cursor = index
        while cursor < messages.count,
              messages[cursor].role == .tool,
              messages[cursor].toolRecord?.modelTurnID == turnID {
            result.append(messages[cursor])
            cursor += 1
        }
        return result
    }

    @ViewBuilder
    private func bubbleMenu(for message: ChatMessage) -> some View {
        Button {
            UIPasteboard.general.string = message.text
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }

        if message.role == .user, !chatService.isStreaming {
            Button {
                onEdit(message)
            } label: {
                Label("Edit Message", systemImage: "pencil")
            }
        }

        if message.role == .model {
            Button {
                infoMessage = message
            } label: {
                Label("Info", systemImage: "info.circle")
            }
        }

        if message.role == .model,
           message.id == messages.last?.id,
           !chatService.isStreaming {
            Divider()
            Button {
                Task { await chatService.regenerate(in: thread) }
            } label: {
                Label("Regenerate", systemImage: "arrow.clockwise")
            }
            Button {
                Task { await chatService.regenerate(in: thread, using: .fast) }
            } label: {
                Label("Regenerate with Fast", systemImage: "hare")
            }
            Button {
                Task { await chatService.regenerate(in: thread, using: .smart) }
            } label: {
                Label("Regenerate with Smart", systemImage: "brain")
            }
        }
    }
}

private struct ChatResponseInfoView: View {
    @Environment(\.dismiss) private var dismiss
    let message: ChatMessage
    let run: ChatAgentRun?
    let contextUsage: ChatContextUsage?
    let contextWarning: String?

    var body: some View {
        Form {
            Section("Generation") {
                infoRow("Status", run?.phase.rawValue.capitalized ?? "Completed")
                infoRow("Provider", message.providerID ?? run?.providerID ?? "Unknown")
                infoRow("Model", message.modelID ?? run?.modelID ?? "Unknown")
                if let baseModel = run?.baseModelID, baseModel != run?.modelID {
                    infoRow("Resolved model", baseModel)
                }
                if let requestID = message.providerRequestID ?? run?.providerRequestID {
                    infoRow("Request ID", requestID)
                }
            }

            if let run {
                Section("Performance") {
                    infoRow("Rounds", run.roundRecords.count.formatted())
                    if let firstEvent = run.roundRecords.compactMap(\.firstProviderEventMs).first {
                        infoRow("First provider event", duration(firstEvent))
                    }
                    if let ttft = run.roundRecords.compactMap(\.firstVisibleTextMs).first {
                        infoRow("First visible text", duration(ttft))
                    }
                    let roundDuration = run.roundRecords.reduce(0) { $0 + $1.durationMs }
                    infoRow("Model time", duration(roundDuration))
                    infoRow("Tool time", duration(run.cumulativeToolLatencyMs))
                    if let started = run.requestStartedAt, let completed = run.requestCompletedAt {
                        infoRow("Total", elapsed(started, completed))
                    }
                    infoRow("Retries", run.roundRecords.reduce(0) { $0 + $1.retryCount }.formatted())
                }

                Section("Usage") {
                    infoRow("Input", run.reportedInputTokens.formatted())
                    infoRow("Cached input", run.reportedCachedInputTokens.formatted())
                    infoRow("Output", run.reportedOutputTokens.formatted())
                    infoRow("Reasoning", run.reportedThinkingTokens.formatted())
                    if let cost = knownCost(run) {
                        infoRow("Estimated cost", cost.formatted(.currency(code: "USD")))
                    } else {
                        infoRow("Cost", "Usage only")
                    }
                }
            }

            Section("Context Window") {
                if let usage = contextUsage {
                    infoRow("Next request estimate", "~\(compactTokens(usage.displayedTokens))")
                    infoRow("Selected limit", compactTokens(usage.selectedLimit))
                    infoRow("Reserved output", compactTokens(usage.reservedOutputTokens))
                    infoRow("Reserved tools", compactTokens(usage.reservedToolTokens))
                    if let reported = usage.reportedInputTokens {
                        infoRow("Last reported input", compactTokens(reported))
                    }
                    if let cached = usage.reportedCachedInputTokens {
                        infoRow("Last reported cached", compactTokens(cached))
                    }
                    if usage.isCompacted { infoRow("Compacted", "Yes") }
                    if usage.isEstimateFrozen { infoRow("Estimate", "Frozen during generation") }
                    if let explanation = usage.explanation ?? contextWarning {
                        Text(explanation)
                            .font(.caption)
                            .foregroundStyle(usage.isContextLimited ? .orange : .secondary)
                    }
                } else if let run {
                    infoRow("Selected limit", compactTokens(run.selectedContextLimit))
                    infoRow("Input used", compactTokens(run.reportedInputTokens))
                    infoRow("Compactions", run.compactionCount.formatted())
                } else {
                    Text("Context details are unavailable for this older response.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Response Info")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func knownCost(_ run: ChatAgentRun) -> Double? {
        let costs = run.roundRecords.compactMap(\.estimatedCostUSD)
        guard !costs.isEmpty, costs.count == run.roundRecords.count else { return nil }
        return costs.reduce(0, +)
    }

    private func duration(_ milliseconds: Int) -> String {
        milliseconds >= 1_000
            ? (Double(milliseconds) / 1_000).formatted(.number.precision(.fractionLength(1))) + " s"
            : "\(milliseconds) ms"
    }

    private func elapsed(_ start: Date, _ end: Date) -> String {
        duration(Int(max(0, end.timeIntervalSince(start)) * 1_000))
    }

    private func compactTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fk", Double(count) / 1_000) }
        return count.formatted()
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        LabeledContent(label, value: value)
            .textSelection(.enabled)
    }
}

// MARK: - ChatBubble

struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        bubbleContent
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassEffect(
                message.role == .user
                    ? .regular.tint(.blue.opacity(0.35))
                    : .regular,
                in: .rect(cornerRadius: 20)
            )
    }

    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(message.safeAttachments, id: \.id) { attachment in
                attachmentView(attachment)
            }
            if !message.text.isEmpty {
                if message.role == .user {
                    Text(message.text)
                        .font(.body)
                        .textSelection(.enabled)
                } else {
                    Text(Self.markdown(message.text))
                        .font(.body)
                        .textSelection(.enabled)
                }
            }
            if message.role == .model, !message.sourceCitations.isEmpty {
                citationLinks
            }
        }
    }

    private var citationLinks: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(message.sourceCitations.enumerated()), id: \.offset) { index, citation in
                    if let url = URL(string: citation.url) {
                        Link(destination: url) {
                            Label(citationLabel(citation, index: index), systemImage: "link")
                                .font(.caption2)
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .glassEffect(in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("assistant.source.\(index)")
                    }
                }
            }
        }
    }

    private func citationLabel(_ citation: ChatSourceCitation, index: Int) -> String {
        if let title = citation.title, !title.isEmpty { return title }
        if let host = URL(string: citation.url)?.host, !host.isEmpty { return host }
        return "Source \(index + 1)"
    }

    @ViewBuilder
    private func attachmentView(_ attachment: ChatAttachment) -> some View {
        if attachment.isImage, let image = UIImage(data: attachment.data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 160)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            Label(attachment.filename.isEmpty ? "Document" : attachment.filename, systemImage: "doc.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Renders the model's Markdown (bold, lists, links). Falls back to the
    /// raw string if parsing fails so text is never silently dropped.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

// MARK: - Tool Activity Chip

struct ToolChipView: View {
    let message: ChatMessage

    var body: some View {
        if let record = message.toolRecord {
            HStack(spacing: 6) {
                Image(systemName: ChatToolRegistry.icon(for: record.name))
                Text(record.summary)
                    .lineLimit(1)
                if let sourceCount = record.sourceArtifactIDs?.count, sourceCount > 0 {
                    let sourceWord = sourceCount == 1 ? "source" : "sources"
                    Label("\(sourceCount)", systemImage: "link")
                        .accessibilityLabel("\(sourceCount) saved \(sourceWord)")
                }
                if record.status == .failed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else if record.status == .queued {
                    Image(systemName: "clock")
                } else if record.status == .running {
                    ProgressView().controlSize(.mini)
                } else if record.status == .interrupted {
                    Image(systemName: "pause.fill").foregroundStyle(.orange)
                } else if record.status == .cancelled || record.status == .denied {
                    Image(systemName: "xmark.circle").foregroundStyle(.secondary)
                } else if record.status == .completed {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect(in: .capsule)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Thread List

struct ChatThreadListView: View {
    @Binding var activeThread: ChatThread?
    @Environment(ChatService.self) private var chatService
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \ChatThread.updatedAt, order: .reverse)
    private var threads: [ChatThread]
    @Query(sort: \ChatAttachment.createdAt, order: .reverse)
    private var attachments: [ChatAttachment]

    /// Threads that have at least one message — lazily created empties from
    /// "New Conversation" taps are hidden until used.
    private var visibleThreads: [ChatThread] {
        threads.filter { !($0.messages ?? []).isEmpty }
    }

    private var libraryAttachments: [ChatAttachment] {
        attachments.filter { $0.message?.thread != nil }
    }

    var body: some View {
        NavigationStack {
            Group {
                if visibleThreads.isEmpty {
                    ContentUnavailableView {
                        Label("No Conversations", systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text("Past conversations with the Assistant appear here.")
                    }
                } else {
                    List {
                        if !libraryAttachments.isEmpty {
                            Section("Images & Files") {
                                attachmentLibrary
                                    .listRowInsets(EdgeInsets(
                                        top: OFJSpace.s6,
                                        leading: OFJSpace.s16,
                                        bottom: OFJSpace.s8,
                                        trailing: OFJSpace.s16
                                    ))
                            }
                        }

                        ForEach(visibleThreads) { thread in
                            HStack(spacing: OFJSpace.s8) {
                                Button {
                                    open(thread)
                                } label: {
                                    threadRow(thread)
                                }
                                .buttonStyle(.plain)

                                Menu {
                                    Button {
                                        Task { await chatService.regenerateTitle(in: thread) }
                                    } label: {
                                        Label("Regenerate Title", systemImage: "sparkles")
                                    }
                                    .disabled(chatService.titleGenerationThreadIDs.contains(thread.id))

                                    Divider()

                                    Button(role: .destructive) {
                                        delete(thread)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                } label: {
                                    Group {
                                        if chatService.titleGenerationThreadIDs.contains(thread.id) {
                                            ProgressView().controlSize(.small)
                                        } else {
                                            Image(systemName: "ellipsis")
                                        }
                                    }
                                    .frame(
                                        minWidth: OFJLayout.minimumHitTarget,
                                        minHeight: OFJLayout.minimumHitTarget
                                    )
                                }
                                .accessibilityLabel("Conversation actions")
                            }
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    delete(thread)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Conversations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var attachmentLibrary: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: OFJSpace.s8) {
                ForEach(libraryAttachments) { attachment in
                    Button {
                        if let thread = attachment.message?.thread {
                            open(thread)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: OFJSpace.s4) {
                            if attachment.isImage,
                               let image = UIImage(data: attachment.data) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 76, height: 64)
                                    .clipped()
                            } else {
                                Image(systemName: attachment.isPDF ? "doc.richtext.fill" : "doc.fill")
                                    .font(.title2)
                                    .frame(width: 76, height: 64)
                                    .background(Color.secondary.opacity(0.10))
                            }

                            Text(attachment.isImage ? "Photo" : attachment.filename)
                                .font(.caption2)
                                .lineLimit(1)
                                .frame(width: 76, alignment: .leading)
                        }
                        .compositingGroup()
                        .clipShape(.rect(cornerRadius: OFJRadius.badge))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        attachment.isImage
                            ? "Open conversation containing photo"
                            : "Open conversation containing \(attachment.filename)"
                    )
                }
            }
        }
    }

    private func threadRow(_ thread: ChatThread) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(thread.displayTitle)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(thread.updatedAt.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if chatService.activeThreadID == thread.id {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Assistant active")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func delete(_ thread: ChatThread) {
        if activeThread == thread {
            activeThread = nil
        }
        modelContext.delete(thread)
    }

    private func open(_ thread: ChatThread) {
        activeThread = thread
        dismiss()
    }
}
