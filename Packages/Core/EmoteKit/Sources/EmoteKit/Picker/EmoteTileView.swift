import MediaCore
import UIKit

/// One emote in the panel, the strip, the suggestion row or the feed's
/// shortcut rail: its glyph at once, its animated art over it when there is
/// one.
///
/// ## What is dressed, and what it costs
///
/// A bake costs up to a few seconds of background drawing and about a
/// megabyte, once per install (the sheet is kept on disk). A tile asks for
/// its art when its owner says it `prefersAnimation`; otherwise it shows art
/// already resident, and its system glyph until then. The panel and the strip
/// ask for every tile they DISPLAY and take it back the moment a tile stops
/// being displayed (`clear()`), so what they hold is one screen of tiles; a
/// tile flicked past inside `EmoteEngine.bakeDelay` costs nothing.
///
/// ## Playing or still
///
/// A tile plays unless its owner says otherwise (`setPlaying`). A still tile
/// keeps its art and holds one frame (`AnimatedIconView.pause`): dressed
/// still, it shows the art's poster frame (`AnimatedIconArt.posterFrame`,
/// never a blank opening frame); stopped mid-loop, it holds the frame it is
/// on, and plays on from there when told to.
///
/// Only a PLAYING tile holds one of `EmoteEngine.maxPlayingTiles` slots: a
/// still tile is a posed layer with no animation on it, which costs the
/// render server nothing. A tile denied a slot stays still until its next
/// start. Under Reduce Motion an emoji stays its glyph and a house emote
/// shows its first frame.
///
/// ## Nothing behind the emote
///
/// The tile and its cell paint no background: the art's own alpha is its
/// shape, on whatever hosts it (the panel's keyboard material, the strip's
/// glass). The press is the cell's (`EmoteTileCell.isHighlighted`).
@MainActor
public final class EmoteTileView: UIView {
    /// The sheet side tiles ask for: the text bucket, so a sheet baked for a
    /// caption serves the picker too, and the reverse.
    static let pixelSide = 64

    private let glyphLabel = UILabel()
    let player = AnimatedIconView(frame: .zero)
    private var request: EmoteRequest?
    private var holdsSlot = false
    public private(set) var emote: Emote?
    private weak var engine: EmoteEngine?
    private var prefersAnimation = false

    /// Whether art is showing over the glyph.
    public private(set) var isShowingArt = false
    /// Whether the art on show has frames to play (a loop, motion allowed).
    private var artMoves = false
    /// Whether the owner wants the art moving. See "Playing or still".
    public private(set) var isPlaying = true

    /// Poster frames by the art's own image (by identity, held weakly):
    /// worked out once per art, forgotten with it, and never answered for
    /// another art of the same emote.
    private static let posterFrames = NSMapTable<UIImage, NSNumber>(
        keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory
    )

    /// Whether the art on show is moving right now.
    public var isAnimating: Bool { isShowingArt && player.isAnimating && !player.isPaused }

