import Testing
import UIKit
@testable import Feed

/// CHROME BUILT AHEAD (#2126): opening a post builds its first cell's chrome
/// and the flight's replica in the tap's turn. Both take a spare built at
/// rest when one is ready; a spare is what `init` leaves, so nothing a page
/// shows depends on which it got.
@MainActor
@Suite(.serialized)
struct SnapChromeSparesTests {
    @Test func aTakeUsesASpareAndAnEmptyStockStillBuilds() {
        SnapChromeView.debugRestock()
        #expect(SnapChromeView.debugSpareCount == SnapChromeView.spareCapacity)

        let first = SnapChromeView.make()
        #expect(SnapChromeView.debugSpareCount == SnapChromeView.spareCapacity - 1, "the take built its own")
        #expect(first.superview == nil && first.window == nil)

        // Drained: the next takes build their own, synchronously.
        for _ in 0..<SnapChromeView.spareCapacity { _ = SnapChromeView.make() }
        #expect(SnapChromeView.debugSpareCount == 0)
        let built = SnapChromeView.make()
        #expect(built.superview == nil)
    }

    /// The page's cell takes from the stock (the replica's take is pinned
    /// in `SnapDeviceRound2Tests`).
    @Test func theCellTakesASpare() {
        SnapChromeView.debugRestock()
        _ = SnapFeedCell(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        #expect(SnapChromeView.debugSpareCount == SnapChromeView.spareCapacity - 1, "the cell built its own chrome")
    }
}
