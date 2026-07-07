import CoreModels
import CoreNavigation
import Foundation
import Testing
@testable import Notifications

private actor StubProvider: NotificationsProviding {
    private let items: [NotificationItem]
    private let loadError: Error?
    private(set) var markAllReadCalls = 0

    init(_ items: [NotificationItem], loadError: Error? = nil) {
        self.items = items
        self.loadError = loadError
    }

    func loadNotifications(limit: Int32) async throws -> [NotificationItem] {
        if let loadError { throw loadError }
        return items
    }
    func markAllRead() async throws { markAllReadCalls += 1 }
}

@MainActor
private final class SpyRouter: Router {
    private(set) var routes: [AppRoute] = []
    func route(to route: AppRoute) { routes.append(route) }
}

private struct LoadError: Error {}

private func item(
    id: String,
    post: PostID? = PostID("post-1"),
    sender: String = "prof-9",
    read: Bool = false
) -> NotificationItem {
    NotificationItem(
        id: id, action: .reaction, senderID: ProfileID(sender), senderName: "Ava",
        otherSenderCount: 0, postSubjectID: post, isRead: read, createdAt: Date(timeIntervalSince1970: 0)
    )
}

@MainActor
struct NotificationsViewModelTests {
    private func settle() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
    }

    @Test func loadsIntoContent() async {
        let viewModel = NotificationsViewModel(repository: StubProvider([item(id: "n1"), item(id: "n2")]))
        var last: NotificationsViewModel.Phase?
        viewModel.onPhaseChange = { last = $0 }

        viewModel.viewDidLoad()
        await settle()

        guard case .content(let models) = last else {
            Issue.record("expected content, got \(String(describing: last))")
            return
        }
        #expect(models.map(\.id) == ["n1", "n2"])
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
        let viewModel = NotificationsViewModel(repository: StubProvider([item(id: "n1", post: nil, sender: "prof-42")]), router: router)
        viewModel.viewDidLoad()
        await settle()

        viewModel.didSelect("n1")
        #expect(router.routes == [.profile(ProfileID("prof-42"))])
    }

    @Test func markAllReadIsOptimisticAndCallsRepository() async {
        let provider = StubProvider([item(id: "n1", read: false), item(id: "n2", read: false)])
        let viewModel = NotificationsViewModel(repository: provider)
        var hasUnread: [Bool] = []
        viewModel.onHasUnreadChange = { hasUnread.append($0) }
        viewModel.viewDidLoad()
        await settle()

        viewModel.markAllRead()
        await settle()

        #expect(hasUnread.last == false)         // cleared optimistically
        #expect(await provider.markAllReadCalls == 1)
    }
}
