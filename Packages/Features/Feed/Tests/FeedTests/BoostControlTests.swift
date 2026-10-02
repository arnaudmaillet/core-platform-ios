import CoreModels
import CoreStorage
import DesignSystem
import MediaCore
import Testing
import UIKit
@testable import Feed

/// The boost controls' spend contract — the same on both surfaces that carry
/// one (the rail anchor on media pages, the comments composer's trailing
/// button): a tap asks for the DEFAULT amount, the long-press menu offers the
/// default and the ×10 shot (live only with a pack loaded), and neither
/// control decides affordability (that verdict is the wallet-holding host's,
/// delivered back as feedback).
@MainActor
struct BoostControlTests {

    /// The user's call (2026-10-02): one point a tap. Every surface below
    /// reads it from the one constant.
    @Test func theDefaultStakeIsOnePoint() {
        #expect(WalletStore.Policy.defaultStakeAmount == 1)
        #expect(WalletStore.Policy.StakePack.pointsPerShot == 10)
    }

    // MARK: - Rail anchor

    @Test func railBoostTapAsksForTheDefaultAmount() {
        let button = SnapRailBoostButton()
        var received: [WalletStakeSpend] = []
        button.onBoost = { received.append($0) }

        button.sendActions(for: .primaryActionTriggered)

        #expect(received == [.points(WalletStore.Policy.defaultStakeAmount)])
    }

    /// No pack: the menu offers the default amount and a disabled ×10 that
    /// points to the Shop — no Max, no 100. Through the builder, not
    /// `menu.children`: the menu is a deferred element resolved only at
    /// present time.
    @Test func railMenuWithoutAPackOffersOnlyTheDefault() {
        let button = SnapRailBoostButton()
        button.setWalletContext(balance: 200, undoableAmount: 0)
        let actions = button.currentMenuActions().compactMap { $0 as? UIAction }
        #expect(actions.map(\.title) == ["×10", StakeMenu.points(WalletStore.Policy.defaultStakeAmount)])
        #expect(actions[0].attributes.contains(.disabled))
        #expect(actions[1].attributes.contains(.disabled) == false)
    }

    /// A loaded pack: "×10 — N left", and picking it asks for a SHOT.
    @Test func railMenuWithAPackAsksForAShot() throws {
        let button = SnapRailBoostButton()
        var received: [WalletStakeSpend] = []
        button.onBoost = { received.append($0) }
        button.setWalletContext(balance: 200, undoableAmount: 0, stakeShots: 7)

        let shot = try #require(button.currentMenuActions().first as? UIAction)
        #expect(shot.title == "×10 — 7 left")
        shot.performWithSender(nil, target: nil)
        #expect(received == [.shot])
    }

    /// A full post disables everything but Undo: the control itself only
    /// stays enabled while a session spend is takeable.
    @Test func aFullPostRefusesEverythingButUndo() {
        let button = SnapRailBoostButton()
        button.setSpentTotal(WalletStore.Policy.perTargetBoostCap)
        button.setWalletContext(balance: 500, undoableAmount: 0, stakeShots: 5)
        #expect(!button.isEnabled)

        button.setWalletContext(balance: 500, undoableAmount: 30, stakeShots: 5)
        #expect(button.isEnabled)
        let actions = button.currentMenuActions().compactMap { $0 as? UIAction }
        #expect(actions.dropLast().allSatisfy { $0.attributes.contains(.disabled) })
        #expect(actions.last?.title == "Undo stakes (30)")
    }

    // MARK: - Affordability & session undo

    /// The control disables only when it has NOTHING to offer: tap
    /// unaffordable AND nothing to undo — a disabled button delivers no
    /// long-press, and the menu is the undo's only door.
    @Test func railAnchorDisablesOnlyWhenBrokeWithNothingToUndo() {
        let button = SnapRailBoostButton()
        #expect(button.isEnabled) // unwired default: historical affordance

        button.setWalletContext(balance: 0, undoableAmount: 0)
        #expect(!button.isEnabled)

        button.setWalletContext(balance: 0, undoableAmount: 10)
        #expect(button.isEnabled)

        button.setWalletContext(balance: WalletStore.Policy.defaultStakeAmount, undoableAmount: 0)
        #expect(button.isEnabled)
    }

    /// The Undo entry exists exactly while a session spend is takeable, and
    /// fires the undo callback.
    @Test func railMenuOffersUndoOnlyWhileTakeable() throws {
        let button = SnapRailBoostButton()
        button.setWalletContext(balance: 60, undoableAmount: 20)
        var undone = false
        button.onUndo = { undone = true }

        let actions = button.currentMenuActions().compactMap { $0 as? UIAction }
        #expect(actions.count == 3)
        let undo = try #require(actions.first { $0.title == "Undo stakes (20)" })
        undo.performWithSender(nil, target: nil)
        #expect(undone)

        // Nothing undoable → no entry.
        button.setWalletContext(balance: 60, undoableAmount: 0)
        #expect(button.currentMenuActions().count == 2)
    }

    @Test func composerBoostSharesTheSameContextContract() throws {
        let bar = CommentsInputBar()
        let boost = try #require(
            bar.subviews.compactMap { $0 as? UIButton }
                .first { $0.accessibilityLabel == "Boost post" }
        )
        bar.setBoostContext(balance: 0, undoableAmount: 0)
        #expect(!boost.isEnabled)
        bar.setBoostContext(balance: 0, undoableAmount: 50)
        #expect(boost.isEnabled)

        var undone = false
        bar.onBoostUndo = { undone = true }
        let actions = bar.currentBoostMenuActions().compactMap { $0 as? UIAction }
        let undo = try #require(actions.first { $0.title == "Undo stakes (50)" })
        undo.performWithSender(nil, target: nil)
        #expect(undone)
    }

    /// The composer's menu is the rail's: the shot, live with a pack.
    @Test func composerMenuWithAPackAsksForAShot() throws {
        let bar = CommentsInputBar()
        var received: [WalletStakeSpend] = []
        bar.onBoost = { received.append($0) }
        bar.setBoostContext(balance: 200, undoableAmount: 0, stakeShots: 2)

        let shot = try #require(bar.currentBoostMenuActions().first as? UIAction)
        #expect(shot.title == "×10 — 2 left")
        shot.performWithSender(nil, target: nil)
        #expect(received == [.shot])
    }

    // MARK: - Comments composer

    @Test func composerBoostTapAsksForTheDefaultAmount() throws {
        let bar = CommentsInputBar()
        var received: [WalletStakeSpend] = []
        bar.onBoost = { received.append($0) }

        let boost = try #require(
            bar.subviews.compactMap { $0 as? UIButton }
                .first { $0.accessibilityLabel == "Boost post" }
        )
        boost.sendActions(for: .primaryActionTriggered)

        #expect(received == [.points(WalletStore.Policy.defaultStakeAmount)])
    }

    @Test func composerBoostCarriesTheTrendingGlyphAndAMenu() throws {
        let bar = CommentsInputBar()
        let boost = try #require(
            bar.subviews.compactMap { $0 as? UIButton }
                .first { $0.accessibilityLabel == "Boost post" }
        )
        // The star face, not the "+" this slot used to wear.
        #expect(boost.configuration?.image != nil)
        // Long-press: the ×10 shot + the default (deferred menu — counted
        // through the builder), tap kept as the primary action.
        #expect(boost.menu != nil)
        #expect(bar.currentBoostMenuActions().count == 2)
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
