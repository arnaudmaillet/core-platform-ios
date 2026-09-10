import CoreModels
import CoreStorage
import DesignSystem
import Foundation
import MediaCore
import Testing
import UIKit
@testable import Search

/// The credit badge in the results header, and the arithmetic that keeps it
/// beside the query rather than instead of it.
@MainActor
struct SearchResultsWalletBadgeTests {

    private actor StubProvider: SearchProviding {
        func searchProfiles(
            matching query: String, sort: SearchSortOrder, limit: Int32
        ) async throws -> [ProfileSearchResult] { [] }
        func suggestions(forPrefix prefix: String, limit: Int32) async throws -> [SearchSuggestion] { [] }
    }

    private func makeScreen(
        wallet: WalletStore?,
        sheet: (@MainActor () -> UIViewController)? = { UIViewController() }
    ) -> SearchResultsViewController {
        let screen = SearchResultsViewController(
            viewModel: SearchViewModel(repository: StubProvider(), router: nil),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            postSurfaces: nil,
            wallet: wallet,
            makeWalletSheet: wallet == nil ? nil : sheet
        )
        screen.loadViewIfNeeded()
        return screen
    }

    private func isolatedWallet() -> WalletStore {
        WalletStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    /// ⚠️ `[0]` IS THE SCREEN EDGE, so this order renders left-to-right as
    /// `[back][credit][query]` — which is the arrangement that was asked for,
    /// and the reason the badge is a TRAILING item rather than a leading one.
    @Test func theCreditSitsInboardOfTheQuery() {
        let screen = makeScreen(wallet: isolatedWallet())
        let items = screen.navigationItem.rightBarButtonItems

        #expect(items?.count == 2)
        #expect(items?.first?.customView is UITextField)
        #expect(items?.last?.customView is WalletBadgeButton)
    }

    /// ⚠️ ONE PILL AROUND BOTH READS AS A SEGMENTED CONTROL. iOS 26 gives a
    /// trailing group a shared background unless each item opts out.
    @Test func neitherTrailingItemSharesABackground() {
        let screen = makeScreen(wallet: isolatedWallet())
        #expect(screen.navigationItem.rightBarButtonItems?.allSatisfy { !$0.sharesBackground } == true)
    }

    /// ⚠️ THE LEADING GROUP STAYS EMPTY, and that is what keeps the interactive
    /// edge pop alive: a custom leading item makes `NativePopPolicy` refuse the
    /// begin unless `leftItemsSupplementBackButton` is true, and the failure is
    /// silent because the chevron still works.
    @Test func theBadgeDoesNotTouchThePopPolicy() {
        let screen = makeScreen(wallet: isolatedWallet())
        #expect(screen.navigationItem.leftBarButtonItems?.isEmpty != false)
        #expect(screen.navigationItem.leftItemsSupplementBackButton == false)
        #expect(screen.navigationItem.hidesBackButton == false)
    }

    /// A composition with no wallet grows no badge — which is also why the rest
    /// of this suite's screens still have exactly one trailing item.
    @Test func aCompositionWithoutAWalletWearsNoBadge() {
        let screen = makeScreen(wallet: nil)
        #expect(screen.navigationItem.rightBarButtonItems?.count == 1)
        #expect(screen.navigationItem.rightBarButtonItems?.first?.customView is UITextField)
    }

    /// ⚠️ THE FIELD PAYS FOR THE BADGE, AND NEVER THE OTHER WAY. Both of this
    /// screen's `•••` burns were REQUIRED widths; the field's is `.defaultHigh`
    /// with a required 44 floor, so a badge that grows narrows the field rather
    /// than overflowing the bar.
    @Test func theFieldYieldsWidthToTheBadgeAndNeverBelowABubble() {
        let bare = SearchResultsViewController.queryWidth(inBarOfWidth: 402, walletWanted: 0)
        let withBadge = SearchResultsViewController.queryWidth(inBarOfWidth: 402, walletWanted: 71)
        let wider = SearchResultsViewController.queryWidth(inBarOfWidth: 402, walletWanted: 86)

        #expect(bare == 294)
        #expect(withBadge == 188)
        #expect(wider < withBadge, "a wider badge must never widen the field")

        // The narrowest bar the app supports, with the widest count the compact
        // spelling can produce, still leaves a control rather than a stub.
        let squeezed = SearchResultsViewController.queryWidth(inBarOfWidth: 375, walletWanted: 86)
        #expect(squeezed >= NavigationBarMetrics.itemPlatterHeight)
    }

    /// ⚠️ **A LEADING ITEM IS CHARGED TOO, AND THE FIELD PAYS FOR IT AS WELL.**
    /// The bar can read `[back][filter][credit][field]`, and a leading glyph
    /// that was not charged is a `•••` on the narrow device — the failure this
    /// whole function exists to prevent.
    ///
    /// The numbers are read off `-header-bar-tree` at 375pt rather than
    /// derived: back 16..60, filter 72..131, credit 162..242, field 254..359.
    /// The gap to the chevron is TWELVE — the two wear their own platters, so
    /// the 27pt shared-pill spacing does not apply.
    ///
    /// ⚠️ **AND THE PLATTER IS WIDER THAN THE VIEW IN IT — this test is what
    /// found that.** The first version charged what the button's
    /// `systemLayoutSizeFitting` returns, asserted the 105 the bar drew, and
    /// got 90: a glyph button fits UNDER the 44pt touch target while UIKit
    /// draws its platter at 59. Under-charging by 15 is the direction that ends
    /// in a `•••`, and it only survived the device because the badge's own
    /// charge over-states by about the same amount — two errors cancelling,
    /// which is not a budget.
    @Test func theFieldPaysForALeadingItemAsWell() {
        let without = SearchResultsViewController.queryWidth(inBarOfWidth: 375, walletWanted: 71)
        let with = SearchResultsViewController.queryWidth(
            inBarOfWidth: 375, walletWanted: 71, leadingWanted: 43
        )
        #expect(with == without - (SearchResultsViewController.glyphItemPlatterWidth + 12))

        // A leading item that WANTS more than the glyph platter is charged what
        // it wants, plus the platter's own inset either side. Asked on a 402pt
        // bar, because at 375 this lands under the 44pt floor and the floor —
        // correctly — answers instead of the arithmetic.
        let wide = SearchResultsViewController.queryWidth(inBarOfWidth: 402, walletWanted: 71)
        #expect(SearchResultsViewController.queryWidth(
            inBarOfWidth: 402, walletWanted: 71, leadingWanted: 90
        ) == wide - (90 + 16 + 12))

        // And the floor still holds at the narrowest bar with everything on it.
        #expect(SearchResultsViewController.queryWidth(
            inBarOfWidth: 375, walletWanted: 86, leadingWanted: 43
        ) >= NavigationBarMetrics.itemPlatterHeight)
    }
}
