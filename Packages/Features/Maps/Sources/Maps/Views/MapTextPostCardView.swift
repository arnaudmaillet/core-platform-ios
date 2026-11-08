import CoreModels
import DesignSystem
import EmoteKit
import MediaCore
import PostGrid
import UIKit

/// `-map-text-card` (the owner, 2026-11-08): over the map, in the filter
/// bars' place above the tab bar, a VERTICAL CAROUSEL of cards for the text
/// posts around the map's centre — each post its own card, the previous one
/// peeking out above the front one.
///
/// ```
///   ╭──────────────────────────────────────╮   ← the previous post's card,
/// ╭──────────────────────────────────────────╮    above, a little smaller
/// │ (◉) Ava Moreau · 2h                1.2K ♥ │
/// │ Golden hour at the pier, the light hit   │
/// │ the water and everything went quiet…     │
/// │ ⌖ Paris, France                          │
/// ╰──────────────────────────────────────────╯
/// ```
///
/// - **A turn is a carousel's.** Next: the front card rises into the place
///   above — it is the previous one now — and the next comes up from below.
///   Previous: the card above comes down to the front and the front one
///   leaves below. As the map moves to another post the cards turn the same
///   way — the words are never just swapped in one card.
/// - **A vertical swipe turns them** (up: next, down: previous), the front
///   card following the finger, rubber-banded; a tap opens the post. The
///   list loops: the host hands the post after the last.
/// - **Glass, as the system's floating controls**: the map shows through it,
///   blurred; a press swells the FRONT card a little, as a glass control
///   grows under the finger.
/// - **Two cards, ever** — the front and the one behind — handed their roles
///   back and forth, never more glass than that.
final class MapTextPostCardView: UIControl {
    /// What a card says.
    struct Content: Equatable {
        let postID: PostID
        let authorName: String
        let monogram: String
        let avatarURL: URL?
        let age: String
        let caption: String
        let place: String?
        let likes: Int64?

        /// A card's words for `post`, read against `now`, at `place`.
        static func of(_ post: GalleryPost, place: String?, now: Date = Date()) -> Content {
            let name = post.authorName ?? post.authorHandle.map { "@\($0)" } ?? ""
            let published = Date(timeIntervalSince1970: TimeInterval(post.publishedAtMS) / 1000)
            return Content(
                postID: post.id,
                authorName: name,
                monogram: MonogramAvatarView.monogram(name: post.authorName ?? "", handle: post.authorHandle ?? ""),
                avatarURL: post.authorAvatarURL,
                age: post.publishedAtMS > 0 ? RelativeAgeFormatter.short(from: published, to: now) : "",
                caption: post.caption.trimmingCharacters(in: .whitespacesAndNewlines),
                place: place,
                likes: post.reactionCount
            )
        }
    }

    /// What a card shows: nothing, bones while the post's words load, or
    /// the words.
    enum Shown: Equatable {
        case hidden
        case loading(PostID)
        case content(Content)

        var postID: PostID? {
            switch self {
            case .hidden: nil
            case .loading(let id): id
            case .content(let words): words.postID
            }
        }
    }

    /// How the front card changes.
    enum Turn: Equatable {
        /// In place — the first card, or its words arriving.
        case none
        /// The next post: the front card rises into the place above, the
        /// next comes up from below.
        case next
        /// The previous post: the card above comes down to the front, the
        /// front one leaves below.
        case previous
    }

    /// A tap: open the front post.
    var onTap: (() -> Void)?
    /// A vertical swipe released past its threshold: up asks for the next
    /// post, down for the previous one.
    var onSwipe: ((Turn) -> Void)?

    private(set) var shown: Shown = .hidden
    private(set) var shownBehind: Shown = .hidden

    // MARK: - Metrics

    static let padding: CGFloat = Spacing.md
    static let rowGap: CGFloat = 6
    static let avatarSide: CGFloat = 28
    /// How far the card behind — the previous post's — shows above the front
    /// one, and how much smaller it stands.
    static let peek: CGFloat = 14
    static let behindScale: CGFloat = 0.9
    /// The card behind's own dimness, so the front one leads.
    static let behindAlpha: CGFloat = 0.75
    /// A swipe that travels this far, or flicks this fast, turns the cards.
    static let swipeDistance: CGFloat = 44
    static let swipeVelocity: CGFloat = 450
    /// How much the front card grows under a finger (the owner: less than a
    /// button's swell).
    static let pressedScale: CGFloat = 1.025

