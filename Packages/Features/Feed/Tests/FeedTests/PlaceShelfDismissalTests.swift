import CoreModels
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// The place page's Popular shelf keeps the drags it can spend (#1373): a
/// rightward drag on the shelf scrolled past its first card scrolls it back,
/// and the page's close takes the drag only at the shelf's start — or from
/// the leading edge, wherever the shelf is.
@MainActor
struct PlaceShelfDismissalTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private static func posts(_ count: Int) -> [GalleryPost] {
        (0..<count).map { index in
            GalleryPost(
                id: PostID("p\(index)"), kind: .photo, isRepost: false,
                thumbnailURL: URL(string: "https://example.test/p\(index).jpg"),
                caption: "post \(index)", publishedAtMS: Int64(index),
                authorID: ProfileID("bo"), authorName: "Bo", authorHandle: "bo",
                reactionCount: Int64(100 - index), commentCount: 1
            )
        }
    }

    /// A place page in a window, its Popular shelf landed and laid out.
    private func landedPage() async -> (PlaceProfileViewController, UIWindow) {
        let posts = Self.posts(14)
        let place = PlaceProfileViewController(
            postIDs: posts.map(\.id), placeName: "Paris", rank: nil,
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()), videoPlayback: nil,
            following: nil, wallet: nil, loadPosts: { posts }, openPost: { _, _, _ in }
        )
        // Pushed, as the map pushes it: a root screen has nothing to close to.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let stack = UINavigationController(rootViewController: UIViewController())
        window.rootViewController = stack
        window.isHidden = false
        stack.pushViewController(place, animated: false)
        place.beginLoading()
        for _ in 0..<1_000 where place.debugShelf.cards.isEmpty {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        window.layoutIfNeeded()
        return (place, window)
    }

    /// The middle of the shelf's row, in the page's view.
    private func shelfPoint(in place: PlaceProfileViewController) -> CGPoint {
        let row = place.debugShelf.mediaView
        return row.convert(CGPoint(x: row.bounds.midX, y: row.bounds.midY), to: place.view)
    }

    @Test func aShelfScrolledPastItsStartKeepsTheRightwardDrag() async throws {
        let (place, window) = await landedPage()
        defer { window.isHidden = true }
        let row = place.debugShelf.mediaView
        try #require(row.contentSize.width > row.bounds.width, "precondition: the shelf overflows")
        row.contentOffset.x = 300
        let point = shelfPoint(in: place)
        try #require(point.x > 28)
        #expect(!place.zoomHorizontalDismissalPermitted(at: point, in: place.view),
                "the shelf's scroll-back went to the page's close")
    }

    @Test func aShelfAtItsStartLetsThePageClose() async {
        let (place, window) = await landedPage()
        defer { window.isHidden = true }
        place.debugShelf.mediaView.contentOffset.x = -place.debugShelf.mediaView.adjustedContentInset.left
        #expect(place.zoomHorizontalDismissalPermitted(at: shelfPoint(in: place), in: place.view),
                "a shelf at its first card kept the close")
    }

    /// ⚠️ ONE DRAG, ONE OWNER (#1595): a grab freezes every sideways
    /// scroller the page holds — the shelf, the posts' carousels — and puts
    /// back exactly what it found; the page's own vertical list stays live.
    @Test func aGrabFreezesTheSidewaysScrollersAndPutsThemBack() async throws {
        let (place, window) = await landedPage()
        defer { window.isHidden = true }
        let row = place.debugShelf.mediaView
        try #require(row.contentSize.width > row.bounds.width, "precondition: the shelf overflows")
        let sideways = PlaceProfileViewController.horizontalScrollers(in: place.view)
        #expect(sideways.contains { $0 === row }, "the shelf is not frozen by a grab")
        let vertical = place.view.allSubviewsOfType(UIScrollView.self).filter { scroller in
            !sideways.contains { $0 === scroller } && scroller.isScrollEnabled
        }

        place.setContentScrollEnabled(false)
        place.setContentScrollEnabled(false) // a start reported twice
        #expect(sideways.allSatisfy { !$0.isScrollEnabled }, "a sideways scroller stayed live under the grab")
        #expect(vertical.allSatisfy { $0.isScrollEnabled }, "the page's own list froze")

        place.setContentScrollEnabled(true)
        #expect(sideways.allSatisfy { $0.isScrollEnabled }, "a scroller was left frozen")
    }

    /// A scroller that was off before the grab stays off after it.
    @Test func aGrabRestoresRatherThanEnables() async throws {
        let (place, window) = await landedPage()
        defer { window.isHidden = true }
        let row = place.debugShelf.mediaView
        try #require(row.contentSize.width > row.bounds.width, "precondition: the shelf overflows")
        row.isScrollEnabled = false
        place.setContentScrollEnabled(false)
        place.setContentScrollEnabled(true)
        #expect(!row.isScrollEnabled, "the grab enabled a scroller it had found off")
    }

    @Test func theLeadingEdgeClosesWhateverTheShelf() async {
        let (place, window) = await landedPage()
        defer { window.isHidden = true }
        place.debugShelf.mediaView.contentOffset.x = 300
        var point = shelfPoint(in: place)
        point.x = 10
        #expect(place.zoomHorizontalDismissalPermitted(at: point, in: place.view))
    }
}

private extension UIView {
    func allSubviewsOfType<T: UIView>(_ type: T.Type) -> [T] {
        subviews.flatMap { ($0 as? T).map { [$0] } ?? [] } + subviews.flatMap { $0.allSubviewsOfType(type) }
    }
}
