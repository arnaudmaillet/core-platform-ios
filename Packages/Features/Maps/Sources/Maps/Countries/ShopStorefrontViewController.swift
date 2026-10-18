import CoreImage
import CoreNavigation
import CoreStorage
import DesignSystem
import EmoteKit
import MapsInterface
import MediaCore
import MediaPlayback
import UIKit

/// What the Shop draws its covers with (#1075): the app's image pipeline for
/// posters, and its player pool for the one preview loop that plays. Nil
/// draws the flags alone.
@MainActor
public struct ShopMedia {
    public let images: ImagePipeline
    public let videos: VideoPlaybackController?

    public init(images: ImagePipeline, videos: VideoPlaybackController?) {
        self.images = images
        self.videos = videos
    }
}

/// The Shop's root (#1075): a storefront of SHELVES, the way a game's shop
/// or the App Store is laid out — a category per shelf, a few items in a
/// horizontal row, and the heading pushing the whole category.
///
/// ```
///   (‹)              Shop           (◆ 120)
///   Boosts
///   ┌──────────────────────────────────────┐
///   │ ⚡ ×100 cartridges           [◆ 50] │   one wide card
///   └──────────────────────────────────────┘
///   Countries 237 ›            3 of 237 ▓░░
///   ┌────┐ ┌────┐ ┌────┐ ┌──                  locked countries, the next
///   │ 🇪🇸 │ │ 🇮🇹 │ │ 🇯🇵 │ │                    one peeking; a "See all"
///   │[◆15]│ │[◆30]│ │[◆50]│                      tile ends the row
///   └────┘ └────┘ └────┘ └──
/// ```
///
/// Today's two categories — Boosts and Countries — each shelf reading its
/// own small model, so the catalogue (#938) adds shelves without touching
/// the layout. The Countries heading (and the row's last tile) pushes the
/// country list the Shop used to be (`CountryShopViewController`): its
/// search, progress, Unlocked / Locked and animated unlock, unchanged.
///
/// A PUSHED screen (owner, 2026-10-13: not a sheet): the back button, the
/// gems on the right, no tab bar. The shelves' rows keep a drag while they
/// have somewhere to go and hand it on at their ends — to the screen's back
/// swipe at the leading one (`ShopShelfRowScrollView`).
///
/// ⚠️ **A TAP NEVER BUYS.** A card's body opens the item's page — a
/// country's unlock sheet, the pack's page — and a purchase always goes
/// through a confirmation: the unlock sheet's button, the pack's menu
/// (FTC v. Epic, 2022: one-press purchases next to a preview).
///
/// ⚠️ **GEMS ARE EARNED, NEVER SOLD.** A price out of reach is the button's
/// disabled state (#935), and the Shop says how gems are earned — never
/// where to buy them.
public final class ShopStorefrontViewController: UIViewController {
    enum Metrics {
        /// The rows' side margin and gap — For You's (`LeadRowMetrics`): a
        /// gap no less than the margin, so a snap can put an item fully away.
        static let margin: CGFloat = 16
        static let gap: CGFloat = 16
        /// The countries are cards in a row (owner, 2026-10-13): the
        /// country's top post as the picture, its name, rank and price over a
        /// blur at the foot — a touch larger than For You's Following cards
        /// (2.3 a width, 3:4), two and the edge of a third.
        static let countryCardsPerWidth: CGFloat = 2.1
        /// Height against width: For You's cards' 3:4 portrait.
        static let countryCardAspect: CGFloat = 4.0 / 3.0
        /// A card plays once it is this much on screen.
        static let playsWhenVisible: CGFloat = 0.6
        /// The row's closing "See all" tile: a chevron's width.
        static let seeAllWidth: CGFloat = 44
        /// Players at once, For You's row budget (`PostShelfSection.concurrentPlayers`).
        static let concurrentPlayers = 3
        /// The packs are PORTRAIT cards in a row (owner, 2026-10-13): two and
        /// a bit per screen, the third peeking to say the row goes on.
        static let packsPerWidth: CGFloat = 2.3
        /// Up to this many packs fit the width whole, for comparison.
        static let packsSideBySide = 3
        /// At most this many items on a shelf; the full list is its See all.
        static let shelfLimit = 10
        static let cardRadius: CGFloat = 16
        /// Between two shelves: the app's section gap.
        static var shelfGap: CGFloat { SectionTitleView.gapAbove() }
    }

    public var onShowCountry: ((String) -> Void)?
    /// Where the Shop was opened for — the stake menu's "Get ×100 cartridges"
    /// lands on the pack, which flashes.
    public internal(set) var focus: CountryShopViewController.Focus?
    private var hasShownFocus = false

    let access: any CountryAccess
    let stakePacks: (any StakePackSelling)?
    /// The profile items (#944): the video banner. Nil: no Profile shelf.
    let profileItems: (any ProfileItemSelling)?
    let atlas: CountryAtlas

    private let scroll = UIScrollView()
    private let column = UIStackView()
    private(set) var boostsShelf: ShopShelfView?
    private(set) var profileShelf: ShopShelfView?
    private(set) var countriesShelf: ShopShelfView?
    /// The profile items' cards, in the seller's order.
    private(set) var itemCards: [ShopProfileItemCardView] = []
    /// The packs' cards, smallest first.
    private(set) var packCards: [ShopPackCardView] = []
    /// The first pack's card — the one the stake menu's door flashes.
    var packCard: ShopPackCardView? { packCards.first }

    let media: ShopMedia?
    /// The country cards on the shelf, in order.
    private(set) var countryCards: [ShopCountryCardView] = []
    /// The cards whose video plays, muted, as For You's rows play.
    private(set) var playingCards: [ShopCountryCardView] = []

