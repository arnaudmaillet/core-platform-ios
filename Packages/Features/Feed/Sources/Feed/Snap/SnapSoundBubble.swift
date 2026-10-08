import DesignSystem
import MediaCore
import UIKit

/// `-snap-pill-footer` (DEBUG, #671): the author pill leaves the top bar for
/// the toolbar's leading slot, where the audio capsule was.
///
/// - The feed's toolbar reads `[author pill] … [⇄ 🔖] [⋯]`: repost takes the
///   share's place in the capsule, share moves into ⋯, the mute button goes.
/// - The column's lower bubble becomes a SOUND bubble wearing the sound's
///   cover (`SnapSoundBubbleButton`): a tap mutes, a long press opens the
///   sound sheet, a `speaker.slash` badge while muted. The comments composer's
///   rail slot wears the same cover.
/// - The Messages thread's toolbar reads `[peer pill] … [⋯]`: the emote strip
///   goes, the peer pill leaves the nav bar.
///
/// ⚠️ READ WHERE THE BARS AND CONSTRAINTS ARE BUILT, ONCE — the
/// `SnapActionColumn.isLikePill` doctrine (`-snap-layout-v2`, #340, was read
/// through a property whose `didSet` never ran). Settable by tests before they
/// build a view; never flipped under a live one.
@MainActor
enum SnapPillFooter {
    static var isOn: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-snap-pill-footer")
        #else
        false
        #endif
    }()
}

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

    /// The cover as it can be drawn on THIS turn: the note, or a picture the
    /// attribution has already fetched (`SnapAttributionCoverCache`).
    @MainActor var cachedCover: UIImage? {
        guard let coverURL else { return SnapMediaAttributionView.noteImage }
        return SnapAttributionCoverCache.cover(for: coverURL)
    }

    /// The cover as a disc of `side` points, drawn once — what a glass
    /// button's configuration can wear.
    @MainActor func disc(side: CGFloat) -> UIImage? {
        guard let cover = cachedCover else { return nil }
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: side, height: side)).addClip()
            let scale = max(side / max(cover.size.width, 1), side / max(cover.size.height, 1))
            let size = CGSize(width: cover.size.width * scale, height: cover.size.height * scale)
            cover.draw(in: CGRect(
                x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height
            ))
        }
        return image.withRenderingMode(.alwaysOriginal)
    }
}

/// The column's lower bubble under `-snap-pill-footer` (#671): the sound's
/// cover on the like bubble's glass, in the repost bubble's place.
///
/// - A TAP toggles the feed's sound; a LONG PRESS opens the sound sheet.
/// - A `speaker.slash` badge on its corner while the sound is off.
/// - Greyed and refusing the mute on a media post with no audio.
/// - The cover turns like a record while the post plays (`setSpinning`), under
///   the same decorative-motion rules as the toolbar's (#580, #650).
///
/// Configured PLAIN at init; the glass materializes on first window attach —
/// the like anchor's doctrine (`SnapRailBoostButton`).
final class SnapSoundBubbleButton: UIButton {
    /// A tap: toggle the sound.
    var onTap: (() -> Void)?
    /// A long press: open the sound sheet.
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
        accessibilityHint = "Double-tap to mute or unmute. Touch and hold for the sound."
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
            guard let image = try? await pipeline.image(for: url) else { return }
            SnapAttributionCoverCache.store(image, for: url)
            guard let self, self.face?.coverURL == url else { return }
            self.coverView.image = image
        }
    }

    /// Turns the cover like a record while the post plays.
    func setSpinning(_ spinning: Bool) {
        coverView.layer.setRecordSpinning(spinning)
    }

    #if DEBUG
    var debugIsMutedBadgeShown: Bool { !mutedBadge.isHidden }
    var debugCoverImage: UIImage? { coverView.image }
    #endif
}
