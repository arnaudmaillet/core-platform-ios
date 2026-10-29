import CoreModels
import CoreNavigation
import Foundation
import NotificationsInterface
import Testing
import UIKit
@testable import DesignSystem
@testable import Notifications

/// A drawer whose rows can grow (a notification arriving), and which records
/// the clears it is asked for.
private actor ClearingProvider: NotificationsProviding {
    private(set) var items: [NotificationItem]
    private(set) var clears: [NotificationsClearBound] = []
    private let clearError: Error?

    init(_ items: [NotificationItem], clearError: Error? = nil) {
        self.items = items
        self.clearError = clearError
    }

    func arrive(_ item: NotificationItem) { items.insert(item, at: 0) }

    func loadNotifications(limit: Int32, after pageToken: String?) async throws -> NotificationsPage {
        NotificationsPage(items: items, nextPageToken: nil)
    }
    func markAllRead() async throws {}
    func unreadCount() async throws -> Int { items.filter { !$0.isRead }.count }
    func clearAll(through bound: NotificationsClearBound) async throws {
        clears.append(bound)
        if let clearError { throw clearError }
        items.removeAll(where: bound.reaches)
    }
}

private struct ClearRefused: Error {}

private let clearNow = Date(timeIntervalSince1970: 100_000)

private func row(_ id: String, minutesAgo: Double, read: Bool = false) -> NotificationItem {
    NotificationItem(
        id: id, action: .reaction, senderID: ProfileID("prof-\(id)"), senderName: "Ava",
        otherSenderCount: 0, postSubjectID: PostID("post-\(id)"), isRead: read,
        createdAt: clearNow.addingTimeInterval(-minutesAgo * 60)
    )
}

/// Clear all (#1574): the trash hides the list at once, Undo brings it back,
/// and only the toast running out deletes — once, on the server, up to the
/// newest row shown.
@MainActor
struct NotificationsClearAllTests {
    private let rows = [row("n1", minutesAgo: 1), row("n2", minutesAgo: 3, read: true), row("n3", minutesAgo: 9)]

    private func loaded(_ provider: ClearingProvider) async -> (NotificationsViewModel, () -> NotificationsViewModel.Phase?) {
        let viewModel = NotificationsViewModel(repository: provider, now: { clearNow })
        viewModel.notificationCenter = NotificationCenter()
        var last: NotificationsViewModel.Phase?
        viewModel.onPhaseChange = { last = $0 }
        viewModel.viewDidLoad()
        await settle { last?.content != nil }
        return (viewModel, { last })
    }

    private func settle(looks: Int = 2_000, until condition: () -> Bool) async {
        for _ in 0..<looks where !condition() {
            await Task.yield()
        }
    }

    private func shownIDs(_ phase: NotificationsViewModel.Phase?) -> [String] {
        (phase?.content ?? []).flatMap(\.rows).map(\.id)
    }

    @Test func theTrashHidesTheListWithoutAServerCall() async throws {
        let provider = ClearingProvider(rows)
        let (viewModel, phase) = await loaded(provider)
        try #require(shownIDs(phase()) == ["n1", "n2", "n3"], "guard: loaded")
        #expect(viewModel.canClearAll)

        #expect(viewModel.clearAll())

        #expect(phase() == .empty)
        #expect(!viewModel.canClearAll, "a pending clear cannot be asked again")
        #expect(await provider.clears.isEmpty, "nothing deleted while the toast runs")
    }

    @Test func undoRestoresEveryRowAsItWasWithoutACall() async throws {
        let provider = ClearingProvider(rows)
        let (viewModel, phase) = await loaded(provider)
        let before = try #require(phase()?.content)

        viewModel.clearAll()
        viewModel.undoClearAll()

        #expect(phase()?.content == before, "the same rows, dots included")
        #expect(viewModel.canClearAll)
        viewModel.commitClearAll()
        #expect(viewModel.clearCall == nil, "an undone clear commits nothing")
        #expect(await provider.clears.isEmpty)
    }

    @Test func theToastRunningOutClearsOnceUpToTheNewestRowShown() async throws {
        let provider = ClearingProvider(rows)
        let (viewModel, phase) = await loaded(provider)

        viewModel.clearAll()
        viewModel.commitClearAll()
        await viewModel.clearCall?.value

        let clears = await provider.clears
        #expect(clears == [NotificationsClearBound(newestID: "n1", newestCreatedAt: rows[0].createdAt)])
        #expect(phase() == .empty)
        #expect(!viewModel.canClearAll, "nothing left to clear")
        viewModel.commitClearAll()
        #expect(await provider.clears.count == 1, "a second commit asks nothing")
    }

    /// A notification that arrives while the toast runs is neither hidden nor
    /// deleted: it shows as soon as the list hears of it, and stays after the
    /// commit.
    @Test func aNotificationArrivingDuringTheToastStays() async throws {
        let provider = ClearingProvider(rows)
        let (viewModel, phase) = await loaded(provider)

        viewModel.clearAll()
        let fresh = NotificationItem(
            id: "fresh", action: .comment, senderID: ProfileID("prof-new"), senderName: "Ben",
            otherSenderCount: 0, postSubjectID: PostID("post-new"), isRead: false,
            createdAt: clearNow.addingTimeInterval(30)
        )
        await provider.arrive(fresh)
        viewModel.refresh()
        await settle { shownIDs(phase()) == ["fresh"] }
        #expect(shownIDs(phase()) == ["fresh"], "the new row shows during the toast")

        viewModel.commitClearAll()
        await viewModel.clearCall?.value

        #expect(shownIDs(phase()) == ["fresh"], "and stays after the clear")
        let remaining = await provider.items.map(\.id)
        #expect(remaining == ["fresh"], "the server kept it too")
    }

