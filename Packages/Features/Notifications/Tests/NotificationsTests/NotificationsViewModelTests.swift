import CoreModels
import CoreNavigation
import CoreNetworking
import Foundation
import Synchronization
import NotificationsInterface
import Testing
@testable import Notifications

private actor StubProvider: NotificationsProviding {
    private var items: [NotificationItem]
    private let loadError: Error?
    private(set) var markAllReadCalls = 0
    private(set) var markedReadIDs: [String] = []
    private(set) var loadCalls = 0

    init(_ items: [NotificationItem], loadError: Error? = nil) {
        self.items = items
        self.loadError = loadError
    }

    func loadNotifications(limit: Int32, after pageToken: String?) async throws -> NotificationsPage {
        loadCalls += 1
        if let loadError { throw loadError }
        return NotificationsPage(items: items, nextPageToken: nil)
    }
    func markAllRead() async throws {
        markAllReadCalls += 1
        items = items.map { $0.markedRead() }
    }
    func markRead(_ read: [NotificationItem]) async throws {
        let ids = Set(read.map(\.id))
        markedReadIDs += read.map(\.id)
        items = items.map { ids.contains($0.id) ? $0.markedRead() : $0 }
    }
    func unreadCount() async throws -> Int { items.filter { !$0.isRead }.count }
}

@MainActor
private final class SpyRouter: Router {
    private(set) var routes: [AppRoute] = []
    func route(to route: AppRoute) { routes.append(route) }
}

private struct LoadError: Error {}

private final class PostCount: Sendable {
    let value = Mutex(0)
    var count: Int { value.withLock { $0 } }
}

/// Rows about DIFFERENT posts, so nothing folds unless a test asks for it.
private func item(
    id: String,
    post: PostID? = nil,
    sender: String = "prof-9",
    read: Bool = false,
    minutesAgo: Double = 0
) -> NotificationItem {
    NotificationItem(
        id: id, action: .reaction, senderID: ProfileID(sender), senderName: "Ava",
        otherSenderCount: 0, postSubjectID: post ?? PostID("post-\(id)"), isRead: read,
        createdAt: Date(timeIntervalSince1970: 100_000 - minutesAgo * 60)
    )
}

/// The clock and calendar every test reads: `item`'s dates are minutes
/// before 03:46 UTC on 2 January 1970.
private let testNow = Date(timeIntervalSince1970: 100_000)
private let testCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

/// A view model on the test clock and calendar.
@MainActor
private func makeViewModel(_ provider: StubProvider) -> NotificationsViewModel {
    NotificationsViewModel(repository: provider, now: { testNow }, calendar: { testCalendar })
}

