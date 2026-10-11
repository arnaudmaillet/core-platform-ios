import MediaCore
import UIKit

/// The row of matches for an inline `:query`, floating just above the
/// composer's field (see `EmoteKeyboard.suggestionAnchor`).
///
/// A Liquid Glass capsule exactly as wide as its matches (#720): narrowing or
/// widening the query grows or shrinks the tiles in and out while the capsule
/// resizes, in one animation — `EmoteKeyboard` moves the frame and calls
/// `show(_:animated:)` inside the same spring, and the batch updates take
/// that spring's timing.
///
/// Its tiles are keyboard tiles (#958): they loop for as long as they show,
/// through idle calm, and are still under Reduce Motion, Low Power Mode,
/// Power Saving, Animate Emojis off or overheating — the panel's gate
/// (`EmoteMotion.keyboardPolicy`), re-dressed in place when it changes.
@MainActor
final class EmoteSuggestionStrip: UIView {
    static let height: CGFloat = 46
    static let tile: CGFloat = 42
    static let tileSpacing: CGFloat = 2
    /// Each end: a little more than the vertical inset, so the capsule's
    /// round ends do not crowd the first and last tile.
    static let sideInset: CGFloat = 6
    /// How many of the leading suggestions may start a bake.
    static let animatedLead = 6

    /// The capsule's width for `count` matches, before any cap.
    static func fittingWidth(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return sideInset * 2 + CGFloat(count) * tile + CGFloat(count - 1) * tileSpacing
    }

    var onSelect: ((Emote) -> Void)?

    private let engine: EmoteEngine
    private(set) var suggestions: [Emote] = []
    private let glass = UIVisualEffectView(effect: nil)
    private let collectionView: UICollectionView

    /// The last animated update: removed indices (old list) and inserted
    /// ones (new list). Internal for tests.
    private(set) var lastUpdate: (removed: [Int], inserted: [Int])?

    init(engine: EmoteEngine) {
        self.engine = engine
        let layout = PoppingFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = CGSize(width: Self.tile, height: Self.tile)
        layout.minimumLineSpacing = Self.tileSpacing
        let vertical = (Self.height - Self.tile) / 2
        layout.sectionInset = UIEdgeInsets(top: vertical, left: Self.sideInset, bottom: vertical, right: Self.sideInset)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: .zero)
        backgroundColor = .clear

