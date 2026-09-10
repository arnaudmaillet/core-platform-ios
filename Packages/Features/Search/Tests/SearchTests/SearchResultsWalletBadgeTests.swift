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
}
