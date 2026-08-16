import CoreModels
import DesignSystem
import MediaCore
import QuartzCore
import UIKit

/// One entry in the sub-filter bar: the refinement it applies plus its pill
/// presentation. People entries carry their `MapFavorite` (full name + avatar
/// URL) for the pin menu and the full-list sheet.
struct MapSubFilterOption: Equatable {
    let subFilter: MapSubFilter
    let content: MapPillButton.Content
    let favorite: MapFavorite?

    /// The full-list sheet's row title (full name for people, pill title
    /// otherwise).
    var sheetTitle: String { favorite?.title ?? content.title ?? content.accessibilityLabel }

    /// The sheet's subtitle line: the person's `@handle`. Nil for place
    /// categories (nothing to say) and for a profile whose handle never
    /// hydrated — the row then renders as a plain single-line cell rather
    /// than reserving an empty second line.
    var sheetSubtitle: String? {
        guard let handle = favorite?.handle, !handle.isEmpty else { return nil }
        return "@\(handle)"
    }

    /// Person rows carry the profile and mute swipe actions; place
    /// categories have no account behind them.
    var profileID: ProfileID? { favorite?.profileID }

    /// The Places refinements. Purely client-side vocabulary — no place-
    /// category contract exists; the tokens ride the Phase-1 filter header as
    /// `pinned:<token>` and are matched literally by the mock.
    static let placeCategories: [MapSubFilterOption] = [
        MapSubFilterOption(
            subFilter: .placeCategory("cafes"),
            content: MapPillButton.Content(
                title: nil,
                symbolName: "cup.and.saucer", selectedSymbolName: "cup.and.saucer.fill",
                accessibilityLabel: "Cafes"
            ),
            favorite: nil
        ),
        MapSubFilterOption(
            subFilter: .placeCategory("restaurants"),
            content: MapPillButton.Content(
                title: nil,
                symbolName: "fork.knife", selectedSymbolName: "fork.knife",
                accessibilityLabel: "Restaurants"
            ),
            favorite: nil
        ),
        MapSubFilterOption(
            subFilter: .placeCategory("parks"),
            content: MapPillButton.Content(
                title: nil,
                symbolName: "tree", selectedSymbolName: "tree.fill",
                accessibilityLabel: "Parks"
            ),
            favorite: nil
        ),
        MapSubFilterOption(
            subFilter: .placeCategory("nightlife"),
            content: MapPillButton.Content(
                title: nil,
                symbolName: "moon.stars", selectedSymbolName: "moon.stars.fill",
                accessibilityLabel: "Nightlife"
            ),
            favorite: nil
        )
    ]

    /// Whether a rail with NOTHING in it should stay on screen as its add
    /// affordance, or retire the way it always did.
    ///
    /// The "+" is only worth showing when it leads somewhere: it opens the
    /// full-list sheet, and a sheet with an empty catalogue is a dead end —
    /// a button that answers a tap with nothing at all. So an empty rail with
    /// people still available keeps the row (curated everyone off; here is the
    /// way back), and an empty rail with an empty catalogue hides it (this
    /// viewer has no friends to show; the row has nothing to say).
    static func rowSurvivesEmpty(catalogue: [MapSubFilterOption]) -> Bool {
        !catalogue.isEmpty
    }

    /// Person refinements (Friends/Following rows): the AVATAR, and nothing
    /// else. `MapPillButton` pins width to height for a title-less pill, so
    /// dropping the name is what makes the pill a circle.
    ///
    /// A face identifies someone faster than a first name does, and a row of
    /// circles fits roughly twice as many people on a phone — the row exists
    /// to be scanned. The name has not disappeared: it is the long-press
    /// menu's title (`menu(for:)`), and it is what VoiceOver reads, since the
    /// label is the only name a screen reader ever had.
    static func people(_ people: [MapFavorite]) -> [MapSubFilterOption] {
        people.map { person in
            MapSubFilterOption(
                subFilter: .profile(person.profileID),
                content: MapPillButton.Content(
                    title: nil,
                    symbolName: "person.crop.circle", selectedSymbolName: "person.crop.circle.fill",
                    accessibilityLabel: person.title
                ),
                favorite: person
            )
        }
    }

    /// "Ava Moreau" → "Ava"; a spaceless title (e.g. "@handle") stays whole.
    private static func firstName(of title: String) -> String {
        title.split(separator: " ").first.map(String.init) ?? title
    }
}

