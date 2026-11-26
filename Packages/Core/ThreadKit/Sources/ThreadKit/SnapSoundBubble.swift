import DesignSystem
import MediaCore
import MediaUI
import UIKit

/// What the sound bubble (and the composer's rail slot) draws for a post.
public struct SnapSoundFace: Equatable {
    /// The cover's picture — the sound's artwork, else the post's own; nil
    /// draws the note (a named song with no artwork).
    public var coverURL: URL?
    /// The post plays a sound. False — a media post with no audio — draws
    /// the bubble greyed.
    public var isAvailable: Bool
    /// Where a remote cover is read from on this turn (#894): the feed's
    /// pipeline, whose memory the attribution pill fills too. Nil reads files
    /// only. Not part of what the face IS: two faces that draw the same
    /// cover are equal whoever holds the pipeline.
    public var pipeline: ImagePipeline?

    public init(coverURL: URL?, isAvailable: Bool, pipeline: ImagePipeline? = nil) {
        self.coverURL = coverURL
        self.isAvailable = isAvailable
        self.pipeline = pipeline
    }

    public static func == (lhs: SnapSoundFace, rhs: SnapSoundFace) -> Bool {
        lhs.coverURL == rhs.coverURL && lhs.isAvailable == rhs.isAvailable
    }

    /// The cover drawn without a fetch: the struck note, the note, or a FILE
    /// read here. Nil for a remote cover — the host's `CoverSlot` loads it
    /// (#1772), its bone and its arrival the media's.
    ///
    /// ⚠️ A FILE IS READ, NEVER FETCHED (#680). Mock posters and local covers
    /// are file URLs, and the image pipeline paints a flat colour for any URL
    /// its fetchers do not recognise, a file among them: on a device the
    /// bubble wore a coloured disc instead of the post's picture, and the
    /// composer's slot wore nothing, since a file was never cached. The
    /// attribution has always read files directly (`SnapMediaAttributionView`).
    @MainActor var localCover: UIImage? {
        guard isAvailable else { return Self.noSoundImage }
        guard let coverURL else { return Self.noteImage }
        guard coverURL.isFileURL else { return nil }
        // Read once, then kept in the pipeline's memory: the next face for the
        // same file does not touch the disk again.
        if let kept = pipeline?.cachedImage(for: coverURL, size: Self.coverBucket) { return kept }
        guard let image = UIImage(contentsOfFile: coverURL.path) else { return nil }
        pipeline?.store(image, for: coverURL)
        return image
    }

    /// Draws this face's cover through `slot` (#1772): a local one handed in,
    /// a remote one loaded on the media's ladder.
    @MainActor public func draw(into slot: CoverSlot) {
        if let local = localCover {
            slot.reset()
            slot.apply(local)
        } else if let coverURL {
            slot.load(coverURL, pipeline: pipeline, item: coverURL)
        } else {
            slot.reset()
        }
    }

    /// A post with no sound (#683): the note struck through, greyed — the
    /// bubble keeps its place and says there is nothing to hear.
    static let noSoundImage: UIImage = {
        let side: CGFloat = 64
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            UIColor.darkGray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let glyph = UIImage(systemName: noSoundSymbol)?
                .withConfiguration(UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold))
                .withTintColor(.lightGray, renderingMode: .alwaysOriginal)
            if let glyph {
                glyph.draw(at: CGPoint(x: (side - glyph.size.width) / 2, y: (side - glyph.size.height) / 2))
            }
        }
    }()
    static let noSoundSymbol = "music.note.slash"

    /// The bucket a remote cover is decoded at, for the pill and the sound
    /// bubble alike (#894): a small disc, so the pipeline's avatar size. Its
    /// memory answers synchronously, so a swap made on this turn draws the new
    /// post wearing its cover instead of popping to it once the blur has
    /// landed. A post's own picture already decoded larger serves it too.
    public static let coverBucket = ImageBucket.avatar

    /// A white note on the cover's own dark ground.
    public static let noteImage: UIImage = {
        let side: CGFloat = 64
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            UIColor.darkGray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let glyph = UIImage(systemName: "music.note")?
                .withConfiguration(UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold))
                .withTintColor(.white, renderingMode: .alwaysOriginal)
            if let glyph {
                glyph.draw(at: CGPoint(x: (side - glyph.size.width) / 2, y: (side - glyph.size.height) / 2))
            }
        }
    }()
}

