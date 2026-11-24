import DesignSystem
import Testing
import UIKit
@testable import ThreadKit

/// The boost bubble as a stake control (#2532): what the session pushes is
/// the bar's total and its menu's context.
@MainActor
struct CommentsInputBarStakeControlTests {
    @Test func showStakeSetsTheTotalAndTheMenusContext() throws {
        let bar = CommentsInputBar()
        let boost = try #require(
            bar.subviews.compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == "Boost post" }
        )

        bar.showStake(
            total: 37,
            state: StakeMenu.State(
                balance: 0, stakedOnTarget: 37, undoable: 5, perTargetCap: 250,
                tapAmount: 1, shotsLeft: 2, shotAmount: 100
            ),
            animated: false
        )

        #expect(boost.accessibilityValue == "37 likes staked")
        // Nothing to afford, but an undo to offer: the menu's door stays open.
        #expect(boost.isEnabled)
        let titles = bar.currentBoostMenuActions().compactMap { ($0 as? UIAction)?.title }
        #expect(titles.first == "×100 — 2 left")
        #expect(titles.last == "Undo stakes (5)")
    }
}
