import CoreNavigation
import Testing
import UIKit
@testable import Chat

/// A re-tap on the Messages tab brings the page in front back to its first
/// row (#1309).
@MainActor
struct InboxTabReselectTests {
    private func list(offset: CGFloat, inset: CGFloat = 100) -> UIScrollView {
        let list = UIScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        list.contentInsetAdjustmentBehavior = .never
        list.contentInset.top = inset
        list.contentSize = CGSize(width: 400, height: 4000)
        list.contentOffset.y = offset
        return list
    }

    @Test func aScrolledListGoesBackToItsFirstRowUnderTheHeader() {
        let list = list(offset: 1200)
        MessagesInboxViewController.scrollToTop(list, animated: false)
        #expect(list.contentOffset.y == -100)
    }

    /// A list pulled past its top is already there: never scrolled down.
    @Test func aListAtOrAboveItsTopIsLeftAlone() {
        let list = list(offset: -160)
        MessagesInboxViewController.scrollToTop(list, animated: false)
        #expect(list.contentOffset.y == -160)
    }
}