    init(
        access: any CountryAccess, stakePacks: (any StakePackSelling)?,
        profileItems: (any ProfileItemSelling)? = nil, media: ShopMedia? = nil,
        atlas: CountryAtlas = .shared
    ) {
        self.media = media
        self.access = access
        self.stakePacks = stakePacks
        self.profileItems = profileItems
        self.atlas = atlas
        super.init(nibName: nil, bundle: nil)
        title = CountryShopEntry.title
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never

        scroll.alwaysBounceVertical = true
        // ⚠️ VERTICAL ONLY. While a push slides this page in, part of it is
        // off screen and UIKit hands it a horizontal safe-area inset; with
        // the automatic behaviour the page took it as a horizontal content
        // inset, sat ~250pt off its rest, and the headings — inset from this
        // surface — drew their titles that far in, snapping back as the push
        // landed (owner's recording, 2026-10-13). This page never scrolls
        // sideways: only its scrolling axis is adjusted.
        scroll.contentInsetAdjustmentBehavior = .scrollableAxes
        scroll.backgroundColor = .clear
        scroll.topEdgeEffect.style = .soft
        view.addSubview(scroll)
        scroll.pin(to: view)
        // The bar's soft edge is drawn where it meets this view.
        setContentScrollView(scroll, for: .top)

        column.axis = .vertical
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            column.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Spacing.xxl),
            // ⚠️ THE CONTENT GUIDE TOO, not only the frame: with no content
            // width the scroll view drifted sideways, and every heading
            // (`SectionTitleView`, which insets from its scroll surface) drew
            // its title 200pt in.
            column.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            column.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])
        for name in [Notification.Name.countryAccessDidChange, .stakePackDidChange, ProfileItemStore.didChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(stockChanged), name: name, object: nil)
        }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.rebuild()
        }
        installBalance()
        rebuild()
    }

    override public func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Item sizes come from the width (For You's rule): re-laid when it
        // changes, not per scroll.
        let width = view.bounds.width
        guard width > 0, width != laidOutWidth else {
            return
        }
        laidOutWidth = width
        rebuild()
    }

    private var laidOutWidth: CGFloat = 0

    override public func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Nothing plays under the unlock sheet or a pushed list.
        stopPreview()
    }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updatePreview()
        guard !hasShownFocus, focus == .boosts else { return }
        hasShownFocus = true
        flashStakePack()
    }

    /// The pack's card lights up, then lets go — "this is what you came for".
    func flashStakePack() {
        packCard?.flash()
    }

    @objc private func stockChanged() {
        installBalance()
        rebuild()
    }

    /// The gems, trailing: the back button leads (owner, 2026-10-13).
    private func installBalance() {
        navigationItem.rightBarButtonItem = CountryShopViewController.balanceItem(gems: access.gems)
    }

    // MARK: - Shelves

    /// Whether shelves run down rather than across: at the accessibility text
    /// sizes, as the App Store does — a row of cropped giant cards is unread.
    var shelvesAreVertical: Bool { traitCollection.preferredContentSizeCategory.isAccessibilityCategory }

    /// The whole storefront, rebuilt from the sellers: a small page, so a
    /// rebuild is cheaper to reason about than a diff. Each row keeps where
    /// it was scrolled to.
    func rebuild() {
        let offsets = (boostsShelf?.rowOffset, countriesShelf?.rowOffset, profileShelf?.rowOffset)
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        boostsShelf = nil
        profileShelf = nil
        countriesShelf = nil
        let width = view.bounds.width > 0 ? view.bounds.width : 402
        // Empty categories are not shown: no seller, no Boosts.
        if let stakePacks, !stakePacks.offers.isEmpty {
            let shelf = boostsShelf(stakePacks.offers, width: width)
            column.addArrangedSubview(shelf)
            boostsShelf = shelf
        }
        if let profileItems, !profileItems.items.isEmpty {
            let shelf = profileShelf(profileItems, width: width)
            column.addArrangedSubview(shelf)
            profileShelf = shelf
        }
        let countries = countriesShelf(width: width)
        column.addArrangedSubview(countries)
        countriesShelf = countries
        for shelf in [boostsShelf, profileShelf].compactMap({ $0 }) { column.setCustomSpacing(Metrics.shelfGap, after: shelf) }
        boostsShelf?.rowOffset = offsets.0 ?? 0
        countriesShelf?.rowOffset = offsets.1 ?? 0
        profileShelf?.rowOffset = offsets.2 ?? 0
        // The new cards play again: a wallet change rebuilds the page under
        // a visible shelf (a no-op while off screen) — once it is laid out,
        // the visibility test reads frames.
        DispatchQueue.main.async { [weak self] in self?.updatePreview() }
    }

    /// One portrait card per pack, the SHOTS leading — they are what changes
    /// from one pack to the next (owner, 2026-10-13). The card is the button:
    /// its tap raises the pack's confirmation menu, as the price did.
    private func boostsShelf(_ offers: [StakePackOffer], width: CGFloat) -> ShopShelfView {
        let loaded = offers.first(where: \.isActive)
        let best = ShopPackCardView.bestValueID(in: offers)
        packCards = offers.map { offer in
            ShopPackCardView(
                offer: offer,
                affordable: access.gems >= offer.price,
                otherLoaded: loaded != nil && loaded?.id != offer.id,
                bestValue: offer.id == best,
                menu: packMenu(offer, blockedBy: loaded)
            )
        }
        // Three tiers or fewer stand side by side, whole — a price ladder
        // is read by comparing it, and a cropped tile hid its "Best value".
        // More than that scroll, the next one peeking.
        let perWidth = offers.count <= Metrics.packsSideBySide ? CGFloat(offers.count) : Metrics.packsPerWidth
        let itemWidth = RowEdgeSnap.itemWidth(
            forWidth: width, perWidth: perWidth, margin: Metrics.margin, gap: Metrics.gap
        )
        let shelf = ShopShelfView(
            heading: SectionTitleView.Content(title: "Boosts"),
            items: packCards.map { ($0, itemWidth) }, vertical: shelvesAreVertical
        )
        return shelf
    }

    /// The pack's one-line confirmation: buying is never one tap. Disabled,
    /// with why, out of reach, while another pack is loaded, or for an
    /// account that may not buy.
    func packMenu(_ offer: StakePackOffer, blockedBy loaded: StakePackOffer?) -> UIMenu {
        let buy = UIAction(title: "Buy for \(offer.price) gems", image: GemSymbol.glyphImage()) { [weak self] _ in
            guard let self else { return }
            MemberGates.perform(.shop, from: self) { [weak self] in self?.buyStakePack(offer) }
        }
        if access.purchasesRestricted {
            buy.attributes = .disabled
            buy.subtitle = PurchaseRestriction.message
        } else if let loaded {
            buy.attributes = .disabled
            buy.subtitle = loaded.id == offer.id
                ? CountryShopViewController.activeText(offer)
                : "Packs don't stack: \(loaded.shotsLeft) shots left in yours"
        } else if access.gems < offer.price {
            buy.attributes = .disabled
            buy.subtitle = "\(offer.price - access.gems) more gems needed"
        }
        return UIMenu(title: "\(ShopPackCardView.shotsTitle(offer)) — \(ShopPackCardView.shotsDetail(offer))", children: [buy])
    }

    /// The profile items (#944): what each does, its price, or Owned. The
    /// card raises its confirmation, as a pack's does.
    private func profileShelf(_ seller: any ProfileItemSelling, width: CGFloat) -> ShopShelfView {
        itemCards = seller.items.map { item in
            let owned = seller.owns(item)
            return ShopProfileItemCardView(
                item: item, owned: owned, affordable: access.gems >= item.gemPrice,
                menu: itemMenu(item, owned: owned)
            )
        }
        let itemWidth = RowEdgeSnap.itemWidth(
            forWidth: width, perWidth: Metrics.packsPerWidth, margin: Metrics.margin, gap: Metrics.gap
        )
        return ShopShelfView(
            heading: SectionTitleView.Content(title: "Profile"),
            items: itemCards.map { ($0, itemWidth) }, vertical: shelvesAreVertical
        )
    }

    /// The item's one-line confirmation: never one tap. Owned, it says where
    /// it is used instead.
    func itemMenu(_ item: ProfileItem, owned: Bool) -> UIMenu {
        if owned {
            // A label, not an action: disabled in its own arguments, which is
            // what `EmptyActionGuardTests` reads (#801).
            let used = UIAction(
                title: "Owned", image: UIImage(systemName: "checkmark.circle"), attributes: .disabled
            ) { _ in }
            used.subtitle = item.whereToUse
            return UIMenu(title: item.shopTitle, children: [used])
        }
        let buy = UIAction(title: "Buy for \(item.gemPrice) gems", image: GemSymbol.glyphImage()) { [weak self] _ in
            guard let self else { return }
            MemberGates.perform(.shop, from: self) { [weak self] in self?.buyItem(item) }
        }
        if access.purchasesRestricted {
            buy.attributes = .disabled
            buy.subtitle = PurchaseRestriction.message
        } else if access.gems < item.gemPrice {
            buy.attributes = .disabled
            buy.subtitle = "\(item.gemPrice - access.gems) more gems needed"
        }
        return UIMenu(title: "\(item.shopTitle) — yours for good", children: [buy])
    }

    /// Buys `item`. Internal for tests — the menu cannot be raised in one.
    @discardableResult
    func buyItem(_ item: ProfileItem) -> ProfileItemPurchase? {
        guard let profileItems, !access.purchasesRestricted else { return nil }
        let outcome = profileItems.buy(item)
        switch outcome {
        case .bought:
            HapticNotification().notificationOccurred(.success)
            Feedback.success("\(item.shopTitle) unlocked", from: self)
        case .alreadyOwned:
            break
        case .insufficientGems(let needed, let have):
            let missing = max(needed - have, 1)
            Feedback.failure(missing == 1 ? "1 more gem needed" : "\(missing) more gems needed", from: self)
        case .unavailable:
            Feedback.failure(PurchaseRestriction.message, from: self)
        }
        return outcome
    }

    private func countriesShelf(width: CGFloat) -> ShopShelfView {
        let standings = access.standings()
        let owned = standings.filter { access.isUnlocked($0.code) }.count
        let cardWidth = RowEdgeSnap.itemWidth(
            forWidth: width, perWidth: Metrics.countryCardsPerWidth, margin: Metrics.margin, gap: Metrics.gap
        )
        let suggested = Self.suggestedCountries(access: access)
        stopPreview()
        countryCards = suggested.compactMap { standing in
            guard let country = atlas.country(code: standing.code) else { return nil }
            return countryCard(country, standing: standing)
        }
        var items: [(UIView, CGFloat)] = countryCards.map { ($0, cardWidth) }
        // The full list is always one tap away: at the row's end, after a
        // swipe, the thumb is there — not back at the heading.
        let seeAll = ShopSeeAllRowView(title: "See all countries")
        seeAll.onOpen = { [weak self] in self?.openCountries() }
        // A narrow tile: a chevron needs little more than a finger's width
        // (owner, 2026-10-13).
        items.append((seeAll, Metrics.seeAllWidth))
        for card in countryCards {
            card.heightAnchor.constraint(equalTo: card.widthAnchor, multiplier: Metrics.countryCardAspect).isActive = true
        }

        let shelf = ShopShelfView(
            heading: SectionTitleView.Content(
                title: "Countries", count: standings.count.formatted(),
                countAccessibilityValue: "\(standings.count.formatted()) countries", isLink: true
            ),
            items: items, vertical: shelvesAreVertical
        )
        shelf.onSeeAll = { [weak self] in self?.openCountries() }
        shelf.onSettle = { [weak self] in self?.updatePreview() }
        shelf.setProgress(owned: owned, total: standings.count)
        // Gems are earned, never bought: said ONCE, at the page's foot, when
        // any price on it — a country's or a pack's — is out of reach.
        let packOutOfReach = stakePacks?.offers.contains { $0.price > access.gems } ?? false
        if !access.purchasesRestricted, suggested.contains(where: { $0.price > access.gems }) || packOutOfReach {
            shelf.setFootnote(Self.earnGemsText)
        }
        return shelf
    }

    /// Where gems come from — the Shop never sells them (charter §26, §34).
    static let earnGemsText = "Gems are earned: stake points on posts, and win when they're rewarded."

    /// The Countries shelf: LOCKED countries only (unlocked ones are on the
    /// map and in See all) — the one the device is in first, then by rank,
    /// the liveliest places first, as the Locked list; at most `shelfLimit`.
    static func suggestedCountries(access: any CountryAccess) -> [CountryStanding] {
        let locked = access.standings()
            .filter { !access.isUnlocked($0.code) }
            .sorted { $0.rank < $1.rank }
        let here = locked.filter { $0.code == access.currentCountry }
        let rest = locked.filter { $0.code != access.currentCountry }
        return Array((here + rest).prefix(Metrics.shelfLimit))
    }

    /// A country's card: its cover (with no post, its round flag, large), and
    /// over a blur at its foot the flag, the name, "🏆 rank · ♥ likes" and the
    /// price. The whole card opens the
    /// unlock sheet (owner, 2026-10-13: the card replaces the price's button).
    private func countryCard(_ country: CountryAtlas.Country, standing: CountryStanding) -> ShopCountryCardView {
        // The map's round flags (owner, 2026-10-13: not the emoji); the
        // emoji only where the catalog has no round one.
        let emoji = { CountryShopViewController.flagImage(for: country, pointSize: 22, trimmed: true) }
        let card = ShopCountryCardView(
            flag: FlagPalette.roundFlag(for: country.code) ?? emoji(), name: country.name,
            largeFlag: FlagPalette.largeRoundFlag(for: country.code) ?? FlagPalette.roundFlag(for: country.code),
            rank: standing.rank, likes: CountryStanding.compact(standing.likes),
            price: standing.price, inReach: access.gems >= standing.price,
            cover: access.cover(of: country.code),
            backdropFlag: CountryShopViewController.flagImage(for: country, pointSize: 160)
        )
        card.onOpen = { [weak self] in self?.openCountry(country) }
        card.accessibilityLabel = "\(country.name), rank \(standing.rank), \(standing.likes) likes, \(standing.price) gems"
        if let images = media?.images { card.loadPoster(with: images) }
        return card
    }

    // MARK: - Playing the videos

    /// The cards play their videos muted, as For You's rows do: every video
    /// card at least `playsWhenVisible` on screen, the leftmost first, at most
    /// `concurrentPlayers`. None under Reduce Motion or Power Saving
    /// (`MotionPreference`), none without a player pool.
    func updatePreview() {
        guard let videos = media?.videos, view.window != nil, !MotionPreference.reducesMotion,
              let shelf = countriesShelf else {
            stopPreview()
            return
        }
        let visible = shelf.row.bounds
        let wanted = countryCards
            .filter { $0.previewURL != nil }
            .filter { card in
                let frame = card.convert(card.bounds, to: shelf.row)
                return frame.intersection(visible).width / max(1, frame.width) >= Metrics.playsWhenVisible
            }
            .prefix(Metrics.concurrentPlayers)
        for card in playingCards where !wanted.contains(where: { $0 === card }) {
            videos.stop(card.videoView)
            card.endPreview()
        }
        for card in wanted where !playingCards.contains(where: { $0 === card }) {
            guard let url = card.previewURL, let postID = card.postID else { continue }
            card.beginPreview()
            Task { [weak self] in
                // Stopped before the task ran: never start a player nobody shows.
                guard self?.playingCards.contains(where: { $0 === card }) == true else { return }
                await videos.play(url, in: card.videoView, peakBitRate: 600_000, scope: postID)
            }
        }
        playingCards = Array(wanted)
    }

    private func stopPreview() {
        for card in playingCards {
            media?.videos?.stop(card.videoView)
            card.endPreview()
        }
        playingCards = []
    }

    /// Buys a pack — only ever from its confirmation menu. Internal for
    /// tests, which cannot raise a menu.
    @discardableResult
    func buyStakePack(_ offer: StakePackOffer) -> StakePackPurchase? {
        guard let stakePacks else { return nil }
        return CountryShopViewController.buyStakePack(offer, from: stakePacks, access: access, presenter: self)
    }

    // MARK: - Pages

    /// A country's page is the unlock sheet the map uses; it is where the
    /// confirmation is.
    func openCountry(_ country: CountryAtlas.Country) {
        CountryShopViewController.offer(country, access: access, from: self)
    }

    /// Countries' See all: the country list, as the Shop used to open on.
    func openCountries() {
        let list = CountryShopViewController(access: access, atlas: atlas)
        list.title = "Countries"
        list.onShowCountry = onShowCountry
        navigationController?.pushViewController(list, animated: true)
    }
}

