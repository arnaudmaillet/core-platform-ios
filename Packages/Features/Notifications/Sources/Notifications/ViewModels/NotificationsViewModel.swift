import CoreModels
import CoreNavigation
import CoreNetworking
import DesignSystem
import Foundation

/// The notifications list: loads, splits into "New" and "Earlier", holds the
/// "Show more" state, marks the new rows seen, and routes a tap.
///
/// ## When a notification counts as read
///
/// When the viewer has LOOKED at the list — the drawer settled open with the
/// list loaded (`didReveal`) — the server is told at once, so the bell's badge
/// clears while the drawer is still open. The rows, though, stay where they
/// were for the rest of that visit: nothing moves out of "New" under the
/// viewer's eye. They move to "Earlier" when the drawer closes
/// (`didConceal`), which is also when "Show more" folds back. A peek that
/// never settles open marks nothing.
///
/// Everything behind "Show more" is marked too — the only write the contract
/// has is "mark ALL read" — and that is the right call anyway: the section
/// header said how many there were, which is what "seen" means for a badge.
///
/// ## Pages (#608)
///
/// The list loads a first page, then the next one as the viewer nears the
/// end, until the server has no more. A later page is appended, never
/// reordering what is shown, and a row already loaded is not shown twice. A
/// reload starts again from the first page.
@MainActor
public final class NotificationsViewModel {
    /// The shared four states (charter P11).
    public typealias Phase = Loadable<[NotificationSection]>

    public var onPhaseChange: ((Phase) -> Void)?

    /// What closes the list (#608): nothing, a spinner while there is another
    /// page to load, or "Try Again" after a page failed.
    public enum PageFooter: Equatable, Sendable {
        case none
        case loading
        case retry
    }

    public private(set) var pageFooter: PageFooter = .none {
        didSet { if pageFooter != oldValue { onPageFooterChange?(pageFooter) } }
    }
    public var onPageFooterChange: ((PageFooter) -> Void)?

    /// A page filtered down to nothing still carries a token; this many in a
    /// row are walked through before waiting for the next approach.
    static let maxEmptyPagesInARow = 5

    private let repository: any NotificationsProviding
    private let router: (any Router)?
    private let pageSize: Int32
    private let now: @Sendable () -> Date

    private var items: [NotificationItem] = []
    private var phase: Phase = .loading { didSet { onPhaseChange?(phase) } }
    private var recovery: RecoveryObservation?
    /// The monitor whose recoveries reload this store — the shared one; a
    /// test hands its own (the shared one is process-wide).
    var connectivity: ConnectivityMonitor = .shared
    private var load: Task<Void, Never>?
    private var hasLoaded = false
    /// Where the next page starts; nil when there are no more.
    private var nextPageToken: String?
    /// The page on its way — one at a time.
    private var pageLoad: Task<Void, Never>?
    /// The last page failed: it waits for "Try Again".
    private var pageFailed = false
    /// "Show more" was pressed this visit.
    private var isNewExpanded = false
    /// The drawer is open and settled.
    private var isRevealed = false
    /// The server has been told this visit's rows are read.
    private var hasMarkedThisVisit = false

    public init(
        repository: any NotificationsProviding,
        router: (any Router)? = nil,
        pageSize: Int32 = 20,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.repository = repository
        self.router = router
        self.pageSize = pageSize
        self.now = now
    }

    // MARK: - Inputs

    public func viewDidLoad() {
        armRecovery()
        reload()
    }

    /// The list is about to show. Every visit after the first reloads, so a
    /// drawer opened an hour later is not an hour stale; the first visit's
    /// load is already running from `viewDidLoad`.
    public func willReveal() {
        guard hasLoaded, load == nil else { return }
        reload()
    }

    /// The list has settled on screen: the viewer is looking at it.
    public func didReveal() {
        isRevealed = true
        markSeenIfLooking()
    }

    /// The list has gone. What was new this visit is old from now on.
    public func didConceal() {
        isRevealed = false
        let wasExpanded = isNewExpanded
        isNewExpanded = false
        if hasMarkedThisVisit {
            hasMarkedThisVisit = false
            items = items.map { $0.markedRead() }
            emitContent()
        } else if wasExpanded {
            emitContent()
        }
    }

    /// Reloads after an outage (#793): what failed while the network was gone
    /// comes back on its own when it returns — the viewer no longer has to
    /// find a way to retry, screen by screen.
    private func armRecovery() {
        guard recovery == nil else { return }
        recovery = connectivity.onRecovery { [weak self] in self?.recoverFromOutage() }
    }

