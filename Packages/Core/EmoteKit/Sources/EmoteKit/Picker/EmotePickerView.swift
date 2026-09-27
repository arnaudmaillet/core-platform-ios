import UIKit

/// The emote panel that takes the keyboard's place: every emote in sections,
/// Recent first, a section bar to jump between them, search, and delete.
///
/// It is an `inputView`, so the system slides it in and out exactly where the
/// keyboard was, and a composer pinned to the keyboard follows it for free.
///
/// ⚠️ **NO SEARCH FIELD IN THE PANEL.** A text field inside an `inputView`
/// cannot be typed into: focusing it takes the first responder away from the
/// composer, which takes its input view — the panel, and the field with it —
/// off the screen. Search is the `:query` typed in the composer itself
/// (`EmoteKeyboard`'s suggestion strip); the panel's magnifier switches back
/// to the keyboard and starts one.
@MainActor
public final class EmotePickerView: UIInputView {
    /// The floating section bar: height, and its inset from the panel's
    /// safe-area edges.
    static let barHeight: CGFloat = 44
    static let barInset = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 4, trailing: 12)
    /// Daylight between the last row, scrolled to its end, and the bar.
    static let barClearance: CGFloat = 8

    /// An emote was tapped.
    var onSelect: ((Emote) -> Void)?
    /// The magnifier: back to the keyboard, with a search started.
    var onSearch: (() -> Void)?
    /// Delete, as the keyboard's key does it.
    var onBackspace: (() -> Void)?

    private let engine: EmoteEngine
    private let heights: EmoteKeyboardHeight
    /// The height the panel asks for: the system keyboard's (see
    /// `matchKeyboardHeight(in:)`).
    private(set) var panelHeight: CGFloat
    /// The screen width `panelHeight` was chosen for — a rotation re-asks.
    private var matchedScreenWidth: CGFloat = 0
    private(set) var sections: [EmoteComposing.Section] = []
    let collectionView: UICollectionView
    /// The section bar's glass, FLOATING over the grid: the grid is the
    /// panel's whole height and scrolls under it, the way the app's other
    /// bars float over their content. Glass, never an opaque slab. The
    /// effect is set on window attach: materialising one in `init` contacts
    /// the render server (and stalls headless CI simulators).
    let sectionBarGlass = UIVisualEffectView(effect: nil)
    private let sectionBar = UIStackView()
    private var sectionButtons: [UIButton] = []
    private let searchButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private var deleteTimer: Timer?

    init(engine: EmoteEngine, heights: EmoteKeyboardHeight = .shared) {
        self.engine = engine
        self.heights = heights
        // A placeholder: `matchKeyboardHeight(in:)` states the real height
        // before the panel is ever handed to the system.
        panelHeight = EmoteKeyboardHeight.defaultHeight(
            screenSize: CGSize(width: 402, height: 874), bottomInset: 34
        )
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: Self.makeLayout())
        super.init(
            frame: CGRect(x: 0, y: 0, width: 0, height: panelHeight),
            inputViewStyle: .keyboard
        )
        // Sized by `intrinsicContentSize` — the keyboard's height — so a
        // change (a rotation) resizes the panel in place.
        allowsSelfSizing = true
        autoresizingMask = [.flexibleWidth]

        collectionView.backgroundColor = .clear
        collectionView.register(EmoteTileCell.self, forCellWithReuseIdentifier: EmoteTileCell.reuseID)
        collectionView.register(
            EmoteSectionHeader.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: EmoteSectionHeader.reuseID
        )
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.showsVerticalScrollIndicator = false
        // The insets are the bar's, stated in `layoutSubviews`; the safe
        // area's bottom is under the bar already.
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(collectionView)

        let symbol = UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        searchButton.setImage(UIImage(systemName: "magnifyingglass", withConfiguration: symbol), for: .normal)
        searchButton.accessibilityLabel = "Search emotes"
        searchButton.tintColor = .secondaryLabel
        deleteButton.tintColor = .secondaryLabel
        searchButton.addAction(UIAction { [weak self] _ in self?.onSearch?() }, for: .primaryActionTriggered)
        deleteButton.setImage(UIImage(systemName: "delete.left", withConfiguration: symbol), for: .normal)
        deleteButton.accessibilityLabel = "Delete"
        deleteButton.addAction(UIAction { [weak self] _ in self?.deleteTapped() }, for: .touchDown)
        deleteButton.addAction(UIAction { [weak self] _ in self?.stopRepeatingDelete() },
                               for: [.touchUpInside, .touchUpOutside, .touchCancel])

        sectionBar.axis = .horizontal
        sectionBar.distribution = .equalSpacing
        sectionBar.alignment = .center
        sectionBar.translatesAutoresizingMaskIntoConstraints = false
        sectionBarGlass.cornerConfiguration = .capsule()
        sectionBarGlass.clipsToBounds = true
        sectionBarGlass.translatesAutoresizingMaskIntoConstraints = false
        sectionBarGlass.contentView.addSubview(sectionBar)
        addSubview(sectionBarGlass)

        let guide = safeAreaLayoutGuide
        let inset = Self.barInset
        NSLayoutConstraint.activate([
            // The grid is the whole panel, top to bottom.
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            sectionBarGlass.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: inset.leading),
            sectionBarGlass.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -inset.trailing),
            sectionBarGlass.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -inset.bottom),
            sectionBarGlass.heightAnchor.constraint(equalToConstant: Self.barHeight),
            sectionBar.leadingAnchor.constraint(equalTo: sectionBarGlass.contentView.leadingAnchor, constant: 10),
            sectionBar.trailingAnchor.constraint(equalTo: sectionBarGlass.contentView.trailingAnchor, constant: -10),
            sectionBar.topAnchor.constraint(equalTo: sectionBarGlass.contentView.topAnchor),
            sectionBar.bottomAnchor.constraint(equalTo: sectionBarGlass.contentView.bottomAnchor)
        ])
    }

    // MARK: - Height

    override public var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: panelHeight)
    }

    /// Takes the height of the system keyboard on `window`'s screen — the
    /// one this panel is about to replace. Called before every swap.
    func matchKeyboardHeight(in window: UIWindow?) {
        guard let window else { return }
        let screen = window.screen.bounds.size
        matchedScreenWidth = screen.width
        setPanelHeight(heights.height(screenSize: screen, bottomInset: window.safeAreaInsets.bottom))
    }

    private func setPanelHeight(_ height: CGFloat) {
        guard height != panelHeight else { return }
        panelHeight = height
        frame.size.height = height
        invalidateIntrinsicContentSize()
    }

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, sectionBarGlass.effect == nil else { return }
        sectionBarGlass.effect = UIGlassEffect(style: .regular)
    }

    override public func layoutSubviews() {
        // A rotation while the panel is up: the keyboard for the new width.
        if let window, window.screen.bounds.width != matchedScreenWidth, matchedScreenWidth > 0 {
            matchKeyboardHeight(in: window)
        }
        super.layoutSubviews()
        // The last row scrolls clear of the floating bar.
        let bottom = max(0, bounds.maxY - sectionBarGlass.frame.minY) + Self.barClearance
        let insets = UIEdgeInsets(top: 4, left: 0, bottom: bottom, right: 0)
        if collectionView.contentInset != insets {
            collectionView.contentInset = insets
            collectionView.verticalScrollIndicatorInsets = insets
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Rebuilds the sections — on first show, and when Recent changed.
    func reload(recents: [Emote]) {
        let next = EmoteComposing.sections(catalog: engine.catalog, recents: recents)
        guard next != sections else { return }
        sections = next
        rebuildSectionBar()
        collectionView.reloadData()
        highlightSection(0)
    }

    private func rebuildSectionBar() {
        sectionBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        sectionButtons = []
        sectionBar.addArrangedSubview(searchButton)
        let symbol = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        for (index, section) in sections.enumerated() {
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: section.symbol, withConfiguration: symbol), for: .normal)
            button.accessibilityLabel = section.title
            button.addAction(UIAction { [weak self] _ in self?.jump(to: index) }, for: .primaryActionTriggered)
            sectionButtons.append(button)
            sectionBar.addArrangedSubview(button)
        }
        sectionBar.addArrangedSubview(deleteButton)
    }

    private func jump(to section: Int) {
        guard section < sections.count,
              let header = collectionView.layoutAttributesForSupplementaryElement(
                ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: section)
              )
        else { return }
        let insets = collectionView.contentInset
        let end = collectionView.contentSize.height + insets.bottom - collectionView.bounds.height
        let top = min(header.frame.minY - insets.top, max(-insets.top, end))
        collectionView.setContentOffset(CGPoint(x: 0, y: top), animated: false)
        highlightSection(section)
    }

    private func highlightSection(_ section: Int) {
        for (index, button) in sectionButtons.enumerated() {
            button.tintColor = index == section ? .label : .secondaryLabel
        }
    }

    private func deleteTapped() {
        onBackspace?()
        stopRepeatingDelete()
        // Held down, delete repeats like the keyboard's own key.
        deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                    MainActor.assumeIsolated { self?.onBackspace?() }
                }
            }
        }
    }

    private func stopRepeatingDelete() {
        deleteTimer?.invalidate()
        deleteTimer = nil
    }

    static func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { _, environment in
            let width = environment.container.effectiveContentSize.width
            let columns = max(6, Int(width / 46))
            let side = floor((width - 16) / CGFloat(columns))
            let item = NSCollectionLayoutItem(layoutSize: .init(
                widthDimension: .absolute(side), heightDimension: .absolute(side)
            ))
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(side)),
                repeatingSubitem: item, count: columns
            )
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 8, trailing: 8)
            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(26)),
                elementKind: UICollectionView.elementKindSectionHeader, alignment: .top
            )
            section.boundarySupplementaryItems = [header]
            return section
        }
    }

    // MARK: - Test seams

    var sectionTitles: [String] { sections.map(\.title) }
    func select(_ indexPath: IndexPath) {
        collectionView(collectionView, didSelectItemAt: indexPath)
    }
}