    /// Refused, the rows come back from the server and the list says so.
    @Test func aRefusedClearBringsTheRowsBack() async throws {
        let provider = ClearingProvider(rows, clearError: ClearRefused())
        let (viewModel, phase) = await loaded(provider)
        var failures = 0
        viewModel.onClearFailed = { failures += 1 }

        viewModel.clearAll()
        viewModel.commitClearAll()
        await viewModel.clearCall?.value
        await settle { shownIDs(phase()).count == 3 }

        #expect(failures == 1)
        #expect(shownIDs(phase()) == ["n1", "n2", "n3"])
    }

    @Test func nothingToClearOnAnEmptyList() async {
        let provider = ClearingProvider([])
        let viewModel = NotificationsViewModel(repository: provider)
        var last: NotificationsViewModel.Phase?
        viewModel.onPhaseChange = { last = $0 }
        viewModel.viewDidLoad()
        await settle { last == .empty }

        #expect(!viewModel.canClearAll)
        #expect(!viewModel.clearAll())
    }
}

/// The trash in the bar (#1574): disabled on an empty list, and its Undo
/// toast takes the trailing items' place and gives them back.
@MainActor
@Suite(.serialized)
struct NotificationsClearItemTests {
    private func hosting(
        _ provider: ClearingProvider, _ body: (NotificationsViewController, NotificationsViewModel) async throws -> Void
    ) async rethrows {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let viewModel = NotificationsViewModel(repository: provider, now: { clearNow })
        viewModel.notificationCenter = NotificationCenter()
        let controller = NotificationsViewController(viewModel: viewModel, imagePipeline: nil, offersClearAll: true)
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.isHidden = false
        window.layoutIfNeeded()
        let (clock, _) = ToastClock.manual()
        let previousClock = ToastClock.current
        ToastClock.current = clock
        defer {
            ToastClock.current = previousClock
            window.rootViewController = nil
            window.isHidden = true
        }
        // The toasts' haptics are recorded, never played.
        try await Haptics.$recorder.withValue(HapticRecorder()) { try await body(controller, viewModel) }
    }

    private func settle(looks: Int = 2_000, until condition: () -> Bool) async {
        for _ in 0..<looks where !condition() {
            await Task.yield()
        }
    }

    @Test func theTrashIsDisabledOnAnEmptyList() async throws {
        try await hosting(ClearingProvider([])) { controller, viewModel in
            let trash = try #require(controller.debugClearItem)
            #expect(controller.navigationItem.rightBarButtonItems?.contains { $0 === trash } == true)
            await settle { !(viewModel.canClearAll) && controller.navigationItem.rightBarButtonItems != nil }
            #expect(!trash.isEnabled)
        }
    }

    /// Undo on the toast: the rows are back on screen, the trash enabled,
    /// and nothing is asked of the server.
    @Test func undoOnTheToastShowsTheRowsAgain() async throws {
        let provider = ClearingProvider([row("n1", minutesAgo: 1), row("n2", minutesAgo: 4)])
        try await hosting(provider) { controller, viewModel in
            let trash = try #require(controller.debugClearItem)
            await settle { trash.isEnabled }
            let list = try #require(controller.view.subviews.lazy.compactMap { $0 as? UICollectionView }.first)
            // The rows land on the kit's timing (#1770): a first page that
            // answered after the skeleton's delay waits out its minimum.
            for _ in 0..<200 where list.isHidden { try? await Task.sleep(for: .milliseconds(10)) }
            try #require(!list.isHidden, "guard: rows shown")

            controller.debugTapClear()
            #expect(list.isHidden, "the list empties at once")
            let toast = try #require(controller.navigationItem.rightBarButtonItems?.first?.customView as? ToastView)
            let undo = try #require(toast.undoButton)
            undo.sendActions(for: .primaryActionTriggered)

            #expect(!list.isHidden, "the rows are back")
            #expect(list.numberOfItems(inSection: 0) == 2)
            let back = controller.navigationItem.rightBarButtonItems ?? []
            #expect(back.count == 1 && back.first === trash)
            #expect(trash.isEnabled)
            #expect(await provider.clears.isEmpty)
        }
    }

    @Test func itsToastTakesTheTrailingItemsAndGivesThemBack() async throws {
        let provider = ClearingProvider([row("n1", minutesAgo: 1), row("n2", minutesAgo: 4)])
        try await hosting(provider) { controller, viewModel in
            let trash = try #require(controller.debugClearItem)
            await settle { trash.isEnabled }
            try #require(trash.isEnabled, "guard: rows to clear")

            controller.debugTapClear()

            let bar = controller.navigationItem.rightBarButtonItems ?? []
            let toast = try #require(bar.first?.customView as? ToastView)
            #expect(!bar.contains { $0 === trash }, "the toast holds the trailing slot")
            #expect(toast.message == "Notifications cleared")
            #expect(!trash.isEnabled, "the trash comes back disabled: nothing left")

            toast.dismiss(animated: false)
            let back = controller.navigationItem.rightBarButtonItems ?? []
            #expect(back.count == 1 && back.first === trash)
            await viewModel.clearCall?.value
            #expect(await provider.clears.count == 1, "the toast leaving on its own commits")
        }
    }
}
