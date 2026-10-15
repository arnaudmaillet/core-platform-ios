import DesignSystem
import MediaCore
import UIKit

/// What the sound bubble (and the composer's rail slot) draws for a post.
struct SnapSoundFace: Equatable {
    /// The cover's picture — the sound's artwork, else the post's own; nil
    /// draws the note (a named song with no artwork).
    var coverURL: URL?
    /// The post plays a sound. False — a media post with no audio — draws
    /// the bubble greyed and refuses the mute.
    var isAvailable: Bool
    /// The feed's sound is off (`FeedSound`).
    var isMuted: Bool
    /// Where a remote cover is read from on this turn (#894): the feed's
    /// pipeline, whose memory the attribution pill fills too. Nil reads files
    /// only. Not part of what the face IS: two faces that draw the same
    /// cover are equal whoever holds the pipeline.
    var pipeline: ImagePipeline?

    init(coverURL: URL?, isAvailable: Bool, isMuted: Bool, pipeline: ImagePipeline? = nil) {
        self.coverURL = coverURL
        self.isAvailable = isAvailable
        self.isMuted = isMuted
        self.pipeline = pipeline
    }

    static func == (lhs: SnapSoundFace, rhs: SnapSoundFace) -> Bool {
        lhs.coverURL == rhs.coverURL && lhs.isAvailable == rhs.isAvailable && lhs.isMuted == rhs.isMuted
    }

    /// The cover as it can be drawn on THIS turn: the note, a picture already
    /// decoded in the pipeline's memory, or a FILE read here.
    ///
    /// ⚠️ A FILE IS READ, NEVER FETCHED (#680). Mock posters and local covers
    /// are file URLs, and the image pipeline paints a flat colour for any URL
    /// its fetchers do not recognise, a file among them: on a device the
    /// bubble wore a coloured disc instead of the post's picture, and the
    /// composer's slot wore nothing, since a file was never cached. The
    /// attribution has always read files directly (`SnapMediaAttributionView`).
    @MainActor var cachedCover: UIImage? {
        guard isAvailable else { return Self.noSoundImage }
        guard let coverURL else { return SnapMediaAttributionView.noteImage }
        if let hit = pipeline?.cachedImage(for: coverURL, size: SnapMediaAttributionView.coverBucket) { return hit }
        guard coverURL.isFileURL, let image = UIImage(contentsOfFile: coverURL.path) else { return nil }
        pipeline?.store(image, for: coverURL)
        return image
    }

    /// A post with no sound (#683): the note struck through, greyed — the
    /// bubble keeps its place and says there is nothing to hear.
    static let noSoundImage: UIImage = {
        let side: CGFloat = 64
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            UIColor.darkGray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let glyph = UIImage.symbol(named: noSoundSymbol, configuration: UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold))?
                .withTintColor(.lightGray, renderingMode: .alwaysOriginal)
            if let glyph {
                glyph.draw(at: CGPoint(x: (side - glyph.size.width) / 2, y: (side - glyph.size.height) / 2))
            }
        }
    }()
    static let noSoundSymbol = AppSymbol.speakerSlash.rawValue

    /// Fetches a remote cover into the pipeline, for a host that has to
    /// redraw once it lands (the composer's slot). Nil for a file, the note,
    /// or a fetch that fails — `cachedCover` already answers the first two.
    @MainActor static func fetchCover(_ url: URL, pipeline: ImagePipeline) async -> UIImage? {
        guard !url.isFileURL else { return nil }
        return try? await pipeline.image(for: url, size: SnapMediaAttributionView.coverBucket)
    }
}

/// The column's lower bubble (#671): the sound's record IN its glass
/// (`SoundRecordGlass`, #1150).
///
/// - A TAP opens the sound sheet; a LONG PRESS toggles the feed's sound
///   (#683).
/// - A `speaker.slash` badge on its corner while the sound is off.
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
    /// A tap: open the sound sheet.
    var onTap: (() -> Void)?
    /// A long press: toggle the sound.
    var onLongPress: (() -> Void)?

    private let record = SoundRecordGlass()
    private var coverView: UIImageView { record.cover }
    private(set) var face: SnapSoundFace?
    private var coverTask: Task<Void, Never>?

    init() {
        super.init(frame: .zero)
        var config = UIButton.Configuration.plain()
        config.contentInsets = .zero
        config.background.backgroundColor = .clear
        configuration = config
        addSubview(record)

        addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .primaryActionTriggered)
        // A recognised hold cancels the button's touch, so it never also
        // counts as the tap.
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.4
        addGestureRecognizer(hold)

        isAccessibilityElement = true
        accessibilityLabel = "Sound"
        accessibilityHint = "Double-tap for the sound. Touch and hold to mute or unmute."
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func held(_ recogniser: UILongPressGestureRecognizer) {
        guard recogniser.state == .began else { return }
        onLongPress?()
    }

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
    }

    /// Draws `face`; nil hides nothing by itself (the host decides visibility)
    /// but clears the cover.
    func setFace(_ face: SnapSoundFace?, pipeline: ImagePipeline?) {
        guard face != self.face else { return }
        let coverChanged = face?.coverURL != self.face?.coverURL || self.face == nil
            || face?.isAvailable != self.face?.isAvailable
        self.face = face
        record.showsMutedBadge = (face?.isMuted ?? false) && (face?.isAvailable ?? false)
        isEnabled = face?.isAvailable ?? false
        alpha = face?.isAvailable == false ? 0.45 : 1
        accessibilityValue = face.map { !$0.isAvailable ? "No audio" : ($0.isMuted ? "Muted" : "On") }
        guard coverChanged else { return }
        coverTask?.cancel()
        coverView.layer.removeAllAnimations()
        coverView.image = face?.cachedCover
        guard let face, coverView.image == nil, let url = face.coverURL, let pipeline else { return }
        coverTask = Task { [weak self] in
            guard let image = await SnapSoundFace.fetchCover(url, pipeline: pipeline) else { return }
            guard let self, self.face?.coverURL == url else { return }
            self.coverView.image = image
        }
    }

    /// Turns the cover like a record while the post plays audibly.
    func setSpinning(_ spinning: Bool) {
        record.setSpinning(spinning)
    }

    #if DEBUG
    /// Whether the record is turning now.
    var debugIsSpinning: Bool { record.isSpinning }
    #endif

    #if DEBUG
    var debugIsMutedBadgeShown: Bool { record.showsMutedBadge }
    var debugRecord: SoundRecordGlass { record }
    var debugCoverImage: UIImage? { coverView.image }
    #endif
}
