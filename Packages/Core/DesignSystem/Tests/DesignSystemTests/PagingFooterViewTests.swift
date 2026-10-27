import Foundation
import Testing
import UIKit
@testable import DesignSystem

/// The one paging footer (#1768): a spinner while the next page comes,
/// "Couldn't load more. Try Again" after one failed, nothing otherwise.
@MainActor
struct PagingFooterViewTests {
    @Test func itSpinsOnlyWhileLoading() {
        let footer = PagingFooterView()
        #expect(!footer.isSpinning && !footer.showsFailure)
        footer.setSpinning(true)
        #expect(footer.isSpinning && !footer.showsFailure)
        #expect(footer.accessibilityLabel == "Loading more")
        footer.setSpinning(false)
        #expect(!footer.isSpinning)
        #expect(footer.accessibilityElementsHidden)
    }

    @Test func aFailedPageOffersTryAgain() {
        let footer = PagingFooterView(state: .loading)
        var retries = 0
        footer.onRetry = { retries += 1 }
        #expect(footer.isUserInteractionEnabled)
        footer.debugTapRetry()
        #expect(retries == 0, "a retry while still loading")
        footer.state = .failed
        #expect(!footer.isSpinning && footer.showsFailure)
        #expect(footer.accessibilityTraits.contains(.button))
        footer.debugTapRetry()
        #expect(retries == 1)
    }

    @Test func aListRowIsTappedOnlyWhenFailed() {
        let cell = PagingFooterCell(frame: CGRect(x: 0, y: 0, width: 320, height: 56))
        cell.configure(.loading)
        #expect(cell.footer.isSpinning)
        #expect(!cell.isUserInteractionEnabled)
        cell.configure(.failed)
        #expect(cell.isUserInteractionEnabled)
        #expect(cell.accessibilityLabel == "Couldn't load more. Try Again")
        cell.prepareForReuse()
        #expect(!cell.footer.isSpinning)
    }

    @Test func aSectionFooterSpinsWhileShown() {
        let view = PagingFooterSupplementaryView(frame: CGRect(x: 0, y: 0, width: 320, height: 56))
        #expect(view.footer.isSpinning)
        view.footer.state = .idle
        view.prepareForReuse()
        #expect(view.footer.isSpinning)
    }
}