// MARK: - A shelf

/// One category: its heading (`SectionTitleView`, a link when there is more
/// than the shelf shows) and a horizontal row of items that comes to rest on
/// an item's edge, as For You's rows do (`RowEdgeSnap`). At the accessibility
/// text sizes the row runs down instead.
@MainActor
final class ShopShelfView: UIView, UIScrollViewDelegate {
    let heading: SectionTitleView
    let row = ShopShelfRowScrollView()
    private let stack = UIStackView()
    private let footnote = UILabel()
    private var drag: RowEdgeDragTracker?
    private(set) var items: [UIView] = []
    var onSeeAll: (() -> Void)? {
        didSet { heading.onTap = onSeeAll }
    }

    init(heading content: SectionTitleView.Content, items: [(UIView, CGFloat)], vertical: Bool) {
        heading = SectionTitleView(content: content)
        // A shelf spans the page: its title stands the surface's 20pt in,
        // said rather than measured — measured, it read the page's position
        // while a push was still placing it, and kept 221pt (2026-10-13).
        heading.fixedInset = SectionTitleView.Metrics.surfaceInset
        super.init(frame: .zero)
        self.items = items.map(\.0)
        let column = UIStackView(arrangedSubviews: [heading])
        column.axis = .vertical
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        column.pin(to: self)

        stack.axis = vertical ? .vertical : .horizontal
        stack.spacing = ShopStorefrontViewController.Metrics.gap
        // Fill: the cards of one row stand as tall as each other.
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (item, width) in items {
            item.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(item)
            if !vertical { item.widthAnchor.constraint(equalToConstant: width).isActive = true }
        }
        let margin = ShopStorefrontViewController.Metrics.margin
        if vertical {
            stack.isLayoutMarginsRelativeArrangement = true
            stack.directionalLayoutMargins = .init(top: 0, leading: margin, bottom: 0, trailing: margin)
            column.addArrangedSubview(stack)
        } else {
            row.showsHorizontalScrollIndicator = false
            // The row sets its own margins: no safe-area inset slid in by a
            // push (see the page's note).
            row.contentInsetAdjustmentBehavior = .never
            row.alwaysBounceHorizontal = true
            row.decelerationRate = .fast
            row.delegate = self
            row.clipsToBounds = false
            row.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: row.contentLayoutGuide.topAnchor),
                stack.bottomAnchor.constraint(equalTo: row.contentLayoutGuide.bottomAnchor),
                stack.leadingAnchor.constraint(equalTo: row.contentLayoutGuide.leadingAnchor, constant: margin),
                stack.trailingAnchor.constraint(equalTo: row.contentLayoutGuide.trailingAnchor, constant: -margin),
                stack.heightAnchor.constraint(equalTo: row.frameLayoutGuide.heightAnchor),
            ])
            column.addArrangedSubview(row)
        }
        footnote.font = .appFont(forTextStyle: .footnote)
        footnote.adjustsFontForContentSizeCategory = true
        footnote.textColor = .secondaryLabel
        footnote.numberOfLines = 0
        footnote.isHidden = true
        let footnoteHost = UIView()
        footnote.translatesAutoresizingMaskIntoConstraints = false
        footnoteHost.addSubview(footnote)
        NSLayoutConstraint.activate([
            footnote.topAnchor.constraint(equalTo: footnoteHost.topAnchor, constant: Spacing.sm),
            footnote.bottomAnchor.constraint(equalTo: footnoteHost.bottomAnchor),
            footnote.leadingAnchor.constraint(equalTo: footnoteHost.leadingAnchor, constant: SectionTitleView.Metrics.surfaceInset),
            footnote.trailingAnchor.constraint(equalTo: footnoteHost.trailingAnchor, constant: -SectionTitleView.Metrics.surfaceInset),
        ])
        column.addArrangedSubview(footnoteHost)
        footnoteHost.isHidden = true
        self.footnoteHost = footnoteHost

        // One VoiceOver container per shelf, named by its heading.
        accessibilityContainerType = .semanticGroup
        accessibilityLabel = content.title
    }

    private var footnoteHost: UIView?

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// "3 of 237" and a short bar, the heading's trailing accessory.
    func setProgress(owned: Int, total: Int) {
        let label = UILabel()
        label.text = "\(owned) of \(total.formatted())"
        label.font = .appFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        let bar = UIProgressView(progressViewStyle: .bar)
        bar.progress = total > 0 ? Float(owned) / Float(total) : 0
        bar.layer.cornerRadius = 2
        bar.clipsToBounds = true
        bar.widthAnchor.constraint(equalToConstant: 48).isActive = true
        bar.heightAnchor.constraint(equalToConstant: 4).isActive = true
        let accessory = UIStackView(arrangedSubviews: [label, bar])
        accessory.spacing = Spacing.sm
        accessory.alignment = .center
        accessory.isAccessibilityElement = true
        accessory.accessibilityLabel = "\(owned) of \(total) countries unlocked"
        let size = accessory.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        accessory.frame.size = size
        heading.trailingAccessory = accessory
    }

    func setFootnote(_ text: String) {
        footnote.text = text
        footnote.isHidden = false
        footnoteHost?.isHidden = false
    }

    var footnoteText: String? { footnote.isHidden ? nil : footnote.text }

    /// Where the row is scrolled to — kept across a rebuild.
    var rowOffset: CGFloat {
        get { row.contentOffset.x }
        set {
            layoutIfNeeded()
            let maximum = max(0, row.contentSize.width - row.bounds.width)
            row.contentOffset.x = min(max(0, newValue), maximum)
        }
    }

    /// Told when the row has come to rest — where the Shop picks the card
    /// that plays.
    var onSettle: (() -> Void)?

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settle() }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settle() }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { settle() }

    private func settle() {
        quiet?.cancel()
        quiet = nil
        onSettle?()
    }

    /// The backstop: a row that has stopped moving for `quietDelay` has come
    /// to rest, whichever callback UIKit left out — an animated snap a new
    /// drag cut short, a deceleration taken over. Without it a missed rest
    /// left the cards on their posters until the next swipe.
    private var quiet: DispatchWorkItem?
    static let quietDelay: TimeInterval = 0.3

    private func armQuiet() {
        quiet?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !row.isTracking else { return }
            settle()
        }
        quiet = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quietDelay, execute: item)
    }

    // MARK: Snapping (For You's rule)

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        drag = RowEdgeDragTracker(offset: scrollView.contentOffset.x)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        drag?.track(scrollView.contentOffset.x)
        armQuiet()
    }

    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        let tracker = drag
        drag = nil
        let offsets: ClosedRange<CGFloat> = 0...max(0, scrollView.contentSize.width - scrollView.bounds.width)
        let extents = items.map { item -> ClosedRange<CGFloat> in
            let frame = item.convert(item.bounds, to: stack)
            let x = stack.frame.minX + frame.minX
            return x...(x + frame.width)
        }
        let direction = RowEdgeSnap.direction(velocity: velocity.x, lastMovement: tracker?.lastMovement)
        let margin = ShopStorefrontViewController.Metrics.margin
        // Wide items (the countries' columns, near a screen each) move ONE per
        // gesture, as For You's text row: a fling carried past two columns
        // reads as the list running away, not as a page turned. Small ones
        // (cards) take the projection.
        // Wide items (a country's card, near a screen wide) PAGE: one per
        // gesture, each resting flush with the left margin, as the App
        // Store's large cards do — a card left half-shown on the left reads as
        // a mistake. Small ones (packs) take For You's rule.
        let isWide = (extents.first.map { $0.upperBound - $0.lowerBound } ?? 0) > scrollView.bounds.width / 2
        let target: CGFloat
        if isWide {
            target = Self.pagedTarget(
                start: tracker?.start ?? scrollView.contentOffset.x, live: scrollView.contentOffset.x,
                direction: direction, items: extents, margin: margin, offsets: offsets
            )
        } else {
            target = RowEdgeSnap.target(
                projected: targetContentOffset.pointee.x, direction: direction,
                items: extents, viewport: scrollView.bounds.width, margin: margin, offsets: offsets
            )
        }
        let current = scrollView.contentOffset.x
        // A release with no speed is animated by hand: handed a new target at
        // zero velocity UIScrollView jumps (For You's note).
        guard abs(velocity.x) < RowEdgeSnap.flickVelocity, offsets.contains(current) else {
            targetContentOffset.pointee.x = target
            return
        }
        targetContentOffset.pointee.x = current
        guard target != current else { return }
        DispatchQueue.main.async { [weak scrollView] in
            guard let scrollView, !scrollView.isTracking else { return }
            scrollView.setContentOffset(CGPoint(x: target, y: scrollView.contentOffset.y), animated: true)
        }
    }

    /// Where a paging row rests: the next item's left edge on the margin
    /// going forward, the previous one's going back — one item per gesture,
    /// counted from where the drag began; the nearest with no direction.
    static func pagedTarget(
        start: CGFloat, live: CGFloat, direction: RowEdgeSnap.Direction?,
        items: [ClosedRange<CGFloat>], margin: CGFloat, offsets: ClosedRange<CGFloat>
    ) -> CGFloat {
        let anchors = RowEdgeSnap.leadingAnchors(items: items, margin: margin, offsets: offsets).sorted()
        let slack = RowEdgeSnap.slack
        switch direction {
        case .forward:
            return anchors.first { $0 > start + slack } ?? offsets.upperBound
        case .backward:
            return anchors.last { $0 < start - slack } ?? offsets.lowerBound
        case nil:
            return anchors.min { abs($0 - live) < abs($1 - live) } ?? live
        }
    }

    #if DEBUG
    func debugSnapTarget(projected: CGFloat, velocity: CGFloat) -> CGFloat {
        layoutIfNeeded()
        var target = CGPoint(x: projected, y: 0)
        scrollViewWillEndDragging(row, withVelocity: CGPoint(x: velocity, y: 0), targetContentOffset: &target)
        return target.x
    }

    var debugIsVertical: Bool { stack.axis == .vertical }
    #endif
}

