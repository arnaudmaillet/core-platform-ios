import UIKit

/// A one-row, horizontally scrolling strip of EVERY emote the build ships, in
/// its own Liquid Glass capsule — the conversation footer's emote bar.
///
/// ## What it lists
///
/// `EmoteCatalog.all`, whole and in its order: the house `:name:` emotes (the
/// StickerKit stickers, then the map's baked GIF icons, `:lol:` and
/// `:blush:`), then the Noto subset. Not a favourites subset: the mock's
/// texts are written with exactly these, and a strip that offered a dozen
/// stickers left most of what people read in a thread out of reach.
///
/// ## What is dressed
///
/// Every tile the collection view is DISPLAYING asks for its art — house
/// emote or emoji alike, as in the emote panel; a row shows about ten, so
/// the cost is bounded by the screen. A tile is configured when it is dequeued (prefetching
/// is off, so that is the moment before it is shown) and gives its request,
/// its art and its slot back the moment it stops being displayed. A tile
/// flicked past inside `EmoteEngine.bakeDelay` costs nothing.
///
/// ## What plays: only while the strip moves
///
/// At rest every tile is still, on its poster frame; the displayed tiles play
/// from a drag's start to the end of its glide, and each stops on the frame
/// it reached. `EmoteScrollPlayback` is the rule, shared with the emote
/// panel (`EmotePickerView`).
///
/// ## Edge to edge, inside the capsule
///
/// ⚠️ **THE CAPSULE IS THE CLIP.** The glass, its rounded ends and the scroll
/// view are one shape: the collection view runs the capsule's full width and
/// the rest position comes from `contentInset`, so a tile scrolls right up to
/// the rounded end and is cut by the curve, not by a rectangle a few points
/// short of it (what a bar's own glass bubble around a custom view did — the
/// bar pads its custom view inside the bubble). A short fade at each end
/// softens the cut, and only appears on an end with content scrolled past it.
@MainActor
public final class EmoteStripView: UIView {
    /// A tile was tapped. The strip has already filed it under Recent.
    public var onSelect: ((Emote) -> Void)?

    /// What the strip lists, left to right.
    public let emotes: [Emote]

    /// Points between a tile cell and the capsule's top and bottom (a cell
    /// insets its tile by 4 more), and between the first and last cells and
    /// the capsule's ends at rest — so the end tiles sit as far from the
    /// curve as from the top.
    static let cellInset: CGFloat = 4
    /// How far each end fades, once content is scrolled past it.
    static let fadeLength: CGFloat = 18

    private let engine: EmoteEngine
    private let recents: EmoteRecents?
    /// The capsule. Its effect is set on window attach: materialising glass
    /// in `init` contacts the render server (and stalls headless CI).
    let glass = UIVisualEffectView(effect: nil)
    /// Holds the fade mask. ⚠️ Not the collection view itself: a scroll
    /// view's layer is its CONTENT's coordinate space, so a mask on it would
    /// scroll away with the tiles.
    private let fadeContainer = UIView()
    private let fadeMask = CAGradientLayer()
    let collectionView: UICollectionView
    private let layout = UICollectionViewFlowLayout()
    /// See "What plays".
    private let playback: EmoteScrollPlayback
    /// From a drag's start to the end of its glide.
    var isScrolling: Bool { playback.isScrolling }

