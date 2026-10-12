import AuthInterface
import CoreModels
import CoreNetworking
import Foundation
import Testing
@testable import Notifications

/// The drawer outlives every viewer, and its rows are the viewer's: a viewer
/// change (a profile switch, a sign-out and a sign-in) empties it and loads
/// the new viewer's (#892).
@MainActor
struct NotificationsViewerChangeTests {
    /// Answers for whoever is signed in now, the way the repository asks the
    /// shared viewer on every read.
    private actor SwitchableProvider: NotificationsProviding {
        private var viewer = "A"
        private var failing = false
        func become(_ viewer: String, failing: Bool = false) {
            self.viewer = viewer
            self.failing = failing
        }

        func loadNotifications(limit: Int32, after pageToken: String?) async throws -> NotificationsPage {
            if failing { throw NotificationsError.transport(message: "down") }
            let item = NotificationItem(
                id: "\(viewer)-1", action: .reaction, senderID: ProfileID("prof-9"), senderName: "Ava",
                otherSenderCount: 0, postSubjectID: PostID("post-\(viewer)"), isRead: false,
                createdAt: Date(timeIntervalSince1970: 100_000)
            )
            return NotificationsPage(items: [item], nextPageToken: nil)
        }
        func markAllRead() async throws {}
        func unreadCount() async throws -> Int { 1 }
    }

    private func rowIDs(_ phase: NotificationsViewModel.Phase?) -> [String] {
        (phase?.content ?? []).flatMap(\.rows).map(\.id)
    }

    private func settle(until condition: () -> Bool) async {
        var looks = 0
        while !condition(), looks < 300 {
            looks += 1
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The block observer goes with the model (#978): its holder is released
    /// with it, and unregisters from the center as it goes.
    @Test func theViewerObserverIsRemovedWithTheModel() async {
        let center = NotificationCenter()
        weak var model: NotificationsViewModel?
        weak var observation: AnyObject?
        do {
            let viewModel = NotificationsViewModel(repository: SwitchableProvider())
            viewModel.notificationCenter = center
            viewModel.viewDidLoad()
            model = viewModel
            observation = viewModel.viewerObservation
            #expect(observation != nil, "guard: the model observes viewer changes")
        }
        // The first load holds the model until it answers.
        for _ in 0..<6_000 where model != nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(model == nil, "the model was never released")
        #expect(observation == nil, "the viewer observer outlived its model")
        center.post(name: .viewerDidChange, object: nil)
    }

    @Test func aViewerChangeLoadsTheNewViewersRows() async {
        let provider = SwitchableProvider()
        let center = NotificationCenter()
        let viewModel = NotificationsViewModel(repository: provider)
        viewModel.notificationCenter = center
        var phases: [NotificationsViewModel.Phase] = []
        viewModel.onPhaseChange = { phases.append($0) }
        viewModel.viewDidLoad()
        await settle { rowIDs(phases.last) == ["A-1"] }
        #expect(rowIDs(phases.last) == ["A-1"])

        await provider.become("B")
        phases = []
        center.post(name: .viewerDidChange, object: nil)

        #expect(phases.first == .loading, "the previous viewer's rows stayed up while B's loaded")
        await settle { rowIDs(phases.last) == ["B-1"] }
        #expect(rowIDs(phases.last) == ["B-1"])
    }

    /// The reload failing must not leave the previous viewer's rows up: a
    /// failed refresh keeps content, so the content has to go first.
    @Test func aFailedReloadAfterAChangeShowsTheFailureNotTheOldRows() async {
        let provider = SwitchableProvider()
        let center = NotificationCenter()
        let viewModel = NotificationsViewModel(repository: provider)
        viewModel.notificationCenter = center
        var last: NotificationsViewModel.Phase?
        viewModel.onPhaseChange = { last = $0 }
        viewModel.viewDidLoad()
        await settle { rowIDs(last) == ["A-1"] }
        #expect(rowIDs(last) == ["A-1"])

        await provider.become("B", failing: true)
        center.post(name: .viewerDidChange, object: nil)
        await settle { if case .failed = last { true } else { false } }

        guard case .failed = last else {
            Issue.record("expected failed, got \(String(describing: last))")
            return
        }
    }
}
