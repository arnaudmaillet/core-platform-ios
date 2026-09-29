import MediaCore
import CoreModels
import DesignSystem
import UIKit

/// The media attribution (mini circular cover + author name + audio line)
/// hosted as the *leading* item of the navigation controller's native
/// toolbar — the bottom-bar sibling of `SnapAuthorIdentityView`, and built on
/// the same contracts:
///
/// - Content-hugging custom view: the toolbar's system glass wraps it, and
///   the `.flexibleSpace()` item next to it owns the spacer role natively —
///   nothing here absorbs width.
/// - Rigidity flows one way: the cover is fixed (shared `barDiameter`
///   circle), the labels compress first (749, one under UIKit's default), so
///   a long author name truncates under the width cap instead of pushing the
///   trailing actions.
/// - Page-fed, ONE VIEW IN ONE ITEM for the screen's life: a page that draws
///   something else blurs the old content out and the new in, inside the
///   item (`BarItemContentTransition`) — the identity pill's mechanism. The
///   glass platter never morphs; only the width glides when it changes.
final class SnapMediaAttributionView: UIView {
    /// The bar-bubble invariant: every bubble on the feed's bars — back
    /// button, identity pill wrapper, and all three toolbar bubbles — renders
    /// 36pt tall (the bar item wrapper's own height on iOS 26), so the system
    /// glass capsules read as one family top and bottom.
    private static let height: CGFloat = 36
    /// Long author names truncate here rather than crowding the share/more
    /// bubbles across the flexible space.
    ///
    /// ⚠️ A BAR SHORT OF ROOM FOLDS ITS TRAILING ITEMS INTO UIKit's OWN
    /// "•••", it does not truncate anything: with a long sound line the
    /// [🔖 ⇄] capsule and ⋯ were replaced by a system overflow button that
    /// looked exactly like ⋯ — the bookmark simply gone. So the cap is the
    /// room the bar actually has, read off the bar's own frames on iOS 27
    /// (iPhone 18 Pro, `-dump-bars`): 28pt margins each side, this capsule's
    /// glass +10 around the pill and the mute's 48pt platter, the [🔖 ⇄]
    /// capsule 86pt, ⋯ 48pt, two 8pt gaps — and 12pt of slack, because the
    /// fold is silent and one point short is the whole capsule. A fixed 180
    /// folded it on a 402pt screen; the host sets it (`setMaximumWidth`).
    static let barReserve: CGFloat = 28 + 10 + 48 + 8 + 86 + 8 + 48 + 28 + 16
    private static let defaultMaxWidth: CGFloat = 120
    private var maxWidthConstraint: NSLayoutConstraint?

    /// A tap on the pill — the feed opens the sound sheet. Nil keeps it a label.
    var onTap: (() -> Void)?

    private let coverView = AvatarImageView()
    private let titleLabel = UILabel()
    private let trackLabel = UILabel()

    /// The post the cover task is loading for — compared on arrival so a fast
    /// page-past cannot land an image on the wrong pill.
    private var postID: PostID?
    /// What is actually on screen, so a repeat call can tell "same page again"
    /// from "same page, better data".
    private var renderedModel: FeedItemDisplayModel?
    private var renderedSound: SoundCredit = .unresolved
    private var renderedCover: Cover = .post
    private var renderedSoundLine: String?
    private var coverTask: Task<Void, Never>?
    /// Everything the pill draws, edge-pinned: the one view a content change
    /// fades — a CONTAINER, because a platter flattens a label's own partial
    /// alpha to opaque.
    private let contentView = UIView()
    /// Blurs one attribution out and the next in, inside the one toolbar item.
    private lazy var contentTransition: BarItemContentTransition = {
        let transition = BarItemContentTransition(host: self, content: contentView)
        transition.remeasure = { [unowned self] duration in BarItemRemeasure.run(self, duration: duration) }
        transition.didSettle = { [unowned self] in self.onContentSettled?() }
        return transition
    }()
    /// Once a content change has fully landed.
    var onContentSettled: (() -> Void)?

