import Testing
import UIKit
@testable import DesignSystem

/// #2577: in a real navigation bar, `[bell][selector] ——— [✎]`, the gap the
/// bar DRAWS between the bell's platter and the selector's equals the one
/// between the selector's and the trailing item's, to within a point — the
/// budget an estimate, the balance measured on what UIKit laid out.
@MainActor
struct BarSelectorBalanceTests {
    private final class Screen: UIViewController {}

    @Test(arguments: [CGSize(width: 402, height: 874), CGSize(width: 375, height: 667)])
    func theDrawnGapsAreEqualOnEachSideOfTheSelector(size: CGSize) async throws {
        let strip = PagedTabBar(titles: ["Chats", "Requests", "Suggestions"], style: .navigationTitle)
        strip.setBadge(44, at: 0)
        strip.setBadge(8, at: 1)
        let selector = BarSelectorItem(strip: strip, id: "test.selector")
        let bell = BarItems.icon(id: "test.bell", image: UIImage(systemName: "bell"), label: "Bell", action: {})
        bell.sharesBackground = false
        let compose = BarItems.icon(
            id: "test.compose", image: UIImage(systemName: "square.and.pencil"), label: "Compose", action: {}
        )
        let screen = Screen()
        let navigation = UINavigationController(rootViewController: screen)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = navigation
        window.isHidden = false
        defer { window.isHidden = true }
        let bar = navigation.navigationBar
        let budget = BarSelectorBudget(
            barWidth: size.width,
            leadingWidths: [BarSelectorBudget.width(of: bell)],
            trailingWidths: [BarSelectorBudget.width(of: compose)]
        )
        selector.fit(budget)
        screen.navigationItem.rightBarButtonItems = [compose]
        screen.navigationItem.leftBarButtonItems = selector.leadingGroup(after: bell)
        window.layoutIfNeeded()

        // The bar hosts its items over a few turns; each balance is laid out
        // again before the next is measured.
        let label = "\(Int(size.width))pt"
        for _ in 0..<100 where selector.drawnGaps(in: bar) == nil {
            try await Task.sleep(for: .milliseconds(50))
            bar.layoutIfNeeded()
        }
        let first = try #require(selector.drawnGaps(in: bar), "\(label): the selector or a neighbour is not in the bar")
        for _ in 0..<6 where selector.balanceGaps(in: bar, budget: budget) {
            bar.setNeedsLayout()
            bar.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            bar.layoutIfNeeded()
        }

        #expect(selector.isHosted, "\(label): the balance swept the selector into a •••")
        let gaps = try #require(selector.drawnGaps(in: bar), "\(label): a neighbour left the bar")
        if budget.balancesGaps {
            #expect(abs(gaps.leading - gaps.trailing) <= 1,
                    "\(label): bell → selector \(gaps.leading), selector → compose \(gaps.trailing)")
            // A sweep a widening balance tipped steps back a point, and the
            // balance never widens past it again (UIKit: 12 drew, 11 swept).
            if selector.balance > 0 {
                let balanced = strip.intrinsicContentSize.width
                #expect(selector.narrowAfterOverflow(budget))
                #expect(abs(strip.intrinsicContentSize.width - (balanced - 1)) < 0.5, "\(label)")
                #expect(selector.trim == 0, "\(label): a trim where a point was enough")
                #expect(!selector.balanceGaps(in: bar, budget: budget), "\(label): widened past the sweep")
                #expect(abs(strip.intrinsicContentSize.width - (balanced - 1)) < 0.5, "\(label)")
            }
        } else {
            // iOS 26: the bar keeps its own gap before the trailing group, and
            // the selector is not balanced against it.
            #expect(selector.balance == 0 && gaps.trailing >= first.trailing - 0.5, "\(label): \(gaps)")
        }
    }
}
