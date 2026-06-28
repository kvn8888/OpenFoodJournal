// OpenFoodJournal — AIFoodSearchView
// Text search for foods/products using Gemini with Google Search grounding.
// AGPL-3.0 License

import SwiftUI
import SwiftData

struct AIFoodSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ScanService.self) private var scanService

    @AppStorage("scan.useProModel") private var useProModel: Bool = false

    var logDate: Date = .now

    @State private var promptText = ""
    @State private var resultPrefill: ManualEntryPrefill?
    @State private var hasSubmitted = false
    @State private var localError: String?

    @FocusState private var isPromptFocused: Bool

    private var trimmedPrompt: String {
        promptText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !trimmedPrompt.isEmpty && !scanService.isScanning
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                promptBar
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 10)

                Divider()

                emptyPrompt
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("AI Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isPromptFocused = false }
                }
            }
            .sheet(item: $resultPrefill) { prefill in
                ManualEntryView(defaultDate: logDate, prefill: prefill)
            }
            .overlay {
                if scanService.isScanning {
                    AIThinkingProgressView(
                        progressMessage: scanService.scanProgressMessage,
                        thinkingTrace: scanService.thinkingTrace,
                        thinkingTraceUpdateCount: scanService.thinkingTraceUpdateCount,
                        expectsThinkingTrace: scanService.expectsThinkingTrace
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.ultraThinMaterial)
                }
            }
            .overlay(alignment: .bottom) {
                if let localError {
                    Text(localError)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.red.gradient, in: Capsule())
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    private var promptBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search food or product", text: $promptText, axis: .vertical)
                .lineLimit(1...3)
                .focused($isPromptFocused)
                .submitLabel(.send)
                .onSubmit {
                    submitSearch()
                }

            Button {
                submitSearch()
            } label: {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .accessibilityLabel("Submit AI search")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.quaternary, in: .rect(cornerRadius: 12))
    }

    private var emptyPrompt: some View {
        ContentUnavailableView {
            Label("AI Search", systemImage: "sparkles")
        } description: {
            Text(hasSubmitted ? "Review the result, or search again." : "Ask for a product, restaurant item, or generic food.")
        }
    }

    private func submitSearch() {
        let query = trimmedPrompt
        guard !query.isEmpty, !scanService.isScanning else { return }

        hasSubmitted = true
        localError = nil
        isPromptFocused = false

        Task {
            do {
                let entry = try await scanService.searchNutrition(query: query, useProModel: useProModel)
                resultPrefill = ManualEntryPrefill(entry: entry)
            } catch {
                localError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

private struct AIThinkingProgressView: View {
    let progressMessage: String
    let thinkingTrace: [String]
    let thinkingTraceUpdateCount: Int
    let expectsThinkingTrace: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProgressView()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Searching nutrition data...")
                        .font(.subheadline.weight(.semibold))
                    Text(progressMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if expectsThinkingTrace || !thinkingTrace.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Searching", systemImage: "brain.head.profile")
                        .font(.caption.weight(.semibold))

                    Text("Search steps: \(thinkingTraceUpdateCount)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if thinkingTrace.isEmpty {
                        Text("Waiting for search results...")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(thinkingTrace.enumerated()), id: \.offset) { _, trace in
                            Text(trace)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 320, alignment: .leading)
        .padding(20)
        .glassEffect(in: .rect(cornerRadius: 20))
        .padding(.horizontal, 24)
    }
}

#Preview {
    AIFoodSearchView()
        .environment(ScanService())
}
