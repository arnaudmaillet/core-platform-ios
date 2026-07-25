import CoreModels
import CoreNavigation
import Foundation

/// The "Requests" surface's view model: conversations from accounts the viewer
/// doesn't follow and hasn't answered.
///
/// It shares `InboxCatalog` with the conversation list, so the inbox is
/// fetched once and a request accepted here appears in All immediately — the
/// two tabs are two projections of one truth, never two copies of it.
@MainActor
public final class MessageRequestsViewModel {
    public nonisolated enum Phase: Equatable, Sendable {
        case loading
        case content([ConversationDisplayModel])
        case empty
        case failed(message: String)
    }

    public var onPhaseChange: ((Phase) -> Void)?
    /// The number of pending requests, for the header badge. Emitted on every
    /// projection — including while the surface is off screen, which is when a
    /// badge matters most.
    public var onCountChange: ((Int) -> Void)?

    private(set) public var count = 0

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

    /// Standalone construction — used by tests; the app injects the shared
    /// catalog so All and Requests agree on one load.
    public convenience init(
        repository: any ChatProviding,
        relations: (any PeerRelationProviding)? = nil,
        router: (any Router)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            catalog: InboxCatalog(repository: repository, relations: relations),
            router: router,
            now: now
        )
    }

    public func refresh() {
        catalog.refresh()
    }

    /// Opening a request reads it — the thread is the same screen as any
    /// other conversation, so the route is the same too.
    public func didSelect(_ id: ConversationID) {
        router?.route(to: .conversation(id))
    }

    /// Lets the sender through: the conversation moves to All and stops being
    /// counted here.
    public func accept(_ id: ConversationID) {
        catalog.accept(id)
    }

    /// Dismisses the request. The conversation still exists server-side —
    /// `chat.v1` has no decline RPC — it simply stops being surfaced.
    public func decline(_ id: ConversationID) {
        catalog.decline(id)
    }

    private func project(_ snapshot: InboxCatalog.Snapshot) {
        if count != snapshot.requests.count {
            count = snapshot.requests.count
            onCountChange?(count)
        }
        switch snapshot.phase {
        case .loading:
            phase = .loading
        case .failed(let message):
            phase = .failed(message: message)
        case .loaded:
            guard !snapshot.requests.isEmpty else {
                phase = .empty
                return
            }
            let now = now()
            phase = .content(snapshot.requests.map { ConversationDisplayModel(conversation: $0, now: now) })
        }
    }
}
