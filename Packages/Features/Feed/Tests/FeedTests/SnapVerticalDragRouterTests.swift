import Testing
import UIKit
@testable import Feed

/// **Who owns a downward drag (#2056, #2057, the owner 2026-11-02).** The
/// first post keeps the downward dismiss; any later post pages back. The
/// pager and the dismissal both ask the router, so exactly one claims a drag.
struct SnapVerticalDragRouterTests {
    private typealias Router = SnapVerticalDragRouter

    private func owner(
        index: Int, atRest: Bool = true, sideList: Bool = false, pager: Bool = true, drive: Bool = false
    ) -> Router.DownwardOwner {
        Router.downwardOwner(.init(
            settledIndex: index, isAtRestOnPage: atRest, sideListOpen: sideList,
            pagerPagesHere: pager, drivePagesHere: drive
        ))
    }

    /// The first post, at rest: the dismissal's — as today.
    @Test func theFirstPostKeepsTheDismiss() {
        #expect(owner(index: 0) == .dismissal)
    }

    /// Any later post, at rest: the pager's — the previous post comes in.
    @Test(arguments: [1, 2, 7])
    func aLaterPostPagesBack(_ index: Int) {
        #expect(owner(index: index) == .pager)
    }

    /// Between two pages, a drag continues the scroll, whatever the index.
    @Test func midScrollIsThePagers() {
        #expect(owner(index: 0, atRest: false) == .pager)
        #expect(owner(index: 3, atRest: false) == .pager)
    }

    /// The side list open (#1425): the pager pages back from its first post
    /// too, the dismissal standing aside.
    @Test func theSideListOpenPagesBackEverywhere() {
        #expect(owner(index: 0, sideList: true) == .pager)
    }

    /// A page the pager does not page (a text page, comments holding the
    /// scroll) pages back through the drive on a later post (#2058) — the
    /// composer, the header band, the pull past the stream's top (#2298) — and keeps its close
    /// on the first.
    @Test func aPageTheDrivePagesGoesBackOnALaterPostOnly() {
        #expect(owner(index: 4, pager: false, drive: true) == .pager)
        #expect(owner(index: 0, pager: false, drive: true) == .dismissal)
    }

    /// Neither the pager nor the drive: nothing pages it, the close keeps it.
    @Test func aPageNothingPagesKeepsItsClose() {
        #expect(owner(index: 4, pager: false) == .dismissal)
    }

    /// The axis test the pager asks first: only a predominantly downward
    /// movement reaches the router.
    @Test func onlyADownwardVerticalTouchReachesTheRouter() {
        #expect(SnapFeedCollectionView.declinesDownwardPagingTouch(velocity: CGPoint(x: 0, y: 300)))
        #expect(!SnapFeedCollectionView.declinesDownwardPagingTouch(velocity: CGPoint(x: 500, y: 200)))
        #expect(!SnapFeedCollectionView.declinesDownwardPagingTouch(velocity: CGPoint(x: 0, y: -300)))
    }
}