    init() {
        super.init(frame: .zero)

        // The shared bar-surface circle: same diameter as the identity
        // avatars, perfectly round by construction.
        coverView.backgroundColor = .darkGray
        coverView.widthAnchor.constraint(equalToConstant: AvatarImageView.barDiameter).isActive = true
        coverView.heightAnchor.constraint(equalToConstant: AvatarImageView.barDiameter).isActive = true

        titleLabel.font = UIFont.preferredFont(forTextStyle: .footnote).withWeight(.semibold)
        titleLabel.textColor = .label
        trackLabel.font = .preferredFont(forTextStyle: .caption2)
        trackLabel.textColor = .secondaryLabel

        // The toolbar is transparent over arbitrary media; shadows keep the
        // text legible without a background (same treatment as the identity
        // pill above).
        for label in [titleLabel, trackLabel] {
            label.layer.shadowColor = UIColor.black.cgColor
            label.layer.shadowOpacity = 0.5
            label.layer.shadowRadius = 3
            label.layer.shadowOffset = .zero
        }

        let labelsStack = UIStackView(arrangedSubviews: [titleLabel, trackLabel])
        labelsStack.axis = .vertical
        labelsStack.alignment = .leading
        labelsStack.setContentCompressionResistancePriority(UILayoutPriority(749), for: .horizontal)

        let row = UIStackView(arrangedSubviews: [coverView, labelsStack])
        row.axis = .horizontal
        row.spacing = Spacing.sm
        row.alignment = .center
        // The cover's uniform breathing inside the item wrapper, matching the
        // identity pill's inset math on the opposite bar.
        let breathing = (Self.height - AvatarImageView.barDiameter) / 2
        contentView.pin(to: self)
        row.constrain(in: contentView) { parent in
            row.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: breathing)
            row.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -Spacing.sm)
            row.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }
        // 999, never required: the bar wraps custom items in its own
        // fixed-height container via autoresizing constraints; anything
        // required loses to that with a console break.
        let height = heightAnchor.constraint(equalToConstant: Self.height)
        height.priority = UILayoutPriority(999)
        height.isActive = true
        let maxWidth = widthAnchor.constraint(lessThanOrEqualToConstant: Self.defaultMaxWidth)
        maxWidth.isActive = true
        maxWidthConstraint = maxWidth

        let press = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
        press.minimumPressDuration = 0
        press.cancelsTouchesInView = false
        addGestureRecognizer(press)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    /// The app's one press: shrink and dim while held, act on a lift inside.
    @objc private func pressed(_ gesture: UILongPressGestureRecognizer) {
        // Only a post with a sound opens anything.
        guard onTap != nil, renderedSoundLine != nil else { return setPressed(false) }
        let inside = bounds.insetBy(dx: -12, dy: -12).contains(gesture.location(in: self))
        switch gesture.state {
        case .began, .changed:
            setPressed(inside)
        case .ended:
            setPressed(false)
            if inside { onTap?() }
        default:
            setPressed(false)
        }
    }

    private func setPressed(_ pressed: Bool) {
        UIView.animate(withDuration: pressed ? 0.12 : 0.22, delay: 0,
                       usingSpringWithDamping: 0.8, initialSpringVelocity: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.transform = pressed ? CGAffineTransform(scaleX: 0.95, y: 0.95) : .identity
            self.alpha = pressed ? 0.7 : 1
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The widest the pill may be — the bar's own room, see `barReserve`.
    func setMaximumWidth(_ width: CGFloat) {
        guard let maxWidthConstraint, abs(maxWidthConstraint.constant - width) > 0.5 else { return }
        maxWidthConstraint.constant = width
        BarItemRemeasure.run(self, duration: 0.22)
    }

    /// The SHADOW only — the identity pill's rule, for the same reason: the
    /// colours are semantic and come from the toolbar's theme.
    func setOverMedia(_ overMedia: Bool) {
        for label in [titleLabel, trackLabel] {
            label.layer.shadowOpacity = overMedia ? 0.5 : 0
        }
    }

    /// Shows `model`'s attribution. A page change blurs the content across and
    /// reloads the cover (guarded against fast page-past); the same CONTENT is
    /// a no-op. Called from the settle-quantized activation seam only — never
    /// mid-scroll.
    ///
    /// ⚠️ The guard compares the MODEL, not its id, and that is the whole
    /// difference between a pill that fills in and one that does not. A page
    /// opened from a grid is shown twice from one id — the projection the grid
    /// handed over, then the entry the network returns — so an id-keyed
    /// early-out reads the second call as "same post, nothing to do" and keeps
    /// the projection's anonymous author for the life of the screen. The
    /// purpose of the guard is unharmed: a re-settle on an unchanged page still
    /// skips the transition and the cover refetch, because an unchanged page
    /// has an unchanged model.
    /// What the second line says about the post's sound.
    enum SoundCredit: Equatable {
        /// Nobody asked: the model's own derived line, or its meta line.
        case unresolved
        /// The post plays this — a tap opens it.
        case sound(String)
        /// The post plays nothing, and the line says so.
        case none
    }

    /// What the round cover shows.
    enum Cover: Equatable {
        /// The post's own picture — its thumbnail, or the author's avatar.
        case post
        /// The sound's artwork: the cover of the song or original sound.
        case artwork(URL)
        /// A sound with no artwork of its own: a note, never somebody's photo.
        case note
    }

    /// The second line `sound` puts under `model`'s name.
    private static func line(for model: FeedItemDisplayModel, sound: SoundCredit) -> String {
        switch sound {
        case .sound(let line): line
        case .none: "No audio"
        // Derived attribution until the BFF carries track metadata; non-audio
        // posts fall back to the handle/time meta line.
        case .unresolved: model.audioText ?? model.metaText
        }
    }

    /// The picture the round cover draws, nil for the note.
    private static func coverURL(for model: FeedItemDisplayModel, cover: Cover) -> URL? {
        switch cover {
        case .note: nil
        case .artwork(let artwork): artwork
        // The media's thumbnail, else the author's avatar.
        case .post: model.thumbnailURL ?? model.avatarURL
        }
    }

    /// Everything the pill DRAWS for this post, as one string: the name, the
    /// sound line, whether a tap opens anything, and the cover.
    ///
    /// It is what the snap feed compares before transitioning. Two pages that
    /// draw the same pill (one person's posts set to one song with its own
    /// artwork) change nothing on the bar; anything that draws differently
    /// blurs across. A post's own id is deliberately NOT in it: the cover
    /// already carries the post whenever the post is what it shows.
    static func contentKey(
        for model: FeedItemDisplayModel, sound: SoundCredit = .unresolved, cover: Cover = .post
    ) -> String {
        let tappable = if case .sound = sound { "tap" } else { "-" }
        let picture = switch cover {
        case .note: "note"
        case .artwork, .post: coverURL(for: model, cover: cover)?.absoluteString ?? "blank"
        }
        return [model.authorName, line(for: model, sound: sound), tappable, picture].joined(separator: "|")
    }

    /// `contentKey` of what the pill shows now; nil before its first post.
    private(set) var shownContentKey: String?

    /// Fetches `model`'s cover into the pill's cache ahead of need — the next
    /// page's — so the pill's swap to it is drawn with it.
    static func warmCover(
        for model: FeedItemDisplayModel, cover: Cover, pipeline: ImagePipeline
    ) {
        guard let url = coverURL(for: model, cover: cover),
              !url.isFileURL, SnapAttributionCoverCache.cover(for: url) == nil else { return }
        Task { @MainActor in
            guard let image = try? await pipeline.image(for: url) else { return }
            SnapAttributionCoverCache.store(image, for: url)
        }
    }

    /// - Parameter animated: whether a change blurs across
    ///   (`BarItemContentTransition`); false, or a pill not in a window, swaps
    ///   in one frame. The pill's STATE (what a tap opens, what the cover
    ///   fetch is for) is the new post at once; only the drawing waits for the
    ///   transition's midpoint.
    func setPost(
        _ model: FeedItemDisplayModel, sound: SoundCredit = .unresolved, cover: Cover = .post,
        pipeline: ImagePipeline, animated: Bool = true
    ) {
        let soundLine: String? = if case .sound(let line) = sound { line } else { nil }
        guard model != renderedModel || sound != renderedSound || cover != renderedCover else { return }
        let isNewPost = model.id != renderedModel?.id
        renderedModel = model
        renderedSound = sound
        renderedCover = cover
        shownContentKey = Self.contentKey(for: model, sound: sound, cover: cover)
        renderedSoundLine = soundLine
        let line = Self.line(for: model, sound: sound)
        postID = model.id
        let url = Self.coverURL(for: model, cover: cover)
        // A cover already in hand is drawn in the same pass as the labels:
        // the blur's new still pictures it, nothing fades in after the swap.
        let cached: UIImage? = switch cover {
        case .note: Self.noteImage
        case .artwork, .post: url.flatMap(SnapAttributionCoverCache.cover(for:))
        }

        contentTransition.perform(animated: animated) {
            // A new post's record starts upright; the same one keeps its angle.
            // At the swap, not before: the old cover must not snap upright
            // while it is blurring out.
            if isNewPost { self.resetSpin() }
            self.titleLabel.text = model.authorName
            self.trackLabel.text = line
            self.accessibilityLabel = "\(model.authorName), \(line)"
            self.accessibilityHint = soundLine == nil ? nil : "Opens the sound"
            self.coverView.image = cached
        }

        coverTask?.cancel()
        guard cached == nil, let url else { return }
        let id = model.id
        coverTask = Task { [weak self] in
            // ⚠️ A file is read as it is: the mock pipeline paints a colour for
            // any URL it does not recognise, a file among them.
            let image: UIImage? = if url.isFileURL {
                await Task.detached(priority: .userInitiated) {
                    UIImage(contentsOfFile: url.path)?.preparingForDisplay()
                }.value
            } else {
                try? await pipeline.image(for: url)
            }
            guard let image else { return }
            if !url.isFileURL { SnapAttributionCoverCache.store(image, for: url) }
            guard let self, self.postID == id else { return }
            // Onto the NEW post's content: mid-blur, the old cover is still
            // what the live view draws.
            self.contentTransition.afterSwap { [weak self] in
                guard let self, self.postID == id else { return }
                UIView.transition(with: self.coverView, duration: 0.15, options: [.transitionCrossDissolve]) {
                    self.coverView.image = image
                }
            }
        }
    }

    /// Turns the cover like a record while the post's media plays, and stops
    /// it where it is when it does not.
    func setSpinning(_ spinning: Bool) {
        coverView.layer.setRecordSpinning(spinning)
    }

    private func resetSpin() {
        coverView.layer.removeAllAnimations()
        coverView.layer.speed = 1
        coverView.layer.timeOffset = 0
        coverView.layer.beginTime = 0
    }

    /// A white note on the cover's own dark ground.
    private static let noteImage: UIImage = {
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

/// The covers the attribution pill has drawn lately, readable SYNCHRONOUSLY —
/// `SnapAuthorFaceCache`'s twin, for the same reason: a swap made on this turn
/// has to draw the new post wearing its cover, not pop to it once the blur
/// has landed.
///
/// Smaller than the face cache: a cover can be a post's whole thumbnail.
@MainActor
enum SnapAttributionCoverCache {
    static let capacity = 8
    private static var covers: [URL: UIImage] = [:]
    /// Least recently stored first.
    private static var order: [URL] = []

    static func cover(for url: URL) -> UIImage? { covers[url] }

    static func store(_ image: UIImage, for url: URL) {
        if covers.updateValue(image, forKey: url) != nil {
            order.removeAll { $0 == url }
        }
        order.append(url)
        while order.count > capacity {
            covers[order.removeFirst()] = nil
        }
    }
}
