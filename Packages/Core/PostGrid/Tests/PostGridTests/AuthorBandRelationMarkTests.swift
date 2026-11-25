import CoreModels
import MediaCore
import MediaCoreFixtures
import MediaUI
import Testing
import UIKit
@testable import PostGrid

/// THE AUTHOR BAND WEARS THE RELATION MARK (#2300, the owner's rule of
/// 2026-11-02: one mark, the same on every avatar that carries one). A text
/// post's author is this band in the lists — the flat rows, a shelf's text
/// card, For You's preview — and it wore a bare face while a media post's
/// author row wore the badge.
///
/// The band draws what its host's binding gives it, on the shared marked face
/// (`RelationMarkedAvatarView`); its tap and hold are the shared contract's
/// (`PersonOpening`, role 1).
@MainActor
struct AuthorBandRelationMarkTests {
    private static let width: CGFloat = 343

    private static func post(author: String? = "p1", handle: String = "ava") -> GalleryPost {
        GalleryPost(
            id: PostID("post-0001"),
            kind: .text,
            isRepost: false,
            thumbnailURL: nil,
            caption: "Refactor landed and the office survived it.",
            publishedAtMS: 1_780_000_000_000,
            authorID: author.map { ProfileID($0) },
            authorName: author == nil ? nil : "Ava Moreau",
            authorHandle: author == nil ? nil : handle,
            reactionCount: 12
        )
    }

    private static func band(_ post: GalleryPost = post(), showsIdentity: Bool = true) -> PostAuthorBandView {
        let band = PostAuthorBandView()
        band.frame = CGRect(x: 0, y: 0, width: width, height: PostAuthorBandView.avatarDiameter)
        band.configure(with: .init(post: post, showsIdentity: showsIdentity), imagePipeline: nil)
        band.layoutIfNeeded()
        return band
    }

    private static func row(_ post: GalleryPost = post()) -> PostGridListRowCell {
        let cell = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: width, height: 200))
        cell.configure(with: post, imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()))
        cell.layoutIfNeeded()
        return cell
    }

    // MARK: - The mark

    /// Every state the binding answers, drawn as given, at the band's 40 pt:
    /// the badge's side from `RelationMarkMetrics`.
    @Test(arguments: [PersonPill.Badge.loading, .following, .friends])
    func theBandDrawsTheMarkItIsGiven(_ mark: PersonPill.Badge) {
        let band = Self.band()
        band.setRelationMark(mark, animated: false)
        band.layoutIfNeeded()
        #expect(band.relationMark == mark)
        #expect(band.debugBadge.drawn == mark)
        #expect(band.debugBadge.metrics == RelationMarkMetrics(faceDiameter: PostAuthorBandView.avatarDiameter))
        #expect(band.debugFaceIsCutOut, "the badge's cutout is out of the face")
        #expect(band.model?.relationMark == mark, "a prop copying the row's model wears its mark")
    }

    /// The viewer's own post (the binding's `.none`): no badge, no cutout.
    @Test func theViewersOwnPostWearsNothing() {
        let band = Self.band()
        band.setRelationMark(.following, animated: false)
        band.setRelationMark(.none, animated: false)
        band.layoutIfNeeded()
        #expect(band.relationMark == .none)
        #expect(!band.debugFaceIsCutOut)
    }

    /// A bare band names nobody, so it wears no mark whatever it is given.
    @Test func aBareBandWearsNoMark() {
        let band = Self.band(showsIdentity: false)
        band.setRelationMark(.following, animated: false)
        #expect(band.relationMark == .none)
        #expect(band.model?.relationMark == PersonPill.Badge.none)
    }

    /// A reveal's prop configured from the row's reading wears the row's mark
    /// — nothing pops in at the landing.
    @Test func thePropWearsTheRowsMark() throws {
        let cell = Self.row()
        cell.setAuthorRelationMark(.friends, animated: false)
        let model = try #require(cell.authorBandModel)
        let prop = PostAuthorBandView()
        prop.configure(with: model, imagePipeline: nil)
        #expect(prop.relationMark == .friends)
    }

    // MARK: - Passive (#2419)

    /// The badge is never a control: the face is the identity's, whatever
    /// the mark, and the identity control stays the hit view on the badge.
    @Test(arguments: [PersonPill.Badge.loading, .following, .friends])
    func theBadgeIsPassive(_ mark: PersonPill.Badge) {
        let band = Self.band()
        band.setRelationMark(mark, animated: false)
        band.layoutIfNeeded()
        let badge = band.debugBadge
        let inside = badge.convert(CGPoint(x: 3, y: 3), to: band)
        #expect(band.hitTest(inside, with: nil) !== badge)
        #expect(!(band.hitTest(CGPoint(x: 8, y: 8), with: nil) is RelationBadgeView))
        #expect(band.hitTest(CGPoint(x: 8, y: 8), with: nil) is UIControl)
    }

    // MARK: - The tap and the hold (#2145, role 1)

    /// A person beside content: a tap the card, a hold the profile — the
    /// shared contract's, with nothing for a band that names nobody.
    @Test func theTapAndTheHoldAreTheContracts() {
        let cell = Self.row()
        var events: [String] = []
        cell.onAuthorTapped = { events.append("card") }
        cell.onAuthorHeld = { events.append("profile") }
        cell.debugTapAuthor()
        cell.debugHoldAuthor()
        #expect(events == ["card", "profile"])

        let anonymous = Self.row(Self.post(author: nil))
        anonymous.onAuthorTapped = { events.append("ghost") }
        anonymous.onAuthorHeld = { events.append("ghost") }
        anonymous.debugTapAuthor()
        anonymous.debugHoldAuthor()
        #expect(events == ["card", "profile"])
    }

    // MARK: - Reuse

    /// A recycled row never wears the previous author's mark or Follow.
    @Test func aRecycledRowForgetsTheMark() {
        let cell = Self.row()
        cell.onAuthorFollowTapped = {}
        cell.onAuthorCancelFollowRequest = {}
        cell.setAuthorRelationMark(.following, animated: false)
        cell.setAuthorFollowOffer(.follow, animated: false)
        cell.prepareForReuse()
        #expect(cell.authorRelationMark == .none)
        #expect(cell.authorFollowOffer == .none)
        #expect(cell.debugAuthorFollowButton.isHidden)
        #expect(cell.onAuthorFollowTapped == nil)
        #expect(cell.onAuthorCancelFollowRequest == nil)
        #expect(cell.onAuthorHeld == nil)
    }

    /// A reconfigure for the same author keeps the mark its host drew; a new
    /// author starts bare until the host binds them.
    @Test func aReconfigureKeepsTheSameAuthorsMark() {
        let cell = Self.row()
        cell.setAuthorRelationMark(.following, animated: false)
        cell.configure(with: Self.post(), imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()))
        #expect(cell.authorRelationMark == .following)
        cell.configure(
            with: Self.post(author: "p2", handle: "kenji"),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        #expect(cell.authorRelationMark == .none)
    }
}
