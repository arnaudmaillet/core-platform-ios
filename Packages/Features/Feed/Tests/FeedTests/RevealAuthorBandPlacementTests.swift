import PostGrid
import Testing
import UIKit
@testable import Feed

/// The destination borrows the source card's author band for the length of a
/// flight, so the window shows the header the card does instead of a blank
/// strip. The whole point is that the two are IDENTICAL — a mismatch is not a
/// smaller version of the same effect, it is a second thing to notice at the
/// exact moment the transition is trying to be invisible.
///
/// These pin the placement, which was wrong once and looked plausible: the
/// first version measured from the page's own edge and put the band 16pt wider
/// on each side than the card's. The page's caption is inset TWICE — once by
/// the stream's section and once by the row — and only the second of those is
/// the card's own.
@MainActor
struct RevealAuthorBandPlacementTests {
    /// A caption row as the page reports it on an iPhone SE: inset from the
    /// screen by the stream's section, 343 wide, starting 78 down.
    private static let anchor = CGRect(x: 16, y: 78, width: 343, height: 331)

    /// The band takes the CAPTION's inset inside the row — the same one the
    /// card gives its own band — so the two sit on the same vertical.
    @Test func theBandTakesTheCaptionsInsetInsideTheRow() {
        let rect = TextRevealInstaller.bandRect(anchoredTo: Self.anchor)
        #expect(rect.minX == Self.anchor.minX + PostGridListRowCell.captionInset)
        #expect(rect.maxX == Self.anchor.maxX - PostGridListRowCell.captionInset)
    }

    /// And it is symmetric: the same margin either side, which is what the
    /// first version broke by anchoring to the view instead of the row.
    @Test func theMarginsAreSymmetric() {
        let rect = TextRevealInstaller.bandRect(anchoredTo: Self.anchor)
        #expect(rect.minX - Self.anchor.minX == Self.anchor.maxX - rect.maxX)
    }

    /// Vertically it sits where the card puts its band above its caption: up by
    /// the caption offset, back down by the inset the card keeps above it.
    @Test func theBandSitsWhereTheCardPutsItsOwn() {
        let rect = TextRevealInstaller.bandRect(anchoredTo: Self.anchor)
        #expect(rect.minY
            == Self.anchor.minY - PostAuthorBandView.captionOffset
                + PostGridListRowCell.captionTopInset)
        #expect(rect.height == PostAuthorBandView.avatarDiameter)
    }

    /// The gap the band leaves under itself is the card's own — otherwise the
    /// caption in the window and the caption on the card would not line up.
    @Test func theGapUnderTheBandIsTheCards() {
        let rect = TextRevealInstaller.bandRect(anchoredTo: Self.anchor)
        let captionInWindow = Self.anchor.minY + PostGridListRowCell.captionTopInset
        #expect(captionInWindow - rect.maxY == PostAuthorBandView.captionGap)
    }

    /// A degenerate row cannot produce a negative width — the sort of thing a
    /// zero-width measurement pass hands over before layout has run.
    @Test func aDegenerateRowIsNotNegative() {
        let rect = TextRevealInstaller.bandRect(
            anchoredTo: CGRect(x: 0, y: 0, width: 8, height: 0)
        )
        #expect(rect.width == 0)
    }
}
