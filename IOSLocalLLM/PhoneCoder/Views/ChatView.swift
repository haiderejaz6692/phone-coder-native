import SwiftUI
import UIKit

@MainActor
protocol PhoneCoderChatHistory {
    func save(id: UUID, messages: [ChatMessage], modelID: String)
}

@MainActor
struct PhoneCoderConversationHistory: PhoneCoderChatHistory {
    func save(id: UUID, messages: [ChatMessage], modelID: String) {
        ConversationStore.shared.saveConversation(id: id, messages: messages, assistantModelID: modelID)
        ConversationStore.shared.flush()
    }
}

@MainActor
final class PhoneCoderChatModel: ObservableObject {
    @Published var draft = ""
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isGenerating = false
    @Published private(set) var error: String?
    @Published private(set) var budgetError: LocalAPIStrictBudgetError?
    @Published private(set) var usage = ""
    @Published private(set) var modelName = "No text model loaded"
    @Published private(set) var context = "Load a model to see its context limit"
    var historyEnabled = true {
        didSet { if !historyEnabled { persistConversation = false } }
    }
    private let coordinator: PhoneCoderInferenceCoordinator
    private let history: any PhoneCoderChatHistory
    private var conversationID = UUID()
    private var persistConversation = true
    private var active: PhoneCoderGenerationRequest?
    var canRetry: Bool { !isGenerating && budgetError == nil && messages.contains { $0.role == .user } }
    convenience init(coordinator: PhoneCoderInferenceCoordinator) {
        self.init(coordinator: coordinator, history: PhoneCoderConversationHistory())
    }
    init(coordinator: PhoneCoderInferenceCoordinator, history: any PhoneCoderChatHistory) {
        self.coordinator = coordinator; self.history = history
    }
    func refresh() async {
        let state = await coordinator.state()
        modelName = state.modelSession?.modelID ?? "No text model loaded"
        if let capabilities = try? await coordinator.capabilities() {
            context = "Context limit: \(capabilities.limits.contextWindow) tokens"
        } else { context = "Load a model to see its context limit" }
    }
    @discardableResult
    func send() -> Task<Void, Never> {
        guard !isGenerating, budgetError == nil, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return Task {} }
        guard draft.utf8.count <= 1_048_576 else {
            error = "This message exceeds the 1 MiB input limit. Send a smaller excerpt."
            return Task {}
        }
        messages.append(.init(role: .user, content: draft))
        draft = ""
        return generate()
    }
    @discardableResult
    func retry() -> Task<Void, Never> {
        guard canRetry else { return Task {} }
        if messages.last?.role == .assistant { messages.removeLast() }
        return generate()
    }
    private func generate() -> Task<Void, Never> {
        isGenerating = true; error = nil; usage = ""
        if !historyEnabled { persistConversation = false }
        let requestID = PhoneCoderRequestID(rawValue: UUID().uuidString)
        let sessionID = UUID()
        let cancellation = PhoneCoderRequestCancellation()
        // Reserve the identity before crossing the actor, so Stop also covers
        // a request waiting for its live model snapshot.
        active = .init(id: requestID, sessionID: sessionID, modelID: "", messages: messages, cancellationSignal: cancellation)
        return Task { [weak self] in
            guard let self else { return }
            do {
                let state = await coordinator.state()
                try cancellation.check()
                guard let session = state.modelSession, state.availability == .available else { throw PhoneCoderRuntimeError.modelUnavailable }
                var request = PhoneCoderGenerationRequest(id: requestID, sessionID: sessionID, modelID: session.modelID, messages: messages)
                request.strictAPI = true; request.expectedModelSessionID = session.id
                request.cancellationSignal = cancellation
                guard active?.id == requestID else { return }
                active = request; modelName = session.modelID
                messages.append(.init(role: .assistant, content: "", isStreaming: true))
                let result = try await coordinator.enqueue(request) { [weak self] event in await self?.receive(event) }
                let completed = try await result.value
                guard active?.id == requestID, !cancellation.isCancelled else { return }
                usage = "\(completed.promptTokens) input · \(completed.completionTokens) output tokens"
                finish(interrupted: false)
            } catch {
                guard active?.id == requestID else { return }
                budgetError = error as? LocalAPIStrictBudgetError
                self.error = phoneCoderError(error)
                finish(interrupted: true)
            }
        }
    }
    func receive(_ event: PhoneCoderRuntimeEvent) {
        guard let active, active.cancellationSignal?.isCancelled != true,
              event.requestID == active.id, event.sessionID == active.sessionID,
              let index = messages.indices.last, messages[index].role == .assistant else { return }
        // The coordinator validates model-session callbacks itself, including
        // a legitimate reconstructed session before any output is committed.
        // UI identity follows the request/session so that recovery stays visible.
        guard messages[index].content.utf8.count + event.text.utf8.count <= 2_097_152 else {
            stop(); error = phoneCoderError(PhoneCoderRuntimeError.outputLimit); return
        }
        messages[index].content += event.text
    }
    func stop() {
        guard let request = active else { return }
        request.cancellationSignal?.cancel()
        Task { await coordinator.cancel(requestID: request.id, sessionID: request.sessionID) }
        finish(interrupted: true)
    }
    private func finish(interrupted: Bool) {
        if let index = messages.indices.last, messages[index].role == .assistant {
            messages[index].isStreaming = false; messages[index].wasInterrupted = interrupted
        }
        if historyEnabled, persistConversation, let active, !active.modelID.isEmpty {
            history.save(id: conversationID, messages: messages, modelID: active.modelID)
        }
        active = nil; isGenerating = false
    }
    func newConversation() {
        stop(); conversationID = UUID(); messages = []; draft = ""; error = nil; budgetError = nil; usage = ""
        persistConversation = historyEnabled
    }
    func shortenLastInput() {
        guard !isGenerating, budgetError != nil,
              let index = messages.lastIndex(where: { $0.role == .user }) else { return }
        draft = messages[index].content
        messages.removeSubrange(index...)
        budgetError = nil; error = nil
    }
    func open(_ conversation: StoredConversation) {
        stop(); conversationID = conversation.id
        messages = ConversationStore.shared.messages(for: conversation.id)
        persistConversation = historyEnabled; error = nil; budgetError = nil; usage = ""
    }
}

