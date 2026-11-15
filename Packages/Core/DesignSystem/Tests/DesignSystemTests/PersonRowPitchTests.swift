import Testing
import UIKit
@testable import DesignSystem

/// Every people list on Instagram's and TikTok's convention (#2420): a 56 pt
/// face in a 72 pt row, the 16 pt inset and the 12 pt face → text gap kept,
/// through the one shared metric (`PersonRowMetrics`, owned by
/// `PersonListCell`).
@MainActor
struct PersonRowPitchTests {
    private func traits(_ size: UIContentSizeCategory) -> UITraitCollection {
        UITraitCollection(preferredContentSizeCategory: size)
    }

    @Test func theFaceIs56() {
        #expect(MonogramAvatarView.rowDiameter == 56)
    }

    /// The face and 8 pt above and below: 72 pt at the default text size.
    @Test func thePitchIs72AtTheDefaultTextSize() {
        #expect(PersonListCell.faceRowHeight == 72)
        #expect(PersonListCell.rowHeight(compatibleWith: traits(.large)) == 72)
    }

    /// At the larger sizes two lines of type outgrow the face, and the row
    /// grows with them: it never crops its text.
    @Test func thePitchGrowsWithTheText() {
        let large = PersonListCell.rowHeight(compatibleWith: traits(.accessibilityLarge))
        let name = UIFont.appFont(forTextStyle: .headline, compatibleWith: traits(.accessibilityLarge)).lineHeight
        let handle = UIFont.appFont(forTextStyle: .subheadline, compatibleWith: traits(.accessibilityLarge)).lineHeight
        #expect(large > 72, "the row did not grow with its text")
        #expect(large >= name + handle + 2 + Spacing.md * 2, "the row is shorter than its two lines")
    }

    /// The shared pitch is the cell's, and a disc-bound row pads 8 pt round
    /// the face to land on it.
    @Test func aDiscBoundRowPads8AroundTheFace() {
        #expect(PersonRowMetrics.rowHeight == PersonListCell.comfortableRowHeight)
        if PersonRowMetrics.rowHeight == 72 {
            #expect(PersonRowMetrics.verticalInset(forContentHeight: MonogramAvatarView.rowDiameter) == 8)
        }
    }

    /// A loading row stands where a loaded one will: the same face, the same
    /// pitch, so nothing jumps when the rows land.
    @Test func theSkeletonRowMatchesTheLoadedRow() {
        #expect(PersonSkeletonCell.debugAvatarSize == MonogramAvatarView.rowDiameter)
        #expect(PersonSkeletonCell.debugRowHeight == PersonListCell.faceRowHeight)
    }

    /// A disc made without a size is the row's 56 pt one.
    @Test func aDefaultDiscIsTheRowsFace() {
        let size = MonogramAvatarView().systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        #expect(size == CGSize(width: 56, height: 56))
    }
}