        // Glass as the system draws it: the capsule is `cornerConfiguration`,
        // which UIKit animates with the frame, not a layer radius.
        // Interactive (#730): the system's press response — the stretch and
        // lensing under a finger — is what says the capsule is touchable.
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = true
        glass.effect = effect
        glass.cornerConfiguration = .capsule()
        // Tiles scrolling past a capped strip's ends stay inside the capsule.
        glass.clipsToBounds = true
        glass.frame = bounds
        glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(glass)

        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.register(EmoteTileCell.self, forCellWithReuseIdentifier: EmoteTileCell.reuseID)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.frame = glass.contentView.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        glass.contentView.addSubview(collectionView)
        accessibilityIdentifier = "emote-suggestions"
        isHidden = true
        // Selector observers are dropped with the strip: nothing to remove.
        for name in EmoteMotion.keyboardPolicyNotifications {
            NotificationCenter.default.addObserver(
                self, selector: #selector(keyboardPolicyMayHaveChanged), name: name, object: nil
            )
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Motion

    /// The policy the tiles on screen were dressed under, to act only on a
    /// change.
    private var dressedPolicy: AnimatedIconView.MotionPolicy?

    /// ⚠️ NONISOLATED: the power-state notification is posted off the main
    /// thread, and a main-actor selector would trap on the isolation check.
    @objc nonisolated private func keyboardPolicyMayHaveChanged() {
        Task { @MainActor [weak self] in self?.redressIfPolicyChanged() }
    }

    /// Re-dresses the displayed tiles when the keyboard's policy changed —
    /// the panel's rule (`EmotePickerView.redressIfPolicyChanged`).
    func redressIfPolicyChanged() {
        // Off screen the tiles hold nothing, and dress themselves afresh
        // when the strip comes back (`EmoteTileView.didMoveToWindow`).
        guard window != nil else {
            dressedPolicy = nil
            return
        }
        let policy = EmoteMotion.keyboardPolicy
        guard policy != dressedPolicy else { return }
        dressedPolicy = policy
        for path in collectionView.indexPathsForVisibleItems where path.item < suggestions.count {
            guard let cell = collectionView.cellForItem(at: path) as? EmoteTileCell else { continue }
            configure(cell, at: path)
        }
    }

    /// The first few matches are what the person is spelling out: those may
    /// bake and animate; the tail plays only what is resident.
    private func configure(_ cell: EmoteTileCell, at path: IndexPath) {
        cell.configure(
            suggestions[path.item], engine: engine, prefersAnimation: path.item < Self.animatedLead, asContent: true
        )
    }

    /// The tiles on screen, in order. Internal for tests.
    var displayedTiles: [EmoteTileView] {
        collectionView.indexPathsForVisibleItems.sorted().compactMap {
            (collectionView.cellForItem(at: $0) as? EmoteTileCell)?.tile
        }
    }

    /// Whether the container is Liquid Glass. Internal for tests.
    var isGlass: Bool { glass.effect is UIGlassEffect }
    /// Whether the glass answers a touch natively (#730). Internal for tests.
    var isInteractiveGlass: Bool { (glass.effect as? UIGlassEffect)?.isInteractive == true }

    /// Shows `emotes`, or collapses to nothing for an empty list.
    ///
    /// `animated`: the tiles that leave shrink out and the ones that arrive
    /// grow in, the rest sliding over — called inside the caller's animation
    /// block, so they move on its curve with the capsule's width.
    func show(_ emotes: [Emote], animated: Bool = false) {
        let old = suggestions.map(\.id)
        let new = emotes.map(\.id)
        guard new != old else { return }
        suggestions = emotes
        isHidden = emotes.isEmpty
        guard animated, !old.isEmpty, !new.isEmpty, Set(new).count == new.count, Set(old).count == old.count else {
            lastUpdate = nil
            collectionView.reloadData()
            if !emotes.isEmpty { collectionView.setContentOffset(.zero, animated: false) }
            return
        }
        let difference = new.difference(from: old)
        var removed: [Int] = []
        var inserted: [Int] = []
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.append(offset)
            case .insert(let offset, _, _): inserted.append(offset)
            }
        }
        lastUpdate = (removed.sorted(), inserted.sorted())
        collectionView.performBatchUpdates {
            collectionView.deleteItems(at: removed.map { IndexPath(item: $0, section: 0) })
            collectionView.insertItems(at: inserted.map { IndexPath(item: $0, section: 0) })
        }
        // The survivors may have changed rank: the lead that may bake moves.
        let survivors = collectionView.indexPathsForVisibleItems.filter { !inserted.contains($0.item) }
        for path in survivors where path.item < suggestions.count {
            if let cell = collectionView.cellForItem(at: path) as? EmoteTileCell { configure(cell, at: path) }
        }
    }
}

/// Tiles grow in from, and shrink out to, their own centre.
private final class PoppingFlowLayout: UICollectionViewFlowLayout {
    static let popScale: CGFloat = 0.3

    override func initialLayoutAttributesForAppearingItem(at itemIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        popped(super.initialLayoutAttributesForAppearingItem(at: itemIndexPath) ?? layoutAttributesForItem(at: itemIndexPath))
    }

    override func finalLayoutAttributesForDisappearingItem(at itemIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        popped(super.finalLayoutAttributesForDisappearingItem(at: itemIndexPath))
    }

    private func popped(_ attributes: UICollectionViewLayoutAttributes?) -> UICollectionViewLayoutAttributes? {
        guard let copy = attributes?.copy() as? UICollectionViewLayoutAttributes else { return attributes }
        copy.alpha = 0
        copy.transform = CGAffineTransform(scaleX: Self.popScale, y: Self.popScale)
        return copy
    }
}

extension EmoteSuggestionStrip: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        suggestions.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: EmoteTileCell.reuseID, for: indexPath)
        if dressedPolicy == nil { dressedPolicy = EmoteMotion.keyboardPolicy }
        if let cell = cell as? EmoteTileCell { configure(cell, at: indexPath) }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard indexPath.item < suggestions.count else { return }
        onSelect?(suggestions[indexPath.item])
    }
}
