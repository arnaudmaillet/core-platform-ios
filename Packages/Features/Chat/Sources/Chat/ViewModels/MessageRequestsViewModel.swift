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
    /// How many requests have arrived since the tab was last visited, for its
    /// badge. Emitted on every projection — including while the surface is off
    /// screen, which is when a badge matters most.
    public var onNewCountChange: ((Int) -> Void)?

    /// NOT the pending total. The badge reports arrivals since the last visit
    /// and clears when the tab is selected — see `InboxTabWatermark`. The
    /// pending requests themselves stay on the tab until they are answered;
    /// they simply stop being announced once they have been seen.
    private(set) public var newCount = 0

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

    /// The tab was selected: clear its badge, and re-project so the rows adopt
    /// the baseline that badge was counting against — the requests that were
    /// new stay marked for the length of this visit.
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
        watermark.leave(at: now(), having: catalog.snapshot.requests)
        // No explicit zero: re-projecting recomputes the count against the
        // watermark that just moved, so the badge clears through the SAME path
        // it is ever set by. Publishing zero first as well let an observer see
        // it twice — zero, then whatever the projection made of it.
        project(catalog.snapshot)
    }

    private func publishNewCount(_ count: Int) {
        guard newCount != count else { return }
        newCount = count
        onNewCountChange?(count)
    }

    private func project(_ snapshot: InboxCatalog.Snapshot) {
        publishNewCount(watermark.newCount(in: snapshot.requests))
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
            // `isUnread` carries "unviewed" here. A request has no read cursor
            // — nothing in `chat.v1` records that you looked at one — so what
            // marks it is the same watermark that counts it, and the row's
            // treatment (bold preview, a dot on the avatar) is the treatment an
            // unread conversation gets. One flag, so both cells stay honest
            // about meaning the same thing: new to you.
            phase = .content(snapshot.requests.map {
                ConversationDisplayModel(
                    conversation: $0,
                    now: now,
                    isUnread: watermark.isNewOnRow($0)
                )
            })
        }
    }
}
