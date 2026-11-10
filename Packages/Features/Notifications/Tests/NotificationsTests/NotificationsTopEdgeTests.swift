import CoreModels
import Testing
import DesignSystem
import UIKit
@testable import Notifications

private actor EmptyProvider: NotificationsProviding {
    func loadNotifications(limit: Int32, after pageToken: String?) async throws -> NotificationsPage {
        NotificationsPage(items: [], nextPageToken: nil)
    }
    func markAllRead() async throws {}
    func unreadCount() async throws -> Int { 0 }
}

/// The notifications drawer is the one list that KEEPS UIKit's top edge
/// effect (every other list hides it — `prefersClearTopEdge`). Pinned here
/// because the failure is silent: a list that hides it, or one the bar does
/// not track, simply shows its rows under the title with nothing between.
@MainActor
struct NotificationsTopEdgeTests {
    private func makeList() -> (NotificationsViewController, UICollectionView?) {
        let controller = NotificationsViewController(
            viewModel: NotificationsViewModel(repository: EmptyProvider()), imagePipeline: nil
        )
        controller.loadViewIfNeeded()
        let list = controller.view.subviews.lazy.compactMap { $0 as? UICollectionView }.first
        return (controller, list)
    }

    @Test func theListKeepsTheSoftTopEdgeEffect() throws {
        let (_, list) = makeList()
        let collection = try #require(list)
        #expect(!collection.topEdgeEffect.isHidden)
        #expect(collection.topEdgeEffect.style == .soft)
    }

    /// ⚠️ NO CLEARANCE UNDER THE LARGE TITLE (#2240): "Notifications"
    /// rests on a large title, so "New" already starts far below the soft
    /// fade, and the titled contract adds nothing (seen on the simulator:
    /// 40 pt of empty space when it did). The skeleton stays pinned to the top.
    @Test func theLargeTitleTakesNoClearance() throws {
        let (controller, list) = makeList()
        let collection = try #require(list)
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.view.layoutIfNeeded()
        #expect(collection.topFadeClearance == 0)
        let skeleton = try #require(controller.view.subviews.first { $0 is PersonListSkeletonView })
        #expect(abs(skeleton.frame.minY) < 0.5)
    }

    /// The bar draws the effect over the scroll view it tracks; the skeleton
    /// and the empty state are siblings, so the list is named, not searched.
    @Test func theListIsTheTopContentScrollView() throws {
        let (controller, list) = makeList()
        let collection = try #require(list)
        #expect(controller.contentScrollView(for: .top) === collection)
    }
}
