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

    /// The cover as it can be drawn on THIS turn: the note, a picture already
    /// fetched (`SnapAttributionCoverCache`), or a FILE read here.
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
        if let hit = SnapAttributionCoverCache.cover(for: coverURL) { return hit }
        guard coverURL.isFileURL, let image = UIImage(contentsOfFile: coverURL.path) else { return nil }
        SnapAttributionCoverCache.store(image, for: coverURL)
        return image
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

    /// Fetches a remote cover into the cache, for a host that has to redraw
    /// once it lands (the composer's slot). Nil for a file, the note, or a
    /// fetch that fails — `cachedCover` already answers the first two.
    @MainActor static func fetchCover(_ url: URL, pipeline: ImagePipeline) async -> UIImage? {
        guard !url.isFileURL else { return nil }
        guard let image = try? await pipeline.image(for: url) else { return nil }
        SnapAttributionCoverCache.store(image, for: url)
        return image
    }

    /// The cover as a disc of `side` points, drawn once — what a glass
    /// button's configuration can wear — with the muted badge on its corner
    /// when `badged`.
    @MainActor func disc(side: CGFloat, badged: Bool = false) -> UIImage? {
        guard let cover = cachedCover else { return nil }
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            context.cgContext.saveGState()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: side, height: side)).addClip()
            let scale = max(side / max(cover.size.width, 1), side / max(cover.size.height, 1))
            let size = CGSize(width: cover.size.width * scale, height: cover.size.height * scale)
            cover.draw(in: CGRect(
                x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height
            ))
            context.cgContext.restoreGState()
            guard badged else { return }
            let badge: CGFloat = 14
            let frame = CGRect(x: side - badge, y: side - badge, width: badge, height: badge)
            UIColor.black.withAlphaComponent(0.7).setFill()
            UIBezierPath(ovalIn: frame).fill()
            if let glyph = UIImage(
                systemName: "speaker.slash.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 7, weight: .bold)
            )?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                glyph.draw(at: CGPoint(x: frame.midX - glyph.size.width / 2, y: frame.midY - glyph.size.height / 2))
            }
        }
        return image.withRenderingMode(.alwaysOriginal)
    }
}

/// The column's lower bubble (#671): the sound's cover on the like pill's
/// glass.
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
/// Configured PLAIN at init; the glass materializes on first window attach —
/// the like anchor's doctrine (`SnapRailBoostButton`).
final class SnapSoundBubbleButton: UIButton {
    /// A tap: open the sound sheet.
    var onTap: (() -> Void)?
    /// A long press: toggle the sound.
    var onLongPress: (() -> Void)?

    private let coverView = UIImageView()
    private let mutedBadge = UIImageView()
    private var hasGlass = false
    private(set) var face: SnapSoundFace?
    private var coverTask: Task<Void, Never>?

    init() {
        super.init(frame: .zero)
        applyGlass()
        coverView.contentMode = .scaleAspectFill
        coverView.clipsToBounds = true
        coverView.isUserInteractionEnabled = false
        addSubview(coverView)

        mutedBadge.image = UIImage(
            systemName: "speaker.slash.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        )
        mutedBadge.tintColor = .white
        mutedBadge.contentMode = .center
        mutedBadge.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        mutedBadge.isUserInteractionEnabled = false
        mutedBadge.isHidden = true
        addSubview(mutedBadge)

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

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, !hasGlass {
            hasGlass = true
            applyGlass()
        }
    }

    private func applyGlass() {
        var config: UIButton.Configuration = hasGlass ? .glass() : .plain()
        config.cornerStyle = .capsule
        config.contentInsets = .zero
        configuration = config
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset: CGFloat = 5
        coverView.frame = bounds.insetBy(dx: inset, dy: inset)
        coverView.layer.cornerRadius = coverView.bounds.width / 2
        let badge: CGFloat = 16
        mutedBadge.frame = CGRect(x: bounds.maxX - badge, y: bounds.maxY - badge, width: badge, height: badge)
        mutedBadge.layer.cornerRadius = badge / 2
        bringSubviewToFront(coverView)
        bringSubviewToFront(mutedBadge)
    }

    /// Draws `face`; nil hides nothing by itself (the host decides visibility)
    /// but clears the cover.
    func setFace(_ face: SnapSoundFace?, pipeline: ImagePipeline?) {
        guard face != self.face else { return }
        let coverChanged = face?.coverURL != self.face?.coverURL || self.face == nil
            || face?.isAvailable != self.face?.isAvailable
        self.face = face
        mutedBadge.isHidden = !(face?.isMuted ?? false) || !(face?.isAvailable ?? false)
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
        coverView.layer.setRecordSpinning(spinning, reducesMotion: MotionPreference.reducesMotion)
    }

    #if DEBUG
    /// Whether the record is turning now.
    var debugIsSpinning: Bool {
        coverView.layer.animation(forKey: CALayer.recordSpinKey) != nil && coverView.layer.speed != 0
    }
    #endif

    #if DEBUG
    var debugIsMutedBadgeShown: Bool { !mutedBadge.isHidden }
    var debugCoverImage: UIImage? { coverView.image }
    #endif
}