/// The column's lower bubble (#671): the sound's record IN its glass
/// (`SoundRecordGlass`, #1150).
///
/// - A TAP opens the sound sheet. No hold of its own since #1931.
/// - Scrolled away from the stream's start (#1929), the record cross-fades
///   with `chevron.up` in the same glass (`setShowsReturn`): the host's tap
///   then goes back to the top, and its hold arms the sheet.
/// - A greyed `music.note.slash`, refusing both, on a post with no sound.
/// - The cover turns like a record while the post plays AUDIBLY
///   (`setSpinning`): it says the sound is playing, so it follows play,
///   pause and mute, and Reduce Motion — not the idle calm (#650), which
///   stopped it on a clip watched to its end and looping (#683).
///
/// The button keeps the touches (tap, hold, VoiceOver) and draws nothing
/// itself: the record view inside it is the glass, and the button's
/// highlight presses it (`isHighlighted`).
public final class SnapSoundBubbleButton: UIButton {
    /// A tap: open the sound sheet — or, while the way back shows, go back
    /// to the stream's start (the host reads `showsReturn`).
    public var onTap: (() -> Void)?

    private let record = SoundRecordGlass()
    /// The glyph in the record's glass: the way back (#1929) or Share
    /// (#1999). The glass is never faded: the record and the glyph cross-fade
    /// inside it, and one glyph becoming another — Share and the way back, up
    /// and down (#2007) — is SF Symbols' own replace (the owner, 2026-11-01).
    private let glyph = UIImageView()
    /// The symbol the glyph wears, nil while the record shows.
    private var glyphSymbol: String?
    /// Whether the way back shows instead of the record.
    public private(set) var showsReturn = false
    /// Whether the bubble is the post's Share instead of its sound (#1999).
    public private(set) var sharesPost = false
    /// What the host last asked of the record, kept while the way back
    /// hides it: the record turns again when it comes back (#692).
    private var wantsSpinning = false
    /// Whether the bubble wears its own glass — off in the page's action
    /// column (#1872), which is one glass for all its bubbles.
    public var drawsGlass: Bool {
        get { record.drawsGlass }
        set { record.drawsGlass = newValue }
    }
    private var coverView: UIImageView { record.cover }
    private(set) var face: SnapSoundFace?
    /// The record's cover on the media slot (#1772): a bone on the dark
    /// ground while it loads, the slot's arrival.
    private lazy var coverSlot: CoverSlot = {
        let slot = CoverSlot(view: record.cover, size: SnapSoundFace.coverBucket)
        slot.bone?.fill = Surface.skeletonOnDark
        return slot
    }()

    public init() {
        super.init(frame: .zero)
        var config = UIButton.Configuration.plain()
        config.contentInsets = .zero
        config.background.backgroundColor = .clear
        configuration = config
        addSubview(record)
        glyph.tintColor = .label
        glyph.contentMode = .center
        glyph.alpha = 0
        glyph.isUserInteractionEnabled = false
        addSubview(glyph)

        addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .primaryActionTriggered)

