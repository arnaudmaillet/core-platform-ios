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
/// - Screen-scoped, page-fed: content follows the active page through the
///   same settle-quantized lifecycle seam that drives the identity pill,
///   cross-fading on page changes — never re-negotiating mid-scroll.
final class SnapMediaAttributionView: UIView {
    /// The bar-bubble invariant: every bubble on the feed's bars — back
    /// button, identity pill wrapper, and all three toolbar bubbles — renders
    /// 36pt tall (the bar item wrapper's own height on iOS 26), so the system
    /// glass capsules read as one family top and bottom.
    private static let height: CGFloat = 36
    /// Long author names truncate here rather than crowding the share/more
    /// bubbles across the flexible space.
    ///
    /// ⚠️ 180, down from 240, since the mute button shares its capsule: sized
    /// for the narrowest phone, 375 − 2×16 margins − 36 (mute) − 72 (🔖 ⇄)
    /// − 8 − 36 (⋯) leaves ~191, and a bar short of room drops whole items
    /// rather than truncating anything.
    private static let maxWidth: CGFloat = 180

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
    private var renderedSoundLine: String?
    private var coverTask: Task<Void, Never>?

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
        row.constrain(in: self) { parent in
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
        widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxWidth).isActive = true

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

    /// The SHADOW only — the identity pill's rule, for the same reason: the
    /// colours are semantic and come from the toolbar's theme.
    func setOverMedia(_ overMedia: Bool) {
        for label in [titleLabel, trackLabel] {
            label.layer.shadowOpacity = overMedia ? 0.5 : 0
        }
    }

    /// Shows `model`'s attribution. A page change cross-fades the labels and
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
    /// skips the cross-dissolve and the cover refetch, because an unchanged page
    /// has an unchanged model.
    func setPost(_ model: FeedItemDisplayModel, soundLine: String? = nil, pipeline: ImagePipeline) {
        guard model != renderedModel || soundLine != renderedSoundLine else { return }
        renderedModel = model
        renderedSoundLine = soundLine
        postID = model.id
        defer { animateBarRemeasure() }

        UIView.transition(with: self, duration: 0.18,
                          options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.titleLabel.text = model.authorName
            // Derived attribution until the BFF carries track metadata;
            // non-audio posts fall back to the handle/time meta line.
            self.trackLabel.text = soundLine ?? model.audioText ?? model.metaText
            self.accessibilityLabel = "\(model.authorName), \(soundLine ?? model.audioText ?? model.metaText)"
            self.accessibilityHint = soundLine == nil ? nil : "Opens the sound"

            self.coverView.image = nil
        }

        coverTask?.cancel()
        // The media's thumbnail is the closest thing to cover art the model
        // carries; text posts fall back to the author's avatar.
        guard let url = model.thumbnailURL ?? model.avatarURL else { return }
        let id = model.id
        coverTask = Task { [weak self] in
            guard let image = try? await pipeline.image(for: url) else { return }
            guard let self, self.postID == id else { return }
            UIView.transition(with: self.coverView, duration: 0.15, options: [.transitionCrossDissolve]) {
                self.coverView.image = image
            }
        }
    }

    /// Content changes resize the item (content-sized by design); glide the
    /// bar's re-measure instead of letting it snap — the toolbar counterpart
    /// of the identity pill's remeasure.
    private func animateBarRemeasure() {
        setNeedsLayout()
        var bar: UIView? = superview
        while let view = bar, !(view is UIToolbar) { bar = view.superview }
        let host = bar ?? superview
        host?.setNeedsLayout()
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
            host?.layoutIfNeeded()
        }
    }
}
