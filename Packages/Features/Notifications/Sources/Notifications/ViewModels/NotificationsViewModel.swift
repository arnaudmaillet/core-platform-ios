import AuthInterface
import CoreModels
import CoreNavigation
import CoreNetworking
import DesignSystem
import Foundation
import LocalStore
import NotificationsInterface

/// The notifications list: loads, splits into sections by day, holds the
/// "Show more" state, reads the rows the viewer sees, and routes a tap.
///
/// ## When a notification counts as read (#1572)
///
/// When the viewer has SEEN it: its row at least half on screen while the
/// drawer is settled open (`didReveal` … `didConceal`, rows reported by
/// `didSee`). The server is told at once, per id (`MarkRead`), so the bell's
/// badge falls while the drawer is still open (`.notificationsReadDidChange`).
/// The pink dot, though, stays for the rest of that visit — nothing changes
/// under the viewer's eye — and is gone on the next. A row never scrolled to,
/// or folded behind "Show more", keeps its dot; opening the drawer reads
/// nothing by itself, and a peek that never settles open sees nothing.
///
/// Rows never leave the list for being read: sections are by day.
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
    /// The viewer's calendar, asked at every build: a time-zone change
    /// re-sections on the next one (#1571).
    private let calendar: @Sendable () -> Calendar

    private var items: [NotificationItem] = [] {
        // New rows can fold into a row already looked at.
        didSet { lookedAtRowIDs = [] }
    }
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
    /// The sections whose "Show more" the viewer pressed this visit.
    private var expandedSections: Set<NotificationSection.Kind> = []
    /// The drawer is open and settled.
    private var isRevealed = false
    /// The rows SEEN this visit (#1572), told to the server once each; their
    /// dots stay for the visit and go on the next.
    private var seenThisVisit: Set<String> = []
    /// The rows `didSee` already resolved since the rows last changed: it
    /// runs at every scroll frame, and a row looked at again costs nothing.
    private var lookedAtRowIDs: Set<String> = []
    /// Where viewer changes are heard — the default center; a test hands its
    /// own, since posting on the shared one reaches every suite at once.
    var notificationCenter: NotificationCenter = .default
    /// Removes its block observer when the model goes (#978): a `deinit` of
    /// a main-actor model cannot reach the token itself.
    private var viewerObserver: ViewerObserver?
    /// The drawer's last 100 rows on the device (#897): the list opens on
    /// them, offline included, and every page the network answers is written
    /// back. Nil keeps them in memory.
    var deviceCache: NotificationsLocalCache?
    /// The rows shown are the device's and no load has answered since.
    private var showsDeviceRows = false

    public init(
        repository: any NotificationsProviding,
        router: (any Router)? = nil,
        pageSize: Int32 = 20,
        now: @escaping @Sendable () -> Date = { Date() },
        calendar: @escaping @Sendable () -> Calendar = { Calendar.current }
    ) {
        self.repository = repository
        self.router = router
        self.pageSize = pageSize
        self.now = now
        self.calendar = calendar
    }

    // MARK: - Inputs

    public func viewDidLoad() {
        armRecovery()
        observeViewer()
        restoreFromDevice()
        reload()
    }

    /// The rows the device stored for this viewer (#897), shown at once with
    /// the cursor past them, and revalidated by the load that follows. Only
    /// on an empty list.
    private func restoreFromDevice() {
        guard items.isEmpty, let stored = deviceCache?.stored(), !stored.items.isEmpty else { return }
        items = stored.items
        nextPageToken = stored.nextCursor
        showsDeviceRows = true
        updatePageFooter()
        emitContent()
    }

    /// ⚠️ THE LIST IS THE VIEWER'S (#892). The drawer lives as long as the
    /// shell, so after a profile switch — or a sign-out and a sign-in as
    /// someone else — it would open on the previous viewer's rows, and keep
    /// them if the reload failed. A viewer change empties it and loads the new
    /// viewer's first page.
    private func observeViewer() {
        guard viewerObserver == nil else { return }
        let center = notificationCenter
        let token = center.addObserver(
            forName: .viewerDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.viewerDidChange() }
        }
        viewerObserver = ViewerObserver(center: center, token: token)
    }

    /// The viewer observer's holder, for tests: it goes with the model, and
    /// unregisters as it goes.
    var viewerObservation: AnyObject? { viewerObserver }

    private func viewerDidChange() {
        load?.cancel()
        load = nil
        pageLoad?.cancel()
        pageLoad = nil
        items = []
        nextPageToken = nil
        pageFailed = false
        expandedSections = []
        seenThisVisit = []
        showsDeviceRows = false
        updatePageFooter()
        phase = .loading
        // Not from the device: the wipe it gets on this same change may not
        // have run yet. The network answers for the new viewer.
        reload()
    }

    /// The list is about to show. Every visit after the first reloads, so a
    /// drawer opened an hour later is not an hour stale; the first visit's
    /// load is already running from `viewDidLoad`.
    public func willReveal() {
        guard hasLoaded, load == nil else { return }
        reload()
    }

    /// The list has settled on screen: the viewer is looking at it. Nothing
    /// is marked for being loaded — only for being seen (`didSee`).
    public func didReveal() {
        isRevealed = true
    }

    /// ⚠️ READ PER ROW, ONCE SEEN (#1572, the owner 2026-10-22): rows the
    /// viewer had on screen — at least half visible, the drawer fully open —
    /// are told to the server (`MarkRead`, per id, the rows folded into them
    /// included). A row never scrolled to keeps its dot. The dots of the rows
    /// seen stay for the rest of the visit, so the viewer can still spot what
    /// was new, and go on the next.
    public func didSee(rowIDs: [String]) {
        guard isRevealed else { return }
        let newRows = rowIDs.filter { lookedAtRowIDs.insert($0).inserted }
        guard !newRows.isEmpty else { return }
        let viewerCalendar = calendar()
        let instant = now()
        let section = { (item: NotificationItem) in
            NotificationSection.Kind.of(item.createdAt, now: instant, calendar: viewerCalendar)
        }
        var fresh: [NotificationItem] = []
        for id in newRows {
            for member in NotificationGrouping.members(ofRow: id, in: items, section: section)
            where !member.isRead && seenThisVisit.insert(member.id).inserted {
                fresh.append(member)
            }
        }
        guard !fresh.isEmpty else { return }
        deviceCache?.markRead(fresh, as: deviceCache?.viewer)
        let repository = repository
        let center = notificationCenter
        Task {
            guard (try? await repository.markRead(fresh)) != nil else { return }
            center.post(name: .notificationsReadDidChange, object: nil)
        }
    }

    /// The list has gone. The rows seen this visit are read from now on.
    public func didConceal() {
        isRevealed = false
        lookedAtRowIDs = []
        let wasExpanded = !expandedSections.isEmpty
        expandedSections = []
        if !seenThisVisit.isEmpty {
            let seen = seenThisVisit
            seenThisVisit = []
            items = items.map { seen.contains($0.id) ? $0.markedRead() : $0 }
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
        // Only what failed, or rows still the device's: a refresh replaces the
        // list with its first page, collapsing a viewer three pages deep.
        if case .failed = phase {
            refresh()
        } else if showsDeviceRows {
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

    /// "Show more": the rest of `kind`'s rows, in place.
    public func showMore(in kind: NotificationSection.Kind) {
        guard expandedSections.insert(kind).inserted else { return }
        emitContent()
    }

    /// Opens a post notification's post from the list itself (#1577): the
    /// vertical feed ABOVE the drawer, which stays open. Answers false when it
    /// cannot (no opener, the list off screen), and the `.post` route goes
    /// instead. Set by the list.
    var opensPost: ((_ rowID: String, _ postID: PostID) -> Bool)?

    /// Tap on a row: open its subject — a post when the notification is about
    /// one (above the drawer, `opensPost`), otherwise the sender's profile.
    /// Notifications never imports Feed or Profile; it only emits routes (and
    /// the shell, receiving one, closes the drawer to show where it went) or
    /// hands the post to the shell's opener.
    public func didSelect(_ id: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if item.action.isSupervision, let account = item.subjectAccountID {
            // Family and Teens, on that link when it still exists (#1106).
            router?.route(to: .supervision(otherAccountID: account))
        } else if let postID = item.postSubjectID {
            if opensPost?(id, postID) != true { router?.route(to: .post(postID)) }
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
        // Whose rows these are, asked before the fetch (#897).
        let writer = deviceCache?.viewer
        load = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await self.repository.loadNotifications(limit: self.pageSize, after: nil)
                let loaded = page.items
                self.deviceCache?.storeFirstPage(page, as: writer)
                self.showsDeviceRows = false
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
                    // "You're offline" when that is why: the one cause the
                    // viewer can fix themselves (#794).
                    self.phase = .failed(message: FailureCopy.message(
                        for: error, fallback: "Couldn't load your notifications."
                    ))
                }
            }
            self.load = nil
        }
    }

    /// The next page from `token`, appended. A page whose rows are all
    /// already loaded leaves nothing on screen to ask again, so the one after
    /// it is asked at once (at most `maxEmptyPagesInARow`).
    private func loadPages(after token: String) {
        let writer = deviceCache?.viewer
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
                // Stored where it follows the stored pages, up to the last 100.
                self.deviceCache?.storeNextPage(page, after: token, as: writer)
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

    private func emitContent() {
        guard !items.isEmpty else { return }
        phase = .content(NotificationSectionBuilder.sections(
            from: items, expanded: expandedSections, now: now(), calendar: calendar()
        ))
    }
}

/// A block observer, unregistered when this goes: with the view model that
/// holds it, whatever thread releases it.
final class ViewerObserver: @unchecked Sendable {
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    init(center: NotificationCenter, token: NSObjectProtocol) {
        self.center = center
        self.token = token
    }

    deinit { center.removeObserver(token) }
}