extension EmotePickerView: UICollectionViewDataSource, UICollectionViewDelegate {
    public func numberOfSections(in collectionView: UICollectionView) -> Int {
        sections.count
    }

    public func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        sections[section].emotes.count
    }

    public func collectionView(
        _ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: EmoteTileCell.reuseID, for: indexPath)
        let section = sections[indexPath.section]
        (cell as? EmoteTileCell)?.configure(
            section.emotes[indexPath.item], engine: engine,
            // Recent and the house emotes animate; the rest play only what is
            // already resident (see `EmoteTileView`).
            prefersAnimation: section.id == "recent" || section.id == EmoteSection.house.rawValue
        )
        return cell
    }

    public func collectionView(
        _ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath
    ) -> UICollectionReusableView {
        let header = collectionView.dequeueReusableSupplementaryView(
            ofKind: kind, withReuseIdentifier: EmoteSectionHeader.reuseID, for: indexPath
        )
        (header as? EmoteSectionHeader)?.label.text = sections[indexPath.section].title.uppercased()
        return header
    }

    public func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard indexPath.section < sections.count, indexPath.item < sections[indexPath.section].emotes.count else { return }
        UIDevice.current.playInputClick()
        onSelect?(sections[indexPath.section].emotes[indexPath.item])
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let probe = CGPoint(x: 20, y: scrollView.contentOffset.y + scrollView.contentInset.top + 30)
        if let indexPath = collectionView.indexPathForItem(at: probe) {
            highlightSection(indexPath.section)
        }
    }
}

extension EmotePickerView: UIInputViewAudioFeedback {
    public var enableInputClicksWhenVisible: Bool { true }
}

/// "SMILEYS AND EMOTIONS", small and quiet, like the system emoji keyboard.
final class EmoteSectionHeader: UICollectionReusableView {
    static let reuseID = "EmoteSectionHeader"
    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .preferredFont(forTextStyle: .caption2).withSymbolicTraits(.traitBold)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private extension UIFont {
    func withSymbolicTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }
}
