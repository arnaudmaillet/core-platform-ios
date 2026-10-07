import CoreModels
import CoreNavigation
import Foundation

/// The "Requests" surface's view model: conversations from accounts the viewer
/// doesn't follow and hasn't answered.
///
/// It also drives the **Hidden requests** list (#552), the same screen over
/// the HIDDEN REQUESTS folder: requests the viewer's hidden words or offensive
/// filter caught. Opening, accepting and declining one work like any request;
/// what differs is that a hidden request announces nothing (no badge, no New
/// section) and the list has no row leading further.
///
/// It shares `InboxCatalog` with the conversation list, so the inbox is
/// fetched once and a request accepted here appears in All immediately — the
/// two tabs are two projections of one truth, never two copies of it.
@MainActor
public final class MessageRequestsViewModel {
    public nonisolated enum Phase: Equatable, Sendable {
        case loading
        case content(InboxListSections)
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
    /// `.requests` or `.hiddenRequests` — which folder this list shows.
    public let folder: InboxFolder

    /// Readable, because a surface's view can be built after the first phase
    /// landed (the inbox no longer loads every surface up front) and must
    /// render what is current, not `.loading`.
    public private(set) var phase: Phase = .loading { didSet { onPhaseChange?(phase) } }
    private var observation: InboxCatalog.ObservationToken?
    private var watermark: InboxTabWatermark

    init(
        catalog: InboxCatalog,
        router: (any Router)? = nil,
        folder: InboxFolder = .requests,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.catalog = catalog
        self.router = router
        self.folder = folder
        self.now = now
        watermark = InboxTabWatermark(openedAt: Self.openingBaseline(now()))
        observation = catalog.observe { [weak self] snapshot in self?.project(snapshot) }
    }

    /// Standalone construction — used by tests; the app injects the shared
    /// catalog so All and Requests agree on one load.
    public convenience init(
        repository: any ChatProviding,
        router: (any Router)? = nil,
        folder: InboxFolder = .requests,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            catalog: InboxCatalog(repository: repository),
            router: router,
            folder: folder,
            now: now
        )
    }

    /// Whether the Requests list ends on the **Hidden requests** row (#552):
    /// the hidden folder holds at least one request. Always false on the
    /// hidden list itself.
    public private(set) var showsHiddenRequestsRow = false {
        didSet { if showsHiddenRequestsRow != oldValue { onShowsHiddenRequestsRowChange?(showsHiddenRequestsRow) } }
    }
    public var onShowsHiddenRequestsRowChange: ((Bool) -> Void)?

    /// Another page is there to load (#593): the list wears its spinner at
    /// the bottom until it lands.
    public private(set) var hasMore = false {
        didSet { if hasMore != oldValue { onHasMoreChange?(hasMore) } }
    }
    public var onHasMoreChange: ((Bool) -> Void)?

    /// The viewer neared the end of the list.
    public func loadMore() {
        catalog.loadMore(folder)
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

    private func publishNewCount(_ count: Int) {
        guard newCount != count else { return }
        newCount = count
        onNewCountChange?(count)
    }

    private func project(_ snapshot: InboxCatalog.Snapshot) {
        let isHiddenFolder = folder == .hiddenRequests
        let requests = isHiddenFolder ? snapshot.hiddenRequests : snapshot.requests
        hasMore = snapshot.hasMore.contains(folder)
        // A hidden request announces nothing: the server sends no push for it,
        // and the badge would point at a list it isn't on.
        publishNewCount(isHiddenFolder ? 0 : watermark.newCount(in: requests))
        showsHiddenRequestsRow = !isHiddenFolder
            && (!snapshot.hiddenRequests.isEmpty || snapshot.hasMore.contains(.hiddenRequests))
        switch snapshot.phase {
        case .loading:
            phase = .loading
        case .failed(let message):
            phase = .failed(message: message)
        case .loaded:
            guard !requests.isEmpty else {
                // No visible request, but hidden ones: the list still shows,
                // empty, so its Hidden requests row stays reachable.
                phase = showsHiddenRequestsRow ? .content(InboxListSections()) : .empty
                return
            }
            let now = now()
            // `isUnread` carries "unviewed" here. A request has no read cursor
            // — nothing in `chat.v1` records that you looked at one — so what
            // marks it is the same watermark that counts it, and the row's
            // treatment (bold preview, a dot on the avatar) is the treatment an
            // unread conversation gets. One flag, so both cells stay honest
            // about meaning the same thing: new to you.
            // Identical to the All list's projection, and deliberately so: a
            // request wears the same bold preview and the same numeric badge on
            // the same corner of the same avatar, and it stops wearing them for
            // the same reason — the viewer opened it, which moved the read
            // cursor. `isUnread` used to be the watermark here, which meant a
            // request stayed marked after being read.
            let isNew = Dictionary(
                uniqueKeysWithValues: requests.map { ($0.id, !isHiddenFolder && watermark.isNewOnRow($0)) }
            )
            let models = requests.map {
                ConversationDisplayModel(
                    conversation: $0,
                    now: now,
                    isUnread: snapshot.unreadIDs.contains($0.id),
                    unreadCount: snapshot.unreadIDs.contains($0.id) ? $0.unreadCount : 0
                )
            }
            // The SECTION is the watermark's question — what arrived since the
            // app opened — which is a different question from whether a row has
            // been read, and the two now have separate answers.
            phase = .content(InboxListSections(rows: models) { isNew[$0.id] ?? false })
        }
    }
}
