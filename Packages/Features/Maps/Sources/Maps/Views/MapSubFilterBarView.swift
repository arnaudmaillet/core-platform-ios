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
/// two rows read as a hierarchy.
///
/// Anatomy: a scrollable pill row plus a FIXED circular expand button pinned
/// to the trailing edge (opens the full-list sheet — presentation is the view
/// controller's job, reported via `onExpandTapped`). Pills scrolling past the
/// fixed button duck-fade beneath it, mirroring the main bar's sticky-header
/// treatment. Long-pressing a person pill offers Pin/Unpin to Favorites via
/// a context menu (`onTogglePin` / `isPinned`).
///
/// Single-select; tapping the active pill clears the refinement (back to the
/// bare primary). Pill widths are strictly content-determined — no width
/// constraints on titled pills.
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

    private struct Entry {
        let option: MapSubFilterOption
        let pill: MapPillButton
    }

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
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
    private var entries: [Entry] = []
    private var avatarTasks: [Task<Void, Never>] = []

    init() {
        super.init(frame: .zero)
        configureLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func configureLayout() {
        // Unclipped halos, same as the main bar (safe: edge-to-edge scroll).
        clipsToBounds = false
        scrollView.clipsToBounds = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.delegate = self
        // Trailing inset clears the fixed expand bubble so pills rest free of
        // it and only overlap mid-scroll (where the duck-fade takes over).
        scrollView.contentInset = UIEdgeInsets(
            top: 0, left: Spacing.lg,
            bottom: 0, right: Spacing.lg + Self.pillHeight + Spacing.sm
        )
        scrollView.pin(to: self)

        stack.axis = .horizontal
        stack.spacing = Spacing.sm
        // .fill (NOT .fillEqually): each pill keeps its intrinsic width —
        // "Ava" rests tight while "Restaurants" runs wide.
        stack.distribution = .fill
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.topAnchor, constant: Self.verticalPadding
            ),
            stack.bottomAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -Self.verticalPadding
            )
        ])

        // The fixed expand bubble: a sibling of the scroll view (it must not
        // scroll), floating above pills gliding beneath it.
        addSubview(expandButton)
        expandButton.translatesAutoresizingMaskIntoConstraints = false
        expandButton.layer.zPosition = 1
        NSLayoutConstraint.activate([
            expandButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.lg),
            expandButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        expandButton.addAction(UIAction { [weak self] _ in self?.onExpandTapped?() }, for: .touchUpInside)
    }

    /// Cross-dissolves to a new option set while the row stays visible (a
    /// primary-to-primary switch, e.g. Friends → Places): fade the current
    /// pills out, swap the content at zero alpha, fade the new pills in.
    /// The fixed expand bubble deliberately stays put — it belongs to the
    /// bar, not to either state. Safe under rapid taps: a newer transition
    /// (or a direct `setOptions`) supersedes the pending swap.
    func transition(to options: [MapSubFilterOption]) {
        transitionGeneration += 1
        let generation = transitionGeneration
        UIView.animate(
            withDuration: 0.2, delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState],
            animations: { self.scrollView.alpha = 0 },
            completion: { _ in
                guard generation == self.transitionGeneration else { return }
                // Content swaps at alpha 0; `setOptions` restores the scroll
                // surface and fades the new pills in.
                self.setOptions(options)
            }
        )
    }

    /// Replaces the row's options; selection resets (a new option set always
    /// belongs to a freshly chosen primary) and the row rewinds to its head.
    /// People pills get their avatars resolved async and a pin context menu.
    func setOptions(_ options: [MapSubFilterOption]) {
        // Direct set supersedes any in-flight cross-dissolve…
        transitionGeneration += 1
        for task in avatarTasks { task.cancel() }
        avatarTasks.removeAll()
        for entry in entries { entry.pill.removeFromSuperview() }
        selectedSubFilter = nil

        entries = options.map { option in
            let pill = MapPillButton(content: option.content, height: Self.pillHeight)
            pill.addAction(
                UIAction { [weak self] _ in self?.didTap(option.subFilter) },
                for: .touchUpInside
            )
            if option.favorite != nil {
                pill.addInteraction(UIContextMenuInteraction(delegate: self))
            }
            return Entry(option: option, pill: pill)
        }
        for entry in entries { stack.addArrangedSubview(entry.pill) }
        scrollView.setContentOffset(
            CGPoint(x: -scrollView.adjustedContentInset.left, y: 0), animated: false
        )
        // Structure lands synchronously — every pill at its final intrinsic
        // width BEFORE anything is visible — then arrival is a pure
        // cross-dissolve to each pill's resting alpha (the trailing duck-fade
        // decides that, so a pill resting under the expand bubble fades in
        // only as far as it should).
        UIView.performWithoutAnimation { layoutIfNeeded() }
        for entry in entries { entry.pill.alpha = 0 }
        // …and repairs the scroll surface if an interrupted swap left it
        // faded (the new pills are at alpha 0, so this can't flash).
        scrollView.alpha = 1
        UIView.animate(
            withDuration: 0.2, delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            self.updateTrailingFade()
        }
        loadAvatars()
    }

    private func loadAvatars() {
        guard let imagePipeline else { return }
        for entry in entries {
            guard let url = entry.option.favorite?.avatarURL else { continue }
            let pill = entry.pill
            avatarTasks.append(Task { [weak pill] in
                guard let image = try? await imagePipeline.image(for: url),
                      !Task.isCancelled else { return }
                pill?.setAvatar(image)
            })
        }
    }

    private func didTap(_ subFilter: MapSubFilter) {
        // Re-tapping the active refinement clears it.
        let next: MapSubFilter? = (subFilter == selectedSubFilter) ? nil : subFilter
        setSelectedSubFilter(next)
        onSubFilterChanged?(next)
    }

    /// Programmatic selection (no callback); reveals the selected pill.
    func setSelectedSubFilter(_ subFilter: MapSubFilter?) {
        selectedSubFilter = subFilter
        for entry in entries {
            entry.pill.setSelectedAppearance(entry.option.subFilter == subFilter)
        }
        if let selected = entries.first(where: { $0.option.subFilter == subFilter })?.pill {
            scrollView.layoutIfNeeded()
            scrollView.scrollRectToVisible(
                selected.convert(selected.bounds, to: scrollView), animated: true
            )
        }
    }

    /// Mirrors the main bar's sticky-header treatment at the trailing edge:
    /// pills sliding beneath the fixed expand bubble fade over a short
    /// duck-under ramp, so their text never ghosts through its glass.
    private func updateTrailingFade() {
        let buttonFrame = expandButton.frame // bar coords
        for entry in entries {
            let frame = entry.pill.convert(entry.pill.bounds, to: self)
            guard buttonFrame.maxX > frame.minX, buttonFrame.minX < frame.maxX, frame.width > 0 else {
                entry.pill.alpha = 1
                continue
            }
            let overlap = min(buttonFrame.maxX, frame.maxX) - max(buttonFrame.minX, frame.minX)
            let rampDistance = min(frame.width, Self.trailingFadeDistance)
            entry.pill.alpha = 1 - min(1, overlap / rampDistance)
        }
    }

    private static let trailingFadeDistance: CGFloat = 60
}

extension MapSubFilterBarView: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateTrailingFade()
    }
}

extension MapSubFilterBarView: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let pill = interaction.view as? MapPillButton,
              let favorite = entries.first(where: { $0.pill === pill })?.option.favorite else {
            return nil
        }
        let pinned = isPinned?(favorite.profileID) ?? false
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            UIMenu(children: [
                UIAction(
                    title: pinned ? "Unpin from Favorites" : "Pin to Favorites",
                    image: UIImage(systemName: pinned ? "pin.slash" : "pin"),
                    handler: { _ in self?.onTogglePin?(favorite) }
                )
            ])
        })
    }
}
