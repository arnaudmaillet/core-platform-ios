import CoreModels
import CoreNavigation
import Foundation

/// The "All" surface's view model: active conversations only.
///
/// Loading and inbox truth live in `InboxCatalog` (shared with the Requests
/// surface, so the inbox's conversations are fetched once, not once per tab).
/// What stays here is this surface's own presentation: phases, display-model
/// projection, and the routes a row tap emits.
@MainActor
public final class ConversationListViewModel {
    public nonisolated enum Phase: Equatable, Sendable {
        case loading
        case content([ConversationDisplayModel])
        case empty
        case failed(message: String)
    }

    public var onPhaseChange: ((Phase) -> Void)?

    private let catalog: InboxCatalog
    private let router: (any Router)?
    private let now: @Sendable () -> Date

    private var phase: Phase = .loading { didSet { onPhaseChange?(phase) } }
    private var observation: InboxCatalog.ObservationToken?

    init(
        catalog: InboxCatalog,
        router: (any Router)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.catalog = catalog
        self.router = router
        self.now = now
        observation = catalog.observe { [weak self] snapshot in self?.project(snapshot) }
    }

    /// Standalone construction — one surface over its own catalog. The app
    /// injects a shared catalog instead, so All and Requests agree on one load.
    public convenience init(
        repository: any ChatProviding,
        router: (any Router)? = nil,
        directory: ConversationDirectory? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            catalog: InboxCatalog(repository: repository, directory: directory),
            router: router,
            now: now
        )
    }

    public func viewWillAppear() {
        // Reload each time it appears so a just-sent message updates the preview.
        catalog.reload()
    }

    public func refresh() {
        catalog.refresh()
    }

    /// Opens the tapped conversation via routing (the resolver pushes the
    /// thread). Chat never navigates directly.
    public func didSelect(_ id: ConversationID) {
        router?.route(to: .conversation(id))
    }

    /// The compose (new message) entry point, same seam as `didSelect`: emit
    /// the route and let the resolver own the contact-selection flow.
    public func didTapCompose() {
        router?.route(to: .newMessage)
    }

    // MARK: - Inbox management

    public func isPinned(_ id: ConversationID) -> Bool { catalog.isPinned(id) }
    public func isMuted(_ id: ConversationID) -> Bool { catalog.isMuted(id) }

    public func togglePin(_ id: ConversationID) { catalog.togglePin(id) }
    public func toggleMute(_ id: ConversationID) { catalog.toggleMute(id) }
    public func delete(_ ids: Set<ConversationID>) { catalog.delete(ids) }

    // MARK: - Projection

    private func project(_ snapshot: InboxCatalog.Snapshot) {
        switch snapshot.phase {
        case .loading:
            phase = .loading
        case .failed(let message):
            phase = .failed(message: message)
        case .loaded:
            guard !snapshot.active.isEmpty else {
                phase = .empty
                return
            }
            let now = now()
            phase = .content(snapshot.active.map {
                ConversationDisplayModel(
                    conversation: $0,
                    now: now,
                    isPinned: snapshot.pinned.contains($0.id),
                    isMuted: snapshot.muted.contains($0.id)
                )
            })
        }
    }
}
