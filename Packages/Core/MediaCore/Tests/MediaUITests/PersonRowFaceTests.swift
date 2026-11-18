import DesignSystem
import Testing
import UIKit
@testable import MediaCore
@testable import MediaUI

/// The faces of a people row at its new 56 pt (#2420): the relation badge
/// grows with the face, and a group's faces fill the larger square.
@MainActor
struct PersonRowFaceTests {
    /// About 22 pt at 56, from about 20 at 48: `RelationMarkMetrics`
    /// interpolates between the pill's face and the header's.
    @Test func theBadgeGrowsWithTheFace() {
        let row = RelationMarkMetrics(faceDiameter: MonogramAvatarView.rowDiameter)
        let before = RelationMarkMetrics(faceDiameter: 48)
        #expect(row.badgeDiameter == 22.5)
        #expect(row.badgeDiameter > before.badgeDiameter)
    }

    /// The marked face and a group's picture default to the row's 56 pt.
    @Test func theRowsFacesAre56ByDefault() {
        #expect(RelationMarkedAvatarView().metrics.faceDiameter == 56)
        #expect(GroupAvatarView().diameter == 56)
        #expect(GroupAvatarView().intrinsicContentSize == CGSize(width: 56, height: 56))
    }

    /// A group's faces fill the 56 pt square: none past its edge, and the set
    /// reaches it as it did at 48 (fractions of the side).
    @Test(arguments: [2, 3, 4])
    func aGroupsFacesFillTheSquare(_ count: Int) {
        let side = MonogramAvatarView.rowDiameter
        let frames = GroupAvatarLayout.frames(count: count, side: side, rightToLeft: false)
        let union = frames.reduce(CGRect.null) { $0.union($1) }
        let square = CGRect(x: 0, y: 0, width: side, height: side)
        #expect(square.contains(union), "a face runs past the square")
        let at48 = GroupAvatarLayout.frames(count: count, side: 48, rightToLeft: false).reduce(CGRect.null) { $0.union($1) }
        #expect(abs(union.width / side - at48.width / 48) < 0.03, "the set's spread changed with the size")
    }
}