struct PhoneCoderChatView: View {
    @ObservedObject var model: PhoneCoderChatModel
    @ObservedObject var settings: PhoneCoderSettingsModel
    @ObservedObject private var history = ConversationStore.shared
    @State private var showHistory = false
    private enum Field: Hashable { case draft }
    @FocusState private var focusedField: Field?
    let openModels: () -> Void
    var body: some View {
        List {
            Section {
                Button(action: openModels) { Label(model.modelName, systemImage: "shippingbox") }.phoneCoderTarget()
                Text(settings.historyEnabled ? "Local history on" : "Private chat · history off").font(.caption).foregroundStyle(.secondary)
                Text(model.context).font(.caption).foregroundStyle(.secondary)
                Text("Responses are text only. Chat never runs commands or tools.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.messages) { message in
                VStack(alignment: .leading, spacing: 8) {
                    Text(message.role == .user ? "You" : "Phone Coder").font(.headline)
                    // Text(verbatim:) prevents tool-looking or Markdown output
                    // from becoming an executable or remote-content surface.
                    Text(verbatim: message.content).textSelection(.enabled)
                    if message.isStreaming { ProgressView("Generating") }
                    if message.wasInterrupted { Label("Stopped", systemImage: "stop.circle").font(.caption) }
                    if !message.isStreaming, !message.content.isEmpty {
                        HStack {
                            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.content }.phoneCoderTarget()
                            ShareLink(item: message.content).phoneCoderTarget()
                        }.buttonStyle(.borderless)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                PhoneCoderInlineError(message: model.error)
                if !model.usage.isEmpty { Text(model.usage).font(.caption).foregroundStyle(.secondary) }
                if model.budgetError != nil {
                    Button("Shorten last input", systemImage: "pencil") { model.shortenLastInput() }.phoneCoderTarget()
                    Button("Start a new conversation", systemImage: "square.and.pencil") {
                        focusedField = nil; model.newConversation()
                    }.phoneCoderTarget()
                } else if model.canRetry {
                    Button("Retry last response", systemImage: "arrow.clockwise") { model.retry() }.phoneCoderTarget()
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .phoneCoderKeyboard($focusedField)
        .safeAreaInset(edge: .bottom) {
            HStack(alignment: .bottom) {
                TextField("Message your local model", text: $model.draft, axis: .vertical)
                    .focused($focusedField, equals: .draft)
                    .accessibilityIdentifier("phonecoder.chat.draft")
                    .lineLimit(1...6).textFieldStyle(.roundedBorder).phoneCoderTarget()
                if model.isGenerating {
                    Button("Stop", systemImage: "stop.fill") { model.stop() }.phoneCoderTarget()
                } else {
                    Button("Send", systemImage: "arrow.up.circle.fill") {
                        let previousCount = model.messages.count
                        model.send()
                        focusedField = PhoneCoderKeyboardFocus.afterSubmission(
                            accepted: model.messages.count > previousCount, current: focusedField)
                    }
                        .accessibilityIdentifier("phonecoder.chat.send")
                        .disabled(model.budgetError != nil || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).phoneCoderTarget()
                }
            }.padding().background(.regularMaterial)
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("History", systemImage: "clock") { focusedField = nil; showHistory = true }
                    .disabled(!settings.historyEnabled).accessibilityIdentifier("phonecoder.chat.history")
                Button("New chat", systemImage: "square.and.pencil") { focusedField = nil; model.newConversation() }
            }
        }
        .sheet(isPresented: $showHistory) {
            NavigationStack {
                List(history.conversations) { conversation in
                    Button(conversation.title) { model.open(conversation); showHistory = false }.phoneCoderTarget()
                }.navigationTitle("Local conversations")
                    .toolbar { Button("Done") { showHistory = false }.accessibilityIdentifier("phonecoder.chat.history.done") }
            }
        }
        .task { model.historyEnabled = settings.historyEnabled; await model.refresh() }
        .onChange(of: settings.historyEnabled) { _, value in model.historyEnabled = value }
    }
}
