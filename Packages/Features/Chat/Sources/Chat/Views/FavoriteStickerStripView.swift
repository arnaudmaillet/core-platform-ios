import DesignSystem
import Lottie
import UIKit

/// The favorites row: a compact, horizontally scrolling strip of stickers that
/// rides the navigation controller's own bottom toolbar as a single
/// `UIBarButtonItem` custom view — the feed media toolbar's arrangement
/// ([[SnapFeedViewController]]), where the bar draws nothing and each custom
/// item gets its own iOS 26 glass capsule.
///
/// It owns no send logic and no keyboard logic — it reports taps through
/// `onSelect` and lets the host decide what a tap means, the same division the
/// composer's media and mic buttons follow.
///
/// Playback is owned HERE, not by the cells: only cells the collection view is
/// actually displaying animate, and a flick freezes the whole strip until it
/// settles. A cell can't see either condition on its own.
final class FavoriteStickerStripView: UIView {
    /// Fired with the tapped sticker.
    var onSelect: ((FavoriteSticker) -> Void)?

    enum Metrics {
        /// Square sticker box, sized to leave the bar-bubble its breathing room.
        static let itemSize: CGFloat = 28
        /// The bar-bubble invariant borrowed from the feed's media toolbar:
        /// custom bar items render 36pt tall on iOS 26, so every glass capsule
        /// across the app's bars reads as one family.
        static let bubbleHeight: CGFloat = 36
    }

    private let stickers = FavoriteStickerCatalog.favorites
    private let collectionView: UICollectionView
    /// Set by the host, which is the only thing that knows how wide the bar is.
    private var widthConstraint: NSLayoutConstraint!
    /// True from the first touch of a drag until the scroll comes to rest.
    private var isScrolling = false

    override init(frame: CGRect) {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = CGSize(width: Metrics.itemSize, height: Metrics.itemSize)
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = Spacing.sm
        layout.sectionInset = .zero
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)

        super.init(frame: frame)

        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.showsVerticalScrollIndicator = false
        // The strip floats over the transcript's own scrolling; bouncing gives
        // it the usual "there is nothing more" feedback without a bar.
        collectionView.alwaysBounceHorizontal = true
        // A tap on a sticker should fire on touch-up even mid-glide, the way
        // the keyboard's own rows behave.
        collectionView.delaysContentTouches = false
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(
            FavoriteStickerCell.self,
            forCellWithReuseIdentifier: FavoriteStickerCell.reuseIdentifier
        )

        // Breathing matches the feed's inset math — half the difference between
        // the bubble and its content — so the stickers sit centred in the glass
        // capsule the bar item wrapper draws around this view, instead of
        // touching its edge.
        let breathing = (Metrics.bubbleHeight - Metrics.itemSize) / 2
        collectionView.constrain(in: self) { parent in
            collectionView.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: breathing)
            collectionView.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -breathing)
            collectionView.topAnchor.constraint(equalTo: parent.topAnchor, constant: breathing)
            collectionView.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -breathing)
        }

        // 999, never required: the bar wraps custom items in its own
        // fixed-height container via autoresizing constraints, and anything
        // required loses to that with a console break.
        translatesAutoresizingMaskIntoConstraints = false
        let bubbleHeight = heightAnchor.constraint(equalToConstant: Metrics.bubbleHeight)
        bubbleHeight.priority = UILayoutPriority(999)
        // A collection view has no intrinsic width, so the item would collapse
        // to nothing without an explicit one — and it cannot be derived from
        // the bar, whose custom items are not in its hierarchy until layout.
        // The host sets it (see `setPreferredWidth`).
        widthConstraint = widthAnchor.constraint(equalToConstant: 0)
        widthConstraint.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([bubbleHeight, widthConstraint])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// How wide the strip should render. Only the host knows the bar's width,
    /// and asking the bar for it from in here is not possible before layout.
    func setPreferredWidth(_ width: CGFloat) {
        let target = max(0, width)
        guard widthConstraint.constant != target else { return }
        widthConstraint.constant = target
    }

    /// A thread that gets popped or backgrounded mid-acknowledgement drops
    /// straight back to bitmaps — nothing should be animating off-window.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window == nil else { return }
        for case let cell as FavoriteStickerCell in collectionView.visibleCells {
            cell.returnToStatic()
        }
    }
}

extension FavoriteStickerStripView: UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        stickers.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: FavoriteStickerCell.reuseIdentifier, for: indexPath
        )
        (cell as? FavoriteStickerCell)?.configure(with: stickers[indexPath.item])
        return cell
    }
}

extension FavoriteStickerStripView: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        // One pass of the real animation is the tap's receipt; the cell drops
        // back to its bitmap when it finishes.
        (collectionView.cellForItem(at: indexPath) as? FavoriteStickerCell)?.playOnce()
        onSelect?(stickers[indexPath.item])
    }

    /// A cell that scrolls out mid-play goes straight back to static — an
    /// animation nobody can see is pure cost, and the cell is about to be
    /// recycled anyway.
    func collectionView(
        _ collectionView: UICollectionView,
        didEndDisplaying cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        (cell as? FavoriteStickerCell)?.returnToStatic()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        setScrolling(true)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard !decelerate else { return }
        setScrolling(false)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        setScrolling(false)
    }

    /// Flattens every visible cell to a cached bitmap for the duration of the
    /// gesture, so the compositor moves textures instead of re-drawing content,
    /// then hands the layers back at rest — a permanently rasterized layer just
    /// spends memory on a cache nothing is reading.
    private func setScrolling(_ scrolling: Bool) {
        guard scrolling != isScrolling else { return }
        isScrolling = scrolling
        for case let cell as FavoriteStickerCell in collectionView.visibleCells {
            cell.setRasterized(scrolling)
        }
    }
}

