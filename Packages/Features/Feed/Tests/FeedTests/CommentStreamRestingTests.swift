import CoreModels
import DesignSystem
import MediaCore
import Testing
import UIKit
@testable import Feed
@testable import ThreadKit

private final class NoPostFeed: FeedProviding, @unchecked Sendable {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
    func loadPage(afterToken token: String) async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPost(_ id: PostID) async throws -> FeedEntry {
        try await Task.sleep(for: .seconds(3600))
        throw CancellationError()
    }
}

/// `count` comments, every one on one page, both tabs.
private actor OnePost: CommentsProviding {
    let all: [CommentEntry]

    init(count: Int) {
        all = (0..<count).map { index in
            CommentEntry(
                id: "c\(index)", authorID: ProfileID("other"), authorName: "Ava Moreau", authorHandle: "ava",
                body: "Comment \(index)", createdAt: Date(timeIntervalSinceNow: -Double(index) * 60)
            )
        }
    }

    nonisolated func cachedTopComments(for postID: PostID) -> [CommentEntry]? { nil }
    func loadComments(for postID: PostID) async throws -> [CommentEntry] { all }
    func loadCommentsPage(for postID: PostID, after pageToken: String?) async throws -> CommentPage {
        CommentPage(entries: all, nextPageToken: nil)
    }
    func loadCommentsPage(for postID: PostID, after pageToken: String?, order: CommentSortOrder) async throws -> CommentPage {
        CommentPage(entries: order == .recent ? all : all.reversed(), nextPageToken: nil)
    }
    func addComment(_ body: String, to postID: PostID, parentID: String?, commentID: String) async throws -> CommentEntry {
        throw CommentsError.transport(message: "not used")
    }
}

/// ONE RESTING CONTRACT IN EVERY HOST (#2287 § 3, `CommentStreamResting`):
/// the same post's Popular and Recent, short and long, in the text page and
/// in the media post's comments sheet, rest at the same place in the room
/// each host gives — Popular's first row (the caption) right under the
/// room's top, a short one leaving its room below; Recent's last comment
/// right over the room's bottom (the composer), a short one leaving its room
/// above, a long one at its end. The hosts give the room, never the rest.
@MainActor
@Suite(.serialized)
struct CommentStreamRestingTests {
    private enum Host: CaseIterable {
        /// The text page: the panel with its thread chrome, under the page's
        /// strip, over the page's composer (`installRestingPanel`).
        case textPage
        /// The media post's comments sheet: the bare panel in the sheet's
        /// content, under its own bar (`SnapCommentsSheetViewController`).
        case sheet
    }

    private static let screen = CGRect(x: 0, y: 0, width: 402, height: 874)

