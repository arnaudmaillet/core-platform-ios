import CoreModels
import DesignSystem
import UIKit

/// The filter bar floating above the tab bar on the map — one horizontally
/// scrolling `UICollectionView`:
///
///   [ ✦ All ] ( 👥 ) ( 🫱 ) ( 📍 ) [ ◉ favorite ] [ ◉ favorite ] …
///    pinned     morphing primaries    capsules, one per pinned profile
///
/// Compositional layout + diffable snapshots. "All" is a boundary
/// supplementary with `pinToVisibleBounds` — it scrolls as the leading item
/// and pins to the leading edge once the row runs past it, with cells
/// duck-fading beneath it (custom scroll pass; pinned headers can't fade
/// their underlap). The icon primaries morph circle → icon+title capsule on
/// selection via cell self-sizing (`performBatchUpdates` inside the morph
/// spring). A deliberate free-floating overlay rather than a toolbar item —
/// the iOS 26 bar systems wrap custom items in their own glass capsule, and
/// a second material inside reads as a dark "double bubble" ring (the
/// `GlassSegmentRow` doctrine).
///
/// Selection semantics: "All" renders the `nil` selection and is active by
/// default; other pills toggle back to All on a second tap. Cells are
/// presentation-only (`MapPillCell`) — taps arrive via `didSelectItemAt`.
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

    /// The morphing icon primaries (All lives in the fixed leading bubble).
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

    private static let allContent = MapPillButton.Content(
        title: "All",
        symbolName: "sparkles", selectedSymbolName: "sparkles",
        accessibilityLabel: "All posts"
    )

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var favoritesByID: [ProfileID: MapFavorite] = [:]
    /// The sticky "All": a FIXED interactive pill overlaying the leading
    /// edge (the sub bar's expand-bubble architecture, mirrored). NOT a
    /// pinned boundary supplementary — compositional pinning hosts the
    /// header in a private container that hard-clips cells across a fixed
    /// leading region (pills sliced in half ~50pt past the header, verified
    /// via frame logging), and it culls nothing here since the button never
    /// scrolls at all.
    private let allButton = MapPillButton(
        content: MapFilterBarView.allContent, height: MapFilterBarView.pillHeight
    )

    init() {
        super.init(frame: .zero)
        configureCollectionView()
        configureAllButton()
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
        // Halo padding above/below the pills; horizontal rest insets come
        // from the collection view's contentInset (the leading one is sized
        // to the fixed All bubble at layout time).
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
        // Leading inset is finalized in layoutSubviews once the All bubble
        // has a width; this is the pre-layout approximation.
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

    private func configureAllButton() {
        addSubview(allButton)
        allButton.translatesAutoresizingMaskIntoConstraints = false
        // Above the cells gliding beneath it.
        allButton.layer.zPosition = 1
        NSLayoutConstraint.activate([
            allButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.lg),
            allButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        allButton.addAction(UIAction { [weak self] _ in self?.didTap(nil) }, for: .touchUpInside)
        allButton.setSelectedAppearance(true) // resting state: All active
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The scrolled row rests just past the fixed All bubble; keep the
        // inset honest as All's width shifts with its selection weight.
        let neededInset = allButton.frame.maxX + Spacing.sm
        if abs(collectionView.contentInset.left - neededInset) > 0.5, neededInset > 0 {
            let atRest = collectionView.contentOffset.x <= -collectionView.contentInset.left + 0.5
            collectionView.contentInset.left = neededInset
            if atRest {
                collectionView.contentOffset.x = -neededInset
            }
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
    /// synchronously, arrival is a pure cross-dissolve to each cell's resting
    /// alpha (the sticky duck-fade decides that). If the active filter's
    /// favorite disappeared in the refresh, selection falls back to All.
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
        UIView.mapBarFade { self.updateStickyFade() }
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
            UIView.mapBarMorph {
                self.collectionView.performBatchUpdates(nil)
                self.updateStickyFade()
            }
        } else {
            UIView.performWithoutAnimation {
                self.collectionView.collectionViewLayout.invalidateLayout()
                self.collectionView.layoutIfNeeded()
            }
        }
        // Reveal the selected pill (not for All — the sticky header is
        // always on screen, and clearing shouldn't yank the row home).
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

    /// Pushes the current selection into every on-screen pill + the fixed
    /// All bubble — atomically, content only; sizing animates separately.
    private func reconfigureVisiblePresentation() {
        UIView.performWithoutAnimation {
            for indexPath in collectionView.indexPathsForVisibleItems {
                guard let item = dataSource.itemIdentifier(for: indexPath),
                      let cell = collectionView.cellForItem(at: indexPath) as? MapPillCell,
                      let (content, selected) = presentation(for: item) else { continue }
                cell.configure(content: content, height: Self.pillHeight, selected: selected)
            }
        }
        allButton.setSelectedAppearance(selectedFilter == nil)
    }

    // MARK: - Sticky duck-fade

    /// Cells nearing / passing beneath the fixed All bubble dissolve on
    /// approach (`MapBarDuckFade`): both surfaces are translucent glass, so a
    /// pill allowed to sit half-under would be sliced by the bubble's capsule
    /// edge into a blurred half and a sharp half — a hard visual clip. The
    /// approach-fade means nothing legible ever reaches the glass. Exact
    /// mirror of the sub bar's trailing treatment, on the leading side.
    private func updateStickyFade() {
        let allFrame = allButton.frame // bar coords
        for cell in collectionView.visibleCells {
            let frame = cell.convert(cell.bounds, to: self)
            // Pills scroll leading-ward under the bubble: penetration is how
            // far the pill's leading edge has advanced past the fade line
            // trailing the bubble.
            let penetration = allFrame.maxX + MapBarDuckFade.approach - frame.minX
            cell.alpha = MapBarDuckFade.alpha(forPenetration: penetration)
        }
    }
}

extension MapFilterBarView: UICollectionViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateStickyFade()
    }
}