/// One sticker. STATIC by default — a single flattened bitmap of the first
/// frame — and a real Lottie player only for the moment a tap is being
/// acknowledged.
///
/// The player is built lazily and torn down again afterwards, so a strip at
/// rest holds zero `LottieAnimationView`s and runs zero render loops. Twelve
/// continuously-looping vector scenes was the thing making this judder.
private final class FavoriteStickerCell: UICollectionViewCell {
    static let reuseIdentifier = "FavoriteStickerCell"

    /// The resting face: one texture for the compositor to push around.
    private let imageView = UIImageView()
    /// Emoji stand-in until the bitmap is rendered, and left in place for good
    /// if the file can't be loaded — the strip never shows a blank box.
    private let fallbackLabel = UILabel()
    /// Built on first play, released when playback ends.
    private var animationView: LottieAnimationView?
    /// Identifies the current binding, so work that finishes after the cell has
    /// been reused is discarded instead of drawing the wrong sticker.
    private var boundStickerID: String?
    private var boundSticker: FavoriteSticker?

    override init(frame: CGRect) {
        super.init(frame: frame)

        fallbackLabel.textAlignment = .center
        fallbackLabel.font = .systemFont(ofSize: FavoriteStickerStripView.Metrics.itemSize * 0.8)
        fallbackLabel.adjustsFontSizeToFitWidth = true
        fallbackLabel.pin(to: contentView)

        imageView.contentMode = .scaleAspectFit
        imageView.isHidden = true
        imageView.pin(to: contentView)

        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(with sticker: FavoriteSticker) {
        boundStickerID = sticker.id
        boundSticker = sticker
        accessibilityLabel = sticker.label
        fallbackLabel.text = sticker.emoji
        fallbackLabel.isHidden = false
        imageView.isHidden = true
        imageView.image = nil

        let side = FavoriteStickerStripView.Metrics.itemSize
        FavoriteStickerCatalog.firstFrame(
            for: sticker, size: CGSize(width: side, height: side)
        ) { [weak self] image in
            guard let self, self.boundStickerID == sticker.id, let image else { return }
            self.imageView.image = image
            self.imageView.isHidden = false
            self.fallbackLabel.isHidden = true
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        boundStickerID = nil
        boundSticker = nil
        returnToStatic()
        imageView.isHidden = true
        imageView.image = nil
        fallbackLabel.isHidden = false
    }

    /// Rasterization is only ever asked for while the strip is in motion, and
    /// only ever while everything in it is static — turning it on over a
    /// running animation would re-cache the layer every frame and cost more
    /// than it saves.
    func setRasterized(_ rasterized: Bool) {
        guard animationView == nil else { return }
        guard contentView.layer.shouldRasterize != rasterized else { return }
        contentView.layer.rasterizationScale = traitCollection.displayScale
        contentView.layer.shouldRasterize = rasterized
    }

    /// The tap's receipt: one pass of the real animation, then straight back to
    /// the bitmap. Core Animation engine — the frames are compiled once and run
    /// by the render server rather than redrawn on the main thread.
    func playOnce() {
        guard let sticker = boundSticker, animationView == nil else { return }
        // Never rasterize a layer that is about to animate.
        contentView.layer.shouldRasterize = false

        FavoriteStickerCatalog.load(sticker) { [weak self] file in
            guard let self, self.boundStickerID == sticker.id, let file else { return }
            let player = LottieAnimationView(
                configuration: LottieConfiguration(renderingEngine: .coreAnimation)
            )
            player.contentMode = .scaleAspectFit
            player.backgroundBehavior = .pauseAndRestore
            player.isUserInteractionEnabled = false
            player.loadAnimation(from: file)
            // AFTER the load: `loadAnimation(from:)` resets loopMode to what the
            // dotLottie manifest declares. These files declare one pass, which
            // is what is wanted here — but stating it keeps the intent from
            // depending on the export's settings.
            player.loopMode = .playOnce
            player.pin(to: self.contentView)
            self.animationView = player
            self.imageView.isHidden = true

            player.play { [weak self] _ in
                // Completion also fires when the animation is interrupted
                // (scrolled away, reused), which is exactly when the static
                // face should come back too.
                self?.returnToStatic()
            }
        }
    }

    /// Tears the player down and shows the bitmap again. Safe to call when no
    /// player exists — that is the common path from `prepareForReuse`.
    func returnToStatic() {
        guard let player = animationView else { return }
        animationView = nil
        player.stop()
        player.removeFromSuperview()
        imageView.isHidden = imageView.image == nil
        fallbackLabel.isHidden = imageView.image != nil
    }
}
