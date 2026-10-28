import Testing
import UIKit
@testable import DesignSystem

/// Skeletons drawn from the real row's layout, on one width rule (#1774).
@MainActor
struct StructuralSkeletonTests {
    @Test func oneWidthRuleCyclesForEveryRow() {
        #expect(SkeletonLineWidths.fraction(SkeletonLineWidths.title, at: 0) == SkeletonLineWidths.title[0])
        #expect(SkeletonLineWidths.fraction(SkeletonLineWidths.title, at: SkeletonLineWidths.title.count)
            == SkeletonLineWidths.title[0])
        #expect(SkeletonLineWidths.fraction(SkeletonLineWidths.body, at: -1) == SkeletonLineWidths.body.last)
        for widths in [SkeletonLineWidths.title, SkeletonLineWidths.detail, SkeletonLineWidths.body] {
            #expect(widths.allSatisfy { $0 > 0 && $0 < 1 })
        }
    }

    @Test func aListWithSectionsLeadsWithItsHeading() {
        let view = PersonListSkeletonView(trailing: .timeBone, lines: .preview, header: .largeTitle)
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        #expect(view.debugFirstRowBoneCount == 4, "avatar, title, time and preview under the heading")
        #expect(view.debugHasHeader)
        let plain = PersonListSkeletonView(trailing: .timeBone)
        plain.frame = view.frame
        _ = plain.debugFirstRowBoneCount
        #expect(!plain.debugHasHeader)
    }

    /// A person row's skeleton draws its avatar with the avatar's own
    /// skeleton (#1750, #1774), in the cell and in the list alike.
    @Test func personRowsWearTheAvatarsOwnSkeleton() {
        func avatars(in view: UIView) -> Int {
            view.subviews.reduce(0) { $0 + ($1 is AvatarSkeletonView ? 1 : avatars(in: $1)) }
        }
        let cell = PersonSkeletonCell(frame: CGRect(x: 0, y: 0, width: 390, height: 64))
        #expect(avatars(in: cell.contentView) == 1)
        let list = PersonListSkeletonView(trailing: .timeBone)
        list.frame = CGRect(x: 0, y: 0, width: 390, height: 200)
        list.layoutIfNeeded()
        #expect(avatars(in: list) > 0)
    }
}
