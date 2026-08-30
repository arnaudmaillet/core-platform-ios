import CoreModels
import CoreStorage
import DesignSystem
import MediaCore
import Testing
import UIKit
@testable import Feed

/// The boost controls' spend contract — the same on both surfaces that carry
/// one (the rail anchor on media pages, the comments composer's trailing
/// button): a tap asks for the default denomination, the long-press menu
/// offers exactly the policy's denominations, and neither control decides
/// affordability (that verdict is the wallet-holding host's, delivered back
/// as feedback).
@MainActor
struct BoostControlTests {

    // MARK: - Rail anchor

    @Test func railBoostTapAsksForTheDefaultDenomination() {
        let button = SnapRailBoostButton()
        var received: [Int] = []
        button.onBoost = { received.append($0) }

        button.sendActions(for: .primaryActionTriggered)

        #expect(received == [WalletStore.Policy.tapBoostAmount])
    }

    /// Menu order: Max first (a fresh, un-broke context fills the whole
    /// cap), then the fixed denomination(s). Through the builder, not
    /// `menu.children`: the menu is a deferred element resolved only at
    /// present time.
    @Test func railBoostMenuOffersMaxThenTheDenominations() {
        let button = SnapRailBoostButton()
        let actions = button.currentMenuActions().compactMap { $0 as? UIAction }
        var expected = ["Max (\(WalletStore.Policy.perTargetBoostCap) points)"]
        expected += WalletStore.Policy.boostDenominations.reversed().map { "\($0) points" }
        #expect(actions.map(\.title) == expected)
    }

    /// Max asks for the CAP'S REMAINDER bounded by the balance — the "put
    /// everything this post can take" gesture.
    @Test func maxAsksForTheCapRemainderBoundedByBalance() throws {
        let button = SnapRailBoostButton()
        var received: [Int] = []
        button.onBoost = { received.append($0) }

        // Fresh post, deep wallet: Max = the whole cap.
        let full = try #require(button.currentMenuActions().first as? UIAction)
        full.performWithSender(nil, target: nil)
        #expect(received == [WalletStore.Policy.perTargetBoostCap])

        // 60 already on the post, balance 120: Max = the 190 remainder,
        // bounded to 120.
        button.setSpentTotal(60)
        button.setWalletContext(balance: 120, undoableAmount: 0)
        let bounded = try #require(button.currentMenuActions().first as? UIAction)
        #expect(bounded.title == "Max (120 points)")
        bounded.performWithSender(nil, target: nil)
        #expect(received == [WalletStore.Policy.perTargetBoostCap, 120])
    }

    /// A full post disables everything but Undo: Max and the denominations
    /// arrive disabled, and the control itself only stays enabled while a
    /// session spend is takeable.
    @Test func aFullPostRefusesEverythingButUndo() {
        let button = SnapRailBoostButton()
        button.setSpentTotal(WalletStore.Policy.perTargetBoostCap)
        button.setWalletContext(balance: 500, undoableAmount: 0)
        #expect(!button.isEnabled)

        button.setWalletContext(balance: 500, undoableAmount: 30)
        #expect(button.isEnabled)
        let actions = button.currentMenuActions().compactMap { $0 as? UIAction }
        #expect(actions.first?.attributes.contains(.disabled) == true)
        #expect(actions.first { $0.title == "100 points" }?.attributes.contains(.disabled) == true)
        #expect(actions.last?.title == "Undo boosts (30)")
    }

    // MARK: - Affordability & session undo

    /// The control disables only when it has NOTHING to offer: tap
    /// unaffordable AND nothing to undo — a disabled button delivers no
    /// long-press, and the menu is the undo's only door.
    @Test func railAnchorDisablesOnlyWhenBrokeWithNothingToUndo() {
        let button = SnapRailBoostButton()
        #expect(button.isEnabled) // unwired default: historical affordance

        button.setWalletContext(balance: 5, undoableAmount: 0)
        #expect(!button.isEnabled)

        button.setWalletContext(balance: 5, undoableAmount: 10)
        #expect(button.isEnabled)

        button.setWalletContext(balance: WalletStore.Policy.tapBoostAmount, undoableAmount: 0)
        #expect(button.isEnabled)
    }

