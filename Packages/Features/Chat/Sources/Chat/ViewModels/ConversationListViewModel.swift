import CoreModels
import CoreNavigation
import Foundation

/// The "All" surface's view model: active conversations, with unread ones
/// marked in place rather than split off.
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
    /// How many conversations have arrived since the tab was last visited,
    /// published so the container can put the count on the All tab.
    public var onNewCountChange: ((Int) -> Void)?

    /// NOT the unread total. This is what the badge reports: new since the last
    /// visit, cleared by visiting — see `InboxTabWatermark`. The unread total
    /// still exists and still marks the rows; it simply is not a badge, because
    /// a number that only goes down when you read everything is a number that
    /// sits there.
    public private(set) var newCount = 0

    private let catalog: InboxCatalog
    private let router: (any Router)?
    private let now: @Sendable () -> Date

    private var phase: Phase = .loading { didSet { onPhaseChange?(phase) } }
    private var observation: InboxCatalog.ObservationToken?
    private var watermark: InboxTabWatermark

    init(
        catalog: InboxCatalog,
        router: (any Router)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.catalog = catalog
        self.router = router
        self.now = now
        watermark = InboxTabWatermark(openedAt: Self.openingBaseline(now()))
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

    /// The tab was selected. Clears its badge — that is what selecting a tab
    /// means — and re-projects so the rows settle on the new baseline.
    /// Where the watermark starts, which is "now" outside a QA run.
    ///
    /// ⚠️ `-inbox-mock-new-activity` back-dates it far enough that the seeded
    /// inbox reads as having arrived since. Mock conversations are STATIC — the
    /// fixtures never gain a message while the app is running — so without this
    /// a watermark badge can only ever be zero, and the feature is unverifiable
    /// in the simulator. The same shape `-foryou-mock-new-activity` uses, and
    /// for the same reason.
    private static func openingBaseline(_ now: Date) -> Date {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-inbox-mock-new-activity") {
            return .distantPast
        }
        #endif
        return now
    }

    /// The viewer has LEFT this tab — paged away, or left the screen. Only now
    /// does the badge clear, and with it the marks on the rows it counted:
    /// while the viewer was here, those were the thing they came to read. A
    /// badge that empties on the tap that reveals it is a badge nobody sees.
    public func didLeave() {
        watermark.leave(at: now())
        // No explicit zero: re-projecting recomputes the count against the
        // watermark that just moved, so the badge clears through the SAME path
        // it is ever set by. Publishing zero first as well let an observer see
        // it twice — zero, then whatever the projection made of it.
        project(catalog.snapshot)
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

    private func publishNewCount(_ count: Int) {
        guard newCount != count else { return }
        newCount = count
        onNewCountChange?(count)
    }

    private func project(_ snapshot: InboxCatalog.Snapshot) {
        let rows = snapshot.active
        publishNewCount(watermark.newCount(in: rows))
        switch snapshot.phase {
        case .loading:
            phase = .loading
        case .failed(let message):
            phase = .failed(message: message)
        case .loaded:
            guard !rows.isEmpty else {
                phase = .empty
                return
            }
            let now = now()
            phase = .content(rows.map {
                ConversationDisplayModel(
                    conversation: $0,
                    now: now,
                    isPinned: snapshot.pinned.contains($0.id),
                    isMuted: snapshot.muted.contains($0.id),
                    isUnread: snapshot.unreadIDs.contains($0.id),
                    // Suppressed with the flag: the catalog's read bridge can
                    // clear a row ahead of the server, and a count left behind
                    // would be a number beside a row that reads as read.
                    unreadCount: snapshot.unreadIDs.contains($0.id) ? $0.unreadCount : 0
                )
            })
        }
    }
}
