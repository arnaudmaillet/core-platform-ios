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
/// default and the ×100 shot (live only with a pack loaded; without one, the
/// way to the Shop), and neither
/// control decides affordability (that verdict is the wallet-holding host's,
/// delivered back as feedback).
@MainActor
struct BoostControlTests {

    /// The user's call (2026-10-02): one point a tap. Every surface below
    /// reads it from the one constant.
    @Test func theDefaultStakeIsOnePoint() {
        #expect(WalletStore.Policy.defaultStakeAmount == 1)
        #expect(WalletStore.Policy.StakePack.pointsPerShot == 100)
    }

    // MARK: - Rail anchor

    @Test func railBoostTapAsksForTheDefaultAmount() {
        let button = SnapRailBoostButton()
        var received: [WalletStakeSpend] = []
        button.onBoost = { received.append($0) }

        button.sendActions(for: .primaryActionTriggered)

        #expect(received == [.points(WalletStore.Policy.defaultStakeAmount)])
    }

    /// No pack, no Shop above: the menu offers the default amount and a
    /// disabled ×100 that points to the Shop — no Max, no free 100. Through
    /// the builder, not `menu.children`: the menu is a deferred element
    /// resolved only at present time.
    @Test func railMenuWithoutAPackOffersOnlyTheDefault() {
        let button = SnapRailBoostButton()
        button.setWalletContext(balance: 200, undoableAmount: 0)
        let actions = button.currentMenuActions().compactMap { $0 as? UIAction }
        #expect(actions.map(\.title) == ["×100", StakeMenu.points(WalletStore.Policy.defaultStakeAmount)])
        #expect(actions[0].subtitle == "Get ×100 cartridges in the Shop")
        #expect(actions[0].attributes.contains(.disabled))
        #expect(actions[1].attributes.contains(.disabled) == false)
    }

    /// No pack, under a screen that opens the Shop (the shell, up the
    /// responder chain): the ×100 row is enabled and asks THAT opener for the
    /// Shop — it stakes nothing.
    @Test func railMenuWithoutAPackOpensTheShop() throws {
        let screen = ShopOpenerSpy()
        let button = SnapRailBoostButton()
        screen.view.addSubview(button)
        var received: [WalletStakeSpend] = []
        button.onBoost = { received.append($0) }
        button.setWalletContext(balance: 200, undoableAmount: 0)

        let row = try #require(button.currentMenuActions().first as? UIAction)
        #expect(row.title == "×100")
        #expect(row.attributes.contains(.disabled) == false)
        row.performWithSender(nil, target: nil)

        #expect(screen.asked == 1)
        #expect(received.isEmpty)
    }