// MARK: - Cards and rows

/// A card: a rounded ground the whole of which is the tap target (owner,
/// 2026-10-13: the card replaces the price's button). With a `menu`, the tap
/// raises it — a confirmation, never a purchase; otherwise it calls `onOpen`.
@MainActor
class ShopCardView: UIView {
    var onOpen: (() -> Void)?
    /// The control the whole card is: it takes the touch, raises the menu,
    /// and drives the card's press.
    let hitArea = UIButton(type: .custom)
    private var feedback: PressFeedback?

    init(menu: UIMenu? = nil) {
        super.init(frame: .zero)
        backgroundColor = .tertiarySystemFill
        layer.cornerRadius = ShopStorefrontViewController.Metrics.cardRadius
        layer.cornerCurve = .continuous
        hitArea.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hitArea)
        hitArea.pin(to: self)
        if let menu {
            hitArea.menu = menu
            hitArea.showsMenuAsPrimaryAction = true
        } else {
            hitArea.addAction(UIAction { [weak self] _ in self?.onOpen?() }, for: .primaryActionTriggered)
        }
        feedback = PressFeedback.attach(to: hitArea, moving: self, sound: nil)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The hit area stays on top of whatever the card draws.
    override func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        if subview !== hitArea { bringSubviewToFront(hitArea) }
    }

    override func accessibilityActivate() -> Bool {
        guard hitArea.menu == nil else { return false }
        onOpen?()
        return true
    }

    /// A brief light-up, for the Shop opened on this item.
    func flash() {
        backgroundColor = .systemFill
        UIView.animate(withDuration: 0.6, delay: 0.3, options: [.allowUserInteraction]) {
            self.backgroundColor = .tertiarySystemFill
        }
    }
}

