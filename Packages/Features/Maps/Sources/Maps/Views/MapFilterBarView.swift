import CoreModels
import DesignSystem
import UIKit

/// The filter bar floating above the tab bar on the map — one horizontally
/// scrolling `UICollectionView`, edge to edge with NO fixed furniture:
///
///   ( 👥 ) ( 🫱 ) ( 📍 ) [ ◉ favorite ] [ ◉ favorite ] …
///    morphing primaries    capsules, one per pinned profile
///
/// Compositional layout + diffable snapshots. There is deliberately no sticky
/// "All" bubble here: the bar is SINGLE-selection, so "all" is simply the
/// absence of a selection — reachable by tapping the active pill again — and
/// a permanently-parked header would spend the leading third of a phone-width
/// row restating the resting state. Without an obstruction there is nothing
/// to duck-fade beneath and nothing to reserve, so the row rests against the
/// bar's own leading margin and every pill is legible for its whole travel.
/// (The sub bar keeps a fixed leading header — see `MapSubFilterBarView` —
/// because MULTI-selection genuinely needs a reset affordance.)
///
/// The icon primaries morph circle → icon+title capsule on selection via cell
/// self-sizing (`performBatchUpdates` inside the morph spring). A deliberate
/// free-floating overlay rather than a toolbar item — the iOS 26 bar systems
/// wrap custom items in their own glass capsule, and a second material inside
/// reads as a dark "double bubble" ring (the `GlassSegmentRow` doctrine).
///
/// Selection semantics: `nil` means "All" and is the default; every pill
/// toggles back to it on a second tap. Cells are presentation-only
/// (`MapPillCell`) — taps arrive through the pill's own `onTap`.
///
/// Clipping: bar and collection view never clip, so glass halos breathe;
/// the vertical halo padding lives in the section's content insets.
final class MapFilterBarView: UIView {
    /// Fired on every selection change; `nil` means "All".
    var onFilterChanged: ((MapFilter?) -> Void)?
    private(set) var selectedFilter: MapFilter?

    /// The bar-bubble invariant: system glass capsules (nav items, toolbar
    /// bubbles) are 36pt tall — the pills must read as the same family.
    static let pillHeight: CGFloat = 36
    /// Breathing room above/below the pills so the glass highlights, hairline
    /// borders, and selection glow render fully — a container sized exactly to
    /// the pill clips them at the top and bottom edges.
    static let verticalPadding: CGFloat = 6
    /// What the owner constrains the bar to: pill plus halo headroom.
    static var barHeight: CGFloat { pillHeight + verticalPadding * 2 }

    private enum Section: Hashable { case main }
    private enum Item: Hashable {
        case primary(MapFilter)
        case favorite(ProfileID)
    }

    /// The morphing icon primaries. "All" is not among them — it is the
    /// `nil` selection, not a pill.
    private static let primaries: [(filter: MapFilter, content: MapPillButton.Content)] = [
        (.friends, MapPillButton.Content(
            title: "Friends",
            symbolName: "person.2", selectedSymbolName: "person.2.fill",
            accessibilityLabel: "Friends",
            expandsWhenSelected: true
        )),
        (.following, MapPillButton.Content(
            title: "Following",
            symbolName: "person.wave.2", selectedSymbolName: "person.wave.2.fill",
            accessibilityLabel: "Following",
            expandsWhenSelected: true
        )),
        (.pinned, MapPillButton.Content(
            title: "Places",
            symbolName: "mappin.and.ellipse", selectedSymbolName: "mappin.and.ellipse",
            accessibilityLabel: "Pinned Places",
            expandsWhenSelected: true
        ))
    ]

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var favoritesByID: [ProfileID: MapFavorite] = [:]

    init() {
        super.init(frame: .zero)
        configureCollectionView()
        applySnapshot(favorites: [], animatingDifferences: false)
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
        // Halo padding above/below the pills; the horizontal rest insets come
        // from the collection view's contentInset (which is also the snap
        // anchor — see `MapBarSnap`).
        section.contentInsets = NSDirectionalEdgeInsets(
            top: Self.verticalPadding, leading: 0,
            bottom: Self.verticalPadding, trailing: Spacing.lg
        )
        return UICollectionViewCompositionalLayout(section: section, configuration: configuration)
    }

