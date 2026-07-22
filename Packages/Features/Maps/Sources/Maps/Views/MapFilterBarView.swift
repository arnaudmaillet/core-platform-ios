import CoreModels
import DesignSystem
import UIKit

/// The filter bar floating above the tab bar on the map — one horizontally
/// scrolling row:
///
///   [ ✦ All ] ( 👥 ) ( 🫱 ) ( 📍 ) [ ◉ favorite ] [ ◉ favorite ] …
///    capsule    circular bubbles     capsules, one per followed profile
///
/// "All" is the leading header item of the scrollable content — and a STICKY
/// one: once the row scrolls past it, it pins to the leading edge (translated
/// by the scroll overshoot, floating above the pills gliding beneath) and
/// settles back into its natural slot as the row scrolls home. The icon-only
/// primaries are perfect 36×36 circular glass bubbles; favorites are
/// icon + name capsules. Everything else scrolls as one smooth surface. A
/// deliberate free-floating overlay rather than a toolbar item — the iOS 26
/// bar systems wrap custom items in their own glass capsule, and a second
/// material inside reads as a dark "double bubble" ring (the
/// `GlassSegmentRow` doctrine).
///
/// Pills are plain `MapPillButton`s — no collection view: the set is small,
/// nothing recycles, and selection is a straight configuration swap. "All"
/// renders the `nil` selection and is active by default; other pills toggle
/// back to All on a second tap.
///
/// Clipping: neither the bar nor the scroll view clips (`clipsToBounds =
/// false`) so glass halos breathe — safe because the scroll view spans the
/// bar edge-to-edge (overscrolled content exits the screen, it has no fixed
/// sibling to draw over).
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

    /// One selectable pill: the filter it represents (`nil` = All) + button.
    private struct Entry {
        let filter: MapFilter?
        let pill: MapPillButton
    }

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var primaryEntries: [Entry] = []
    private var favoriteEntries: [Entry] = []
    private var allEntries: [Entry] { primaryEntries + favoriteEntries }

    /// The fixed section: All (icon + text, the default) then icon-only
    /// Friends / Following / Places.
    private static let primaries: [(filter: MapFilter?, content: MapPillButton.Content)] = [
        (nil, MapPillButton.Content(
            title: "All",
            symbolName: "sparkles", selectedSymbolName: "sparkles",
            accessibilityLabel: "All posts"
        )),
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

    init() {
        super.init(frame: .zero)
        configureLayout()
        configurePrimaryPills()
        // The default state: "All" active until a narrower pill is chosen.
        applySelectionAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Layout

    private func configureLayout() {
        // Halos must never be cut mid-render: neither the bar nor the scroll
        // view masks (safe — the scroll view spans the bar edge-to-edge, so
        // overscrolled content exits the screen rather than covering anything).
        clipsToBounds = false
        scrollView.clipsToBounds = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.delegate = self
        // Pills scroll edge-to-edge but rest inset from the screen edges.
        scrollView.contentInset = UIEdgeInsets(top: 0, left: Spacing.lg, bottom: 0, right: Spacing.lg)
        scrollView.pin(to: self)

        stack.axis = .horizontal
        stack.spacing = Spacing.sm
        // .fill (NOT .fillEqually): each pill keeps its intrinsic width.
        stack.distribution = .fill
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            // The halo padding lives inside the content, so the content height
            // matches the frame (no incidental vertical scroll).
            stack.topAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.topAnchor, constant: Self.verticalPadding
            ),
            stack.bottomAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -Self.verticalPadding
            )
        ])
    }

    private func configurePrimaryPills() {
        primaryEntries = Self.primaries.map { makeEntry(filter: $0.filter, content: $0.content) }
        for entry in primaryEntries { stack.addArrangedSubview(entry.pill) }
        // The sticky header must draw ABOVE the pills gliding beneath it.
        // z only — arrangement (and thus layout) is untouched.
        primaryEntries.first?.pill.layer.zPosition = 1
    }

    private func makeEntry(filter: MapFilter?, content: MapPillButton.Content) -> Entry {
        let pill = MapPillButton(content: content, height: Self.pillHeight)
        pill.addAction(UIAction { [weak self] _ in self?.didTap(filter) }, for: .touchUpInside)
        return Entry(filter: filter, pill: pill)
    }

    /// The sticky-header engine: once the row scrolls past "All"'s natural
    /// slot, translate it by exactly the overshoot so it pins to the leading
    /// rest edge; at-or-before rest, identity — it rides (and rubber-bands)
    /// with the row and settles seamlessly into its origin. Transforms don't
    /// disturb Auto Layout's alignment rects, so the stack never re-lays-out,
    /// and hit-testing follows the pill wherever it sits.
    ///
    /// Pills passing beneath the pinned header fade out in proportion to how
    /// far they've slid under it — both surfaces are translucent glass, so
    /// without the fade the underlying pill's text reads straight through the
    /// header ("All" + "ji Tanaka" collide into gibberish).
    private func updateStickyHeader() {
        guard let allPill = primaryEntries.first?.pill else { return }
        let overshoot = scrollView.contentOffset.x + scrollView.adjustedContentInset.left
        allPill.transform = overshoot > 0 ? CGAffineTransform(translationX: overshoot, y: 0) : .identity

        let headerFrame = allPill.frame // transform-inclusive, stack coords
        for entry in allEntries where entry.pill !== allPill {
            let frame = entry.pill.frame
            guard headerFrame.maxX > frame.minX, headerFrame.minX < frame.maxX, frame.width > 0 else {
                entry.pill.alpha = 1
                continue
            }
            let overlap = min(headerFrame.maxX, frame.maxX) - max(headerFrame.minX, frame.minX)
            // Ramp over a short duck-under distance, not the pill's full
            // width — a wide favorite would otherwise linger half-faded with
            // its text still ghosting through the header's glass.
            let rampDistance = min(frame.width, Self.stickyFadeDistance)
            entry.pill.alpha = 1 - min(1, overlap / rampDistance)
        }
    }

    /// How far a pill slides beneath the sticky header before it is fully
    /// faded (shorter for pills narrower than this).
    private static let stickyFadeDistance: CGFloat = 60

    // MARK: - Favorites

    /// Populates (or refreshes) the scrollable favorites section. If the
    /// active filter's favorite disappeared in the refresh, selection falls
    /// back to All — silently, since nothing narrower is being shown anymore.
    func setFavorites(_ favorites: [MapFavorite]) {
        for entry in favoriteEntries { entry.pill.removeFromSuperview() }
        favoriteEntries = favorites.map { favorite in
            makeEntry(
                filter: .profile(favorite.profileID),
                content: MapPillButton.Content(
                    title: favorite.title,
                    symbolName: "person.crop.circle", selectedSymbolName: "person.crop.circle.fill",
                    accessibilityLabel: favorite.title
                )
            )
        }
        for entry in favoriteEntries { stack.addArrangedSubview(entry.pill) }

        if case .profile(let id) = selectedFilter,
           !favorites.contains(where: { $0.profileID == id }) {
            selectedFilter = nil
            onFilterChanged?(nil)
        }
        applySelectionAppearance()

        // Structure synchronously, arrival as a pure cross-dissolve — the
        // sticky-fade pass decides each pill's resting alpha (same recipe as
        // the sub-filter row; no width interpolation, ever).
        UIView.performWithoutAnimation { layoutIfNeeded() }
        for entry in favoriteEntries { entry.pill.alpha = 0 }
        UIView.animate(
            withDuration: 0.2, delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            self.updateStickyHeader()
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

    /// Programmatic selection (no callback) — keeps the pills honest if state
    /// is ever restored from outside. Reveals the selected pill: an active
    /// filter hiding off the carousel's edge would leave the bar looking
    /// unfiltered while the map is not. (Not for All — the sticky header is
    /// always on screen, and clearing shouldn't yank the row home.)
    func setSelectedFilter(_ filter: MapFilter?, animated: Bool = true) {
        selectedFilter = filter
        applySelectionAppearance(animated: animated)
        if filter != nil, let selected = allEntries.first(where: { $0.filter == filter })?.pill {
            scrollView.layoutIfNeeded()
            scrollView.scrollRectToVisible(
                selected.convert(selected.bounds, to: scrollView), animated: true
            )
        }
    }

    /// Appearance swap plus — when animated — the deliberate width morph:
    /// pill content/constraints land atomically inside the pills, then one
    /// animated layout pass glides every frame (an expanding primary pushes
    /// its neighbors aside smoothly) and retargets the sticky header + fades
    /// for the new geometry. This is the sanctioned width animation: both
    /// endpoints are fully-laid-out states, unlike the appearance accordion.
    private func applySelectionAppearance(animated: Bool = false) {
        for entry in allEntries {
            entry.pill.setSelectedAppearance(entry.filter == selectedFilter)
        }
        guard animated else {
            UIView.performWithoutAnimation { layoutIfNeeded() }
            return
        }
        UIView.animate(
            withDuration: 0.25, delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            self.layoutIfNeeded()
            self.updateStickyHeader()
        }
    }
}

extension MapFilterBarView: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateStickyHeader()
    }
}
