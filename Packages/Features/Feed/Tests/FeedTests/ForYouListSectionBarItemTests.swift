import CoreModels
import DesignSystem
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// The pushed lists' pinned section in the bar (#1378): `[‹][New · 3]`,
/// `[‹][Recent]`, `[‹][Popular]`, nothing at the top, and no capsule pinned
/// under the bar — the Messages inbox's item (#1301).
///
/// Async only to let a main-queue turn pass (the section is re-read, and the
/// item placed, one turn later); no global state is swapped.
@MainActor
struct ForYouListSectionBarItemTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private func post(_ id: String, at publishedAtMS: Int64) -> GalleryPost {
        GalleryPost(
            id: PostID(id), kind: .text, isRepost: false, thumbnailURL: nil,
            caption: "caption \(id) — long enough to wrap onto a second line of the card", publishedAtMS: publishedAtMS,
            authorID: ProfileID("bo"), authorName: "Bo", authorHandle: "bo"
        )
    }

    private func hosting(
        _ kind: ForYouPostListViewController.Kind, newCount: Int,
        _ body: @MainActor (ForYouPostListViewController, ForYouGridPage) async throws -> Void
    ) async rethrows {
        let list = ForYouPostListViewController(
            kind: kind, imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            videoPlayback: nil, staking: nil,
            header: PushedScreenHeader(wallet: nil, makeWalletSheet: nil, router: nil), openPost: nil
        )
        let navigation = UINavigationController(rootViewController: list)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = navigation
        window.isHidden = false
        defer { window.isHidden = true }
        let posts = (0..<14).map { post("p\($0)", at: Int64(100 - $0)) }
        list.render(.content(posts), newPosts: Set(posts.prefix(newCount).map(\.id)))
        window.layoutIfNeeded()
        list.view.layoutIfNeeded()
        try await body(list, list.debugPage)
    }

    /// Scrolls so `section`'s header is `beyond` points past the pin line,
    /// then lets the page re-read and the bar place its item.
    private func scroll(_ page: ForYouGridPage, toSection section: Int, beyond: CGFloat = 40) async throws {
        let collection = page.collectionView
        collection.layoutIfNeeded()
        let row = try #require(collection.layoutAttributesForItem(at: IndexPath(item: 0, section: section)))
        collection.contentOffset.y = row.frame.minY - collection.adjustedContentInset.top + beyond
        collection.layoutIfNeeded()
        page.updatePinnedSection()
        try await Task.sleep(for: .milliseconds(30))
    }

    @Test func theNewRunThenRecentAreNamedInTheBar() async throws {
        try await hosting(.following, newCount: 3) { list, page in
            try await Task.sleep(for: .milliseconds(30))
            #expect(page.pinnedSection == nil, "at the top the header is a title in the flow")
            #expect(list.debugSectionItem == nil)

            try await scroll(page, toSection: 0)
            #expect(page.pinnedSection?.title == "New" && page.pinnedSection?.count == 3)
            #expect(list.debugSectionItem?.title == "New · 3")

            try await scroll(page, toSection: 1)
            #expect(page.pinnedSection?.title == "Recent")
            #expect(list.debugSectionItem?.title == "Recent")
            #expect(list.navigationItem.leftItemsSupplementBackButton, "after the back chevron, not instead of it")
        }
    }

    /// The headers leave as they pin: nothing floats under the bar.
    @Test func theHeadersLeaveAsTheyPin() async throws {
        try await hosting(.following, newCount: 3) { _, page in
            let headers = page.collectionView.visibleSupplementaryViews(ofKind: PostGridListLayout.headerElementKind)
                .compactMap { $0 as? SectionHeaderCapsuleView }
            #expect(!headers.isEmpty)
            let allLeave = headers.allSatisfy { $0.hidesWhenPinned }
            #expect(allLeave)
        }
    }

    /// Popular, pushed from a place page: its one run, named once its header
    /// is under the bar.
    @Test func popularIsNamedOnceUnderTheBar() async throws {
        try await hosting(.popular, newCount: 0) { list, page in
            try await scroll(page, toSection: 0)
            #expect(page.pinnedSection?.title == "Popular")
            #expect(list.debugSectionItem?.title == "Popular")
        }
    }

    /// Tapping the name puts that section's first row on the pin line.
    @Test func tappingTheNameScrollsToItsFirstRow() async throws {
        try await hosting(.following, newCount: 3) { _, page in
            try await scroll(page, toSection: 1, beyond: 400)
            #expect(page.pinnedSection?.title == "Recent")
            page.scrollToPinnedSection(animated: false)
            let collection = page.collectionView
            let row = try #require(collection.layoutAttributesForItem(at: IndexPath(item: 0, section: 1)))
            let pinLine = collection.contentOffset.y + collection.adjustedContentInset.top
            #expect(abs(row.frame.minY - pinLine) < 1, "row \(row.frame.minY), pin line \(pinLine)")
        }
    }
}
