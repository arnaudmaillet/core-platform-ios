import DesignSystem
import Foundation
import Testing
import UIKit
@testable import Maps

/// THE SHOP'S SHELF STEPS (#1887): one `step` per item crossed under the
/// finger or in its glide; none for a scroll the viewer did not make.
@MainActor
struct ShopShelfHapticTests {
    private func shelf() -> ShopShelfView {
        let items = (0..<6).map { _ in (UIView(), CGFloat(140)) }
        let shelf = ShopShelfView(heading: .init(title: "Packs", isLink: false), items: items, vertical: false)
        shelf.frame = CGRect(x: 0, y: 0, width: 402, height: 220)
        shelf.layoutIfNeeded()
        return shelf
    }

    /// Where item `index` rests: its leading edge on the margin.
    private func rest(_ index: Int, in shelf: ShopShelfView) -> CGFloat {
        let item = shelf.items[index]
        return item.convert(item.bounds, to: shelf.row).minX - ShopStorefrontViewController.Metrics.margin
    }

    @Test func theShelfStepsOncePerItemCrossed() throws {
        let shelf = shelf()
        try #require(rest(3, in: shelf) > rest(0, in: shelf), "guard: the items are laid out in a row")
        shelf.debugIsDriven = true
        let recorder = HapticRecorder()
        var now: TimeInterval = 0
        recorder.clock = { now }
        Haptics.$recorder.withValue(recorder) {
            for (index, nudge) in [(0, 10.0), (1, 0), (1, 20), (2, 0), (3, 0)] {
                now += 1
                shelf.row.contentOffset.x = rest(index, in: shelf) + nudge
            }
        }
        #expect(recorder.played == [.step, .step, .step], "\(recorder.played)")
    }

    @Test func aProgrammaticScrollIsSilent() {
        let shelf = shelf()
        shelf.debugIsDriven = false
        let played = HapticRecorder.recording {
            shelf.row.contentOffset.x = rest(2, in: shelf)
            shelf.row.contentOffset.x = rest(4, in: shelf)
        }
        #expect(played.isEmpty, "\(played)")
    }
}