    /// Denominations the balance can't cover arrive disabled; the Undo
    /// entry exists exactly while a session spend is takeable, and fires
    /// the undo callback.
    @Test func railMenuDisablesUnaffordableAndOffersUndo() throws {
        let button = SnapRailBoostButton()
        button.setWalletContext(balance: 60, undoableAmount: 20)
        var undone = false
        button.onUndo = { undone = true }

        let actions = button.currentMenuActions().compactMap { $0 as? UIAction }
        // Max (bounded to the 60 balance) enabled, 100 unaffordable,
        // plus the Undo entry.
        #expect(actions.count == WalletStore.Policy.boostDenominations.count + 2)
        let byTitle = { (title: String) in actions.first { $0.title.hasPrefix(title) } }
        #expect(byTitle("Max (60 points)")?.attributes.contains(.disabled) == false)
        #expect(byTitle("100 points")?.attributes.contains(.disabled) == true)

        let undo = try #require(byTitle("Undo boosts (20)"))
        undo.performWithSender(nil, target: nil)
        #expect(undone)

        // Nothing undoable → no entry.
        button.setWalletContext(balance: 60, undoableAmount: 0)
        #expect(button.currentMenuActions().count == WalletStore.Policy.boostDenominations.count + 1)
    }

    @Test func composerBoostSharesTheSameContextContract() throws {
        let bar = CommentsInputBar()
        let boost = try #require(
            bar.subviews.compactMap { $0 as? UIButton }
                .first { $0.accessibilityLabel == "Boost post" }
        )
        bar.setBoostContext(balance: 3, undoableAmount: 0)
        #expect(!boost.isEnabled)
        bar.setBoostContext(balance: 3, undoableAmount: 50)
        #expect(boost.isEnabled)

