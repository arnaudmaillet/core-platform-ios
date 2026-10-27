import Testing
import UIKit
@testable import DesignSystem

/// A person-row skeleton wears its real row's trailing furniture (#1774):
/// nothing, a time's bone, or an action pill with its ✕.
@MainActor
struct PersonListSkeletonTrailingTests {
    private func firstRowBones(_ trailing: PersonListSkeletonView.Trailing) -> Int {
        let view = PersonListSkeletonView(trailing: trailing)
        view.frame = CGRect(x: 0, y: 0, width: 402, height: 200)
        view.layoutIfNeeded()
        return view.debugFirstRowBoneCount
    }

    @Test func eachTrailingHasItsBones() {
        // Avatar, first line, second line…
        #expect(firstRowBones(.none) == 3)
        // …a time on the first line…
        #expect(firstRowBones(.timeBone) == 4)
        // …Follow or Accept, and the ✕.
        #expect(firstRowBones(.followAndDismiss) == 5)
        #expect(firstRowBones(.acceptAndDismiss) == 5)
        #expect(firstRowBones(.action(pillWidth: 78, dismiss: nil)) == 4)
    }

    @Test func theOldSpellingStillReadsAsATimeBone() {
        let view = PersonListSkeletonView(showsTrailingBone: true)
        view.frame = CGRect(x: 0, y: 0, width: 402, height: 200)
        view.layoutIfNeeded()
        #expect(view.debugFirstRowBoneCount == 4)
    }
}