    // MARK: - Views

    private var front: Shell
    private var back: Shell
    private let pan = UIPanGestureRecognizer()
    private var isPanning = false

    init(imagePipeline: ImagePipeline?) {
        front = Shell(imagePipeline: imagePipeline)
        back = Shell(imagePipeline: imagePipeline)
        super.init(frame: .zero)
        for shell in [back, front] {
            shell.translatesAutoresizingMaskIntoConstraints = false
            addSubview(shell)
            NSLayoutConstraint.activate([
                shell.leadingAnchor.constraint(equalTo: leadingAnchor),
                shell.trailingAnchor.constraint(equalTo: trailingAnchor),
                // The room the card behind peeks into.
                shell.topAnchor.constraint(equalTo: topAnchor, constant: Self.peek),
                shell.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        back.alpha = 0
        // Down until a text post is in view.
        alpha = 0
        isHidden = true
        transform = Self.downTransform

        // ⚠️ `.touchUpInside`, NOT `.primaryActionTriggered`: a plain
        // control never sends the latter (a button does), and the card's tap
        // went unheard. A swipe cancels the touch first, so it is no tap.
        addAction(UIAction { [weak self] _ in self?.tapped() }, for: .touchUpInside)
        // The front card alone grows under the finger, a little, and springs
        // back past rest — the one behind does not move.
        addAction(UIAction { [weak self] _ in self?.setPressed(true) }, for: [.touchDown, .touchDragEnter])
        addAction(UIAction { [weak self] _ in self?.setPressed(false) },
                  for: [.touchUpInside, .touchUpOutside, .touchDragExit, .touchCancel])
        pan.addTarget(self, action: #selector(panned(_:)))
        pan.delegate = self
        addGestureRecognizer(pan)

        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityHint = "Opens the post"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The card behind keeps its pose as the size settles.
        if (back.layer.animationKeys() ?? []).isEmpty, !isPanning {
            back.transform = behindPose
        }
    }

    /// Where a stack down rests: a little lower, a little smaller.
    private static let downTransform = CGAffineTransform(translationX: 0, y: 24).scaledBy(x: 0.96, y: 0.96)

    /// The card behind: smaller, its top `peek` above the front card's.
    private var behindPose: CGAffineTransform {
        let height = max(1, front.bounds.height)
        let drop = height * (1 - Self.behindScale) / 2
        return CGAffineTransform(translationX: 0, y: -(Self.peek + drop))
            .scaledBy(x: Self.behindScale, y: Self.behindScale)
    }

    /// Where a card comes up from, and leaves to: below the front one.
    private var belowPose: CGAffineTransform {
        CGAffineTransform(translationX: 0, y: max(1, front.bounds.height) * 0.7).scaledBy(x: 0.96, y: 0.96)
    }

    // MARK: - The press

    private var isPressed = false
    /// Where the finger came down, in the stack's space.
    private var touchDownPoint: CGPoint?

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        touchDownPoint = touch.location(in: self)
        return super.beginTracking(touch, with: event)
    }

    /// Whether `point` falls on the card above's strip, over the front one
    /// (the owner, 2026-11-08: a tap there turns back to it).
    func isOnCardAbove(_ point: CGPoint) -> Bool {
        back.alpha > 0 && point.y < front.frame.minY
    }

    /// A tap: on the card above, back to it — as a swipe down; anywhere else,
    /// the front post opens.
    private func tapped() {
        if let point = touchDownPoint, isOnCardAbove(point) {
            Haptics.play(.armed)
            onSwipe?(.previous)
        } else {
            onTap?()
        }
    }

    private func setPressed(_ pressed: Bool) {
        // A press on the card above is not the front card's.
        if pressed, let point = touchDownPoint, isOnCardAbove(point) { return }
        guard pressed != isPressed, !isPanning else { return }
        isPressed = pressed
        let card = front
        let grown = pressed ? CGAffineTransform(scaleX: Self.pressedScale, y: Self.pressedScale) : .identity
        guard !MotionPreference.reducesMotion else { return }
        UIView.animate(
            springDuration: pressed ? 0.25 : 0.4, bounce: pressed ? 0.2 : 0.45,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            card.transform = grown
        }
    }

    // MARK: - Showing

    /// Shows `next` in front and `behind` behind it, the front card turning
    /// `turn`'s way; `.hidden` in front takes the stack down.
    func show(_ next: Shown, behind: Shown = .hidden, turn: Turn = .none, animated: Bool) {
        guard next != shown || behind != shownBehind else { return }
        let previous = shown
        shown = next
        shownBehind = behind
        let moves = animated && window != nil && !MotionPreference.reducesMotion
        defer { applyAccessibility() }
        guard next != .hidden else { return goDown(animated: moves) }
        if previous == .hidden {
            front.layer.removeAllAnimations()
            back.layer.removeAllAnimations()
            front.apply(next)
            back.apply(behind)
            front.setShowsWords(true, animated: false)
            back.setShowsWords(false, animated: false)
            front.transform = .identity
            front.alpha = 1
            back.transform = behindPose
            back.alpha = behind == .hidden ? 0 : Self.behindAlpha
            return comeUp(animated: moves)
        }
        if next.postID == previous.postID {
            // The same post: its words arriving fill in place; the card
            // behind follows on its own.
            front.apply(next, fading: moves)
            setBehind(behind, animated: moves)
            return
        }
        switch turn {
        case .previous: turnBack(to: next, behind: behind, animated: moves)
        case .next, .none: turnForward(to: next, behind: behind, animated: moves)
        }
    }

    /// The card behind alone changes: it fades to its new post.
    private func setBehind(_ behind: Shown, animated: Bool) {
        let target: CGFloat = behind == .hidden ? 0 : Self.behindAlpha
        guard back.shown != behind else {
            if !animated { back.alpha = target; return }
            UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState]) { self.back.alpha = target }
            return
        }
        guard animated else {
            back.apply(behind)
            back.alpha = target
            return
        }
        let card = back
        UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState]) {
            card.alpha = 0
        } completion: { _ in
            guard card === self.back else { return }
            card.apply(self.shownBehind)
            let alpha: CGFloat = self.shownBehind == .hidden ? 0 : Self.behindAlpha
            UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState]) { card.alpha = alpha }
        }
    }

    /// Next: the front card rises into the place above — the previous one
    /// now — and the next comes up from below, in the card that stood above.
    private func turnForward(to next: Shown, behind: Shown, animated: Bool) {
        let rising = front
        let arriving = back
        front = arriving
        back = rising
        bringSubviewToFront(arriving)
        arriving.layer.removeAllAnimations()
        arriving.apply(next)
        arriving.setShowsWords(true, animated: false)
        rising.setShowsWords(false, animated: animated)
        if rising.shown != behind { rising.apply(behind) }
        let behindAlpha: CGFloat = behind == .hidden ? 0 : Self.behindAlpha
        guard animated else {
            arriving.transform = .identity
            arriving.alpha = 1
            rising.transform = behindPose
            rising.alpha = behindAlpha
            return
        }
        arriving.transform = belowPose
        arriving.alpha = 0
        UIView.animate(springDuration: 0.5, bounce: 0.15, options: [.allowUserInteraction, .beginFromCurrentState]) {
            arriving.transform = .identity
            arriving.alpha = 1
        }
        let pose = behindPose
        UIView.animate(springDuration: 0.5, bounce: 0.1, options: [.allowUserInteraction, .beginFromCurrentState]) {
            rising.transform = pose
            rising.alpha = behindAlpha
        }
    }

    /// Previous: the card above comes down to the front; the front one
    /// leaves below, and comes back above with the post before.
    private func turnBack(to next: Shown, behind: Shown, animated: Bool) {
        let leaving = front
        let arriving = back
        front = arriving
        back = leaving
        bringSubviewToFront(arriving)
        if arriving.shown != next { arriving.apply(next) }
        arriving.setShowsWords(true, animated: animated)
        guard animated else {
            leaving.setShowsWords(false, animated: false)
            arriving.transform = .identity
            arriving.alpha = 1
            leaving.apply(behind)
            leaving.transform = behindPose
            leaving.alpha = behind == .hidden ? 0 : Self.behindAlpha
            return
        }
        // A card that was not peeking (nothing above) comes from there.
        if arriving.alpha == 0 { arriving.transform = behindPose }
        UIView.animate(springDuration: 0.5, bounce: 0.15, options: [.allowUserInteraction, .beginFromCurrentState]) {
            arriving.transform = .identity
            arriving.alpha = 1
        }
        let below = belowPose
        UIView.animate(springDuration: 0.4, bounce: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            leaving.transform = below
            leaving.alpha = 0
        } completion: { _ in
            guard leaving === self.back else { return }
            // Above now, with the post before: it settles into its place.
            leaving.setShowsWords(false, animated: false)
            leaving.apply(self.shownBehind)
            leaving.transform = self.behindPose.translatedBy(x: 0, y: -14)
            guard self.shownBehind != .hidden else { return }
            UIView.animate(springDuration: 0.4, bounce: 0.1, options: [.allowUserInteraction, .beginFromCurrentState]) {
                leaving.transform = self.behindPose
                leaving.alpha = Self.behindAlpha
            }
        }
    }

    private func comeUp(animated: Bool) {
        isHidden = false
        guard animated else {
            alpha = 1
            transform = .identity
            return
        }
        UIView.animate(springDuration: 0.5, bounce: 0.25, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.alpha = 1
            self.transform = .identity
        }
    }

    private func goDown(animated: Bool) {
        let finish = { [weak self] in
            guard let self, shown == .hidden else { return }
            isHidden = true
        }
        guard animated else {
            alpha = 0
            transform = Self.downTransform
            return finish()
        }
        UIView.animate(springDuration: 0.35, bounce: 0, options: [.beginFromCurrentState]) {
            self.alpha = 0
            self.transform = Self.downTransform
        } completion: { _ in
            finish()
        }
    }

    private func applyAccessibility() {
        switch shown {
        case .hidden:
            accessibilityLabel = nil
        case .loading:
            accessibilityLabel = "Text post, loading"
        case .content(let content):
            var parts = ["\(content.caption)", "by \(content.authorName)"]
            if !content.age.isEmpty { parts.append(content.age) }
            if let place = content.place { parts.append(place) }
            accessibilityLabel = parts.joined(separator: ", ")
        }
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Next text post") { [weak self] _ in
                self?.onSwipe?(.next)
                return true
            },
            UIAccessibilityCustomAction(name: "Previous text post") { [weak self] _ in
                self?.onSwipe?(.previous)
                return true
            },
        ]
    }

    // MARK: - The swipe

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        let dy = pan.translation(in: self).y
        switch pan.state {
        case .began:
            setPressed(false)
            isPanning = true
        case .changed:
            // Rubber-banded: the front card follows the finger, giving less
            // the further; the one behind stays where it is.
            let damped = dy / (1 + abs(dy) / 160)
            front.transform = CGAffineTransform(translationX: 0, y: damped)
        case .ended, .cancelled, .failed:
            isPanning = false
            let velocity = pan.velocity(in: self).y
            let commits = pan.state == .ended
                && (abs(dy) > Self.swipeDistance || abs(velocity) > Self.swipeVelocity)
            let turn: Turn = (abs(dy) > 1 ? dy : velocity) < 0 ? .next : .previous
            let before = shown
            if commits {
                Haptics.play(.armed)
                onSwipe?(turn)
            }
            // Nothing turned (nothing that way): back into place.
            guard shown == before else { return }
            UIView.animate(springDuration: 0.4, bounce: 0.25, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.front.transform = .identity
            }
        default:
            break
        }
    }

    // MARK: - DEBUG

    var debugFrontCaption: String? { front.face.debugCaption }
    var debugFrontAuthor: String? { front.face.debugAuthor }
    var debugShowsBones: Bool { front.face.debugShowsBones }
    var debugBehindCaption: String? { back.alpha > 0 ? back.face.debugCaption : nil }
    /// Whether the card behind shows its words (it never should).
    var debugBehindShowsWords: Bool { back.face.alpha > 0 }
    var debugFrontShowsWords: Bool { front.face.alpha > 0 }
    /// Whether the card behind shows above the front one.
    var debugBehindPeeks: Bool { back.alpha > 0 && back.frame.minY < front.frame.minY - 1 }
}