/// The dynamic refinement carousel floating directly ABOVE the main filter
/// bar: people under Friends/Following (avatar + first name), place
/// categories under Places; hidden for All / favorite selections. Same
/// Liquid Glass system as the main bar, one size down (32pt pills) so the
/// two rows read as a hierarchy. A horizontally scrolling `UICollectionView`
/// (compositional + diffable), mirroring the main bar's architecture.
///
/// Anatomy — ONE fixed glass button on the LEADING edge, then the scrolling
/// pill row, whose first cell is "All":
///
///   [ ☰ ] │ [ ✦ All ] ( ◉ Ava ) ( ◉ Ines ) ( ◉ Théo ) …
///   fixed │ scrolling — All is a CELL, not furniture
///
/// "All" scrolls with the row because it belongs to the row: it is the head of
/// the same one-of-these list every other pill is in, and pinning it would
/// spend a fifth of a phone-width bar restating the resting state on every
/// screen. What it costs is the reset affordance once the viewer scrolls past
/// it — which the fixed button absorbs by going CONTEXTUAL
/// (`MapSubFilterHeaderRole`): it organizes while All is on screen, and
/// becomes a rewind the moment All finishes dissolving under it. One button,
/// two jobs, never both needed at once.
///
/// Cells scrolling beneath the button duck-fade under it (`updateHeaderFade`),
/// and the row's leading content inset — which is also the snap anchor — is a
/// constant: the button is a fixed-diameter circle, so its trailing edge never
/// moves. Long-pressing a person pill offers Pin/Unpin to Favorites via the
/// pill's native menu.
///
/// The main bar has no fixed button at all (single-selection needs no reset
/// affordance — see `MapFilterBarView`); this bar does, because
/// multi-selection can accumulate several refinements with no other way home.
///
/// Selection is a SET and every tap toggles one pill: several refinements can
/// ride at once and the map queries their union, and clearing the last one
/// falls back to the bare primary. There is no single/multi mode — one
/// behaviour, in the bar and in the full-list sheet alike. Cells are
/// presentation-only (`MapPillCell`).
final class MapSubFilterBarView: UIView {
    /// Fired on every selection change; the empty set means "no refinement".
    var onSubFiltersChanged: ((Set<MapSubFilter>) -> Void)?
    /// The fixed button was tapped in its ORGANIZE role — present the
    /// full-list sheet. (Its rewind role is handled entirely in-bar.)
    var onExpandTapped: (() -> Void)?
    /// Resolves avatar thumbnails for people pills.
    var imagePipeline: ImagePipeline?

    // MARK: Long-press menu

    /// The pill menu's destinations. Every one is the HOST's affair — the bar
    /// knows which verb was chosen and nothing about where it goes, exactly as
    /// the sheet's `RowActions` does. Which of them a given pill offers is
    /// `MapSubFilterMenuAction.actions(for:)`, keyed on the entity behind it.
    var onViewProfile: ((MapFavorite) -> Void)?
    var onSendMessage: ((MapFavorite) -> Void)?
    var onToggleMute: ((MapFavorite) -> Void)?
    /// Live mute state, read when the menu is BUILT (not when the pill was
    /// configured), so a stale flag can't title the row wrong.
    var isMuted: ((ProfileID) -> Bool)?
    /// A place category's detail destination, by category token.
    var onViewDetails: ((String) -> Void)?
    /// Share whatever this refinement stands for.
    var onShare: ((MapSubFilterOption) -> Void)?
    /// Drop this refinement from the row. The host owns the list, so it
    /// republishes and the bar restacks — see `restack(to:)`.
    var onUnpinSubFilter: ((MapSubFilter) -> Void)?

    /// Every refinement currently applied; empty means "no refinement".
    private(set) var selectedSubFilters: Set<MapSubFilter> = []

    /// One size below the main bar's 36pt family, per the type ladder.
    /// The pill's diameter — every pill in this row is a circle now, so this
    /// is both. 32 → 40 → 48: a bare avatar has to carry the identity a name
    /// used to, and it is the whole tap target. At 48 the photo inside it
    /// (`MapPillButton.avatarInset` off the diameter, so 44pt of face) is
    /// legible at a glance rather than a coloured dot.
    static let pillHeight: CGFloat = 48
    /// Same halo headroom rationale as the main bar.
    /// Breathing room above and below the pills, so the glass highlights and
    /// the selection glow render fully. Grown with the pills — the same 6pt
    /// that framed a 32pt pill reads as a crowded band around a 48pt one.
    static let verticalPadding: CGFloat = 8
    static var barHeight: CGFloat { pillHeight + verticalPadding * 2 }

    /// The fixed button's trailing edge in bar coordinates. A CONSTANT, not a
    /// measurement: the button is title-less, so `MapPillButton` pins its
    /// width to its height and the circle can never change size. Deriving it
    /// arithmetically (rather than reading `frame.maxX` in `layoutSubviews`)
    /// means the duck-fade and the role flip are already correct on the very
    /// first pass, before any layout has run.
    static var headerTrailingX: CGFloat { Spacing.lg + pillHeight }
    /// Where the row rests, snaps, and starts duck-fading — the button's
    /// trailing edge plus the fade's APPROACH margin. Reserve anything
    /// narrower and the pill parked on the anchor rests permanently
    /// part-dissolved; at exactly `approach` the fade starts where that pill
    /// ends, so every settled pill is flush AND fully opaque.
    static var rowInsetLeft: CGFloat { headerTrailingX + MapBarDuckFade.approach }

