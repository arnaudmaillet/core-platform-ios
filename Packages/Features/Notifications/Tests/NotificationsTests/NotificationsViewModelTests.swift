import CoreModels
import CoreNavigation
import Foundation
import Testing
@testable import Notifications

private actor StubProvider: NotificationsProviding {
    private var items: [NotificationItem]
    private let loadError: Error?
    private(set) var markAllReadCalls = 0
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
    func unreadCount() async throws -> Int { items.filter { !$0.isRead }.count }
}

@MainActor
private final class SpyRouter: Router {
    private(set) var routes: [AppRoute] = []
    func route(to route: AppRoute) { routes.append(route) }
}

private struct LoadError: Error {}

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

@MainActor
struct NotificationsViewModelTests {
    private func settle() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
    }

    private func sections(_ phase: NotificationsViewModel.Phase?) -> [NotificationSection] {
        phase?.content ?? []
    }

    @Test func loadsIntoNewAndEarlier() async {
        let viewModel = NotificationsViewModel(repository: StubProvider([
            item(id: "n1", minutesAgo: 1), item(id: "n2", read: true, minutesAgo: 2)
        ]))
        var last: NotificationsViewModel.Phase?
        viewModel.onPhaseChange = { last = $0 }

        viewModel.viewDidLoad()
        await settle()

        let loaded = sections(last)
        #expect(loaded.map(\.kind) == [.new, .earlier])
        #expect(loaded[0].rows.map(\.id) == ["n1"])
        #expect(loaded[1].rows.map(\.id) == ["n2"])
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
        let items = (0..<10).map { item(id: "n\($0)", minutesAgo: Double($0)) }
        let viewModel = NotificationsViewModel(repository: StubProvider(items))
        var last: NotificationsViewModel.Phase?
        viewModel.onPhaseChange = { last = $0 }
        viewModel.viewDidLoad()
        await settle()

        #expect(sections(last).first?.rows.count == 6)
        #expect(sections(last).first?.hiddenCount == 4)

        viewModel.showMore()
        #expect(sections(last).first?.rows.count == 10)
        #expect(sections(last).first?.hiddenCount == 0)
    }

    /// Looking at the list tells the server — once — but the rows stay in
    /// "New" until the drawer closes, so nothing moves under the viewer.
    @Test func revealMarksSeenAndConcealMovesTheRowsToEarlier() async {
        let provider = StubProvider([item(id: "n1"), item(id: "n2", minutesAgo: 1)])
        let viewModel = NotificationsViewModel(repository: provider)
        var last: NotificationsViewModel.Phase?
        viewModel.onPhaseChange = { last = $0 }
        viewModel.viewDidLoad()
        await settle()

        viewModel.didReveal()
        await settle()
        #expect(await provider.markAllReadCalls == 1)
        #expect(sections(last).map(\.kind) == [.new], "still new while the drawer is open")

        viewModel.didReveal()
        await settle()
        #expect(await provider.markAllReadCalls == 1, "once per visit")

        viewModel.didConceal()
        #expect(sections(last).map(\.kind) == [.earlier])
    }

    /// A drawer opened over a skeleton marks nothing until there is something
    /// to have seen — and then marks it.
    @Test func aRevealBeforeTheLoadWaitsForIt() async {
        let provider = StubProvider([item(id: "n1")])
        let viewModel = NotificationsViewModel(repository: provider)
        viewModel.viewDidLoad()
        viewModel.didReveal()
        #expect(await provider.markAllReadCalls == 0)
        await settle()
        #expect(await provider.markAllReadCalls == 1)
    }

    /// A peek (will-appear without did-appear) never marks anything.
    @Test func aPeekMarksNothing() async {
        let provider = StubProvider([item(id: "n1")])
        let viewModel = NotificationsViewModel(repository: provider)
        viewModel.viewDidLoad()
        await settle()
        viewModel.willReveal()
        await settle()
        viewModel.didConceal()
        await settle()
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
        let items = (0..<10).map { item(id: "n\($0)", minutesAgo: Double($0)) }
        let viewModel = NotificationsViewModel(repository: StubProvider(items))
        var last: NotificationsViewModel.Phase?
        viewModel.onPhaseChange = { last = $0 }
        viewModel.viewDidLoad()
        await settle()
        viewModel.showMore()
        viewModel.didConceal()
        #expect(sections(last).first?.hiddenCount == 4)
    }
}