/// A price as text: the diamond and the number, in the gems' cyan when in
/// reach, grey out of it. No container: the card is the button.
final class ShopPriceLabel: UIStackView {
    let inReach: Bool

    /// - Parameter onDark: on a card's dark blur: white ink in reach, a dim
    ///   white out of it.
    init(price: Int, inReach: Bool, onDark: Bool = false) {
        self.inReach = inReach
        super.init(frame: .zero)
        let font = UIFont.scaledMonospacedDigitSystemFont(
            ofSize: 15, weight: .semibold, relativeTo: .subheadline, maximumPointSize: 20
        )
        let dim: UIColor = onDark ? UIColor.white.withAlphaComponent(0.45) : .tertiaryLabel
        let color: UIColor = inReach ? GemSymbol.tint : dim
        let diamond = UIImageView(image: UIImage.symbol(named: GemSymbol.glyph)?
            .applyingSymbolConfiguration(.init(pointSize: 11, weight: .bold)))
        diamond.tintColor = color
        let number = UILabel()
        number.text = price.formatted()
        number.font = font
        number.textColor = inReach ? (onDark ? .white : .label) : dim
        number.adjustsFontForContentSizeCategory = true
        // Both at their own size: in a row, the name gives way, not these.
        for view in [diamond, number] as [UIView] {
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        addArrangedSubview(diamond)
        addArrangedSubview(number)
        spacing = 4
        alignment = .center
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var text: String? { (arrangedSubviews.last as? UILabel)?.text }
}

/// The row's last tile: the whole category — a ground and a chevron, no
/// words (owner, 2026-10-13); VoiceOver hears its title.
final class ShopSeeAllRowView: ShopCardView {
    init(title: String) {
        super.init()
        let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        chevron.preferredSymbolConfiguration = .init(textStyle: .title3, scale: .medium)
        chevron.tintColor = .secondaryLabel
        chevron.isUserInteractionEnabled = false
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevron)
        NSLayoutConstraint.activate([
            chevron.centerXAnchor.constraint(equalTo: centerXAnchor),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
        ])
        accessibilityLabel = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// A country, as a large card (owner, 2026-10-13): its top post as the
/// picture — a photo, a video's poster (its preview loop playing when the
/// card is the one most on screen), or for a text post its words over the
/// flag's colours, blurred whole; the flag alone when it has no post — and
/// at its foot, over a blur, the flag and name, "#rank · ♥ likes", and the
/// price in a bubble concentric with the card.
///
/// ```
///   ┌──────────────────┐
///   │                  │
///   │   (top post)     │
///   │░░░░░░░░░░░░░░░░░░│  the blur rises from the foot
///   │ 🇳🇬 Nigeria       │
///   │ #8 · ♥ 57K       │
///   │ (    ◆ 50      ) │
///   └──────────────────┘
/// ```
final class ShopCountryCardView: ShopCardView {
    let cover: CountryCover?
    let nameLabel = UILabel()
    let posterView = UIImageView()
    let videoView = VideoRenderView()
    let priceBubble = UIView()
    let price: ShopPriceLabel
    /// The quote a text post's card shows, its emotes animated; nil otherwise.
    private(set) var quoteLabel: EmoteLabel?
    /// The large round flag a card with no post shows; nil otherwise.
    private(set) var heroFlagView: UIImageView?

    var previewURL: URL? {
        if case .video(_, _, let preview) = cover { return preview }
        return nil
    }

    var postID: String? {
        switch cover {
        case .image(let id, _), .video(let id, _, _), .text(let id, _): id
        case nil: nil
        }
    }

    init(
        flag: UIImage, name: String, largeFlag: UIImage? = nil, rank: Int, likes: String, price amount: Int,
        inReach: Bool, cover: CountryCover?, backdropFlag: UIImage
    ) {
        self.cover = cover
        self.price = ShopPriceLabel(price: amount, inReach: inReach, onDark: true)
        super.init()
        clipsToBounds = true
        backgroundColor = .black

        // The picture.
        posterView.contentMode = .scaleAspectFill
        posterView.clipsToBounds = true
        posterView.isUserInteractionEnabled = false
        videoView.isUserInteractionEnabled = false
        videoView.alpha = 0
        let backdrop = Self.flagBackdrop(backdropFlag)
        for view in [backdrop, posterView, videoView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            view.pin(to: self)
        }
        switch cover {
        case .image, .video:
            backdrop.isHidden = true
        case .text(_, let caption):
            let quote = EmoteLabel()
            quote.font = .scaledSystemFont(ofSize: 15, weight: .semibold, relativeTo: .subheadline, maximumPointSize: 21)
            quote.adjustsFontForContentSizeCategory = true
            quote.textColor = .white
            quote.numberOfLines = 5
            quote.lineBreakMode = .byTruncatingTail
            quote.setEmoteText("“\(caption)”")
            // The words give way, never the price: a long caption truncates
            // rather than squeezing the foot (owner, 2026-10-13).
            quote.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
            quote.setContentHuggingPriority(.defaultLow, for: .vertical)
            quote.isUserInteractionEnabled = false
            quote.translatesAutoresizingMaskIntoConstraints = false
            addSubview(quote)
            NSLayoutConstraint.activate([
                quote.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.md),
                quote.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.md),
                quote.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.md),
            ])
            quoteLabel = quote
        case nil:
            // No post: the flag itself, centred over the info (owner,
            // 2026-10-13), on its blurred colours.
            if let largeFlag {
                let hero = UIImageView(image: largeFlag)
                hero.contentMode = .scaleAspectFit
                // Sized by the card, not by the image's 96pt.
                hero.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                hero.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
                hero.isUserInteractionEnabled = false
                hero.translatesAutoresizingMaskIntoConstraints = false
                addSubview(hero)
                heroFlagView = hero
            }
        }

        // The foot: a blur rising from the bottom edge, and the info over it.
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
        blur.isUserInteractionEnabled = false
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)
        let fade = CAGradientLayer()
        fade.colors = [UIColor.clear.cgColor, UIColor.black.cgColor, UIColor.black.cgColor]
        fade.locations = [0, 0.28, 1]
        blur.layer.mask = fade
        self.blurFade = fade
        self.blur = blur