    private func configureCollectionView() {
        collectionView = MapBarCollectionView(frame: .zero, collectionViewLayout: makeLayout())
        // Halos must never be cut mid-render: neither the bar nor the
        // collection view masks (safe — it spans the bar edge-to-edge, so
        // overscrolled content exits the screen).
        clipsToBounds = false
        collectionView.clipsToBounds = false
        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.delegate = self
        // A selection swap changes pill intrinsics (weight, morph) — cells
        // must re-self-size on content/constraint changes, not serve their
        // cached measurement (a stale width wraps the title).
        collectionView.selfSizingInvalidation = .enabledIncludingConstraints
        // Highlight must land on touch-down, not after the scroll-intent
        // grace period — the press dip reads as lag otherwise.
        collectionView.delaysContentTouches = false
        // The leading container margin — and, with no fixed bubble to clear,
        // also the snap anchor (`MapBarSnap` reads exactly this inset), so the
        // resting offset and the first pill's snap target are the same number
        // by construction. Trailing breathing room lives in the section's own
        // insets, so it rides inside the content size.
        collectionView.contentInset = UIEdgeInsets(top: 0, left: Spacing.lg, bottom: 0, right: 0)
        collectionView.pin(to: self)

        let pillRegistration = UICollectionView.CellRegistration<MapPillCell, Item> { [weak self] cell, _, item in
            guard let self, let (content, selected) = self.presentation(for: item) else { return }
            cell.configure(content: content, height: Self.pillHeight, selected: selected)
            // The pill is natively interactive — its own tracking supplies
            // press feedback; the recognized tap routes into selection.
            cell.onTap = { [weak self] in
                guard let self else { return }
                self.didTap(self.filter(for: item))
            }
        }
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) {
            collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: pillRegistration, for: indexPath, item: item)
        }

    }

    private func presentation(for item: Item) -> (MapPillButton.Content, Bool)? {
        switch item {
        case .primary(let filter):
            guard let content = Self.primaries.first(where: { $0.filter == filter })?.content else { return nil }
            return (content, filter == selectedFilter)
        case .favorite(let id):
            guard let favorite = favoritesByID[id] else { return nil }
            let content = MapPillButton.Content(
                title: favorite.title,
                symbolName: "person.crop.circle", selectedSymbolName: "person.crop.circle.fill",
                accessibilityLabel: favorite.title
            )
            return (content, MapFilter.profile(id) == selectedFilter)
        }
    }

    private func filter(for item: Item) -> MapFilter {
        switch item {
        case .primary(let filter): filter
        case .favorite(let id): .profile(id)
        }
    }

    private func applySnapshot(favorites: [MapFavorite], animatingDifferences: Bool) {
        favoritesByID = Dictionary(uniqueKeysWithValues: favorites.map { ($0.profileID, $0) })
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.main])
        snapshot.appendItems(Self.primaries.map { .primary($0.filter) })
        snapshot.appendItems(favorites.map { .favorite($0.profileID) })
        dataSource.apply(snapshot, animatingDifferences: animatingDifferences)
    }

    // MARK: - Favorites

    /// Populates (or refreshes) the favorites section. Structure lands
    /// synchronously at final widths, arrival is a pure cross-dissolve. If the
    /// active filter's favorite disappeared in the refresh, selection falls
    /// back to All.
    func setFavorites(_ favorites: [MapFavorite]) {
        UIView.performWithoutAnimation {
            applySnapshot(favorites: favorites, animatingDifferences: false)
            collectionView.layoutIfNeeded()
        }

        if case .profile(let id) = selectedFilter, favoritesByID[id] == nil {
            selectedFilter = nil
            onFilterChanged?(nil)
            reconfigureVisiblePresentation()
        }

        for indexPath in collectionView.indexPathsForVisibleItems {
            if case .favorite = dataSource.itemIdentifier(for: indexPath) {
                collectionView.cellForItem(at: indexPath)?.alpha = 0
            }
        }
        UIView.mapBarFade {
            for cell in self.collectionView.visibleCells { cell.alpha = 1 }
        }
    }

    // MARK: - Selection

    private func didTap(_ filter: MapFilter?) {
        // "All" is absolute; the others toggle back to All on a second tap.
        let next: MapFilter?
        if let filter {
            next = (filter == selectedFilter) ? nil : filter
        } else {
            next = nil
        }
        guard next != selectedFilter else { return }
        setSelectedFilter(next, animated: true)
        onFilterChanged?(next)
    }

    /// Programmatic selection (no callback). Content swaps land atomically,
    /// then one morph-spring batch update glides every frame (an expanding
    /// primary pushes its neighbors aside smoothly — the sanctioned width
    /// animation) and reveals the selected pill.
    func setSelectedFilter(_ filter: MapFilter?, animated: Bool = true) {
        selectedFilter = filter
        reconfigureVisiblePresentation()
        if animated {
            UIView.mapBarMorph { self.collectionView.performBatchUpdates(nil) }
        } else {
            UIView.performWithoutAnimation {
                self.collectionView.collectionViewLayout.invalidateLayout()
                self.collectionView.layoutIfNeeded()
            }
        }
        // Reveal the selected pill. Clearing to All reveals nothing — there
        // is no "All" pill to scroll to, and yanking the row home behind the
        // viewer's back would undo their scroll position for free.
        if let filter, let indexPath = dataSource.indexPath(for: item(for: filter)) {
            collectionView.layoutIfNeeded()
            if let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame {
                collectionView.scrollRectToVisible(frame, animated: true)
            }
        }
    }

    private func item(for filter: MapFilter) -> Item {
        if case .profile(let id) = filter { .favorite(id) } else { .primary(filter) }
    }

    /// Pushes the current selection into every on-screen pill — atomically,
    /// content only; sizing animates separately.
    private func reconfigureVisiblePresentation() {
        UIView.performWithoutAnimation {
            for indexPath in collectionView.indexPathsForVisibleItems {
                guard let item = dataSource.itemIdentifier(for: indexPath),
                      let cell = collectionView.cellForItem(at: indexPath) as? MapPillCell,
                      let (content, selected) = presentation(for: item) else { continue }
                cell.configure(content: content, height: Self.pillHeight, selected: selected)
            }
        }
    }
}

extension MapFilterBarView: UICollectionViewDelegate {
    /// Magnetic snap: the release lands the nearest pill's leading edge flush
    /// against the bar's leading container margin, so the row always comes to
    /// rest on a pill boundary rather than mid-capsule. See `MapBarSnap`.
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
