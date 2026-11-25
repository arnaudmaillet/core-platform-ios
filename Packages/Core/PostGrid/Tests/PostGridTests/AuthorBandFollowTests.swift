import CoreModels
import DesignSystem
import MediaCore
import Testing
import UIKit
@testable import PostGrid

/// THE FOLLOW BESIDE THE BAND'S "…" (#2419, the owner 2026-11-13): the face's
/// badge is information only, and following moved to a tinted row action,
/// right-aligned just left of the "…": `(◯) Name … (Follow) •••`.
@MainActor
struct AuthorBandFollowTests {
    private static let width: CGFloat = 343

    private static func post(name: String = "Ava Moreau", handle: String = "ava") -> GalleryPost {
        GalleryPost(
            id: PostID("post-0001"),
            kind: .text,
            isRepost: false,
            thumbnailURL: nil,
            caption: "Refactor landed and the office survived it.",
            publishedAtMS: 1_780_000_000_000,
            authorID: ProfileID("p1"),
            authorName: name,
            authorHandle: handle,
            reactionCount: 12
        )
    }

    /// A band with its "…", laid out at a row's width.
    private static func band(_ post: GalleryPost = post(), showsIdentity: Bool = true) -> PostAuthorBandView {
        let band = PostAuthorBandView()
        band.frame = CGRect(x: 0, y: 0, width: width, height: PostAuthorBandView.avatarDiameter)
        band.configure(with: .init(post: post, showsIdentity: showsIdentity), imagePipeline: nil)
        band.menuActions = { [.report {}] }
        band.layoutIfNeeded()
        return band
    }

    // MARK: - Which offer

    /// The offer for each relation: Follow, Follow back, Requested; nothing
    /// for the viewer, someone blocked, a relation not known yet; followed
    /// draws no button.
    @Test func eachRelationHasItsOffer() {
        #expect(AuthorFollowOffer(relation: .notFollowing) == .follow)
        #expect(AuthorFollowOffer(relation: .followedBy) == .followBack)
        #expect(AuthorFollowOffer(relation: .requested) == .requested)
        #expect(AuthorFollowOffer(relation: .following) == .following)
        #expect(AuthorFollowOffer(relation: .mutual) == .following)
        #expect(AuthorFollowOffer(relation: .viewer) == .none)
        #expect(AuthorFollowOffer(relation: .blocked) == .none)
        #expect(AuthorFollowOffer(relation: nil) == .none)
        let shown = [AuthorFollowOffer.follow, .followBack, .requested].map(\.showsButton)
        let hidden = [AuthorFollowOffer.none, .following].map(\.showsButton)
        #expect(shown == [true, true, true])
        #expect(hidden == [false, false])
    }

    /// The button for each offer: tinted while it invites, quiet once
    /// requested, none at all for nothing or followed.
    @Test(arguments: [
        (AuthorFollowOffer.follow, "Follow", false),
        (.followBack, "Follow back", false),
        (.requested, "Requested", true),
    ])
    func theBandShowsTheButtonForItsOffer(_ offer: AuthorFollowOffer, _ title: String, _ quiet: Bool) {
        let band = Self.band()
        band.setFollowOffer(offer, animated: false)
        band.layoutIfNeeded()
        let button = band.debugFollowButton
        #expect(!button.isHidden)
        #expect(button.content.title == title)
        #expect(button.isSelected == quiet)
        #expect(button.aspect == .rowAction, "not the row action's tinted ground")
        #expect(band.model?.followOffer == offer, "a stand-in copying the row's model would lose it")
    }

    @Test(arguments: [AuthorFollowOffer.none, .following])
    func noButtonForNothingOrFollowed(_ offer: AuthorFollowOffer) {
        let band = Self.band()
        band.setFollowOffer(.follow, animated: false)
        band.setFollowOffer(offer, animated: false)
        #expect(band.debugFollowButton.isHidden)
        #expect(!band.debugFollowButton.isConfirming)
    }

    /// A bare band names nobody to follow.
    @Test func aBareBandOffersNothing() {
        let band = Self.band(showsIdentity: false)
        band.setFollowOffer(.follow, animated: false)
        #expect(band.followOffer == .none)
        #expect(band.debugFollowButton.isHidden)
    }

    // MARK: - Where

    /// Right-aligned, Follow THEN the "…", at the "…"'s height, the band's
    /// pill height.
    @Test func followStandsJustLeftOfTheMenu() {
        let band = Self.band()
        band.setFollowOffer(.follow, animated: false)
        band.layoutIfNeeded()
        let button = band.debugFollowButton.convert(band.debugFollowButton.bounds, to: band)
        let menu = band.debugMenuFrame
        #expect(button.maxX <= menu.minX + 0.5, "Follow \(button) is not left of the … \(menu)")
        #expect(menu.minX - button.maxX < 12, "Follow drifted away from the …")
        #expect(abs(menu.maxX - band.bounds.maxX) < 0.5)
        #expect(abs(button.height - PostMetaPillView.height) < 0.5)
        #expect(abs(button.height - menu.height) < 0.5)
        #expect(band.debugNameFrame.maxX <= button.minX, "the name runs under Follow")
    }

