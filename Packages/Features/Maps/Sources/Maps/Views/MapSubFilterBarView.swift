import CoreModels
import DesignSystem
import MediaCore
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
                title: "Cafes",
                symbolName: "cup.and.saucer", selectedSymbolName: "cup.and.saucer.fill",
                accessibilityLabel: "Cafes"
            ),
            favorite: nil
        ),
        MapSubFilterOption(
            subFilter: .placeCategory("restaurants"),
            content: MapPillButton.Content(
                title: "Restaurants",
                symbolName: "fork.knife", selectedSymbolName: "fork.knife",
                accessibilityLabel: "Restaurants"
            ),
            favorite: nil
        ),
        MapSubFilterOption(
            subFilter: .placeCategory("parks"),
            content: MapPillButton.Content(
                title: "Parks",
                symbolName: "tree", selectedSymbolName: "tree.fill",
                accessibilityLabel: "Parks"
            ),
            favorite: nil
        ),
        MapSubFilterOption(
            subFilter: .placeCategory("nightlife"),
            content: MapPillButton.Content(
                title: "Nightlife",
                symbolName: "moon.stars", selectedSymbolName: "moon.stars.fill",
                accessibilityLabel: "Nightlife"
            ),
            favorite: nil
        )
    ]

    /// Person refinements (Friends/Following rows): avatar + first name.
    static func people(_ people: [MapFavorite]) -> [MapSubFilterOption] {
        people.map { person in
            MapSubFilterOption(
                subFilter: .profile(person.profileID),
                content: MapPillButton.Content(
                    title: firstName(of: person.title),
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
    /// Long-press menu action on a person pill.
    var onTogglePin: ((MapFavorite) -> Void)?
    /// Whether a person is currently pinned (titles the menu Pin vs Unpin).
    var isPinned: ((ProfileID) -> Bool)?
    /// Resolves avatar thumbnails for people pills.
    var imagePipeline: ImagePipeline?

    /// Every refinement currently applied; empty means "no refinement".
    private(set) var selectedSubFilters: Set<MapSubFilter> = []

    /// One size below the main bar's 36pt family, per the type ladder.
    static let pillHeight: CGFloat = 32
    /// Same halo headroom rationale as the main bar.
    static let verticalPadding: CGFloat = 6
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
    private enum Item: Hashable {
        case all
        case subFilter(MapSubFilter)
    }

    private static let allContent = MapPillButton.Content(
        title: "All",
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
            widthDimension: .estimated(80), heightDimension: .absolute(Self.pillHeight)
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
                // Pin/Unpin menu directly on the pill (people only).
                cell.onTap = { [weak self] in self?.didTap(subFilter) }
                if let favorite = self.optionsBySubFilter[subFilter]?.favorite {
                    cell.setAvatar(self.avatarCache[favorite.profileID])
                    cell.menuProvider = { [weak self] in
                        guard let self else { return nil }
                        let pinned = self.isPinned?(favorite.profileID) ?? false
                        return UIMenu(children: [
                            UIAction(
                                title: pinned ? "Unpin from Favorites" : "Pin to Favorites",
                                image: UIImage(systemName: pinned ? "pin.slash" : "pin"),
                                handler: { [weak self] _ in self?.onTogglePin?(favorite) }
                            )
                        ])
                    }
                } else {
                    cell.menuProvider = nil
                }
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
        // faded (the new cells are at alpha 0, so this can't flash).
        for cell in collectionView.visibleCells { cell.alpha = 0 }
        collectionView.alpha = 1
        // The row is home, so the button is back to organizing — but this is
        // a content swap, not a scroll: land that state, don't crossfade it.
        UIView.mapBarFade { self.updateHeaderFade() }
        updateHeaderRole(animated: false)
        loadAvatars(for: options)
    }

    /// The row's items: All at the head, then the refinements in order.
    private static func items(for subFilters: [MapSubFilter]) -> [Item] {
        [.all] + subFilters.map(Item.subFilter)
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
        orderedSubFilters = options.map(\.subFilter)
        optionsBySubFilter = Dictionary(uniqueKeysWithValues: options.map { ($0.subFilter, $0) })
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.main])
        snapshot.appendItems(Self.items(for: orderedSubFilters))
        dataSource.apply(snapshot, animatingDifferences: true) { [weak self] in
            // Pills changed seats: whoever now sits under the fixed button
            // must re-derive its duck-fade alpha — and All may have moved
            // out from under it, or back beneath it.
            self?.updateHeader()
        }
    }

    /// Cross-dissolves to a new option set while the row stays visible (a
    /// primary-to-primary switch, e.g. Friends → Places): fade the current
    /// cells out, swap the content at zero alpha, fade the new cells in.
    /// The fixed button deliberately stays put — it belongs to the bar, not
    /// to either state. Safe under rapid taps: a newer transition
    /// (or a direct `setOptions`) supersedes the pending swap.
    func transition(to options: [MapSubFilterOption]) {
        transitionGeneration += 1
        let generation = transitionGeneration
        UIView.mapBarFade(
            { self.collectionView.alpha = 0 },
            completion: { _ in
                guard generation == self.transitionGeneration else { return }
                // Content swaps at alpha 0; `setOptions` restores the scroll
                // surface and fades the new cells in.
                self.setOptions(options)
            }
        )
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
                // Atomic content refresh — no width animation on arrival.
                UIView.performWithoutAnimation {
                    if let indexPath = self.dataSource.indexPath(for: .subFilter(subFilter)) {
                        (self.collectionView.cellForItem(at: indexPath) as? MapPillCell)?.setAvatar(image)
                        self.collectionView.collectionViewLayout.invalidateLayout()
                        self.collectionView.layoutIfNeeded()
                    }
                }
            })
        }
    }

    // MARK: - Selection

    private func didTap(_ subFilter: MapSubFilter) {
        // Every tap toggles its own pill; the rest hold their state.
        let next = selectedSubFilters.symmetricDifference([subFilter])
        setSelectedSubFilters(next, reveal: subFilter)
        onSubFiltersChanged?(next)
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
            allLeadingEdgeX: allCellLeadingEdgeX(), headerTrailingX: Self.headerTrailingX
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
        case .organize: onExpandTapped?()
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