extension MapTextPostCardView: UIGestureRecognizerDelegate {
    /// Only a vertical drag is the stack's.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
        let velocity = pan.velocity(in: self)
        return abs(velocity.y) > abs(velocity.x)
    }
}

// MARK: - A card

/// One card: its glass and its words.
private final class Shell: UIView {
    let glass = UIVisualEffectView(effect: UIGlassEffect())
    let face: Face
    private(set) var shown: MapTextPostCardView.Shown = .hidden

    /// Whether the words show: the front card's do; the card behind is its
    /// glass alone, so a front card slid up never shows another post's
    /// words through it (the owner, 2026-11-08).
    func setShowsWords(_ shows: Bool, animated: Bool) {
        let alpha: CGFloat = shows ? 1 : 0
        guard face.alpha != alpha else { return }
        guard animated else { face.alpha = alpha; return }
        UIView.animate(withDuration: shows ? 0.3 : 0.18, delay: shows ? 0.08 : 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.face.alpha = alpha
        }
    }

    init(imagePipeline: ImagePipeline?) {
        face = Face(imagePipeline: imagePipeline)
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        glass.cornerConfiguration = .corners(radius: .fixed(Surface.cardCornerRadius))
        glass.clipsToBounds = true
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        glass.pin(to: self)
        face.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(face)
        face.pin(to: glass.contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(_ shown: MapTextPostCardView.Shown, fading: Bool = false) {
        guard shown != self.shown else { return }
        self.shown = shown
        guard fading else { return face.apply(shown) }
        UIView.transition(with: face, duration: 0.25, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.face.apply(shown)
        }
    }
}

// MARK: - A card's words

private final class Face: UIView {
    private let avatar: AvatarView
    private let nameLabel = UILabel()
    private let ageLabel = UILabel()
    private let likes = PostMetricLabel(
        symbol: LikesSymbol.glyph, font: .appFont(forTextStyle: .footnote), color: .secondaryLabel, glyphTrailing: true
    )
    private let captionLabel = EmoteLabel()
    /// Two lines' room for the words, however many they take — the card
    /// keeps one height as they change; the words sit at its top.
    private let captionBox = UIView()
    private var captionBoxHeight: NSLayoutConstraint?
    private let placeRow = UIStackView()
    private let placeLabel = UILabel()
    private let content = UIStackView()
    private let bones = UIStackView()
    private let imagePipeline: ImagePipeline?

    init(imagePipeline: ImagePipeline?) {
        self.imagePipeline = imagePipeline
        avatar = AvatarView(diameter: MapTextPostCardView.avatarSide, size: .avatar)
        super.init(frame: .zero)
        isUserInteractionEnabled = false

        nameLabel.font = UIFont.scaledFont(forTextStyle: .subheadline, weight: .semibold)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = .label
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        ageLabel.font = .appFont(forTextStyle: .subheadline)
        ageLabel.adjustsFontForContentSizeCategory = true
        ageLabel.textColor = .secondaryLabel
        ageLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        ageLabel.setContentHuggingPriority(.required, for: .horizontal)
        likes.setContentHuggingPriority(.required, for: .horizontal)
        likes.setContentCompressionResistancePriority(.required, for: .horizontal)

        captionLabel.font = .appFont(forTextStyle: .body)
        captionLabel.adjustsFontForContentSizeCategory = true
        captionLabel.textColor = .label
        captionLabel.numberOfLines = 2
        captionLabel.lineBreakMode = .byTruncatingTail
        captionLabel.textEntityStyle = .link
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        captionBox.addSubview(captionLabel)
        let boxHeight = captionBox.heightAnchor.constraint(equalToConstant: 44)
        captionBoxHeight = boxHeight
        NSLayoutConstraint.activate([
            captionLabel.leadingAnchor.constraint(equalTo: captionBox.leadingAnchor),
            captionLabel.trailingAnchor.constraint(equalTo: captionBox.trailingAnchor),
            captionLabel.topAnchor.constraint(equalTo: captionBox.topAnchor),
            captionLabel.bottomAnchor.constraint(lessThanOrEqualTo: captionBox.bottomAnchor),
            boxHeight,
        ])

        let pinGlyph = UIImageView(image: UIImage(systemName: "mappin.and.ellipse"))
        pinGlyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote, scale: .small)
        pinGlyph.tintColor = .secondaryLabel
        pinGlyph.setContentHuggingPriority(.required, for: .horizontal)
        placeLabel.font = .appFont(forTextStyle: .footnote)
        placeLabel.adjustsFontForContentSizeCategory = true
        placeLabel.textColor = .secondaryLabel
        placeLabel.lineBreakMode = .byTruncatingTail
        placeRow.axis = .horizontal
        placeRow.spacing = 4
        placeRow.alignment = .center
        placeRow.addArrangedSubview(pinGlyph)
        placeRow.addArrangedSubview(placeLabel)

        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.widthAnchor.constraint(equalToConstant: MapTextPostCardView.avatarSide).isActive = true
        avatar.heightAnchor.constraint(equalToConstant: MapTextPostCardView.avatarSide).isActive = true
        let spacer = UIView()
        spacer.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        let header = UIStackView(arrangedSubviews: [avatar, nameLabel, ageLabel, spacer, likes])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = Spacing.sm
        header.setCustomSpacing(4, after: nameLabel)

        content.axis = .vertical
        content.spacing = MapTextPostCardView.rowGap
        content.alignment = .fill
        for row in [header, captionBox, placeRow] { content.addArrangedSubview(row) }
        addPadded(content)
        applyCaptionRoom()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (face: Face, _) in
            face.applyCaptionRoom()
        }

        // The bones: the header's disc and name, two lines of words.
        let disc = SkeletonBoneView(rounding: .capsule)
        let name = SkeletonBoneView(rounding: .capsule)
        let lineA = SkeletonBoneView(rounding: .capsule)
        let lineB = SkeletonBoneView(rounding: .capsule)
        let boneHeader = UIStackView(arrangedSubviews: [disc, name, UIView()])
        boneHeader.axis = .horizontal
        boneHeader.alignment = .center
        boneHeader.spacing = Spacing.sm
        bones.axis = .vertical
        bones.spacing = 10
        bones.alignment = .leading
        for row in [boneHeader, lineA, lineB] { bones.addArrangedSubview(row) }
        NSLayoutConstraint.activate([
            disc.widthAnchor.constraint(equalToConstant: MapTextPostCardView.avatarSide),
            disc.heightAnchor.constraint(equalToConstant: MapTextPostCardView.avatarSide),
            name.widthAnchor.constraint(equalToConstant: 120),
            name.heightAnchor.constraint(equalToConstant: 12),
            boneHeader.widthAnchor.constraint(equalTo: bones.widthAnchor),
            lineA.widthAnchor.constraint(equalTo: bones.widthAnchor),
            lineA.heightAnchor.constraint(equalToConstant: 12),
            lineB.widthAnchor.constraint(equalTo: bones.widthAnchor, multiplier: 0.62),
            lineB.heightAnchor.constraint(equalToConstant: 12),
        ])
        addPadded(bones, centredVertically: true)
        bones.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Two of the words' lines, at the size they are drawn now.
    private func applyCaptionRoom() {
        let font = UIFont.appFont(forTextStyle: .body, compatibleWith: traitCollection)
        captionBoxHeight?.constant = ceil(font.lineHeight * 2)
    }

    private func addPadded(_ view: UIView, centredVertically: Bool = false) {
        let padding = MapTextPostCardView.padding
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
        ])
        if centredVertically {
            view.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        } else {
            view.topAnchor.constraint(equalTo: topAnchor, constant: padding).isActive = true
            view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding).isActive = true
        }
    }

    func apply(_ shown: MapTextPostCardView.Shown) {
        switch shown {
        case .hidden:
            break
        case .loading:
            // The words' room is kept (laid out, unseen): one height.
            content.alpha = 0
            bones.isHidden = false
        case .content(let words):
            content.alpha = 1
            bones.isHidden = true
            nameLabel.text = words.authorName
            ageLabel.text = words.age.isEmpty ? nil : "· \(words.age)"
            ageLabel.isHidden = words.age.isEmpty
            likes.set(words.likes)
            likes.isHidden = words.likes == nil
            captionLabel.text = words.caption
            // The place's row keeps its room without a place: one height.
            placeLabel.text = words.place ?? " "
            placeRow.alpha = words.place == nil ? 0 : 1
            avatar.setMonogram(words.monogram)
            avatar.setPicture(words.avatarURL, pipeline: imagePipeline)
        }
    }

    var debugCaption: String? { content.alpha > 0 ? captionLabel.text : nil }
    var debugAuthor: String? { content.alpha > 0 ? nameLabel.text : nil }
    var debugShowsBones: Bool { !bones.isHidden }
}
