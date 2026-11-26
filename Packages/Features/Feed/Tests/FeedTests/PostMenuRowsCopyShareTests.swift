import CoreModels
import PostGrid
import Testing
import UIKit
@testable import PostSurfaces

/// A text post's "…" once its row draws share (#2441): Copy Text and Copy
/// Link at the top, no Share, and Copy Text copies the post's words.
@MainActor
struct PostMenuRowsCopyShareTests {
    private let post = GalleryPost(
        id: PostID("p-coffee"), kind: .text, isRepost: false, thumbnailURL: nil,
        caption: "Third coffee. Still deciding whether the rewrite was a good idea.",
        publishedAtMS: 1_800_000_000_000,
        authorID: ProfileID("a1"), authorName: "Ava Moreau", authorHandle: "ava", reactionCount: 234
    )

    private func titles(_ elements: [UIMenuElement]) -> [String] {
        elements.flatMap { element -> [String] in
            if let menu = element as? UIMenu, menu.title.isEmpty { return titles(menu.children) }
            return [element.title]
        }
    }

    private func offersShare(_ rows: [PostCardMenuAction]) -> Bool {
        rows.contains { if case .share = $0 { true } else { false } }
    }

    @Test func aRowThatDrawsShareOffersNoneInItsMenu() {
        let rows = PostMenuRows(comment: {}, offersShare: false).rows(for: post, anchor: UIView())
        #expect(!offersShare(rows))
    }

    @Test func aTileStillOffersShare() {
        let rows = PostMenuRows(comment: {}).rows(for: post, anchor: UIView())
        #expect(offersShare(rows))
    }

    @Test func copyTextAndCopyLinkLeadTheMenu() throws {
        let rows = PostMenuRows(comment: {}, offersShare: false).rows(for: post, anchor: UIView())
        let sections = PostCardMenu.sections(for: rows, author: PostMenuRows.author(of: post))
        let first = try #require(sections.first)
        #expect(titles([first]) == ["Copy Text", "Copy Link"])
        #expect(!titles(sections).contains("Share"))
    }

    /// ⚠️ Never `UIPasteboard.general` here: on a CI simulator it blocked
    /// the main thread, and the whole Feed shard with it (#2568's two reds).
    @Test func copyTextCopiesThePostsWords() throws {
        let copied = Copied()
        var menuRows = PostMenuRows(comment: {}, offersShare: false)
        menuRows.copyToPasteboard = { copied.strings.append($0) }
        let rows = menuRows.rows(for: post, anchor: UIView())
        let sections = PostCardMenu.sections(for: rows, author: nil)
        let action = try #require((sections.first as? UIMenu)?.children.first as? UIAction)
        #expect(action.title == "Copy Text")
        action.performWithSender(nil, target: nil)
        #expect(copied.strings == [post.caption])
    }
}

/// What Copy Text wrote, in order.
@MainActor
private final class Copied {
    var strings: [String] = []
}
