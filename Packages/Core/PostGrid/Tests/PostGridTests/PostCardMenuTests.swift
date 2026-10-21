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

    /// A surface that can service nothing must produce NO menu, so the band
    /// can hide the control: an empty `UIMenu` would still open.
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

    /// Report, Delete and Block are destructive; Unfollow deliberately is
    /// not, since following again undoes it.
    @Test func onlyTheIrreversibleRowsAreDestructive() {
        #expect(PostCardMenuAction.report {}.attributes == .destructive)
        #expect(PostCardMenuAction.block {}.attributes == .destructive)
        #expect(PostCardMenuAction.unfollow {}.attributes == [])
        #expect(PostCardMenuAction.mute {}.attributes == [])
    }

    @Test func ownPostRowsAreEditAndDelete() {
        #expect(PostCardMenuAction.edit {}.title == "Edit post")
        #expect(PostCardMenuAction.delete {}.title == "Delete post")
        #expect(PostCardMenuAction.edit {}.attributes == [])
        #expect(PostCardMenuAction.delete {}.attributes == .destructive)
    }

    @Test func theRowRunsTheHandlerItWasBuiltWith() {
        final class Box: @unchecked Sendable { var fired = false }
        let box = Box()

        let action = PostCardMenuAction.report { box.fired = true }.element as? UIAction
        action?.performWithSender(nil, target: nil)

        #expect(box.fired)
    }

    // MARK: - The stub a tapped author travels with

    private func post(name: String? = "Ada Lovelace", handle: String? = "ada") -> GalleryPost {
        GalleryPost(
            id: PostID("post-1"),
            kind: .text,
            isRepost: false,
            thumbnailURL: nil,
            caption: "note",
            publishedAtMS: 0,
            authorID: ProfileID("prof-1"),
            authorName: name,
            authorHandle: handle
        )
    }

    @Test func theStubCarriesWhatTheRowDrew() {
        let stub = post().authorIdentityStub
        #expect(stub?.displayName == "Ada Lovelace")
        #expect(stub?.handle == "ada")
    }

    /// Half an identity is still an identity — the band draws it, so the push
    /// gets it.
    @Test func aHandleAloneStandsInForTheName() {
        #expect(post(name: nil).authorIdentityStub?.displayName == "ada")
    }

    /// No identity at all means no stub, matching the condition that hides the
    /// band: a stub of two empty strings would make the pushed screen render a
    /// blank name instead of its placeholder.
    @Test func noIdentityMeansNoStub() {
        #expect(post(name: "  ", handle: nil).authorIdentityStub == nil)
    }
}

/// The band's overflow control appears exactly when it can do something — plus
/// the one exception that is not an exception at all.
@MainActor
struct PostAuthorBandControlTests {
    private func control(in band: PostAuthorBandView) -> UIView? {
        band.menuAnchor
    }

    @Test func aBandWithNoRowsToOfferShowsNoControl() {
        let band = PostAuthorBandView()
        #expect(control(in: band)?.isHidden == true)
    }

    @Test func supplyingRowsRevealsIt() {
        let band = PostAuthorBandView()
        band.menuActions = { [.report {}] }
        #expect(control(in: band)?.isHidden == false)
    }

    /// The case that put the rule here: a surface hands a provider to every row
    /// that has an author, and then answers with nothing for the viewer's own
    /// post. Tracking the PROVIDER left a "..." that opened an empty sheet.
    @Test func aProviderThatOffersNothingStillHidesIt() {
        let band = PostAuthorBandView()
        band.menuActions = { [] }
        #expect(control(in: band)?.isHidden == true)
    }

    @Test func withdrawingThemHidesItAgain() {
        let band = PostAuthorBandView()
        band.menuActions = { [.report {}] }
        band.menuActions = nil
        #expect(control(in: band)?.isHidden == true)
    }

    /// A transition's prop takes no touches and has no handlers, and must still
    /// draw the glyph: the card it lands on has one, and a control that appears
    /// in the last frame is the frame the reveal exists to make unremarkable.
    @Test func sceneryDrawsItWithoutWiringIt() {
        let band = PostAuthorBandView()
        band.showMenuControlAsScenery()
        #expect(control(in: band)?.isHidden == false)
        #expect(band.menuActions == nil)
    }
}
