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

    /// ⚠️ "New" rests below the soft blur's fade (#2240): the contract adds
    /// what the first title's own step lacks, and the skeleton — a sibling
    /// of the list — moves down by the same amount, so the rows land where
    /// its bones stood.
    @Test func theFirstSectionRestsBelowTheFade() throws {
        let (controller, list) = makeList()
        let collection = try #require(list)
        let expected = SoftTopEdge.clearance(below: Spacing.sm)
        #expect(NotificationsViewController.skeletonTopClearance == expected)
        // Empty, before the first page: a plain list's whole fade, in place
        // before the first frame; the first title's step gives some back
        // once it is laid out.
        #expect(collection.topFadeClearance >= expected)
        let skeleton = try #require(controller.view.subviews.first { $0 is PersonListSkeletonView })
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.view.layoutIfNeeded()
        #expect(abs(skeleton.frame.minY - expected) < 0.5)
    }

    /// The bar draws the effect over the scroll view it tracks; the skeleton
    /// and the empty state are siblings, so the list is named, not searched.
    @Test func theListIsTheTopContentScrollView() throws {
        let (controller, list) = makeList()
        let collection = try #require(list)
        #expect(controller.contentScrollView(for: .top) === collection)
    }
}