        var undone = false
        bar.onBoostUndo = { undone = true }
        let actions = bar.currentBoostMenuActions().compactMap { $0 as? UIAction }
        let undo = try #require(actions.first { $0.title == "Undo boosts (50)" })
        undo.performWithSender(nil, target: nil)
        #expect(undone)
    }

    // MARK: - Comments composer

    @Test func composerBoostTapAsksForTheDefaultDenomination() throws {
        let bar = CommentsInputBar()
        var received: [Int] = []
        bar.onBoost = { received.append($0) }

        let boost = try #require(
            bar.subviews.compactMap { $0 as? UIButton }
                .first { $0.accessibilityLabel == "Boost post" }
        )
        boost.sendActions(for: .primaryActionTriggered)

        #expect(received == [WalletStore.Policy.tapBoostAmount])
    }

    @Test func composerBoostCarriesTheTrendingGlyphAndAMenu() throws {
        let bar = CommentsInputBar()
        let boost = try #require(
            bar.subviews.compactMap { $0 as? UIButton }
                .first { $0.accessibilityLabel == "Boost post" }
        )
        // The star face, not the "+" this slot used to wear.
        #expect(boost.configuration?.image != nil)
        // Long-press: Max + the denominations (deferred menu — counted
        // through the builder), tap kept as the primary action.
        #expect(boost.menu != nil)
        #expect(bar.currentBoostMenuActions().count == WalletStore.Policy.boostDenominations.count + 1)
        #expect(boost.showsMenuAsPrimaryAction == false)
    }

    // MARK: - The spent-total (receipt) face

    /// A spend flips the anchor from the star glyph to the gold number,
    /// and clearing it flips back — one face at a time, never both.
    @Test func railAnchorSwapsGlyphForSpentTotalAndBack() {
        let button = SnapRailBoostButton()
        #expect(button.configuration?.image != nil)
        #expect(button.configuration?.attributedTitle == nil)

        button.setSpentTotal(60)
        #expect(button.configuration?.image == nil)
        let title = button.configuration?.attributedTitle
        #expect(title.map { String($0.characters) } == "60")
        #expect(button.accessibilityValue == "60 points spent")

        button.setSpentTotal(0)
        #expect(button.configuration?.image != nil)
        #expect(button.configuration?.attributedTitle == nil)
        #expect(button.accessibilityValue == nil)
    }

    /// Large receipts wear the app's one compact spelling, same as every
    /// other count on screen.
    @Test func railAnchorSpellsTheReceiptCompactly() {
        let button = SnapRailBoostButton()
        button.setSpentTotal(1_240)
        let title = button.configuration?.attributedTitle
        #expect(title.map { String($0.characters) } == "1.2K")
    }

    @Test func composerBoostSwapsGlyphForSpentTotalAndBack() throws {
        let bar = CommentsInputBar()
        let boost = try #require(
            bar.subviews.compactMap { $0 as? UIButton }
                .first { $0.accessibilityLabel == "Boost post" }
        )
        bar.setBoostTotal(60)
        #expect(boost.configuration?.image == nil)
        #expect((boost.configuration?.attributedTitle).map { String($0.characters) } == "60")

        bar.setBoostTotal(0)
        #expect(boost.configuration?.image != nil)
        #expect(boost.configuration?.attributedTitle == nil)
    }

    // MARK: - The feed header's balance badge

    /// With a wallet injected the trailing run closes with the badge —
    /// [‹ back] … [🪙 solde] [author pill] — in BOTH engagement states
    /// (`rightBarButtonItems` is indexed right-to-left, so the badge is the
    /// LAST item), spacer-separated so iOS 26 keeps the pills apart.
    @Test func feedTrailingRunEndsWithTheWalletBadgeWhenAWalletIsWired() throws {
        let (feed, _) = Self.walletFeed()

        let resting = feed.navigationItem.rightBarButtonItems ?? []
        #expect(resting.count == 3)
        #expect(resting[0].customView is SnapAuthorIdentityView)
        #expect(resting[1].customView == nil) // the fixed space
        #expect(resting[2].customView is WalletBadgeButton)

        // ⚠️ THE BADGE HOLDS ITS PLACE THROUGH THE ENGAGEMENT; the OUTERMOST
        // item is what changes. The sort used to join this run — first inboard
        // of the author, then outboard of the badge — and neither read: it is a
        // control over the thread, not a fact about the post, and it sits
        // beside the back arrow now. What does belong here is the ✕, which
        // takes the author's slot while a media post's thread is open: the
        // balance is still one in from the edge, whatever is at the edge.
        feed.setEngagedChrome(true, hasMedia: true, animated: false)
        let engaged = feed.navigationItem.rightBarButtonItems ?? []
        #expect(engaged.count == 3)
        #expect((engaged[0].customView as? UIButton)?.accessibilityLabel == "Close comments")
        #expect(engaged[1] == resting[1])   // the same fixed space
        #expect(engaged[2] == resting[2])   // …and the same badge
        #expect(engaged.contains { $0.customView is SnapCommentSortButton } == false)

        feed.setEngagedChrome(false, hasMedia: true, animated: false)
        #expect((feed.navigationItem.rightBarButtonItems ?? []).count == 3)
    }

    /// No wallet → the historical author-only run, untouched. This is the
    /// contract that keeps every older bar test green.
    @Test func feedTrailingRunIsUnchangedWithoutAWallet() {
        let feed = SnapFeedViewController(
            viewModel: FeedViewModel(repository: InertFeedProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        feed.loadViewIfNeeded()
        #expect((feed.navigationItem.rightBarButtonItems ?? []).count == 1)
    }

    /// The header badge renders the live balance and re-renders on a spend —
    /// the store's scoped change post, heard by the same screen that spent.
    @Test func feedHeaderBadgeTracksTheBalance() throws {
        let (feed, wallet) = Self.walletFeed()
        let badge = try #require(
            (feed.navigationItem.rightBarButtonItems ?? [])
                .compactMap { $0.customView as? WalletBadgeButton }.first
        )
        #expect(badge.renderedCount == wallet.balance.formattedCompact())

        wallet.boost(targetID: "post-x", amount: 10)
        // The observer hops through OperationQueue.main; drain it.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(badge.renderedCount == wallet.balance.formattedCompact())
    }

    // MARK: - Helpers

    private static func walletFeed() -> (SnapFeedViewController, WalletStore) {
        let suite = "boost-control-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let wallet = WalletStore(defaults: defaults)
        let feed = SnapFeedViewController(
            viewModel: FeedViewModel(repository: InertFeedProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            wallet: wallet
        )
        feed.loadViewIfNeeded()
        return (feed, wallet)
    }
}

/// The empty provider, restated: the presentation suite's own is file-private
/// (test files don't share private helpers), and these tests need nothing
/// more than a feed that renders zero pages.
private final class InertFeedProvider: FeedProviding, @unchecked Sendable {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPage(afterToken token: String) async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPost(_ id: PostID) async throws -> FeedEntry {
        FeedEntry(
            post: Post(
                id: id, authorID: ProfileID("p"), caption: "hi",
                attachments: [], publishedAt: Date(timeIntervalSince1970: 0)
            ),
            author: AuthorSummary(
                id: ProfileID("p"), handle: "ava", displayName: "Ava", avatarURL: nil
            ),
            likeCount: 0
        )
    }
}
