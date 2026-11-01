import DesignSystem
import MediaCore
import UIKit

/// What the sound bubble (and the composer's rail slot) draws for a post.
struct SnapSoundFace: Equatable {
    /// The cover's picture — the sound's artwork, else the post's own; nil
    /// draws the note (a named song with no artwork).
    var coverURL: URL?
    /// The post plays a sound. False — a media post with no audio — draws
    /// the bubble greyed.
    var isAvailable: Bool
    /// Where a remote cover is read from on this turn (#894): the feed's
    /// pipeline, whose memory the attribution pill fills too. Nil reads files
    /// only. Not part of what the face IS: two faces that draw the same
    /// cover are equal whoever holds the pipeline.
    var pipeline: ImagePipeline?

    init(coverURL: URL?, isAvailable: Bool, pipeline: ImagePipeline? = nil) {
        self.coverURL = coverURL
        self.isAvailable = isAvailable
        self.pipeline = pipeline
    }

    static func == (lhs: SnapSoundFace, rhs: SnapSoundFace) -> Bool {
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
        guard let coverURL else { return SnapMediaAttributionView.noteImage }
        guard coverURL.isFileURL else { return nil }
        // Read once, then kept in the pipeline's memory: the next face for the
        // same file does not touch the disk again.
        if let kept = pipeline?.cachedImage(for: coverURL, size: SnapMediaAttributionView.coverBucket) { return kept }
        guard let image = UIImage(contentsOfFile: coverURL.path) else { return nil }
        pipeline?.store(image, for: coverURL)
        return image
    }

    /// Draws this face's cover through `slot` (#1772): a local one handed in,
    /// a remote one loaded on the media's ladder.
    @MainActor func draw(into slot: CoverSlot) {
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
final class SnapSoundBubbleButton: UIButton {
    /// A tap: open the sound sheet — or, while the way back shows, go back
    /// to the stream's start (the host reads `showsReturn`).
    var onTap: (() -> Void)?

    private let record = SoundRecordGlass()
    /// The way back's glyph, in the record's glass (#1929). The glass is
    /// never faded: the record and the glyph cross-fade inside it.
    /// The composer slot's glyph size (`CommentsInputBar`), so the two
    /// chevrons read alike.
    private let returnGlyph = UIImageView(
        image: UIImage.symbol(named: "chevron.up", configuration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
    )
    /// Whether the way back shows instead of the record.
    private(set) var showsReturn = false
    /// Share's glyph, in the same glass (#1999): a pushed text page's
    /// bubble is the post's Share, not its sound — a text post has none.
    private let shareGlyph = UIImageView(
        image: UIImage.symbol(named: CommentsInputBar.shareRailSymbol, configuration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
    )
    /// Whether the bubble is the post's Share instead of its sound (#1999).
    private(set) var sharesPost = false
    /// What the host last asked of the record, kept while the way back
    /// hides it: the record turns again when it comes back (#692).
    private var wantsSpinning = false
    /// Whether the bubble wears its own glass — off in the page's action
    /// column (#1872), which is one glass for all its bubbles.
    var drawsGlass: Bool {
        get { record.drawsGlass }
        set { record.drawsGlass = newValue }
    }
    private var coverView: UIImageView { record.cover }
    private(set) var face: SnapSoundFace?
    /// The record's cover on the media slot (#1772): a bone on the dark
    /// ground while it loads, the slot's arrival.
    private lazy var coverSlot: CoverSlot = {
        let slot = CoverSlot(view: record.cover, size: SnapMediaAttributionView.coverBucket)
        slot.bone?.fill = Surface.skeletonOnDark
        return slot
    }()

    init() {
        super.init(frame: .zero)
        var config = UIButton.Configuration.plain()
        config.contentInsets = .zero
        config.background.backgroundColor = .clear
        configuration = config
        addSubview(record)
        returnGlyph.tintColor = .label
        returnGlyph.contentMode = .center
        returnGlyph.alpha = 0
        returnGlyph.isUserInteractionEnabled = false
        addSubview(returnGlyph)
        shareGlyph.tintColor = .label
        shareGlyph.contentMode = .center
        shareGlyph.alpha = 0
        shareGlyph.isUserInteractionEnabled = false
        addSubview(shareGlyph)

        addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .primaryActionTriggered)

        isAccessibilityElement = true
        accessibilityLabel = "Sound"
        accessibilityHint = "Double-tap for the sound."
        isHidden = true
    }

    /// The way back (#1929): the record cross-fades with `chevron.up`, the
    /// glass standing still. The record stops while hidden.
    func setShowsReturn(_ shows: Bool, animated: Bool) {
        guard shows != showsReturn else { return }
        showsReturn = shows
        applyFace(animated: animated)
    }

    /// The bubble as the post's Share (#1999), or back to its sound: Share's
    /// glyph in the glass where the record was, the way back cross-fading
    /// with it as with the record.
    func setSharesPost(_ shares: Bool) {
        guard shares != sharesPost else { return }
        sharesPost = shares
        accessibilityIdentifier = shares ? SnapFooterToolbar.ID.share : nil
        applyFace(animated: false)
    }

    /// Labels, enabled state and glyphs as the bubble stands: the way back,
    /// Share, or the sound.
    private func applyFace(animated: Bool) {
        let shows = showsReturn
        accessibilityLabel = shows ? "Back to top" : sharesPost ? "Share" : "Sound"
        accessibilityHint = shows || sharesPost ? nil : "Double-tap for the sound."
        // An unavailable sound stays greyed; the way back and Share always answer.
        isEnabled = shows || sharesPost || face?.isAvailable == true
        alpha = shows || sharesPost || face?.isAvailable != false ? 1 : 0.45
        let sharing = sharesPost
        let apply = {
            self.record.recordAlpha = shows || sharing ? 0 : 1
            self.returnGlyph.alpha = shows ? 1 : 0
            self.shareGlyph.alpha = sharing && !shows ? 1 : 0
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
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            record.setPressed(isHighlighted)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // By bounds and centre, not frame: the press transforms the record.
        record.bounds = CGRect(origin: .zero, size: bounds.size)
        record.center = CGPoint(x: bounds.midX, y: bounds.midY)
        bringSubviewToFront(record)
        returnGlyph.bounds = record.bounds
        returnGlyph.center = record.center
        bringSubviewToFront(returnGlyph)
        shareGlyph.bounds = record.bounds
        shareGlyph.center = record.center
        bringSubviewToFront(shareGlyph)
    }

    /// Draws `face`; nil hides nothing by itself (the host decides visibility)
    /// but clears the cover.
    func setFace(_ face: SnapSoundFace?, pipeline: ImagePipeline?) {
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
    func setSpinning(_ spinning: Bool) {
        wantsSpinning = spinning
        applySpinning()
    }

    private func applySpinning() {
        guard let face, face.isAvailable, !showsReturn, !sharesPost else { return record.setSpinning(false) }
        record.setSpinning(wantsSpinning)
    }

    /// The record's cover as drawn now — the hold's disc carries it (#1929).
    var coverImage: UIImage? { coverView.image }

    #if DEBUG
    /// Whether the record is turning now.
    var debugIsSpinning: Bool { record.isSpinning }
    #endif

    #if DEBUG
    var debugRecord: SoundRecordGlass { record }
    var debugCoverImage: UIImage? { coverView.image }
    var debugReturnGlyphAlpha: CGFloat { returnGlyph.alpha }
    var debugShareGlyphAlpha: CGFloat { shareGlyph.alpha }
    #endif
}