    override public init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        glyphLabel.textAlignment = .center
        glyphLabel.adjustsFontSizeToFitWidth = false
        glyphLabel.backgroundColor = .clear
        addSubview(glyphLabel)
        player.isHidden = true
        addSubview(player)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func layoutSubviews() {
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

    /// Shows `emote`, dressing its art if the rules above allow — still, on
    /// its poster frame, unless `playing`.
    public func configure(_ emote: Emote, engine: EmoteEngine, prefersAnimation: Bool, playing: Bool = true) {
        reset()
        self.emote = emote
        self.engine = engine
        self.prefersAnimation = prefersAnimation
        isPlaying = playing
        glyphLabel.text = emote.glyph
        glyphLabel.isHidden = false
        accessibilityLabel = emote.name

        let policy = EmoteMotion.policy
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

    /// Dresses the art still on its poster frame, and plays it from there if
    /// the owner wants it moving.
    private func present(_ art: AnimatedIconArt, motion: EmoteEngine.Motion) {
        player.setArt(art, phase: posterFrame(of: art), paused: true)
        player.isHidden = false
        glyphLabel.isHidden = true
        isShowingArt = true
        artMoves = motion == .loop && art.frameCount > 1
        if isPlaying { play() }
    }

    /// Starts or stops the art where it is: stopping holds the frame
    /// on show, starting plays on from it.
    ///
    /// `finishingLoop` (#559): the art plays out its current loop and rests
    /// on its poster frame instead of freezing mid-gesture; the engine slot
    /// is given back once it rests. Playing again before then just carries on.
    public func setPlaying(_ playing: Bool, finishingLoop: Bool = false) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        if playing {
            play()
        } else if finishingLoop {
            finish()
        } else {
            hold()
        }
    }

    /// Plays on from the frame on show, if a slot is free. A loop being
    /// finished keeps its slot and simply goes on.
    private func play() {
        guard isShowingArt, artMoves, let engine else { return }
        player.cancelFinish()
        if !holdsSlot {
            guard engine.acquireTileSlot() else { return }
            holdsSlot = true
        }
        player.resume()
    }

    /// Plays the loop out, then rests and gives the slot back.
    private func finish() {
        guard isShowingArt, holdsSlot else {
            hold()
            return
        }
        player.finishLoop { [weak self] in
            guard let self, !self.isPlaying else { return }
            self.releaseSlot()
        }
    }

    /// Holds the frame on show, and gives the slot back.
    private func hold() {
        if isShowingArt { player.pause() }
        releaseSlot()
    }

    private func releaseSlot() {
        guard holdsSlot else { return }
        holdsSlot = false
        engine?.releaseTileSlot()
    }

    /// The frame a still dressing shows. A loop's own first frame unless that
    /// is (nearly) blank; the same art always answers the same.
    private func posterFrame(of art: AnimatedIconArt) -> Int {
        guard art.frameCount > 1 else { return 0 }
        let image: UIImage
        switch art {
        case .sheet(let sheet): image = sheet.sheet
        case .decomposed(let still): image = still.mark
        }
        if let known = Self.posterFrames.object(forKey: image) { return known.intValue }
        let frame = art.posterFrame()
        Self.posterFrames.setObject(NSNumber(value: frame), forKey: image)
        return frame
    }

    /// Drops the art, the request and the slot — reuse, or leaving the window.
    func reset() {
        request?.cancel()
        request = nil
        player.setArt(nil)
        player.isHidden = true
        glyphLabel.isHidden = false
        isShowingArt = false
        artMoves = false
        releaseSlot()
    }

    /// `reset()`, and forgets the emote too, so a window re-attach does not
    /// ask again — for a cell the collection view stopped displaying but
    /// keeps, hidden, in its hierarchy.
    public func clear() {
        reset()
        emote = nil
    }

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            // Off screen holds nothing — no slot, no request, and no art: a
            // panel taken down keeps its cells, and a screen of sheets with them.
            if isShowingArt || request != nil { reset() }
        } else if let emote, let engine, !isShowingArt, request == nil {
            // Back on screen (the picker came back up): ask again.
            configure(emote, engine: engine, prefersAnimation: prefersAnimation, playing: isPlaying)
        }
    }
}

/// A collection cell around one tile.
///
/// ⚠️ **NO BACKGROUND, NOT EVEN A DEFAULT ONE.** The cell, its content view
/// and its background configuration are all clear, so the emote sits on the
/// host's own material. The press plate is a SHAPE LAYER (a translucent
/// system fill resolved per trait) shown only while highlighted — glass
/// repaints a view's `backgroundColor` its own way (the strip lives in glass).
@MainActor
final class EmoteTileCell: UICollectionViewCell {
    static let reuseID = "EmoteTileCell"
    let tile = EmoteTileView()
    /// The press: behind the tile, rounded, invisible at rest.
    let pressPlate = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        backgroundConfiguration = .clear()
        contentView.backgroundColor = .clear
        pressPlate.opacity = 0
        contentView.layer.addSublayer(pressPlate)
        tile.frame = contentView.bounds.insetBy(dx: 4, dy: 4)
        tile.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(tile)
        isAccessibilityElement = true
        accessibilityTraits = .button
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (cell: EmoteTileCell, _) in
            cell.resolvePlateColor()
        }
        resolvePlateColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let plate = CGRect(origin: .zero, size: contentView.bounds.size).insetBy(dx: 1, dy: 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pressPlate.frame = contentView.bounds
        pressPlate.path = UIBezierPath(roundedRect: plate, cornerRadius: min(12, plate.width / 4)).cgPath
        CATransaction.commit()
    }

    private func resolvePlateColor() {
        pressPlate.fillColor = UIColor.tertiarySystemFill.resolvedColor(with: traitCollection).cgColor
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        tile.reset()
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            pressPlate.opacity = isHighlighted ? 1 : 0
            UIView.animate(withDuration: 0.12, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.tile.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.85, y: 0.85) : .identity
            }
        }
    }

    func configure(_ emote: Emote, engine: EmoteEngine, prefersAnimation: Bool, playing: Bool = true) {
        tile.configure(emote, engine: engine, prefersAnimation: prefersAnimation, playing: playing)
        accessibilityLabel = emote.code.map { "\(emote.name), \($0)" } ?? emote.name
    }
}
