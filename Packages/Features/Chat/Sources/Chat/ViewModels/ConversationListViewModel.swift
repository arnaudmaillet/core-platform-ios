import CoreModels
import CoreNavigation
import Foundation

@MainActor
public final class ConversationListViewModel {
    public nonisolated enum Phase: Equatable, Sendable {
        case loading
        case content([ConversationDisplayModel])
        case empty
        case failed(message: String)
    }

    public var onPhaseChange: ((Phase) -> Void)?

    private let repository: any ChatProviding
    private let router: (any Router)?
    private let now: @Sendable () -> Date

    private var conversations: [Conversation] = []
    private var phase: Phase = .loading { didSet { onPhaseChange?(phase) } }
    private var load: Task<Void, Never>?

    public init(
        repository: any ChatProviding,
        router: (any Router)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.repository = repository
        self.router = router
        self.now = now
    }

    public func viewWillAppear() {
        // Reload each time it appears so a just-sent message updates the preview.
        reload()
    }

    public func refresh() {
        guard load == nil else { return }
        reload()
    }

    /// Opens the tapped conversation via routing (the resolver pushes the
    /// thread). Chat never navigates directly.
    public func didSelect(_ id: ConversationID) {
        router?.route(to: .conversation(id))
    }

    private func reload() {
        load?.cancel()
        load = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await self.repository.loadConversations()
                self.conversations = loaded
                if loaded.isEmpty {
                    self.phase = .empty
                } else {
                    let now = self.now()
                    self.phase = .content(loaded.map { ConversationDisplayModel(conversation: $0, now: now) })
                }
            } catch is CancellationError {
                // Superseded.
            } catch {
                if case .content = self.phase {} else {
                    self.phase = .failed(message: "Couldn't load your messages. Pull to retry.")
                }
            }
            self.load = nil
        }
    }
}
