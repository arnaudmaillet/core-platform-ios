import Testing
import UIKit
@testable import DesignSystem

/// Back buttons are the chevron alone (#727): never the previous title, never
/// "Back".
@MainActor
struct ChevronBackNavigationControllerTests {
    @Test func everyScreenTheStackHoldsLendsAChevronOnlyBackButton() {
        let root = UIViewController()
        let stack = ChevronBackNavigationController(rootViewController: root)
        #expect(root.navigationItem.backButtonDisplayMode == .minimal)

        let pushed = UIViewController()
        pushed.navigationItem.backButtonTitle = "Back"
        stack.pushViewController(pushed, animated: false)
        #expect(pushed.navigationItem.backButtonDisplayMode == .minimal, "a pushed screen would label the next one's back button")

        let replaced = [UIViewController(), UIViewController()]
        stack.setViewControllers(replaced, animated: false)
        #expect(replaced.allSatisfy { $0.navigationItem.backButtonDisplayMode == .minimal })

        let assigned = [UIViewController(), UIViewController()]
        stack.viewControllers = assigned
        #expect(assigned.allSatisfy { $0.navigationItem.backButtonDisplayMode == .minimal })
    }

    @Test func anEmptyStackMarksWhatItIsGiven() {
        let stack = ChevronBackNavigationController()
        let first = UIViewController()
        stack.viewControllers = [first]
        let second = UIViewController()
        stack.pushViewController(second, animated: false)
        #expect(first.navigationItem.backButtonDisplayMode == .minimal)
        #expect(second.navigationItem.backButtonDisplayMode == .minimal)
    }
}
