import CoreModels
import Testing
import UIKit
@testable import PostGrid

/// One menu for a post's long press and its "..." (#1498 §3).
@MainActor
struct PostCardMenuTests {
    private func titles(_ elements: [UIMenuElement]) -> [String] {
        elements.flatMap { element -> [String] in
            if let menu = element as? UIMenu, menu.title.isEmpty { return titles(menu.children) }
            return [element.title]
        }
    }

    private func others() -> [PostCardMenuAction] {
        [
            .save(isOn: true) {}, .repost(isOn: false, perform: nil), .comment {},
            .like(isOn: false, amounts: UIMenu(children: [UIAction(title: "+1") { _ in }])),
            .share {}, .copyText {}, .copyLink(perform: nil),
            .viewProfile {}, .follow {}, .hide {}, .report {},
        ]
    }

    /// Someone else's post: the palette, the post's rows, then "@handle ▸"
    /// holding the author's rows.
    @Test func someoneElsesPostReadsInTheOwnersOrder() throws {
        let sections = PostCardMenu.sections(for: others(), author: PostCardMenuAuthor(handle: "ada"))
        #expect(sections.count == 3)
        let palette = try #require(sections[0] as? UIMenu)
        #expect(palette.options.contains(.displayAsPalette))
        #expect(palette.children.map(\.title) == ["Saved", "Repost", "Comment", "Like"])
        #expect(titles([sections[1]]) == ["Share", "Copy Text", "Copy Link"])
        let author = try #require((sections[2] as? UIMenu)?.children.first as? UIMenu)
        #expect(author.title == "@ada")
        #expect(author.children.map(\.title) == ["View Profile", "Follow", "Hide This Post", "Report"])
    }

    /// Repost and Copy Link are shown disabled until they exist; Save shows
    /// its state; Like opens the amounts (the owner's choices).
    @Test func statesAndDisabledRows() throws {
        let sections = PostCardMenu.sections(for: others(), author: nil)
        let palette = try #require(sections[0] as? UIMenu)
        let repost = try #require(palette.children[1] as? UIAction)
        #expect(repost.attributes.contains(.disabled))
        #expect(palette.children[3] is UIMenu, "Like does not open the amounts")
        let copyLink = try #require((sections[1] as? UIMenu)?.children.last as? UIAction)
        #expect(copyLink.attributes.contains(.disabled))
    }

    /// The viewer's own post: its rows inline, no author submenu.
    @Test func ownPostHasNoAuthorSubmenu() {
        let rows: [PostCardMenuAction] = [.share {}, .edit {}, .delete {}]
        let sections = PostCardMenu.sections(for: rows, author: PostCardMenuAuthor(handle: "me"))
        #expect(titles(sections) == ["Share", "Edit post", "Delete post"])
    }

    /// No caption: no Copy Text — the host builds none.
    @Test func noRowsNoMenu() {
        #expect(PostCardMenu.menu(for: []) == nil)
    }

    /// A face is redrawn small for the row, not at its own size.
    @Test func theFaceIsSmall() throws {
        let big = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 400)).image { context in
            UIColor.systemPink.setFill(); context.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
        }
        let face = try #require(PostCardMenuAuthor(handle: "ada", face: big).face)
        #expect(face.size == CGSize(width: PostCardMenuAuthor.faceSide, height: PostCardMenuAuthor.faceSide))
    }
}