    public init(
        engine: EmoteEngine = .shared,
        emotes: [Emote]? = nil,
        recents: EmoteRecents? = .shared
    ) {
        self.engine = engine
        self.emotes = emotes ?? engine.catalog.all
        self.recents = recents
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = .zero
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        playback = EmoteScrollPlayback(collectionView: collectionView)
        super.init(frame: .zero)

        glass.cornerConfiguration = .capsule()
        glass.clipsToBounds = true
        glass.frame = bounds
        glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(glass)

        fadeContainer.frame = glass.contentView.bounds
        fadeContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        fadeContainer.layer.mask = fadeMask
        fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
        glass.contentView.addSubview(fadeContainer)

        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.showsVerticalScrollIndicator = false
        collectionView.alwaysBounceHorizontal = true
        collectionView.alwaysBounceVertical = false
        collectionView.contentInsetAdjustmentBehavior = .never
        // Off: a prefetched cell is dequeued but not shown, and would start a
        // bake for a tile nobody sees.
        collectionView.isPrefetchingEnabled = false
        // A tap fires on touch-up even mid-glide, like the keyboard's rows.
        collectionView.delaysContentTouches = false
        collectionView.register(EmoteTileCell.self, forCellWithReuseIdentifier: EmoteTileCell.reuseID)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.frame = fadeContainer.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        fadeContainer.addSubview(collectionView)
        accessibilityLabel = "Emotes"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { playback.stop() }
        guard window != nil, glass.effect == nil else { return }
        glass.effect = UIGlassEffect(style: .regular)
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        let inset = Self.cellInset
        let side = max(1, bounds.height - inset * 2)
        if layout.itemSize != CGSize(width: side, height: side) {
            layout.itemSize = CGSize(width: side, height: side)
            layout.invalidateLayout()
        }
        let insets = UIEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        if collectionView.contentInset != insets {
            collectionView.contentInset = insets
            // At rest on the first tile, not on the inset's edge.
            collectionView.contentOffset = CGPoint(x: -inset, y: -inset)
        }
        updateFades()
    }

    /// The mask: opaque, with each end faded only as far as content has
    /// scrolled past it — at rest the first tile is whole.
    private func updateFades() {
        let bounds = fadeContainer.bounds
        guard bounds.width > 0 else { return }
        let offset = collectionView.contentOffset.x
        let insets = collectionView.contentInset
        let fade = Self.fadeLength
        let start = offset + insets.left
        let end = collectionView.contentSize.width + insets.right - bounds.width - offset
        let leading = 1 - min(max(start / fade, 0), 1)
        let trailing = 1 - min(max(end / fade, 0), 1)
        let edge = min(fade / bounds.width, 0.5)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeMask.frame = bounds
        fadeMask.colors = [
            UIColor(white: 0, alpha: leading).cgColor,
            UIColor.black.cgColor,
            UIColor.black.cgColor,
            UIColor(white: 0, alpha: trailing).cgColor
        ]
        fadeMask.locations = [0, NSNumber(value: Double(edge)), NSNumber(value: Double(1 - edge)), 1]
        CATransaction.commit()
    }

    // MARK: - Test seams

    /// The tiles the strip is showing, left to right.
    var displayedTiles: [EmoteTileView] {
        collectionView.indexPathsForVisibleItems.sorted().compactMap {
            (collectionView.cellForItem(at: $0) as? EmoteTileCell)?.tile
        }
    }

    func select(_ index: Int) {
        collectionView(collectionView, didSelectItemAt: IndexPath(item: index, section: 0))
    }
}

extension EmoteStripView: UICollectionViewDataSource, UICollectionViewDelegate {
    public func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        emotes.count
    }

    public func collectionView(
        _ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: EmoteTileCell.reuseID, for: indexPath)
        (cell as? EmoteTileCell)?.configure(
            emotes[indexPath.item], engine: engine, prefersAnimation: true, playing: isScrolling
        )
        return cell
    }

    /// Off-screen is still: the request and the slot go back at once, not at
    /// the cell's next reuse.
    public func collectionView(
        _ collectionView: UICollectionView,
        didEndDisplaying cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        (cell as? EmoteTileCell)?.tile.clear()
    }

    public func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard indexPath.item < emotes.count else { return }
        let emote = emotes[indexPath.item]
        recents?.record(emote)
        onSelect?(emote)
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateFades()
    }

    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        playback.willBeginDragging()
    }

    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        playback.didEndDragging(willDecelerate: decelerate)
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        playback.didEndScrolling()
    }

    public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        playback.didEndScrolling()
    }
}