    private enum Section: Hashable { case main }

    /// The row's cells. "All" is a first-class item rather than a special
    /// index, so the diffable snapshot, the snap candidates, and the
    /// duck-fade all treat it as the ordinary pill it looks like.
    enum Item: Hashable {
        case all
        case subFilter(MapSubFilter)
    }

    private static let allContent = MapPillButton.Content(
        title: nil,
        symbolName: "sparkles", selectedSymbolName: "sparkles",
        accessibilityLabel: "All"
    )

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var optionsBySubFilter: [MapSubFilter: MapSubFilterOption] = [:]
    private var orderedSubFilters: [MapSubFilter] = []
    /// Resolved avatars, keyed by profile — survives cell reuse and option
    /// refreshes (the pipeline's cache makes re-resolution cheap anyway).
    private var avatarCache: [ProfileID: UIImage] = [:]
    /// Handles already seen for a profile, so an option set that arrives
    /// without one cannot un-name someone the bar has already identified.
    /// See `carryingKnownHandles(_:)`.
    private var handleCache: [ProfileID: String] = [:]
    /// Menu-header faces, circle-cropped from `avatarCache`.
    private var headerImageCache: [ProfileID: UIImage] = [:]
    private var avatarTasks: [Task<Void, Never>] = []
    /// Monotonic token superseding in-flight cross-dissolves: a stale
    /// fade-out completion must never swap content selected later (rapid
    /// taps land mid-animation; `.beginFromCurrentState` retargets the
    /// alphas, this retargets the *intent*).
    private var transitionGeneration = 0

    /// The one fixed button, contextual by scroll position — see
    /// `MapSubFilterHeaderRole`. Born in the organize role, which is also its
    /// role whenever the row is at rest.
    private let headerButton = MapPillButton(
        content: MapSubFilterHeaderRole.organize.content,
        height: MapSubFilterBarView.pillHeight
    )
    private var headerRole: MapSubFilterHeaderRole = .organize