        isAccessibilityElement = true
        accessibilityLabel = "Sound"
        accessibilityHint = "Double-tap for the sound."
        isHidden = true
    }

    /// The way back (#1929): the record cross-fades with `chevron.up`, the
    /// glass standing still — `chevron.down` when the stream's start is its
    /// end (`down`: Recent's newest, #2007). The record stops while hidden.
    public func setShowsReturn(_ shows: Bool, down: Bool = false, animated: Bool) {
        if down != returnPointsDown {
            returnPointsDown = down
            if shows == showsReturn { applyFace(animated: animated) }
        }
        guard shows != showsReturn else { return }
        showsReturn = shows
        applyFace(animated: animated)
    }

    /// Whether the way back points down (#2007).
    public private(set) var returnPointsDown = false

    /// The glyph's symbol and its size: the way back's chevrons at the
    /// composer slot's 15 pt (`CommentsInputBar`), so the two read alike;
    /// Share as it reads in a bubble, the heart's size by its ink
    /// (`ShareBubbleGlyph`, #2581).
    private static func glyphImage(_ symbol: String) -> UIImage? {
        guard symbol != CommentsInputBar.shareRailSymbol else { return ShareBubbleGlyph.image() }
        return UIImage.symbol(named: symbol, configuration: AppSymbol.fixed(15, weight: .semibold))
    }

    /// How far the glyph stands off the record's centre: Share moved so its
    /// ink's centre of mass is the bubble's (#2581), a chevron not at all.
    /// Kept while the record shows, so the fading glyph never slides.
    private var glyphMove = UIOffset.zero
    private var glyphCentre: CGPoint {
        CGPoint(x: record.center.x + glyphMove.horizontal, y: record.center.y + glyphMove.vertical)
    }

    /// The bubble as the post's Share (#1999), or back to its sound: Share's
    /// glyph in the glass where the record was, the way back cross-fading
    /// with it as with the record.
    public func setSharesPost(_ shares: Bool) {
        guard shares != sharesPost else { return }
        sharesPost = shares
        accessibilityIdentifier = shares ? SnapFooterToolbar.ID.share : nil
        applyFace(animated: false)
    }

    /// Labels, enabled state and glyphs as the bubble stands: the way back,
    /// Share, or the sound.
    private func applyFace(animated: Bool) {
        let shows = showsReturn
        accessibilityLabel = shows
            ? (returnPointsDown ? "Scroll to latest comment" : "Back to top")
            : sharesPost ? "Share" : "Sound"
        accessibilityHint = shows || sharesPost ? nil : "Double-tap for the sound."
        // An unavailable sound stays greyed; the way back and Share always answer.
        isEnabled = shows || sharesPost || face?.isAvailable == true
        alpha = shows || sharesPost || face?.isAvailable != false ? 1 : 0.45
        let symbol: String? = shows
            ? (returnPointsDown ? "chevron.down" : "chevron.up")
            : sharesPost ? CommentsInputBar.shareRailSymbol : nil
        if let symbol, symbol != glyphSymbol, let image = Self.glyphImage(symbol) {
            // Glyph to glyph: the symbol's replace. From the record: the image
            // is set, and the cross-fade below brings it in.
            if glyphSymbol != nil, animated, !MotionPreference.reducesMotion {
                glyph.setSymbolImage(image, contentTransition: .replace)
            } else {
                glyph.image = image
            }
        }
        glyphSymbol = symbol
        if let symbol { glyphMove = symbol == CommentsInputBar.shareRailSymbol ? ShareBubbleGlyph.offset() : .zero }
        let apply = {
            self.record.recordAlpha = symbol != nil ? 0 : 1
            self.glyph.alpha = symbol != nil ? 1 : 0
            self.glyph.center = self.glyphCentre
        }
        // A cross-fade, not a motion: Reduce Motion keeps it.
        if animated {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: apply)
        } else {
            apply()
        }
        applySpinning()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            record.setPressed(isHighlighted)
        }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        // By bounds and centre, not frame: the press transforms the record.
        record.bounds = CGRect(origin: .zero, size: bounds.size)
        record.center = CGPoint(x: bounds.midX, y: bounds.midY)
        bringSubviewToFront(record)
        glyph.bounds = record.bounds
        glyph.center = glyphCentre
        bringSubviewToFront(glyph)
    }

    /// Draws `face`; nil hides nothing by itself (the host decides visibility)
    /// but clears the cover.
    public func setFace(_ face: SnapSoundFace?, pipeline: ImagePipeline?) {
        guard face != self.face else { return }
        let coverChanged = face?.coverURL != self.face?.coverURL || self.face == nil
            || face?.isAvailable != self.face?.isAvailable
        self.face = face
        isEnabled = showsReturn || sharesPost || face?.isAvailable == true
        alpha = showsReturn || sharesPost || face?.isAvailable != false ? 1 : 0.45
        accessibilityValue = face.map { $0.isAvailable ? nil : "No audio" } ?? nil
        // A face that loses its sound always counts as a cover change, so the
        // record stops here at once, not at the host's next look (#1871).
        guard coverChanged else { return }
        coverView.layer.removeAllAnimations()
        if let face { face.draw(into: coverSlot) } else { coverSlot.reset() }
    }

    /// Turns the cover like a record while the post plays — only for a sound
    /// (#1871). A "No audio" face never turns, whatever the page's clip does:
    /// a carousel's clips are muted (#1849), and a record that turns says a
    /// sound is playing. The rail's rule (`CommentsInputBar.setRailSpinning`).
    public func setSpinning(_ spinning: Bool) {
        wantsSpinning = spinning
        applySpinning()
    }

    private func applySpinning() {
        guard let face, face.isAvailable, !showsReturn, !sharesPost else { return record.setSpinning(false) }
        record.setSpinning(wantsSpinning)
    }

    /// The record's cover as drawn now — the hold's disc carries it (#1929).
    public var coverImage: UIImage? { coverView.image }

    #if DEBUG
    /// Whether the record is turning now.
    public var debugIsSpinning: Bool { record.isSpinning }
    #endif

    #if DEBUG
    var debugRecord: SoundRecordGlass { record }
    public var debugCoverImage: UIImage? { coverView.image }
    var debugReturnGlyphAlpha: CGFloat { showsReturn ? glyph.alpha : 0 }
    var debugShareGlyphAlpha: CGFloat { sharesPost && !showsReturn ? glyph.alpha : 0 }
    /// The glyph's symbol now. Tests.
    var debugGlyphSymbol: String? { glyphSymbol }
    /// The glyph's view, for the specs that measure its size and place.
    var debugGlyph: UIImageView { glyph }
    #endif
}