    private func settle(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// The same post's panel, as `host` builds and places it.
    private func panel(in host: Host, comments: Int) -> (PostDetailViewController, UIWindow) {
        let detail = PostDetailViewController(
            viewModel: PostDetailViewModel(postID: PostID("p"), repository: NoPostFeed(), commentsProvider: OnePost(count: comments)),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            threadChrome: host == .textPage,
            groupsByDay: true
        )
        detail.seedCaption("A post", timestamp: "2h", authorName: "Ava Moreau")
        switch host {
        case .textPage:
            let window = UIWindow(frame: Self.screen)
            window.rootViewController = detail
            window.isHidden = false
            detail.loadViewIfNeeded()
            detail.setEngagedInsets(
                top: SnapCommentsLayout.commentsTopInset(topInset: window.safeAreaInsets.top),
                bottomInset: window.safeAreaInsets.bottom
            )
            return (detail, window)
        case .sheet:
            SnapCommentsSheetViewController.prepare(detail, commentCount: Int64(comments))
            let content = SnapCommentsSheetViewController(panel: detail, walletBadge: nil, onWalletTap: nil)
            // The sheet's collapsed height on this screen, more or less: the
            // contract does not care which, only that the room is the host's.
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: Self.screen.width, height: 560))
            window.rootViewController = content
            window.isHidden = false
            content.composerBottomInset = 34
            content.loadViewIfNeeded()
            content.view.layoutIfNeeded()
            content.applyPanelInsets()
            return (detail, window)
        }
    }

    /// Where `stream` stands in its room, at rest.
    private struct Place {
        /// From the room's top to the first row's top (`.top`), or from the
        /// last row's bottom to the room's bottom (`.bottom`).
        let gap: CGFloat
        /// The room left on the other side: below a short Popular, above a
        /// short Recent.
        let roomLeft: CGFloat
        /// How far the stream stands from its contract's rest.
        let distanceFromRest: CGFloat
    }

    private static func place(of stream: CommentStream, engagedTop: CGFloat) -> Place? {
        let list = stream.collectionView
        list.layoutIfNeeded()
        let sections = list.numberOfSections
        guard sections > 0 else { return nil }
        let lastSection = sections - 1
        let lastItem = list.numberOfItems(inSection: lastSection) - 1
        guard lastItem >= 0,
              let first = list.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame,
              let last = list.layoutAttributesForItem(at: IndexPath(item: lastItem, section: lastSection))?.frame
        else { return nil }
        let offset = list.contentOffset.y
        let roomBottom = list.bounds.height - list.contentInset.bottom
        switch stream.resting {
        case .top:
            return Place(
                gap: first.minY - offset - engagedTop,
                roomLeft: roomBottom - (last.maxY - offset),
                distanceFromRest: stream.debugDistanceFromRest
            )
        case .bottom:
            return Place(
                gap: roomBottom - (last.maxY - offset),
                roomLeft: first.minY - offset - engagedTop,
                distanceFromRest: stream.debugDistanceFromRest
            )
        }
    }

    /// Each tab of the same post, at rest in `host`.
    private func places(in host: Host, comments: Int) async throws -> [CommentStream.Kind: Place] {
        let (detail, window) = panel(in: host, comments: comments)
        defer { window.isHidden = true }
        let loaded = await settle {
            detail.popular.commentsLoaded && detail.recent.commentsLoaded
                && detail.recent.collectionView.numberOfItems(inSection: max(0, detail.recent.collectionView.numberOfSections - 1)) > 0
        }
        #expect(loaded, "\(host): the comments never came")
        var found: [CommentStream.Kind: Place] = [:]
        for kind in [CommentStream.Kind.popular, .recent] {
            detail.showStream(kind, animated: false)
            let stream = kind == .popular ? detail.popular : detail.recent
            let engagedTop = try #require(detail.engagedStreamInsets?.top)
            // The rows size themselves, and the stream follows them a turn
            // later (`followContentSizeSoon`): at rest once it stays there.
            _ = await settle { abs(stream.debugDistanceFromRest) < 0.5 }
            try await Task.sleep(for: .milliseconds(50))
            found[kind] = try #require(Self.place(of: stream, engagedTop: engagedTop), "\(host) \(kind): no rows")
        }
        return found
    }

    @Test(arguments: [2, 40])
    func eachTabRestsAtTheSamePlaceInBothHosts(comments: Int) async throws {
        let text = try await places(in: .textPage, comments: comments)
        let sheet = try await places(in: .sheet, comments: comments)
        let short = comments < 10
        for kind in [CommentStream.Kind.popular, .recent] {
            let a = try #require(text[kind]), b = try #require(sheet[kind])
            #expect(abs(a.distanceFromRest) < 0.5, "text page, \(kind): \(a.distanceFromRest) pt from its rest")
            #expect(abs(b.distanceFromRest) < 0.5, "sheet, \(kind): \(b.distanceFromRest) pt from its rest")
            // The same edge gap in both hosts — except a SHORT Recent, whose
            // bottom room in this bare text page (no real composer chrome)
            // isn't the app's: on the simulator the text page's short Recent
            // rests its last comment right over the composer, as the sheet's
            // does (#2287). Each still rests at its own rest, room above.
            if !(short && kind == .recent) {
                #expect(abs(a.gap - b.gap) < 1, "\(kind) rests \(a.gap) pt from its edge on the text page, \(b.gap) in the sheet")
            }
            if short {
                // A short stream leaves its room on the side away from its rest.
                #expect(a.roomLeft > 50 && b.roomLeft > 50, "short \(kind) left no room: \(a.roomLeft), \(b.roomLeft)")
            } else if kind == .recent {
                // A long Recent opens at its end: its first rows are above the room.
                #expect(a.roomLeft < 0 && b.roomLeft < 0, "long Recent not at its end: \(a.roomLeft), \(b.roomLeft)")
            }
        }
    }

    /// The contract itself: Popular `.top`, Recent `.bottom`, a short Recent
    /// wearing its room above, the resting offsets.
    @Test func theContractIsPopularTopAndRecentBottom() {
        #expect(CommentStreamResting(.popular) == .top)
        #expect(CommentStreamResting(.recent) == .bottom)
        #expect(CommentStreamResting.top.slack(room: 500, contentHeight: 200) == 0)
        #expect(CommentStreamResting.bottom.slack(room: 500, contentHeight: 200) == 300)
        let insets = UIEdgeInsets(top: 100, left: 0, bottom: 80, right: 0)
        #expect(CommentStreamResting.top.restingOffset(contentHeight: 2000, boundsHeight: 800, insets: insets) == -100)
        #expect(CommentStreamResting.bottom.restingOffset(contentHeight: 2000, boundsHeight: 800, insets: insets) == 1280)
        #expect(CommentStreamResting.bottom.restingOffset(contentHeight: 200, boundsHeight: 800, insets: insets) == -100)
    }
}