    init() {
        super.init(frame: .zero)
        configureCollectionView()
        configureHeader()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Collection view

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        let configuration = UICollectionViewCompositionalLayoutConfiguration()
        configuration.scrollDirection = .horizontal

        let itemSize = NSCollectionLayoutSize(
            // Absolute, not estimated: every pill is a circle, so its width IS
            // its height and there is nothing left to measure.
            widthDimension: .absolute(Self.pillHeight),
            heightDimension: .absolute(Self.pillHeight)
        )
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: itemSize, subitems: [NSCollectionLayoutItem(layoutSize: itemSize)]
        )
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = Spacing.sm
        section.contentInsets = NSDirectionalEdgeInsets(
            top: Self.verticalPadding, leading: 0,
            bottom: Self.verticalPadding, trailing: 0
        )
        return UICollectionViewCompositionalLayout(section: section, configuration: configuration)
    }

    private func configureCollectionView() {
        collectionView = MapBarCollectionView(frame: .zero, collectionViewLayout: makeLayout())
        // Unclipped halos, same as the main bar (safe: edge-to-edge scroll).
        clipsToBounds = false
        collectionView.clipsToBounds = false
        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.delegate = self
        // A selection swap changes pill intrinsics (weight) — cells must
        // re-self-size on content/constraint changes, not serve their cached
        // measurement (a stale width wraps the title).
        collectionView.selfSizingInvalidation = .enabledIncludingConstraints
        // Highlight must land on touch-down, not after the scroll-intent
        // grace period — the press dip reads as lag otherwise.
        collectionView.delaysContentTouches = false
        // Leading inset clears the fixed button so pills rest free of it and
        // only overlap mid-scroll (where the duck-fade takes over) — and it is
        // the snap anchor, so the resting offset and the first pill's snap
        // target are the same number by construction.
        collectionView.contentInset = UIEdgeInsets(
            top: 0, left: Self.rowInsetLeft, bottom: 0, right: Spacing.lg
        )
        collectionView.pin(to: self)

        let pillRegistration = UICollectionView.CellRegistration<MapPillCell, Item> { [weak self] cell, _, item in
            guard let self, let (content, selected) = self.presentation(for: item) else { return }
            cell.configure(content: content, height: Self.pillHeight, selected: selected)
            switch item {
            case .all:
                // The head of the list, not a refinement: it clears rather
                // than toggles, and there is no account behind it to pin.
                cell.onTap = { [weak self] in self?.didTapAll() }
                cell.setAvatar(nil)
                cell.menuProvider = nil
            case .subFilter(let subFilter):
                // Native pill interaction: tap → selection; long-press → the
                // entity-aware menu, built fresh at presentation time.
                cell.onTap = { [weak self] in self?.didTap(subFilter) }
                cell.setAvatar(self.optionsBySubFilter[subFilter]?.favorite
                    .flatMap { self.avatarCache[$0.profileID] })
                cell.menuProvider = { [weak self] in self?.pillMenu(for: subFilter) }
            }
        }
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) {
            collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: pillRegistration, for: indexPath, item: item)
        }
    }

    /// What a cell renders, and whether it reads as active. All is active
    /// exactly while nothing is refined — it IS the empty selection, not a
    /// fifth thing you could also pick.
    private func presentation(for item: Item) -> (MapPillButton.Content, Bool)? {
        switch item {
        case .all:
            (Self.allContent, selectedSubFilters.isEmpty)
        case .subFilter(let subFilter):
            optionsBySubFilter[subFilter].map { ($0.content, selectedSubFilters.contains(subFilter)) }
        }
    }

    private func configureHeader() {
        // A sibling of the collection view (it must not scroll), floating
        // above the cells gliding beneath it.
        addSubview(headerButton)
        headerButton.translatesAutoresizingMaskIntoConstraints = false
        headerButton.layer.zPosition = 1
        NSLayoutConstraint.activate([
            headerButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.lg),
            headerButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        headerButton.addAction(UIAction { [weak self] _ in self?.didTapHeader() }, for: .touchUpInside)
    }

    // MARK: - Content

    /// Replaces the row's options; selection resets (a new option set always
    /// belongs to a freshly chosen primary) and the row rewinds to its head.
    /// Structure lands synchronously at final widths, arrival is a pure
    /// cross-dissolve to each cell's resting alpha (the header duck-fade
    /// decides that); avatars resolve async into the cache and reconfigure.
    func setOptions(_ options: [MapSubFilterOption]) {
        // Direct set supersedes any in-flight cross-dissolve…
        transitionGeneration += 1
        for task in avatarTasks { task.cancel() }
        avatarTasks.removeAll()
        selectedSubFilters = []
        let options = carryingKnownHandles(options)
        orderedSubFilters = options.map(\.subFilter)
        optionsBySubFilter = Dictionary(uniqueKeysWithValues: options.map { ($0.subFilter, $0) })

        UIView.performWithoutAnimation {
            let items = Self.items(for: orderedSubFilters)
            var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
            snapshot.appendSections([.main])
            snapshot.appendItems(items)
            // A fresh option set may reuse identities (friends ⊂ following) —
            // force reconfiguration so stale presentation can't survive.
            snapshot.reconfigureItems(items)
            dataSource.apply(snapshot, animatingDifferences: false)
            collectionView.setContentOffset(
                CGPoint(x: -collectionView.adjustedContentInset.left, y: 0), animated: false
            )
            collectionView.layoutIfNeeded()
        }

        // …and repairs the scroll surface if an interrupted swap left it
        // faded (the new cells are at alpha 0, so this can't flash). The
        // surface alpha is ANIMATED back rather than assigned: `transition`
        // hands over while its fade-out spring is still running, and a bare
        // assignment would set the model value under a live animation that
        // keeps driving toward 0. Re-entering the same spring retargets it
        // from wherever it is (`.beginFromCurrentState`).
        for cell in collectionView.visibleCells { cell.alpha = 0 }
        UIView.mapBarFade {
            self.collectionView.alpha = 1
            self.updateHeaderFade()
        }
        // The row is home, so the button is back to organizing — but this is
        // a content swap, not a scroll: land that state, don't crossfade it.
        updateHeaderRole(animated: false)
        loadAvatars(for: options)
    }

    #if DEBUG
    /// `-maps-subfilter-menu-open`: presents a pill's long-press menu so it
    /// can be SEEN. The audit print proves the menu is built and titled; only
    /// a screenshot proves iOS renders that title, and a long press cannot be
    /// injected. Flipping the pill to menu-as-primary for the one demo tap is
    /// the only way to make UIKit present it.
    /// The header of the menu INSTALLED on that pill — see
    /// `MapPillCell.debugInstalledMenuTitle`.
    func debugInstalledMenuTitle(for subFilter: MapSubFilter) -> String? {
        guard let indexPath = dataSource.indexPath(for: .subFilter(subFilter)),
              let cell = collectionView.cellForItem(at: indexPath) as? MapPillCell
        else { return nil }
        return cell.debugInstalledMenuTitle
    }

    /// The header's second line as INSTALLED on the pill.
    func debugInstalledMenuSubtitle(for subFilter: MapSubFilter) -> String? {
        guard let indexPath = dataSource.indexPath(for: .subFilter(subFilter)),
              let cell = collectionView.cellForItem(at: indexPath) as? MapPillCell
        else { return nil }
        return cell.debugInstalledMenuSubtitle
    }

    func debugPresentMenu(for subFilter: MapSubFilter) {
        guard let indexPath = dataSource.indexPath(for: .subFilter(subFilter)),
              let cell = collectionView.cellForItem(at: indexPath) as? MapPillCell
        else { return }
        cell.debugPresentMenu()
    }
    #endif

    /// Fills in handles the bar already knows.
    ///
    /// ⚠️ The menu header is drawn from whatever `MapFavorite` the row is
    /// holding, and a person whose handle is momentarily absent renders a
    /// one-line header that grows a second line when a fuller favorite
    /// arrives — the menu changing shape under a thumb that is already on it.
    /// A screen recording caught exactly that: the handle appearing ~1.8s
    /// after the menu opened, in place.
    ///
    /// Every path in this feature hydrates title, avatar and handle from ONE
    /// profile response, so a handle-less favorite should not exist — and on
    /// the current code none is reachable (traced at every timing, both the
    /// curated and the graph-fallback paths). This does not trust that. Once
    /// a handle is known for a profile it is kept and reapplied, so identity
    /// only ever gains detail, never loses it, whichever path fills the row.
    private func carryingKnownHandles(_ options: [MapSubFilterOption]) -> [MapSubFilterOption] {
        for option in options {
            guard let favorite = option.favorite,
                  let handle = favorite.handle, !handle.isEmpty else { continue }
            handleCache[favorite.profileID] = handle
        }
        return options.map { option in
            guard let favorite = option.favorite,
                  favorite.handle?.isEmpty ?? true,
                  let known = handleCache[favorite.profileID]
            else { return option }
            return MapSubFilterOption(
                subFilter: option.subFilter,
                content: option.content,
                favorite: MapFavorite(
                    profileID: favorite.profileID,
                    title: favorite.title,
                    avatarURL: favorite.avatarURL,
                    handle: known
                )
            )
        }
    }

    /// The row's items: All at the head, then the refinements in order.
    /// How many refinements a row needs before it is worth heading with All.
    ///
    /// Below this the pill earns nothing. All means "none of these selected",
    /// which a one- or two-pill row already SHOWS — every pill unselected —
    /// and every tap toggles its own pill, so nothing is trapped in a
    /// filtered state without it. What it costs is a fifth of a phone-width
    /// row spent restating the resting state next to two people.
    static let allPillMinimumCount = 3

    /// The row's cells: the refinements in order, headed by All only once
    /// there are enough of them to be worth resetting — and NOTHING at all
    /// when there are none.
    ///
    /// An empty rail drops All for a different reason: "all" of nothing
    /// selects nothing, and a lone All pill beside a lone organize button is a
    /// row that looks populated and does nothing. The fixed button becomes the
    /// add affordance there instead (`MapSubFilterHeaderRole.add`).
    static func items(for subFilters: [MapSubFilter]) -> [Item] {
        guard subFilters.count >= allPillMinimumCount else {
            return subFilters.map(Item.subFilter)
        }
        return [.all] + subFilters.map(Item.subFilter)
    }

    /// The organize sheet's committed arrangement: the same options
    /// reordered, minus any the viewer removed. Deliberately not
    /// `setOptions` — this is not a content swap, so the selection survives,
    /// the row keeps its scroll offset, and nothing cross-dissolves; pills
    /// glide to their new seats and a removed one animates out via the
    /// diffable diff (the one width/position animation both endpoints are
    /// laid out for). Lands as the sheet begins dismissing, so the row is
    /// already right by the time it is uncovered.
    func restack(to options: [MapSubFilterOption]) {
        let options = carryingKnownHandles(options)
        orderedSubFilters = options.map(\.subFilter)
        optionsBySubFilter = Dictionary(uniqueKeysWithValues: options.map { ($0.subFilter, $0) })
        // A restack can now ADD people (someone favorited from their profile
        // while this row was on screen), and an added pill has never had its
        // avatar resolved. Cache-guarded, so the ones already here cost
        // nothing and do not re-fetch.
        loadAvatars(for: options)
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.main])
        snapshot.appendItems(Self.items(for: orderedSubFilters))
        dataSource.apply(snapshot, animatingDifferences: true) { [weak self] in
            guard let self else { return }
            // Pills changed seats: whoever now sits under the fixed button
            // must re-derive its duck-fade alpha — and All may have moved
            // out from under it, or back beneath it.
            updateHeader()
            // A removal shortens the row under a stationary offset, so the
            // rest position the viewer was snapped to may not be a pill
            // boundary any more — or may be past the end entirely. Settle
            // re-aligns (a sub-point no-op when the row didn't shorten past
            // where they were sitting).
            MapBarSnap.settle(collectionView)
        }
    }

    /// How far into the fade-OUT the incoming row starts arriving. The two
    /// halves used to run end to end (fade out, then in the completion, fade
    /// in) — two full springs, ~0.5s for what reads as one gesture. Handing
    /// over at 60% overlaps them into ~0.4s and, because the outgoing spring
    /// is critically damped, the old row is already down near a tenth of its
    /// opacity by then: the swap still happens somewhere the eye can't
    /// resolve it, which is the property the original sequencing was really
    /// protecting.
    private static let transitionHandoff = 0.6

    /// Cross-dissolves to a new option set while the row stays visible (a
    /// primary-to-primary switch, e.g. Friends → Places): fade the current
    /// cells out and, before that has finished settling, swap the content and
    /// bring the new cells up through it. The fixed button deliberately stays
    /// put — it belongs to the bar, not to either state. Safe under rapid
    /// taps: a newer transition (or a direct `setOptions`) supersedes the
    /// pending swap, and the handoff is a generation-guarded hop rather than a
    /// completion block, so an abandoned fade-out can't drag a stale row in
    /// behind it.
    func transition(to options: [MapSubFilterOption]) {
        transitionGeneration += 1
        let generation = transitionGeneration
        UIView.mapBarFade { self.collectionView.alpha = 0 }
        let handoff = UIView.mapBarFadeDuration * Self.transitionHandoff
        DispatchQueue.main.asyncAfter(deadline: .now() + handoff) { [weak self] in
            guard let self, generation == transitionGeneration else { return }
            // `setOptions` swaps the content and springs the surface back up,
            // retargeting the fade-out that is still in flight.
            setOptions(options)
        }
    }

    private func loadAvatars(for options: [MapSubFilterOption]) {
        guard let imagePipeline else { return }
        for option in options {
            guard let favorite = option.favorite, let url = favorite.avatarURL,
                  avatarCache[favorite.profileID] == nil else { continue }
            let subFilter = option.subFilter
            avatarTasks.append(Task { [weak self] in
                guard let image = try? await imagePipeline.image(for: url),
                      let self, !Task.isCancelled else { return }
                self.avatarCache[favorite.profileID] = image
                self.headerImageCache[favorite.profileID] = nil
                // Atomic content refresh — no width animation on arrival.
                UIView.performWithoutAnimation {
                    if let indexPath = self.dataSource.indexPath(for: .subFilter(subFilter)) {
                        let cell = self.collectionView.cellForItem(at: indexPath) as? MapPillCell
                        cell?.setAvatar(image)
                        // The menu was built while this face was still a
                        // placeholder glyph — rebuild it, or the header keeps
                        // the glyph until the next restack.
                        cell?.refreshMenu()
                        self.collectionView.collectionViewLayout.invalidateLayout()
                        self.collectionView.layoutIfNeeded()
                    }
                }
            })
        }
    }

    // MARK: - Selection

    #if DEBUG
    /// `-maps-tap-subfilter`: drives a pill through the SAME handler a real
    /// tap reaches, so the toggle can be seen in a screenshot. The touch
    /// itself is UIKit's business; what is being verified here is that a
    /// second tap on a selected pill takes the ring off.
    func debugTap(_ subFilter: MapSubFilter) { didTap(subFilter) }
    #endif

    private func didTap(_ subFilter: MapSubFilter) {
        // Every tap toggles its own pill; the rest hold their state.
        let next = selectedSubFilters.symmetricDifference([subFilter])
        setSelectedSubFilters(next, reveal: subFilter)
        onSubFiltersChanged?(next)
    }

    // MARK: - Long-press menu

    /// The entity behind a pill, or nil once the row no longer carries it.
    func entity(for subFilter: MapSubFilter) -> MapSubFilterEntity? {
        optionsBySubFilter[subFilter].map(MapSubFilterEntity.init(option:))
    }

    /// This pill's menu, assembled at PRESENTATION time (the cell's
    /// `menuProvider` runs inside a `UIDeferredMenuElement.uncached`), so the
    /// mute title reflects live state rather than whatever was true when the
    /// cell was last configured.
    ///
    /// Ordering is thumb-first, and the pill sets
    /// `preferredMenuElementOrder = .priority` to keep it that way: this bar
    /// sits directly above the tab bar, so its menus always open UPWARD, and
    /// under `.automatic` UIKit would flip the ladder and put the destructive
    /// Remove nearest the thumb. `.priority` pins the first action closest to
    /// the touch and leaves Remove farthest from it.
    func menu(for subFilter: MapSubFilter) -> UIMenu? {
        guard let built = pillMenu(for: subFilter) else { return nil }
        return UIMenu(
            title: built.title,
            children: [built.header].compactMap { $0 } + built.liveSection()
        )
    }

    /// The same menu, split into what the pill can draw immediately and what
    /// it must ask for when the menu opens — see `MapPillMenu`. This is what
    /// the cell installs; `menu(for:)` is the assembled view of it, and both
    /// come from the same two builders so they cannot drift.
    func pillMenu(for subFilter: MapSubFilter) -> MapPillMenu? {
        guard let option = optionsBySubFilter[subFilter] else { return nil }
        let entity = MapSubFilterEntity(option: option)
        let label = option.content.accessibilityLabel
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-maps-trace-menu") {
            print("[maps] pill menu built at \(CACurrentMediaTime()) for \(subFilter) "
                + "title=\"\(option.favorite?.title ?? "-")\" "
                + "handle=\(option.favorite?.handle.map { "\"\($0)\"" } ?? "nil")")
        }
        #endif
        let header = headerSection(for: option, entity: entity, fallback: label)
        return MapPillMenu(
            // A headed menu has no caption: the header IS the name, and UIKit
            // would otherwise draw it twice.
            title: header == nil ? entity.menuTitle(fallback: label) : "",
            header: header,
            liveSection: { [weak self] in
                [self?.verbsSection(for: subFilter, entity: entity)].compactMap { $0 }
            }
        )
    }

    /// A PERSON is headed by a tappable row — their face, their name, and
    /// their handle under it — which opens the profile. It sits in its own
    /// inline section, and that is what draws the separator between the
    /// subject of the menu and the verbs acting on it.
    ///
    /// Everything else keeps the plain caption: a place category has no
    /// profile behind it, so a header that navigates nowhere would only look
    /// like a dead row.
    ///
    /// Every field here is read straight off the in-memory `MapFavorite` —
    /// nothing is fetched, awaited or resolved, which is what lets the cell
    /// install this eagerly.
    private func headerSection(
        for option: MapSubFilterOption,
        entity: MapSubFilterEntity,
        fallback: String
    ) -> UIMenu? {
        guard let header = entity.menuHeader(fallback: fallback) else { return nil }
        let subFilter = option.subFilter
        return UIMenu(options: .displayInline, children: [
            UIAction(
                title: header.title,
                subtitle: header.subtitle,
                image: headerImage(for: option),
                handler: { [weak self] _ in self?.perform(header.action, on: subFilter) }
            )
        ])
    }

    /// The verbs, read at the moment the menu opens: the mute entry reflects
    /// live state rather than whatever was true when the cell was configured.
    private func verbsSection(for subFilter: MapSubFilter, entity: MapSubFilterEntity) -> UIMenu {
        let muted = if case .person(let favorite) = entity {
            isMuted?(favorite.profileID) ?? false
        } else {
            false
        }
        let children = MapSubFilterMenuAction.actions(for: entity).map { action in
            UIAction(
                title: action.title(isMuted: muted),
                image: UIImage(systemName: action.symbolName(isMuted: muted)),
                attributes: action.isDestructive ? .destructive : [],
                handler: { [weak self] _ in self?.perform(action, on: subFilter) }
            )
        }
        return UIMenu(options: .displayInline, children: children)
    }

    /// The header's face: the resolved avatar, circle-cropped, or the generic
    /// person glyph while it is still loading. Cropped rather than handed over
    /// square because every other place this photo appears is a circle, and a
    /// menu row is the one place UIKit will not round it for us.
    private func headerImage(for option: MapSubFilterOption) -> UIImage? {
        guard let profileID = option.favorite?.profileID,
              let avatar = avatarCache[profileID]
        else { return UIImage(systemName: "person.crop.circle") }
        if let cropped = headerImageCache[profileID] { return cropped }
        // Cropping is a render pass, and the menu is now built whenever a
        // cell is configured rather than when one is opened — so this runs
        // for every visible pill on every restack. Cached against the avatar
        // that produced it (`loadAvatars` drops the entry when a new one
        // resolves).
        let cropped = avatar.mapMenuHeaderAvatar()
        headerImageCache[profileID] = cropped
        return cropped
    }

    /// Routes one chosen verb to its callback. Split out from menu building so
    /// the routing is exercisable without a long-press: a `UIAction`'s handler
    /// is not reachable from a test, its identity is.
    func perform(_ action: MapSubFilterMenuAction, on subFilter: MapSubFilter) {
        guard let option = optionsBySubFilter[subFilter] else { return }
        let favorite = option.favorite
        switch action {
        case .viewProfile:
            favorite.map { onViewProfile?($0) }
        case .sendMessage:
            favorite.map { onSendMessage?($0) }
        case .toggleMute:
            favorite.map { onToggleMute?($0) }
        case .viewDetails:
            if case .placeCategory(let token) = subFilter { onViewDetails?(token) }
        case .share:
            onShare?(option)
        case .unpin:
            onUnpinSubFilter?(subFilter)
        }
    }

    /// The All pill: clears every refinement at once. Absolute (never a
    /// toggle) and inert when the selection is already empty, so tapping the
    /// resting state can't fire a redundant query.
    private func didTapAll() {
        guard !selectedSubFilters.isEmpty else { return }
        setSelectedSubFilters([])
        onSubFiltersChanged?([])
    }

    /// Programmatic selection (no callback); reveals `reveal` if given.
    func setSelectedSubFilters(_ subFilters: Set<MapSubFilter>, reveal: MapSubFilter? = nil) {
        selectedSubFilters = subFilters
        UIView.performWithoutAnimation {
            for indexPath in collectionView.indexPathsForVisibleItems {
                guard let item = dataSource.itemIdentifier(for: indexPath),
                      let (content, selected) = presentation(for: item),
                      let cell = collectionView.cellForItem(at: indexPath) as? MapPillCell else { continue }
                cell.configure(content: content, height: Self.pillHeight, selected: selected)
                if case .subFilter(let subFilter) = item,
                   let favorite = optionsBySubFilter[subFilter]?.favorite {
                    cell.setAvatar(avatarCache[favorite.profileID])
                }
            }
        }
        // Selection nudges widths (weight shift) — glide, don't snap.
        UIView.mapBarMorph {
            self.collectionView.performBatchUpdates(nil)
            self.updateHeader()
        }
        // Only ever reveal the pill the viewer just touched: with several
        // selected, scrolling to "the selection" has no single answer.
        if let reveal, let indexPath = dataSource.indexPath(for: .subFilter(reveal)) {
            collectionView.layoutIfNeeded()
            if let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame {
                collectionView.scrollRectToVisible(frame, animated: true)
            }
        }
    }

    // MARK: - Contextual header

    /// One scroll pass: everything the fixed button derives from the row's
    /// offset — what fades beneath it, and what it does when tapped.
    private func updateHeader() {
        updateHeaderFade()
        updateHeaderRole(animated: true)
    }

    /// Cells nearing / sliding beneath the fixed button dissolve on approach
    /// (`MapBarDuckFade`): both surfaces are translucent glass, so a pill
    /// allowed to sit half-under would be sliced by the button's capsule edge
    /// into a blurred half and a sharp half — a hard visual clip. The
    /// approach-fade means nothing legible ever reaches the glass.
    private func updateHeaderFade() {
        for cell in collectionView.visibleCells {
            let frame = cell.convert(cell.bounds, to: self)
            // Pills scroll leading-ward under the button: penetration is how
            // far the pill's leading edge has advanced past the fade line
            // trailing it.
            let penetration = Self.headerTrailingX + MapBarDuckFade.approach - frame.minX
            cell.alpha = MapBarDuckFade.alpha(forPenetration: penetration)
        }
    }

    /// Flips the button between its two jobs as All dissolves in and out from
    /// under it. The swap is a pure CROSS-DISSOLVE, never a re-layout: both
    /// roles are title-less, so the circle's geometry is identical on both
    /// sides and only the glyph changes — a scale or slide would make a fixed
    /// piece of chrome twitch every time the row crosses the threshold.
    private func updateHeaderRole(animated: Bool) {
        let role = MapSubFilterHeaderRole.resolve(
            rowIsEmpty: orderedSubFilters.isEmpty,
            allLeadingEdgeX: allCellLeadingEdgeX(),
            headerTrailingX: Self.headerTrailingX
        )
        guard role != headerRole else { return }
        headerRole = role
        guard animated else {
            headerButton.setContent(role.content)
            return
        }
        UIView.transition(
            with: headerButton, duration: 0.22,
            options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState]
        ) {
            self.headerButton.setContent(role.content)
        }
    }

    /// The All cell's leading edge in bar coordinates, from LAYOUT ATTRIBUTES
    /// rather than the cell: once All has scrolled away it is recycled, and a
    /// nil cell would read as "no All in this row" — the one state that must
    /// keep the button organizing. Attributes exist whether or not the cell
    /// is realized.
    private func allCellLeadingEdgeX() -> CGFloat? {
        guard let indexPath = dataSource.indexPath(for: .all),
              let attributes = collectionView.collectionViewLayout
                  .layoutAttributesForItem(at: indexPath) else { return nil }
        return attributes.frame.minX - collectionView.contentOffset.x
    }

    private func didTapHeader() {
        switch headerRole {
        // Same destination for both: the full-list sheet IS the place people
        // are chosen from, so an empty rail's "+" opens exactly what organize
        // opens. The glyph differs because the promise does — organize edits a
        // row that exists, add offers to start one.
        case .organize, .add: onExpandTapped?()
        case .rewind: rewindToAll()
        }
    }

    /// The rewind: glide the row back to its head and clear the refinements,
    /// so the viewer lands exactly where a fresh row starts. Both halves are
    /// animated and independent — the scroll is honoured even when nothing
    /// was selected (the button's whole point is that All is off-screen), and
    /// the clear is skipped when the selection is already empty so it can't
    /// fire a redundant query.
    private func rewindToAll() {
        collectionView.setContentOffset(
            CGPoint(x: -collectionView.adjustedContentInset.left, y: 0), animated: true
        )
        guard !selectedSubFilters.isEmpty else { return }
        setSelectedSubFilters([])
        onSubFiltersChanged?([])
    }
}

extension MapSubFilterBarView: UICollectionViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateHeader()
    }

    /// The rewind's own glide ends here — re-derive rather than trust the
    /// last `didScroll` frame.
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        updateHeader()
    }

    /// Magnetic snap: the release lands the nearest pill's LEADING edge flush
    /// against the anchor the fixed button reserves, so no pill ever rests
    /// half-ducked beneath it. See `MapBarSnap`.
    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        targetContentOffset.pointee.x = MapBarSnap.offsetX(
            snapping: collectionView,
            proposedX: targetContentOffset.pointee.x,
            velocityX: velocity.x
        )
    }

    /// A release too slow to decelerate never honours the retargeted offset —
    /// snap it home directly.
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard !decelerate else { return }
        MapBarSnap.settle(collectionView)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        MapBarSnap.settle(collectionView)
    }
}
