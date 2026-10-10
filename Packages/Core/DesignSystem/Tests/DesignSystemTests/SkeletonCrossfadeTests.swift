import Testing
import UIKit
@testable import DesignSystem

/// The list-shaped skeleton exit (`crossfadeSkeleton(swapping:)`): the swap
/// always happens, animated only where there is something to see.
@MainActor
struct SkeletonCrossfadeTests {
    /// Off screen the rows are swapped at once: a list built before it is
    /// shown never waits on a transition nobody sees.
    @Test func offScreenTheSwapRunsAtOnce() {
        let list = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        var swapped = false
        list.crossfadeSkeleton { swapped = true }
        #expect(swapped)
        #expect(list.layer.animationKeys() == nil)
    }
}
