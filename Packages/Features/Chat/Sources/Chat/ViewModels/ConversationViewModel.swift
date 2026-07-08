import CoreModels
import Foundation

@MainActor
public final class ConversationViewModel {
    public nonisolated enum Phase: Equatable, Sendable {
        case loading
        case content([MessageDisplayModel])
        case failed(message: String)
    }

    public var onPhaseChange: ((Phase) -> Void)?
    /// True while a message is being sent (disables the send control).
    public var onSendingChange: ((Bool) -> Void)?

    private let conversationID: ConversationID
    private let repository: any ChatProviding

    private var messages: [ChatMessage] = []
    private var phase: Phase = .loading { didSet { onPhaseChange?(phase) } }
    private var isSending = false
    private var load: Task<Void, Never>?

    public init(conversationID: ConversationID, repository: any ChatProviding) {
        self.conversationID = conversationID
        self.repository = repository
    }

    public func viewDidLoad() {
        reload()
    }

    public func refresh() {
        guard load == nil else { return }
        reload()
    }

    /// Sends a message and appends it. Empty/whitespace input is ignored.
    public func send(_ text: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !isSending else { return }
        setSending(true)
        Task { [weak self] in
            guard let self else { return }
            if let message = try? await self.repository.send(body, to: self.conversationID) {
                self.messages.append(message)
                self.emit()
                try? await self.repository.markRead(self.conversationID, upTo: message.id)
            }
            self.setSending(false)
        }
    }

    private func reload() {
        load?.cancel()
        load = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await self.repository.loadMessages(in: self.conversationID)
                self.messages = loaded
                self.emit()
                if let last = loaded.last {
                    try? await self.repository.markRead(self.conversationID, upTo: last.id)
                }
            } catch is CancellationError {
                // Superseded.
            } catch {
                if case .content = self.phase {} else {
                    self.phase = .failed(message: "Couldn't load this conversation. Pull to retry.")
                }
            }
            self.load = nil
        }
    }

    private func emit() {
        phase = .content(messages.map(MessageDisplayModel.init))
    }

    private func setSending(_ sending: Bool) {
        isSending = sending
        onSendingChange?(sending)
    }
}