        let flagView = UIImageView(image: flag)
        flagView.contentMode = .scaleAspectFit
        flagView.setContentHuggingPriority(.required, for: .horizontal)
        // A round flag is drawn large in the catalog: pinned to the name's
        // cap height, as the emoji was.
        let flagSide = UIFontMetrics(forTextStyle: .headline).scaledValue(for: 18)
        flagView.widthAnchor.constraint(equalToConstant: flagSide).isActive = true
        flagView.heightAnchor.constraint(equalTo: flagView.widthAnchor, multiplier: flag.size.height / max(1, flag.size.width)).isActive = true
        nameLabel.text = name
        nameLabel.font = .appFont(forTextStyle: .headline)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = .white
        nameLabel.lineBreakMode = .byTruncatingTail
        let title = UIStackView(arrangedSubviews: [flagView, nameLabel])
        title.spacing = 6
        title.alignment = .center
        let metaLabel = UILabel()
        metaLabel.adjustsFontForContentSizeCategory = true
        metaLabel.attributedText = Self.metaLine(rank: rank, likes: likes, font: .appFont(forTextStyle: .footnote))
        let info = UIStackView(arrangedSubviews: [title, metaLabel])
        info.axis = .vertical
        info.spacing = 2
        info.isUserInteractionEnabled = false
        info.translatesAutoresizingMaskIntoConstraints = false
        addSubview(info)

        priceBubble.layer.cornerRadius = ShopPackCardView.bubbleRadius
        priceBubble.layer.cornerCurve = .continuous
        priceBubble.backgroundColor = inReach ? GemSymbol.tint.withAlphaComponent(0.35) : UIColor.white.withAlphaComponent(0.16)
        priceBubble.isUserInteractionEnabled = false
        priceBubble.translatesAutoresizingMaskIntoConstraints = false
        price.translatesAutoresizingMaskIntoConstraints = false
        priceBubble.addSubview(price)
        addSubview(priceBubble)

        let inset = Spacing.md
        let bubbleInset = ShopPackCardView.bubbleInset
        NSLayoutConstraint.activate([
            priceBubble.leadingAnchor.constraint(equalTo: leadingAnchor, constant: bubbleInset),
            priceBubble.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -bubbleInset),
            priceBubble.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -bubbleInset),
            // Exactly the packs' bubble height, on every card whatever its cover.
            priceBubble.heightAnchor.constraint(equalToConstant: 34),
            price.centerXAnchor.constraint(equalTo: priceBubble.centerXAnchor),
            price.centerYAnchor.constraint(equalTo: priceBubble.centerYAnchor),
            price.topAnchor.constraint(greaterThanOrEqualTo: priceBubble.topAnchor, constant: 6),
            info.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            info.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),
            info.bottomAnchor.constraint(equalTo: priceBubble.topAnchor, constant: -Spacing.sm),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            blur.topAnchor.constraint(equalTo: info.topAnchor, constant: -Spacing.xl),
        ])
        if let hero = heroFlagView {
            // Centred in the room above the foot's blur.
            let room = UILayoutGuide()
            addLayoutGuide(room)
            NSLayoutConstraint.activate([
                room.topAnchor.constraint(equalTo: topAnchor),
                room.bottomAnchor.constraint(equalTo: blur.topAnchor, constant: Spacing.xl / 2),
                hero.centerXAnchor.constraint(equalTo: centerXAnchor),
                hero.centerYAnchor.constraint(equalTo: room.centerYAnchor),
                hero.heightAnchor.constraint(equalTo: hero.widthAnchor),
                hero.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: Spacing.md),
            ])
            // Shrinks rather than overlapping the info at the large text sizes.
            let width = hero.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.42)
            width.priority = .defaultHigh
            width.isActive = true
        }
        if let quote = quoteLabel {
            quote.bottomAnchor.constraint(lessThanOrEqualTo: blur.topAnchor, constant: -Spacing.sm).isActive = true
        }
        bringSubviewToFront(hitArea)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// "🏆 8 · ♥ 57K": a trophy for the rank (owner, 2026-10-13: not "#8"),
    /// and the points' heart for the likes.
    static func metaLine(rank: Int, likes: String, font: UIFont) -> NSAttributedString {
        let ink = UIColor.white.withAlphaComponent(0.85)
        let symbol = UIImage.SymbolConfiguration(font: font, scale: .small)
        let line = NSMutableAttributedString()
        if let trophy = UIImage(systemName: "trophy.fill", withConfiguration: symbol)?
            .withTintColor(.systemYellow, renderingMode: .alwaysOriginal) {
            line.append(NSAttributedString(attachment: NSTextAttachment(image: trophy)))
        }
        line.append(NSAttributedString(string: " \(rank)  ·  ", attributes: [.font: font, .foregroundColor: ink]))
        if let heart = PointsSymbol.glyphImage(symbol) {
            line.append(NSAttributedString(attachment: NSTextAttachment(image: heart)))
        }
        line.append(NSAttributedString(string: " \(likes)", attributes: [.font: font, .foregroundColor: ink]))
        return line
    }

    private weak var blur: UIVisualEffectView?
    private var blurFade: CAGradientLayer?

    override func layoutSubviews() {
        super.layoutSubviews()
        if let blur, let blurFade {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            blurFade.frame = blur.bounds
            CATransaction.commit()
        }
    }

    /// The flag's colours, blurred whole: the ground of a text post's card and
    /// of a country with no post. A text post has no colour of its own yet;
    /// when posts get a theme (the card styles of #945), a text cover wears it
    /// instead.
    private static func flagBackdrop(_ flag: UIImage) -> UIView {
        let host = UIView()
        host.clipsToBounds = true
        host.isUserInteractionEnabled = false
        host.backgroundColor = .black
        let image = UIImageView(image: washed(flag))
        image.contentMode = .scaleAspectFill
        image.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(image)
        image.pin(to: host)
        // A shade, so white words over a pale flag still read.
        let shade = UIView()
        shade.backgroundColor = UIColor.black.withAlphaComponent(0.25)
        shade.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(shade)
        shade.pin(to: host)
        return host
    }

    /// The flag blurred until only its colours are left — no stripe or
    /// emblem to read (owner, 2026-10-13: "blur entirely").
    /// One context for every card: a CIContext is costly to make.
    private static let washContext = CIContext(options: [.useSoftwareRenderer: false])

    static func washed(_ flag: UIImage) -> UIImage {
        guard let input = CIImage(image: flag) else { return flag }
        let radius = max(input.extent.width, input.extent.height) / 6
        let blurred = input.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: input.extent)
        guard let output = washContext.createCGImage(blurred, from: input.extent) else { return flag }
        return UIImage(cgImage: output, scale: flag.scale, orientation: .up)
    }

    /// The poster, decoded at the card's size.
    func loadPoster(with images: ImagePipeline) {
        let poster: URL? = switch cover {
        case .image(_, let url): url
        case .video(_, let url, _): url
        default: nil
        }
        guard let poster else { return }
        // A card is ~810 px wide at @3x: the full bucket, not a tile's. On the
        // loading ladder's rules (#1085): a warm poster at once, a late one
        // dissolved in over the card's black.
        posterLoad.load(poster, using: images) { [weak self] image, transition in
            guard let self else { return }
            transition.perform(on: posterView) { self.posterView.image = image }
        }
    }

    private let posterLoad = ImageLoadSlot(size: .full)

    /// The preview loop starts: the video fades in over the poster once it has
    /// a picture.
    ///
    /// ⚠️ ASKED OF THE SURFACE, not announced by it: a card played again after
    /// a stop gets a surface already "ready" (its layer kept the flag), so a
    /// change callback never fired and the video ran invisible behind the
    /// poster — autoplay "stopping" after a few back-and-forths (owner,
    /// 2026-10-13).
    func beginPreview() {
        videoView.fadeInOnFirstFrame(over: 0.25)
    }

    func endPreview() {
        videoView.alpha = 0
    }
}