@MainActor
struct NotificationsViewModelTests {
    private func settle() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
    }

    private func sections(_ phase: NotificationsViewModel.Phase?) -> [NotificationSection] {
        phase?.content ?? []
    }

    @Test func loadsIntoSectionsByDay() async {
        let viewModel = makeViewModel(StubProvider([
            item(id: "n1", minutesAgo: 1), item(id: "n2", read: true, minutesAgo: 2),
            item(id: "y1", minutesAgo: 5 * 60),
        ]))
        var last: NotificationsViewModel.Phase?
        viewModel.onPhaseChange = { last = $0 }

        viewModel.viewDidLoad()
        await settle()

        let loaded = sections(last)
        #expect(loaded.map(\.kind) == [.new, .yesterday])
        #expect(loaded[0].rows.map(\.id) == ["n1", "n2"], "read or not, today's rows are New")
        #expect(loaded[1].rows.map(\.id) == ["y1"])
    }

    @Test func emptyWhenNoNotifications() async {
        let viewModel = NotificationsViewModel(repository: StubProvider([]))
        var last: NotificationsViewModel.Phase?
        viewModel.onPhaseChange = { last = $0 }

        viewModel.viewDidLoad()
        await settle()

        #expect(last == .empty)
    }

    @Test func failsWhenLoadThrows() async {
        let viewModel = NotificationsViewModel(repository: StubProvider([], loadError: LoadError()))
        var last: NotificationsViewModel.Phase?
        viewModel.onPhaseChange = { last = $0 }

        viewModel.viewDidLoad()
        await settle()

        guard case .failed = last else {
            Issue.record("expected failed, got \(String(describing: last))")
            return
        }
    }

    /// Notifications that failed offline say so; a server fault keeps
    /// "Couldn't load your notifications." (#794).
    @Test(arguments: [
        (NetworkFailure.offline, FailureCopy.offline),
        (NetworkFailure.server(code: "unavailable"), "Couldn't load your notifications."),
    ])
    func aFailedLoadIsWordedByWhyItFailed(failure: NetworkFailure, expected: String) async {
        let error = NotificationsError.transport(message: "x", failure: failure)
        let viewModel = NotificationsViewModel(repository: StubProvider([], loadError: error))
        var last: NotificationsViewModel.Phase?
        viewModel.onPhaseChange = { last = $0 }

        viewModel.viewDidLoad()
        await settle()

        guard case .failed(let message) = last else {
            Issue.record("expected failed, got \(String(describing: last))")
            return
        }
        #expect(message == expected)
    }

    @Test func tapOnPostNotificationRoutesToPost() async {
        let router = SpyRouter()
        let viewModel = NotificationsViewModel(repository: StubProvider([item(id: "n1", post: PostID("post-7"))]), router: router)
        viewModel.viewDidLoad()
        await settle()

        viewModel.didSelect("n1")
        #expect(router.routes == [.post(PostID("post-7"))])
    }

    @Test func tapOnNonPostNotificationRoutesToProfile() async {
        let router = SpyRouter()
        let comment = NotificationItem(
            id: "n1", action: .reaction, senderID: ProfileID("prof-42"), senderName: "Ava",
            otherSenderCount: 0, postSubjectID: nil, isRead: false, createdAt: Date()
        )
        let viewModel = NotificationsViewModel(repository: StubProvider([comment]), router: router)
        viewModel.viewDidLoad()
        await settle()

        viewModel.didSelect("n1")
        #expect(router.routes == [.profile(ProfileID("prof-42"), stub: nil)])
    }

    @Test func showMoreRevealsTheRestOfTheNewRows() async {
        let items = (0..<10).map { item(id: "n\($0)", minutesAgo: Double($0)) } + [item(id: "y", minutesAgo: 5 * 60)]
        let viewModel = makeViewModel(StubProvider(items))
        var last: NotificationsViewModel.Phase?
        viewModel.onPhaseChange = { last = $0 }
        viewModel.viewDidLoad()
        await settle()

        #expect(sections(last).first?.rows.count == 6)
        #expect(sections(last).first?.hiddenCount == 4)

        viewModel.showMore(in: .new)
        #expect(sections(last).first?.rows.count == 10)
        #expect(sections(last).first?.hiddenCount == 0)
    }

    /// Rows seen are read on the server — once each — and the rows stay in
    /// "New", on every visit (#1571: closing and reopening emptied it).
    @Test func newSurvivesACloseAndAReopen() async {
        let provider = StubProvider([item(id: "n1"), item(id: "n2", minutesAgo: 1)])
        let viewModel = makeViewModel(provider)
        var last: NotificationsViewModel.Phase?
        viewModel.onPhaseChange = { last = $0 }
        viewModel.viewDidLoad()
        await settle()

        viewModel.didReveal()
        viewModel.didSee(rowIDs: ["n1", "n2"])
        await settle()
        #expect(await provider.markedReadIDs == ["n1", "n2"])
        #expect(sections(last).map(\.kind) == [.new])

        viewModel.didSee(rowIDs: ["n1", "n2"])
        await settle()
        #expect(await provider.markedReadIDs == ["n1", "n2"], "once per row")

        viewModel.didConceal()
        #expect(sections(last).map(\.kind) == [.new], "New emptied on close")
        viewModel.willReveal()
        await settle()
        viewModel.didReveal()
        await settle()
        #expect(sections(last).map(\.kind) == [.new], "New emptied on reopen")
        #expect(sections(last).first?.rows.map(\.id) == ["n1", "n2"])
    }

    /// ⚠️ #1572: opening the list reads NOTHING — only the rows seen lose
    /// their dot, and not before the visit ends.
    @Test func onlyTheRowsSeenAreRead() async {
        let provider = StubProvider([item(id: "n1"), item(id: "n2", minutesAgo: 1), item(id: "n3", minutesAgo: 2)])
        let viewModel = makeViewModel(provider)
        var last: NotificationsViewModel.Phase?
        viewModel.onPhaseChange = { last = $0 }
        viewModel.viewDidLoad()
        await settle()

        viewModel.didReveal()
        await settle()
        #expect(await provider.markAllReadCalls == 0, "opening read everything")
        #expect(await provider.markedReadIDs.isEmpty)

        viewModel.didSee(rowIDs: ["n1"])
        await settle()
        #expect(await provider.markedReadIDs == ["n1"])
        #expect(sections(last).first?.rows.allSatisfy { !$0.isRead } == true, "a dot went mid-visit")

        viewModel.didConceal()
        let read = Dictionary(uniqueKeysWithValues: (sections(last).first?.rows ?? []).map { ($0.id, $0.isRead) })
        #expect(read == ["n1": true, "n2": false, "n3": false])

        // The next visit reloads: the unseen rows still carry their dot.
        viewModel.willReveal()
        await settle()
        let reloaded = (sections(last).first?.rows ?? []).filter { !$0.isRead }.map(\.id)
        #expect(reloaded == ["n2", "n3"])
    }

    /// The badge follows once the server has the rows (#1572).
    @Test func readingRowsTellsTheBadge() async {
        let provider = StubProvider([item(id: "n1")])
        let viewModel = makeViewModel(provider)
        let center = NotificationCenter()
        viewModel.notificationCenter = center
        let posts = PostCount()
        let token = center.addObserver(forName: .notificationsReadDidChange, object: nil, queue: nil) { _ in
            posts.value.withLock { $0 += 1 }
        }
        defer { center.removeObserver(token) }
        viewModel.viewDidLoad()
        await settle()
        viewModel.didReveal()
        await settle()
        #expect(posts.count == 0, "opening told the badge")
        viewModel.didSee(rowIDs: ["n1"])
        await settle()
        #expect(posts.count == 1)
    }

    /// Seeing a folded row reads every notification folded into it.
    @Test func seeingAFoldedRowReadsItsMembers() async {
        let post = PostID("shared")
        let provider = StubProvider([
            item(id: "a", post: post, sender: "p1"), item(id: "b", post: post, sender: "p2", minutesAgo: 1),
        ])
        let viewModel = makeViewModel(provider)
        var last: NotificationsViewModel.Phase?
        viewModel.onPhaseChange = { last = $0 }
        viewModel.viewDidLoad()
        await settle()
        #expect(sections(last).first?.rows.map(\.id) == ["a"])

        viewModel.didReveal()
        viewModel.didSee(rowIDs: ["a"])
        await settle()
        #expect(await provider.markedReadIDs.sorted() == ["a", "b"])
    }

    /// Rows on screen during a peek (will-appear without did-appear) are not
    /// seen.
    @Test func aPeekMarksNothing() async {
        let provider = StubProvider([item(id: "n1")])
        let viewModel = NotificationsViewModel(repository: provider)
        viewModel.viewDidLoad()
        await settle()
        viewModel.willReveal()
        viewModel.didSee(rowIDs: ["n1"])
        await settle()
        viewModel.didConceal()
        await settle()
        #expect(await provider.markedReadIDs.isEmpty)
        #expect(await provider.markAllReadCalls == 0)
    }

    /// Every visit after the first reloads, so the drawer is never stale.
    @Test func eachLaterVisitReloads() async {
        let provider = StubProvider([item(id: "n1")])
        let viewModel = NotificationsViewModel(repository: provider)
        viewModel.viewDidLoad()
        viewModel.willReveal() // the first visit rides viewDidLoad's load
        await settle()
        #expect(await provider.loadCalls == 1)
        viewModel.didConceal()
        viewModel.willReveal()
        await settle()
        #expect(await provider.loadCalls == 2)
    }

    @Test func concealFoldsShowMoreBack() async {
        let items = (0..<10).map { item(id: "n\($0)", minutesAgo: Double($0)) } + [item(id: "y", minutesAgo: 5 * 60)]
        let viewModel = makeViewModel(StubProvider(items))
        var last: NotificationsViewModel.Phase?
        viewModel.onPhaseChange = { last = $0 }
        viewModel.viewDidLoad()
        await settle()
        viewModel.showMore(in: .new)
        viewModel.didConceal()
        #expect(sections(last).first?.hiddenCount == 4)
    }
}