    /// THE NAME TRUNCATES FIRST: Follow and the "…" keep their size.
    @Test func aLongNameTruncatesFirst() {
        let long = String(repeating: "Maximilian Alexander ", count: 4) + "von Hohenzollern"
        let band = Self.band(Self.post(name: long, handle: "maximilian.alexander.hohenzollern"))
        band.setFollowOffer(.followBack, animated: false)
        band.layoutIfNeeded()
        let button = band.debugFollowButton
        let natural = button.fittingSize(for: button.content).width
        #expect(button.bounds.width >= natural - 0.5, "Follow back was squeezed: \(button.bounds.width) < \(natural)")
        #expect(abs(band.debugMenuFrame.width - PostAuthorBandView.actionControlWidth) < 0.5)
        #expect(band.debugNameIsTruncated, "the name was not the one to give way")
        #expect(band.debugNameFrame.maxX <= button.convert(button.bounds, to: band).minX)
    }

    // MARK: - What it does

    /// A tap on Follow or Follow back is the host's follow; Requested's tap
    /// is its menu, which offers to cancel the request.
    @Test func aTapFollowsAndRequestedOffersToCancel() throws {
        let band = Self.band()
        var follows = 0
        band.onFollowTapped = { follows += 1 }
        band.setFollowOffer(.follow, animated: false)
        band.debugFollowButton.debugTap()
        band.setFollowOffer(.followBack, animated: false)
        band.debugFollowButton.debugTap()
        #expect(follows == 2)
        #expect(!band.debugFollowButton.showsMenuAsPrimaryAction)

        band.setFollowOffer(.requested, animated: false)
        band.debugFollowButton.debugTap()
        #expect(follows == 2, "Requested followed again")
        let button = band.debugFollowButton
        #expect(button.showsMenuAsPrimaryAction)
        let cancel = try #require(button.menu?.children.first as? UIAction)
        #expect(cancel.title == "Cancel Request")
        #expect(cancel.attributes.contains(.destructive))
    }

    /// FOLLOWED ON SCREEN: "✓ Following" for a moment, then the button folds
    /// away and the name gets the room back.
    @Test func followedOnScreenConfirmsThenFolds() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 200))
        window.isHidden = false
        defer { window.isHidden = true }
        let band = Self.band()
        window.addSubview(band)
        let clock = ManualLoadingClock()
        band.debugFollowButton.loadClock = clock.clock
        band.setFollowOffer(.follow, animated: false)
        band.layoutIfNeeded()

        band.setFollowOffer(.following, animated: true)
        let button = band.debugFollowButton
        #expect(button.isConfirming)
        #expect(!button.isHidden)
        #expect(button.content.title == "Following")
        #expect(button.content.symbol == "checkmark")
        clock.advance(AuthorFollowButton.confirmationDuration - 0.1)
        #expect(!button.isHidden, "folded before its moment")
        clock.advance(0.2)
        #expect(button.isHidden, "\"✓ Following\" never folded")
        #expect(!button.isConfirming)
    }

    /// A PRIVATE ACCOUNT: the optimistic "✓ Following" gives way to
    /// "Requested", which stays.
    @Test func aPrivateAccountTurnsTheConfirmationIntoRequested() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 200))
        window.isHidden = false
        defer { window.isHidden = true }
        let band = Self.band()
        window.addSubview(band)
        let clock = ManualLoadingClock()
        band.debugFollowButton.loadClock = clock.clock
        band.setFollowOffer(.follow, animated: false)
        band.setFollowOffer(.following, animated: true)
        band.setFollowOffer(.requested, animated: true)
        clock.advance(5)
        let button = band.debugFollowButton
        #expect(!button.isHidden, "Requested folded away")
        #expect(!button.isConfirming)
        #expect(button.content.title == "Requested")
        #expect(button.isSelected)
    }

    /// A ROW FILLED AFRESH draws its offer at once: no confirmation, no
    /// fold, on screen or not.
    @Test func aRowFilledAfreshDrawsItsOfferAtOnce() {
        let band = Self.band()
        band.setFollowOffer(.follow, animated: false)
        band.setFollowOffer(.following, animated: false)
        #expect(band.debugFollowButton.isHidden)
        #expect(!band.debugFollowButton.isConfirming)
    }

    /// VoiceOver names the person: "Follow" alone is ambiguous in a list.
    @Test func voiceOverNamesThePerson() {
        let band = Self.band()
        band.setFollowOffer(.follow, animated: false)
        #expect(band.debugFollowButton.accessibilityLabel == "Follow Ava Moreau")
        band.setFollowOffer(.followBack, animated: false)
        #expect(band.debugFollowButton.accessibilityLabel == "Follow Ava Moreau back")
    }
}