    private func recoverFromOutage() {
        // Only what failed: a refresh replaces the list with its first page,
        // collapsing a viewer three pages deep.
        if case .failed = phase {
            refresh()
        } else if pageFailed {
            retryPage()
        }
    }

    public func refresh() {
        guard load == nil else { return }
        reload()
    }

    /// The viewer neared the end of the list: the next page, if there is one,
    /// none is already on the way, and the last one did not fail.
    public func loadNextPageIfNeeded() {
        guard pageLoad == nil, load == nil, !pageFailed, let token = nextPageToken else { return }
        loadPages(after: token)
    }

    /// "Try Again" under the list: the page that failed, once more.
    public func retryPage() {
        guard pageFailed, pageLoad == nil, load == nil, let token = nextPageToken else { return }
        pageFailed = false
        updatePageFooter()
        loadPages(after: token)
    }

    /// "Show more": the rest of the new rows, in place.
    public func showMore() {
        guard !isNewExpanded else { return }
        isNewExpanded = true
        emitContent()
    }

    /// Tap on a row: route to its subject — a post when the notification is
    /// about one, otherwise the sender's profile. Notifications never imports
    /// Feed or Profile; it only emits routes (and the shell, receiving one,
    /// closes the drawer to show where it went).
    public func didSelect(_ id: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if let postID = item.postSubjectID {
            router?.route(to: .post(postID))
        } else {
            // Notification rows render an aggregated sentence, not the raw
            // handle, so there is no identity slice to attach.
            router?.route(to: .profile(item.senderID, stub: nil))
        }
    }

    // MARK: - Loading

    private func reload() {
        load?.cancel()
        // The first page replaces the list, and its token the cursor: a page
        // still on its way belongs to the list being replaced.
        pageLoad?.cancel()
        pageLoad = nil
        load = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await self.repository.loadNotifications(limit: self.pageSize, after: nil)
                let loaded = page.items
                self.items = loaded
                self.nextPageToken = page.nextPageToken
                self.pageFailed = false
                self.hasLoaded = true
                self.updatePageFooter()
                if loaded.isEmpty {
                    self.phase = .empty
                } else {
                    self.emitContent()
                }
            } catch is CancellationError {
                // Superseded; leave the phase alone.
            } catch {
                if case .content = self.phase {} else {
                    self.phase = .failed(message: "Couldn't load your notifications.")
                }
            }
            self.load = nil
            self.markSeenIfLooking()
        }
    }

    /// The next page from `token`, appended. A page whose rows are all
    /// already loaded leaves nothing on screen to ask again, so the one after
    /// it is asked at once (at most `maxEmptyPagesInARow`).
    private func loadPages(after token: String) {
        pageLoad = Task { [weak self] in
            guard let self else { return }
            var token = token
            var fresh: [NotificationItem] = []
            for _ in 0..<Self.maxEmptyPagesInARow {
                let page: NotificationsPage
                do {
                    page = try await self.repository.loadNotifications(limit: self.pageSize, after: token)
                } catch {
                    // A reload cancelled this page: the list it belonged to is gone.
                    guard !Task.isCancelled else { return }
                    self.pageLoad = nil
                    self.pageFailed = true
                    self.updatePageFooter()
                    return
                }
                guard !Task.isCancelled else { return }
                self.nextPageToken = page.nextPageToken
                let known = Set(self.items.map(\.id))
                fresh = page.items.filter { !known.contains($0.id) }
                guard fresh.isEmpty, let next = page.nextPageToken else { break }
                token = next
            }
            // ⚠️ The slot frees BEFORE the rows render: rendering them can show
            // the end of the list again, which asks for the next page from the
            // rows' `willDisplay` — an ask that must find the slot free, or the
            // list stops short under its spinner.
            self.pageLoad = nil
            self.items += fresh
            self.updatePageFooter()
            self.emitContent()
        }
    }

    private func updatePageFooter() {
        pageFooter = nextPageToken == nil ? .none : (pageFailed ? .retry : .loading)
    }

    /// Tells the server the new rows were seen — once per visit, only while
    /// the viewer is looking, and only once there is something loaded to have
    /// looked AT (a reveal over a skeleton waits for the load).
    private func markSeenIfLooking() {
        guard isRevealed, load == nil, !hasMarkedThisVisit,
              items.contains(where: { !$0.isRead }) else { return }
        hasMarkedThisVisit = true
        let repository = repository
        Task { try? await repository.markAllRead() }
    }

    private func emitContent() {
        guard !items.isEmpty else { return }
        phase = .content(NotificationSectionBuilder.sections(
            from: items, newExpanded: isNewExpanded, now: now()
        ))
    }
}
