import CoreModels
import DesignSystem
import MediaCore
import UIKit

/// One entry in the sub-filter bar: the refinement it applies plus its pill
/// presentation. People entries carry their `MapFavorite` (full name + avatar
/// URL) for the pin menu and the full-list sheet.
struct MapSubFilterOption {
    let subFilter: MapSubFilter
    let content: MapPillButton.Content
    let favorite: MapFavorite?

    /// The full-list sheet's row title (full name for people, pill title
    /// otherwise).
    var sheetTitle: String { favorite?.title ?? content.title ?? content.accessibilityLabel }

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
/// Anatomy: the pill row plus a FIXED circular expand button pinned to the
/// trailing edge (opens the full-list sheet — presentation is the view
/// controller's job, reported via `onExpandTapped`). Cells scrolling past
/// the fixed button duck-fade beneath it, mirroring the main bar's sticky
/// treatment. Long-pressing a person pill offers Pin/Unpin to Favorites via
/// the collection view's native context-menu hooks.
///
/// Single-select; tapping the active pill clears the refinement (back to the
/// bare primary). Cells are presentation-only (`MapPillCell`).
final class MapSubFilterBarView: UIView {
    /// Fired on every selection change; `nil` means "no refinement".
    var onSubFilterChanged: ((MapSubFilter?) -> Void)?
    /// The trailing expand bubble was tapped — present the full-list sheet.
    var onExpandTapped: (() -> Void)?
    /// Long-press menu action on a person pill.
    var onTogglePin: ((MapFavorite) -> Void)?
    /// Whether a person is currently pinned (titles the menu Pin vs Unpin).
    var isPinned: ((ProfileID) -> Bool)?
    /// Resolves avatar thumbnails for people pills.
    var imagePipeline: ImagePipeline?

    private(set) var selectedSubFilter: MapSubFilter?

    /// One size below the main bar's 36pt family, per the type ladder.
    static let pillHeight: CGFloat = 32
    /// Same halo headroom rationale as the main bar.
    static let verticalPadding: CGFloat = 6
    static var barHeight: CGFloat { pillHeight + verticalPadding * 2 }

    private enum Section: Hashable { case main }

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, MapSubFilter>!
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

    private let expandButton = MapPillButton(
        content: MapPillButton.Content(
            title: nil,
            symbolName: "list.bullet", selectedSymbolName: "list.bullet",
            accessibilityLabel: "Show full list"
        ),
        height: MapSubFilterBarView.pillHeight
    )

