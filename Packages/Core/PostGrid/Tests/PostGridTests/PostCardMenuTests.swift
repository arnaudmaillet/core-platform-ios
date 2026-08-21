import CoreModels
import Foundation
import Testing
import UIKit
@testable import PostGrid

/// The card's "..." — what it says, and what it does when a surface can offer
/// nothing.
///
/// The rows themselves are chosen per screen (Following offers Unfollow, a
/// profile gallery does not), and that choice is the host's. What is pinned
/// here is everything BOTH hosts must agree on, because the whole reason the
/// menu is built from one type is that two screens cannot be trusted to word
/// the same action the same way.
@MainActor
struct PostCardMenuTests {
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

    /// A surface that can service nothing must produce NO menu, so the band can
    /// hide the control. An empty `UIMenu` would still open — a sheet with
    /// nothing in it, which reads as a broken screen rather than as an absent
    /// feature.
    @Test func noRowsMeansNoMenu() {
        #expect(PostCardMenu.menu(for: []) == nil)
    }

    @Test func theRowsKeepTheOrderTheHostAskedFor() throws {
        let menu = try #require(PostCardMenu.menu(for: [.unfollow {}, .report {}]))

        #expect(menu.children.compactMap { ($0 as? UIAction)?.title }
            == ["Unfollow", "Report"])
    }

    /// Bare verbs, as the profile's "..." settled on — the card names its
    /// author two lines above the menu. Pinned because the handle WAS in this
    /// row until the sim showed UIKit wrapping it and hyphenating mid-handle.
    @Test func rowsAreBareVerbs() {
        #expect(PostCardMenuAction.unfollow {}.title == "Unfollow")
        #expect(PostCardMenuAction.report {}.title == "Report")
    }

    /// Report is the destructive row and Unfollow deliberately is not: painting
    /// both red would make the menu's one irreversible action indistinguishable
    /// from its routine one.
    @Test func onlyReportIsDestructive() {
        #expect(PostCardMenuAction.report {}.attributes == .destructive)
        #expect(PostCardMenuAction.unfollow {}.attributes == [])
    }

    @Test func theRowRunsTheHandlerItWasBuiltWith() {
        final class Box: @unchecked Sendable { var fired = false }
        let box = Box()

        let action = PostCardMenuAction.report { box.fired = true }.element
        action.performWithSender(nil, target: nil)

        #expect(box.fired)
    }

    // MARK: - The stub a tapped author travels with

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