/// A stake pack: three lines (owner, 2026-10-13) — the SHOTS, what differs
/// from one pack to the next, then what a shot stakes, then the price.
///
/// ```
///   ┌──[BEST VALUE]┐   a state ribbon across the top edge
///   │ ×10          │   the quantity, a store's "×N"
///   │ 100 ♥ a shot │   one shot's points, in the points' own red heart
///   │ ( ◆ 150    ) │   the price in a full-width bubble, or "Active — 2 left"
///   └──────────────┘
/// ```
///
/// "Best value" is said only of the pack whose shot is the cheapest — a fact
/// of the prices, never a timer or a scarcity (#1075's honest merchandising).
///
/// ⚠️ THE PRICE BUBBLE LOOKS LIKE A BUTTON, AND IS ONE IN EFFECT: the whole
/// card raises the pack's confirmation, so the bubble only shows where the
/// action is (a store tile's price bar). It must never sit on a card whose
/// tap does something else.
final class ShopPackCardView: ShopCardView {
    let offer: StakePackOffer
    let quantityLabel = UILabel()
    let footLabel: UIView
    let badgeLabel = UILabel()
    /// The bubble the price (or the loaded state) stands in.
    let priceBubble = UIView()

    static func shotsTitle(_ offer: StakePackOffer) -> String {
        offer.shotsPerPack == 1 ? "1 shot" : "\(offer.shotsPerPack) shots"
    }

    static func shotsDetail(_ offer: StakePackOffer) -> String {
        "\(StakeMenu.points(offer.pointsPerShot)) a shot"
    }

    /// How far the price bubble sits in from the card's edges, and its radius:
    /// the card's less that inset, so the corners are concentric.
    static let bubbleInset: CGFloat = 6
    static var bubbleRadius: CGFloat { ShopStorefrontViewController.Metrics.cardRadius - bubbleInset }

    /// "×10".
    static func quantityText(_ offer: StakePackOffer) -> String { "×\(offer.shotsPerPack.formatted())" }

