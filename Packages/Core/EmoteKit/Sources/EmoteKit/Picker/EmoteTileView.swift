import MediaCore
import UIKit

/// One emote in the picker or the suggestion strip: its glyph at once, its
/// animation over it when there is one to play.
///
/// ## What animates, and why not everything
///
/// A bake costs up to a few seconds of background drawing and about a
/// megabyte, so a picker that baked every visible cell would spend tens of
/// seconds and tens of megabytes the moment it opened. A tile therefore plays:
///
/// - art already resident — free, whatever the section;
/// - the house emotes and the recents — bounded (a dozen house emotes, at
///   most `EmoteRecents.limit` recents), and what a person reaches for;
/// - everything else stays on its system glyph, which is the emoji itself.
///
/// Every animating tile holds one of `EmoteEngine.maxAnimatedEmotes` slots,
/// and gives it back when it is reused or leaves the window. Under Reduce
/// Motion an emoji stays its glyph and a house emote shows its first frame.
@MainActor
final class EmoteTileView: UIView {
    /// The sheet side tiles ask for: the text bucket, so a sheet baked for a
    /// caption serves the picker too, and the reverse.
    static let pixelSide = 64

    private let glyphLabel = UILabel()
    private let player = AnimatedIconView(frame: .zero)
    private var request: EmoteRequest?
    private var holdsSlot = false
    private(set) var emote: Emote?
    private weak var engine: EmoteEngine?
    private var prefersAnimation = false

    /// Whether art is showing over the glyph.
    private(set) var isShowingArt = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        glyphLabel.textAlignment = .center
        glyphLabel.adjustsFontSizeToFitWidth = false
        addSubview(glyphLabel)
        player.isHidden = true
        addSubview(player)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = min(bounds.width, bounds.height)
        let square = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        glyphLabel.frame = square
        // Apple Color Emoji draws ~1.2 em tall: a font of 0.8 of the side
        // fills the square the way the animation does.
        let size = (side * 0.8).rounded()
        if glyphLabel.font?.pointSize != size { glyphLabel.font = .systemFont(ofSize: size) }
        player.frame = square
    }

    /// Shows `emote`, animating it if the rules above allow.
    func configure(_ emote: Emote, engine: EmoteEngine, prefersAnimation: Bool) {
        reset()
        self.emote = emote
        self.engine = engine
        self.prefersAnimation = prefersAnimation
        glyphLabel.text = emote.glyph
        glyphLabel.isHidden = false
        accessibilityLabel = emote.name

        let policy = AnimatedIconView.policy
        let motion: EmoteEngine.Motion = policy == .still ? .still : .loop
        if motion == .still && emote.isUnicodeEmoji { return }
        if let art = engine.cachedArt(for: emote, pixelSide: Self.pixelSide, motion: motion) {
            present(art, motion: motion)
            return
        }
        guard prefersAnimation || !emote.isUnicodeEmoji else { return }
        request = engine.requestArt(for: emote, pixelSide: Self.pixelSide, motion: motion) { [weak self] art in
            guard let self, self.emote?.id == emote.id else { return }
            self.request = nil
            if let art { self.present(art, motion: motion) }
        }
    }

    private func present(_ art: AnimatedIconArt, motion: EmoteEngine.Motion) {
        guard let engine else { return }
        if motion == .loop, art.frameCount > 1 {
            guard engine.acquirePlaybackSlot(waiter: self) else { return }
            holdsSlot = true
        }
        player.setArt(art)
        player.isHidden = false
        glyphLabel.isHidden = true
        isShowingArt = true
    }

    /// Drops the art, the request and the slot — reuse, or leaving the window.
    func reset() {
        request?.cancel()
        request = nil
        player.setArt(nil)
        player.isHidden = true
        glyphLabel.isHidden = false
        isShowingArt = false
        if holdsSlot {
            holdsSlot = false
            engine?.releasePlaybackSlot()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            if holdsSlot || request != nil { reset() }
        } else if let emote, let engine, !isShowingArt, request == nil {
            // Back on screen (the picker came back up): ask again.
            configure(emote, engine: engine, prefersAnimation: prefersAnimation)
        }
    }
}

extension EmoteTileView: EmotePlaybackWaiting {
    func emotePlaybackSlotFreed() {
        // A tile does not queue for a slot: the next reuse asks again.
    }
}

/// A collection cell around one tile.
@MainActor
final class EmoteTileCell: UICollectionViewCell {
    static let reuseID = "EmoteTileCell"
    let tile = EmoteTileView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        tile.frame = contentView.bounds.insetBy(dx: 4, dy: 4)
        tile.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(tile)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        tile.reset()
    }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.12, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.tile.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.85, y: 0.85) : .identity
            }
        }
    }

    func configure(_ emote: Emote, engine: EmoteEngine, prefersAnimation: Bool) {
        tile.configure(emote, engine: engine, prefersAnimation: prefersAnimation)
        accessibilityLabel = emote.code.map { "\(emote.name), \($0)" } ?? emote.name
    }
}