    init() {
        super.init(frame: .zero)
        configureCollectionView()
        configureExpandButton()
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
        // Trailing inset clears the fixed expand bubble so pills rest free of
        // it and only overlap mid-scroll (where the duck-fade takes over).
        collectionView.contentInset = UIEdgeInsets(
            top: 0, left: Spacing.lg,
            bottom: 0, right: Spacing.lg + Self.pillHeight + Spacing.sm
        )
        collectionView.pin(to: self)

        let pillRegistration = UICollectionView.CellRegistration<MapPillCell, MapSubFilter> { [weak self] cell, _, subFilter in
            guard let self, let option = self.optionsBySubFilter[subFilter] else { return }
            cell.configure(
                content: option.content, height: Self.pillHeight,
                selected: subFilter == self.selectedSubFilter
            )
            // Native pill interaction: tap → selection; long-press → the
            // Pin/Unpin menu directly on the pill (people only).
            cell.onTap = { [weak self] in self?.didTap(subFilter) }
            if let favorite = option.favorite {
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
        dataSource = UICollectionViewDiffableDataSource<Section, MapSubFilter>(collectionView: collectionView) {
            collectionView, indexPath, subFilter in
            collectionView.dequeueConfiguredReusableCell(using: pillRegistration, for: indexPath, item: subFilter)
        }
    }

    private func configureExpandButton() {
        // The fixed expand bubble: a sibling of the collection view (it must
        // not scroll), floating above cells gliding beneath it.
        addSubview(expandButton)
        expandButton.translatesAutoresizingMaskIntoConstraints = false
        expandButton.layer.zPosition = 1
        NSLayoutConstraint.activate([
            expandButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.lg),
            expandButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        expandButton.addAction(UIAction { [weak self] _ in self?.onExpandTapped?() }, for: .touchUpInside)
    }

    // MARK: - Content

    /// Replaces the row's options; selection resets (a new option set always
    /// belongs to a freshly chosen primary) and the row rewinds to its head.
    /// Structure lands synchronously at final widths, arrival is a pure
    /// cross-dissolve to each cell's resting alpha (the trailing duck-fade
    /// decides that); avatars resolve async into the cache and reconfigure.
    func setOptions(_ options: [MapSubFilterOption]) {
        // Direct set supersedes any in-flight cross-dissolve…
        transitionGeneration += 1
        for task in avatarTasks { task.cancel() }
        avatarTasks.removeAll()
        selectedSubFilter = nil
        orderedSubFilters = options.map(\.subFilter)
        optionsBySubFilter = Dictionary(uniqueKeysWithValues: options.map { ($0.subFilter, $0) })

        UIView.performWithoutAnimation {
            var snapshot = NSDiffableDataSourceSnapshot<Section, MapSubFilter>()
            snapshot.appendSections([.main])
            snapshot.appendItems(orderedSubFilters)
            // A fresh option set may reuse identities (friends ⊂ following) —
            // force reconfiguration so stale presentation can't survive.
            snapshot.reconfigureItems(orderedSubFilters)
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
        UIView.mapBarFade { self.updateTrailingFade() }
        loadAvatars(for: options)
    }

    /// Cross-dissolves to a new option set while the row stays visible (a
    /// primary-to-primary switch, e.g. Friends → Places): fade the current
    /// cells out, swap the content at zero alpha, fade the new cells in.
    /// The fixed expand bubble deliberately stays put — it belongs to the
    /// bar, not to either state. Safe under rapid taps: a newer transition
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
                    if let indexPath = self.dataSource.indexPath(for: subFilter) {
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
        // Re-tapping the active refinement clears it.
        let next: MapSubFilter? = (subFilter == selectedSubFilter) ? nil : subFilter
        setSelectedSubFilter(next)
        onSubFilterChanged?(next)
    }

    /// Programmatic selection (no callback); reveals the selected pill.
    func setSelectedSubFilter(_ subFilter: MapSubFilter?) {
        selectedSubFilter = subFilter
        UIView.performWithoutAnimation {
            for indexPath in collectionView.indexPathsForVisibleItems {
                guard let item = dataSource.itemIdentifier(for: indexPath),
                      let option = optionsBySubFilter[item],
                      let cell = collectionView.cellForItem(at: indexPath) as? MapPillCell else { continue }
                cell.configure(
                    content: option.content, height: Self.pillHeight,
                    selected: item == subFilter
                )
                if let favorite = option.favorite {
                    cell.setAvatar(avatarCache[favorite.profileID])
                }
            }
        }
        // Selection nudges widths (weight shift) — glide, don't snap.
        UIView.mapBarMorph {
            self.collectionView.performBatchUpdates(nil)
            self.updateTrailingFade()
        }
        if let subFilter, let indexPath = dataSource.indexPath(for: subFilter) {
            collectionView.layoutIfNeeded()
            if let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame {
                collectionView.scrollRectToVisible(frame, animated: true)
            }
        }
    }

    // MARK: - Trailing duck-fade

    /// Mirrors the main bar's sticky treatment at the trailing edge: cells
    /// nearing / sliding beneath the fixed expand bubble dissolve on
    /// approach (`MapBarDuckFade`), so nothing legible ever sits under its
    /// glass and the bubble's edge never reads as a hard clip.
    private func updateTrailingFade() {
        let buttonFrame = expandButton.frame // bar coords
        for cell in collectionView.visibleCells {
            let frame = cell.convert(cell.bounds, to: self)
            // Pills scroll trailing-ward under the bubble: penetration is how
            // far the pill's trailing edge has advanced past the fade line
            // leading the bubble.
            let penetration = frame.maxX - (buttonFrame.minX - MapBarDuckFade.approach)
            cell.alpha = MapBarDuckFade.alpha(forPenetration: penetration)
        }
    }
}

extension MapSubFilterBarView: UICollectionViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateTrailingFade()
    }
}