    /// "100 ♥ a shot", the heart in the points' red.
    static func shotLine(_ offer: StakePackOffer, font: UIFont) -> NSAttributedString {
        let line = NSMutableAttributedString(
            string: "\(offer.pointsPerShot.formatted()) ",
            attributes: [.font: font, .foregroundColor: UIColor.label]
        )
        let heart = NSTextAttachment(image: PointsSymbol.glyphImage(.init(font: font, scale: .small)) ?? UIImage())
        line.append(NSAttributedString(attachment: heart))
        line.append(NSAttributedString(string: " a shot", attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel]))
        return line
    }

    /// The pack whose shot costs the least, when one does strictly.
    static func bestValueID(in offers: [StakePackOffer]) -> String? {
        let perShot = offers.map { (id: $0.id, cost: Double($0.price) / Double(max(1, $0.shotsPerPack))) }
        guard let best = perShot.min(by: { $0.cost < $1.cost }),
              perShot.filter({ $0.cost == best.cost }).count == 1, offers.count > 1 else { return nil }
        return best.id
    }

    init(offer: StakePackOffer, affordable: Bool, otherLoaded: Bool, bestValue: Bool, menu: UIMenu) {
        self.offer = offer
        if offer.isActive {
            let active = UILabel()
            active.text = CountryShopViewController.activeText(offer)
            active.font = .appFont(forTextStyle: .subheadline)
            active.adjustsFontForContentSizeCategory = true
            active.textColor = PointsSymbol.tint
            active.numberOfLines = 2
            active.textAlignment = .center
            footLabel = active
        } else {
            footLabel = ShopPriceLabel(price: offer.price, inReach: affordable && !otherLoaded)
        }
        super.init(menu: menu)

        // Line 1: "×10", the multiplication sign a store's quantity wears.
        quantityLabel.text = Self.quantityText(offer)
        quantityLabel.font = .scaledSystemFont(ofSize: 28, weight: .bold, relativeTo: .title1, maximumPointSize: 40)
        quantityLabel.adjustsFontForContentSizeCategory = true
        let quantity = quantityLabel

        // Line 2: "100 ♥ a shot" — the heart is the points' own symbol, so the
        // number reads as points, not as more shots.
        let detail = UILabel()
        detail.attributedText = Self.shotLine(offer, font: .appFont(forTextStyle: .footnote))
        detail.adjustsFontForContentSizeCategory = true
        detail.numberOfLines = 2

        // Line 3, at the foot so every card's price stands on one line.
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        // The price, centred in a bubble the card's width: in reach it wears
        // the gems' tint, out of reach (or blocked by a loaded pack) it greys,
        // loaded it wears the points' red.
        // CONCENTRIC with the card (owner, 2026-10-13): the bubble sits
        // `bubbleInset` in from the card's sides and foot, and its radius is
        // the card's less that inset, so the two curves run parallel.
        priceBubble.layer.cornerRadius = Self.bubbleRadius
        priceBubble.layer.cornerCurve = .continuous
        priceBubble.isUserInteractionEnabled = false
        if offer.isActive {
            priceBubble.backgroundColor = PointsSymbol.tint.withAlphaComponent(0.14)
        } else if affordable && !otherLoaded {
            priceBubble.backgroundColor = GemSymbol.tint.withAlphaComponent(0.16)
        } else {
            priceBubble.backgroundColor = .quaternarySystemFill
        }
        footLabel.translatesAutoresizingMaskIntoConstraints = false
        priceBubble.addSubview(footLabel)
        NSLayoutConstraint.activate([
            priceBubble.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
            footLabel.centerXAnchor.constraint(equalTo: priceBubble.centerXAnchor),
            footLabel.topAnchor.constraint(greaterThanOrEqualTo: priceBubble.topAnchor, constant: 6),
            footLabel.centerYAnchor.constraint(equalTo: priceBubble.centerYAnchor),
            footLabel.leadingAnchor.constraint(greaterThanOrEqualTo: priceBubble.leadingAnchor, constant: Spacing.sm),
        ])

        priceBubble.translatesAutoresizingMaskIntoConstraints = false
        addSubview(priceBubble)
        let stack = UIStackView(arrangedSubviews: [quantity, detail, spacer])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = Spacing.xs
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        // The state chip, in the corner: loaded, or the best value.
        badgeLabel.font = .scaledSystemFont(ofSize: 9, weight: .bold, relativeTo: .caption2, maximumPointSize: 12)
        badgeLabel.adjustsFontForContentSizeCategory = true
        let chip = UIView()
        chip.layer.cornerRadius = 8
        chip.layer.cornerCurve = .continuous
        chip.isUserInteractionEnabled = false
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(badgeLabel)
        chip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chip)
        if offer.isActive {
            badgeLabel.text = "LOADED"
            badgeLabel.textColor = .white
            chip.backgroundColor = PointsSymbol.tint
        } else if bestValue {
            badgeLabel.text = "BEST VALUE"
            badgeLabel.textColor = .white
            chip.backgroundColor = PointsSymbol.tint
        } else {
            chip.isHidden = true
        }

        let inset = Spacing.md
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            priceBubble.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: Spacing.sm),
            priceBubble.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.bubbleInset),
            priceBubble.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.bubbleInset),
            priceBubble.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.bubbleInset),
            // A ribbon across the card's top edge, as a pricing table marks
            // its plan: it never takes the quantity's room.
            chip.centerYAnchor.constraint(equalTo: topAnchor),
            chip.centerXAnchor.constraint(equalTo: centerXAnchor),
            badgeLabel.topAnchor.constraint(equalTo: chip.topAnchor, constant: 3),
            badgeLabel.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -3),
            badgeLabel.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 6),
            badgeLabel.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -6),
        ])
        let state = offer.isActive ? CountryShopViewController.activeText(offer) : "\(offer.price) gems"
        accessibilityLabel = [Self.shotsTitle(offer), Self.shotsDetail(offer), bestValue && !offer.isActive ? "best value" : nil, state]
            .compactMap { $0 }.joined(separator: ", ")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

// MARK: - A shelf's row

/// A shelf's horizontal row. It KEEPS a horizontal drag while it has
/// somewhere to go in that direction — UIKit already lets a horizontal
/// scroller win over the stack's full-surface back swipe — and HANDS IT ON at
/// its ends: a rightward drag with the row at its start, or one from the
/// screen's leading edge strip, goes to the back swipe, as a profile's
/// carousels do (`HorizontalPagerScrollView`, `MediaCarouselTouchRouting`).
final class ShopShelfRowScrollView: UIScrollView {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer {
            let pan = panGestureRecognizer
            // ⚠️ Asked once the pan has travelled its slop: the origin is the
            // location less the translation.
            let location = pan.location(in: nil)
            let translation = pan.translation(in: nil)
            if !keepsDrag(fromScreenX: location.x - translation.x, velocity: pan.velocity(in: self)) {
                return false
            }
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    /// Whether a drag starting at `screenX` (window space) and moving at
    /// `velocity` is this row's.
    func keepsDrag(fromScreenX screenX: CGFloat, velocity: CGPoint) -> Bool {
        // The leading edge strip is always the back swipe's.
        if screenX <= PagedScreenDismissalPolicy.edgeZone { return false }
        // Mostly vertical: the page's scroll, not a question for this row.
        guard abs(velocity.x) > abs(velocity.y) else { return true }
        let start = -adjustedContentInset.left
        let end = max(start, contentSize.width + adjustedContentInset.right - bounds.width)
        if velocity.x > 0 { return contentOffset.x > start + 0.5 }
        return contentOffset.x < end - 0.5
    }
}

/// A profile item (#944), as a portrait card like a pack's: its symbol,
/// its name, what it does, and at the foot its price — or Owned.
final class ShopProfileItemCardView: ShopCardView {
    let item: ProfileItem
    let owned: Bool
    let priceBubble = UIView()

    init(item: ProfileItem, owned: Bool, affordable: Bool, menu: UIMenu) {
        self.item = item
        self.owned = owned
        super.init(menu: menu)

        let symbol = UIImageView(image: UIImage(systemName: item.shopSymbol))
        symbol.preferredSymbolConfiguration = .init(textStyle: .title1, scale: .large)
        symbol.tintColor = .label
        symbol.contentMode = .left
        symbol.setContentHuggingPriority(.required, for: .vertical)
        let title = UILabel()
        title.text = item.shopTitle
        title.font = .appFont(forTextStyle: .headline)
        title.adjustsFontForContentSizeCategory = true
        title.numberOfLines = 2
        let detail = UILabel()
        detail.text = item.shopDetail
        detail.font = .appFont(forTextStyle: .footnote)
        detail.adjustsFontForContentSizeCategory = true
        detail.textColor = .secondaryLabel
        detail.numberOfLines = 3
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        let stack = UIStackView(arrangedSubviews: [symbol, title, detail, spacer])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = Spacing.xs
        stack.setCustomSpacing(Spacing.sm, after: symbol)
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let foot: UIView
        if owned {
            let label = UILabel()
            label.text = "Owned"
            label.font = .appFont(forTextStyle: .subheadline)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .secondaryLabel
            foot = label
            priceBubble.backgroundColor = .quaternarySystemFill
        } else {
            foot = ShopPriceLabel(price: item.gemPrice, inReach: affordable)
            priceBubble.backgroundColor = affordable ? GemSymbol.tint.withAlphaComponent(0.16) : .quaternarySystemFill
        }
        priceBubble.layer.cornerRadius = ShopPackCardView.bubbleRadius
        priceBubble.layer.cornerCurve = .continuous
        priceBubble.isUserInteractionEnabled = false
        foot.translatesAutoresizingMaskIntoConstraints = false
        priceBubble.addSubview(foot)
        priceBubble.translatesAutoresizingMaskIntoConstraints = false
        addSubview(priceBubble)

        let inset = Spacing.md
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            priceBubble.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: Spacing.sm),
            priceBubble.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ShopPackCardView.bubbleInset),
            priceBubble.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ShopPackCardView.bubbleInset),
            priceBubble.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -ShopPackCardView.bubbleInset),
            priceBubble.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
            foot.centerXAnchor.constraint(equalTo: priceBubble.centerXAnchor),
            foot.centerYAnchor.constraint(equalTo: priceBubble.centerYAnchor),
            foot.topAnchor.constraint(greaterThanOrEqualTo: priceBubble.topAnchor, constant: 6),
        ])
        accessibilityLabel = "\(item.shopTitle). \(item.shopDetail)"
        accessibilityValue = owned ? "Owned" : "\(item.gemPrice) gems"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
