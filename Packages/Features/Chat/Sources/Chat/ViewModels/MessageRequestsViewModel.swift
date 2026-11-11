import CoreModels
import CoreNavigation
import Foundation

/// The "Requests" surface's view model: conversations from accounts the viewer
/// doesn't follow and hasn't answered.
///
/// It also drives the **Hidden requests** list (#552), the same screen over
/// the HIDDEN REQUESTS folder: requests the viewer's hidden words or offensive
/// filter caught. Opening, accepting and declining one work like any request;
/// what differs is that a hidden request announces nothing (no badge, never
/// marked new) and the list has no row leading further.
///
/// It shares `InboxCatalog` with the conversation list, so the inbox is
/// fetched once and a request accepted here appears in All immediately — the
/// two tabs are two projections of one truth, never two copies of it.
///
/// With channels (#2230, `-channels`), the Requests list also leads with a
/// **Join requests** section: the channels the viewer runs with requests
/// waiting, one row each (`ChannelJoinRequestsDigest`), counted in the badge
/// one per request, as a message request is (#2171).
@MainActor
public final class MessageRequestsViewModel {
    public nonisolated enum Phase: Equatable, Sendable {
        case loading
        /// One list of requests, sorted by recency (#2292): no New / Recent
        /// sections. Empty while only the Hidden requests row or the join
        /// requests show.
        case content([ConversationDisplayModel])
        case empty
        case failed(message: String)
    }

    public var onPhaseChange: ((Phase) -> Void)?
    /// How many requests are new, for its badge. Emitted on every
    /// projection — including while the surface is off screen, which is when
    /// a badge matters most.
    public var onNewCountChange: ((Int) -> Void)?

    /// THE NEW REQUESTS, each one 1 whatever its messages (the owner,
    /// 2026-11-07, #2171; it counted their unread messages, #1210): the
    /// requests the row marks new with its bold preview, falling as one is
    /// opened. The Chats tab keeps counting messages. Every join request waiting on
    /// a channel the viewer runs adds one too (#2230), until it is answered.
    private(set) public var newCount = 0

    /// The Join requests section's rows (#2230): the channels the viewer
    /// runs with requests waiting. Empty without channels, and always on the
    /// Hidden requests list.
    private(set) var joinRequests: [ChannelJoinRequestsDigest.Entry] = []
    /// The section's rows changed.
    var onJoinRequestsChange: (([ChannelJoinRequestsDigest.Entry]) -> Void)?
    /// Where they come from; nil without channels.
    private let joinRequestsDigest: ChannelJoinRequestsDigest?
    /// The catalog's last word, re-projected when the join requests change.
    private var lastSnapshot: InboxCatalog.Snapshot?

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

    /// `joinRequests`: the channels' join requests (#2230), for the
    /// Requests list only — the hidden one never shows them.
    init(
        catalog: InboxCatalog,
        router: (any Router)? = nil,
        folder: InboxFolder = .requests,
        joinRequests: ChannelJoinRequestsDigest? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.catalog = catalog
        self.router = router
        self.folder = folder
        self.now = now
        joinRequestsDigest = folder == .requests ? joinRequests : nil
        watermark = InboxTabWatermark(openedAt: Self.openingBaseline(now()))
        observation = catalog.observe { [weak self] snapshot in self?.project(snapshot) }
        joinRequestsDigest?.onChange = { [weak self] in
            guard let self, let snapshot = self.lastSnapshot else { return }
            self.project(snapshot)
        }
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

    /// Try Again (#1770): asks again whatever is in flight — past "taking
    /// longer" the first read is still out, and `refresh()` would wait on it.
    public func retry() {
        catalog.reload()
    }

    public func refresh() {
        catalog.refresh()
        joinRequestsDigest?.refresh()
    }

    /// Counts the join requests again (#2230): the list answered some.
    func refreshJoinRequests() {
        joinRequestsDigest?.refresh()
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

    /// Dismisses the request, silently declined server-side
    /// (`RespondToMessageRequest`, #2212).
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
        lastSnapshot = snapshot
        let isHiddenFolder = folder == .hiddenRequests
        let requests = isHiddenFolder ? snapshot.hiddenRequests : snapshot.requests
        hasMore = snapshot.hasMore.contains(folder)
        let channelRequests = joinRequestsDigest?.entries ?? []
        if channelRequests != joinRequests {
            joinRequests = channelRequests
            onJoinRequestsChange?(channelRequests)
        }
        // A hidden request announces nothing: the server sends no push for it,
        // and the badge would point at a list it isn't on.
        let unreadRequests = isHiddenFolder ? 0 : requests.count { snapshot.unreadIDs.contains($0.id) }
        let waitingToJoin: Int = joinRequestsDigest?.total ?? 0
        publishNewCount(unreadRequests + waitingToJoin)
        showsHiddenRequestsRow = !isHiddenFolder
            && (!snapshot.hiddenRequests.isEmpty || snapshot.hasMore.contains(.hiddenRequests))
        switch snapshot.phase {
        case .loading:
            phase = .loading
        case .failed(let message):
            phase = .failed(message: message)
        case .loaded:
            guard !requests.isEmpty else {
                // No visible request, but hidden ones, or join requests
                // (#2230): the list still shows, so its Hidden requests row
                // and its Join requests section stay reachable.
                phase = showsHiddenRequestsRow || !channelRequests.isEmpty ? .content([]) : .empty
                return
            }
            let now = now()
            // `isUnread` carries "unviewed" here. A request has no read cursor
            // — nothing in `chat.v1` records that you looked at one — so what
            // marks it is the same watermark that counts it, and the row's
            // treatment (bold preview, a dot on the avatar) is the treatment an
            // unread conversation gets. One flag, so both cells stay honest
            // about meaning the same thing: new to you.
            // The All list's projection, and deliberately so: a request wears
            // the same bold preview, and it stops wearing it for the same
            // reason — the viewer opened it, which moved the read cursor. Its
            // row shows no count (#2171): the tab counts requests. `isUnread`
            // used to be the watermark here, which meant a request stayed
            // marked after being read.
            //
            // One list (#2292): the watermark's question — what arrived since
            // the app opened — no longer splits it. It is carried on the row
            // (`isNew`), as on Chats; a request draws no count, so it changes
            // nothing a viewer sees here. A hidden request is never new.
            let models = requests.map {
                ConversationDisplayModel(
                    conversation: $0,
                    now: now,
                    isUnread: snapshot.unreadIDs.contains($0.id),
                    unreadCount: snapshot.unreadIDs.contains($0.id) ? $0.unreadCount : 0,
                    isNew: !isHiddenFolder && watermark.isNewOnRow($0)
                )
            }
            phase = .content(models)
        }
    }
}