    /// Short of a shot's 100 points, or of room for them on the post, the
    /// loaded shot is refused — and says which.
    @Test func railShotNeedsAHundredPointsAndRoomForThem() throws {
        let button = SnapRailBoostButton()
        button.setWalletContext(balance: 99, undoableAmount: 0, stakeShots: 2)
        let broke = try #require(button.currentMenuActions().first as? UIAction)
        #expect(broke.attributes.contains(.disabled))
        #expect(broke.subtitle == "Not enough points")

        button.setSpentTotal(200)
        button.setWalletContext(balance: 250, undoableAmount: 0, stakeShots: 2)
        // Under the "You staked" line the snap feed's menu now opens with.
        let full = try #require(
            button.currentMenuActions().compactMap { $0 as? UIAction }.first { $0.title.hasPrefix("×100") }
        )
        #expect(full.attributes.contains(.disabled))
        #expect(full.subtitle == "Only 50 points more fit on this post")
    }

    /// A loaded pack: "×100 — N left", and picking it asks for a SHOT.
    @Test func railMenuWithAPackAsksForAShot() throws {
        let button = SnapRailBoostButton()
        var received: [WalletStakeSpend] = []
        button.onBoost = { received.append($0) }
        button.setWalletContext(balance: 200, undoableAmount: 0, stakeShots: 2)

        let shot = try #require(button.currentMenuActions().first as? UIAction)
        #expect(shot.title == "×100 — 2 left")
        #expect(shot.subtitle == "100 points in one tap")
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
        #expect(shot.title == "×100 — 2 left")
        shot.performWithSender(nil, target: nil)
        #expect(received == [.shot])
    }

    /// The composer's empty-pack row opens the Shop, as the rail's does.
    @Test func composerMenuWithoutAPackOpensTheShop() throws {
        let screen = ShopOpenerSpy()
        let bar = CommentsInputBar()
        screen.view.addSubview(bar)
        var received: [WalletStakeSpend] = []
        bar.onBoost = { received.append($0) }
        bar.setBoostContext(balance: 200, undoableAmount: 0)

        let row = try #require(bar.currentBoostMenuActions().first as? UIAction)
        #expect(row.title == "×100")
        #expect(row.attributes.contains(.disabled) == false)
        row.performWithSender(nil, target: nil)

        #expect(screen.asked == 1)
        #expect(received.isEmpty)
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
        // Long-press: the ×100 shot + the default (deferred menu — counted
        // through the builder), tap kept as the primary action.
        #expect(boost.menu != nil)
        #expect(bar.currentBoostMenuActions().count == 2)
        #expect(boost.showsMenuAsPrimaryAction == false)
    }

    // MARK: - The like face (#668)

    private static let railGlyph = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)

    private static func drawn(_ image: UIImage?) -> Data? { image?.pngData() }

    /// A heart either way: white while the viewer has staked nothing, the
    /// points' red once they have — never a number in its place.
    @Test func railHeartIsWhiteAtRestRedOnceStakedNeverANumber() {
        let white = Self.drawn(PointsSymbol.likeImage(staked: false, Self.railGlyph))
        let red = Self.drawn(PointsSymbol.likeImage(staked: true, Self.railGlyph))
        #expect(white != red, "the two hearts must differ")

        let button = SnapRailBoostButton()
        #expect(Self.drawn(button.configuration?.image) == white)
        #expect(button.configuration?.attributedTitle == nil)

        button.setSpentTotal(60)
        #expect(Self.drawn(button.configuration?.image) == red)
        #expect(button.configuration?.attributedTitle == nil, "the spend came back as a number")

        button.setSpentTotal(0)
        #expect(Self.drawn(button.configuration?.image) == white)
    }

    /// VoiceOver reads the like state and both counts.
    @Test func railReadsTheLikeAndBothCounts() {
        let button = SnapRailBoostButton()
        #expect(button.accessibilityLabel == "Like")
        button.setLikeCount(1_203)
        #expect(button.accessibilityValue == "1.2K likes")
        button.setSpentTotal(3)
        #expect(button.accessibilityValue == "1.2K likes, you staked 3 points")
        button.setLikeCount(nil)
        #expect(button.accessibilityValue == "you staked 3 points", "a hidden count is not read")
    }

    /// The snap feed's menu says what the viewer has staked, above zero only.
    @Test func railMenuSaysTheStakeAboveZeroOnly() throws {
        let button = SnapRailBoostButton()
        button.setWalletContext(balance: 200, undoableAmount: 0)
        #expect(button.currentMenuActions().compactMap { $0 as? UIAction }
            .allSatisfy { !$0.title.hasPrefix("You staked") })

        button.setSpentTotal(37)
        let first = try #require(button.currentMenuActions().first as? UIAction)
        #expect(first.title == "You staked 37 points")
        #expect(first.attributes.contains(.disabled), "a line that reads, not one that acts")
    }

    /// ...and the cards' like-chip menu, `StakeMenu`'s default, does not.
    @Test func theCardsMenuNeverSaysTheStake() {
        let state = StakeMenu.State(
            balance: 200, stakedOnTarget: 37, undoable: 0, perTargetCap: 250,
            tapAmount: 1, shotsLeft: 0, shotAmount: 100
        )
        let titles = StakeMenu.elements(for: state, stake: { _ in }, shoot: {}, undo: nil)
            .compactMap { ($0 as? UIAction)?.title }
        #expect(!titles.contains { $0.hasPrefix("You staked") })
    }

    // MARK: - The like badge (#668)

    private static func chrome(likes: Int64, hidden: Bool = false, media: Bool = true) -> SnapChromeView {
        let chrome = SnapChromeView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        chrome.configure(with: FeedItemDisplayModel(
            id: PostID("post-1"), authorID: ProfileID("profile-1"), authorName: "Ana",
            metaText: "@ana", avatarURL: nil, caption: "A caption",
            mediaURL: media ? URL(string: "mock://media/1") : nil, mediaKind: .image,
            thumbnailURL: nil, audioText: nil, likeCount: likes, likeCountHidden: hidden
        ))
        chrome.layoutIfNeeded()
        return chrome
    }

    /// The post's count with the viewer's stake in it: a stake adds, an Undo
    /// takes it back off.
    @Test func theBadgeCountsThePostsLikesWithTheViewersStake() {
        let chrome = Self.chrome(likes: 40)
        #expect(chrome.debugLikeBadgeText == "40")
        chrome.setBoostTotal(2, animated: true)
        #expect(chrome.debugLikeBadgeText == "42")
        chrome.setBoostTotal(0, animated: true)
        #expect(chrome.debugLikeBadgeText == "40")
        // The app's one compact spelling.
        #expect(Self.chrome(likes: 1_203).debugLikeBadgeText == "1.2K")
    }

    /// No badge at zero; the viewer's like brings it.
    @Test func noBadgeAtZeroUntilALikeTakesItToOne() {
        let chrome = Self.chrome(likes: 0)
        #expect(chrome.debugLikeBadgeText == nil)
        chrome.setBoostTotal(1, animated: true)
        #expect(chrome.debugLikeBadgeText == "1")
        chrome.setBoostTotal(0, animated: true)
        #expect(chrome.debugLikeBadgeText == nil)
    }

    /// On screen, the like that takes the count off zero brings the badge in
    /// with an animation (the fade and bounce); a page opening on a count
    /// does not perform.
    @Test func theFirstLikeAnimatesTheBadgeIn() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let chrome = Self.chrome(likes: 0)
        window.addSubview(chrome)
        defer { chrome.removeFromSuperview() }
        let badge = try #require(chrome.subviews.compactMap { $0 as? SnapLikeCountBadge }.first)

        chrome.setBoostTotal(1, animated: true)
        #expect(badge.layer.animationKeys()?.isEmpty == false, "the badge popped in without its bounce")

        let opened = Self.chrome(likes: 12)
        window.addSubview(opened)
        defer { opened.removeFromSuperview() }
        let still = try #require(opened.subviews.compactMap { $0 as? SnapLikeCountBadge }.first)
        opened.setBoostTotal(3)
        #expect(still.layer.animationKeys()?.isEmpty ?? true)
        #expect(still.alpha == 1)
    }

    /// A hidden count (#397) shows no badge, stake or not; a text page has no
    /// like button to wear one.
    @Test func noBadgeForAHiddenCountOrOnATextPage() {
        let hidden = Self.chrome(likes: 900, hidden: true)
        hidden.setBoostTotal(3)
        #expect(hidden.debugLikeBadgeText == nil)

        let text = Self.chrome(likes: 900, media: false)
        #expect(text.debugLikeBadgeText == nil)
    }

    /// The comments panel's stake bubble wears the same face, badge and menu
    /// line — so the layouts' crossfade stays between two identical bubbles.
    @Test func theComposersLikeFaceMatchesTheRails() throws {
        let bar = CommentsInputBar()
        bar.usesLikeFace = true
        let boost = try #require(
            bar.subviews.compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == "Like" }
        )
        bar.setLikeCount(40)
        #expect(bar.debugLikeBadgeText == "40")
        #expect(boost.configuration?.image != nil)

        bar.setBoostTotal(2, animated: true)
        #expect(bar.debugLikeBadgeText == "42")
        #expect(boost.configuration?.image != nil)
        #expect(boost.configuration?.attributedTitle == nil, "the composer's like face showed a number")
        #expect(boost.accessibilityValue == "42 likes, you staked 2 points")
        let first = try #require(bar.currentBoostMenuActions().first as? UIAction)
        #expect(first.title == "You staked 2 points")
    }

    /// Off (post detail, everywhere but the snap panel): the receipt face as
    /// before, and no badge.
    @Test func withoutTheLikeFaceTheComposerKeepsItsReceipt() {
        let bar = CommentsInputBar()
        bar.setLikeCount(40)
        bar.setBoostTotal(60)
        #expect(bar.debugLikeBadgeText == nil)
        let titles = bar.currentBoostMenuActions().compactMap { ($0 as? UIAction)?.title }
        #expect(!titles.contains { $0.hasPrefix("You staked") })
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

/// A screen that can open the Shop — counts the asks, builds nothing (a
/// presentation never completes in the test host; DesignSystem's
/// `StakeShopTests` covers presenting).
@MainActor
private final class ShopOpenerSpy: UIViewController, StakeShopOpening {
    var asked = 0
    func makeStakeShop() -> UIViewController? {
        asked += 1
        return nil
    }
}
