import CoreModels
import DesignSystem
import UIKit

/// The snap *page's* UI chrome — caption over the bottom scrim and the
/// engagement rail. Screen-scoped chrome (back item, author identity) lives in
/// the navigation bar instead (`SnapAuthorIdentityView` / `SnapNavControls`), so
/// it stays fixed while pages scroll.
///
/// It exists twice per hero flight: embedded in every `SnapFeedCell` (the
/// live, interactive instance) and inside the transition's flying card (an
/// inert replica configured from the same display model). One scaffold, two
/// instances — the flight is pixel-identical to the landed page and the two
/// layouts can never fork, because there is only one layout.
///
/// Geometry is data-independent: labels fill in whenever `configure` runs
/// (possibly mid-flight, on a cold tap) without moving the scaffold.
final class SnapChromeView: UIView {
    /// The text-only post's page background, defined once here for both the
    /// live cell and the flight replica. Living *inside* the chrome means the
    /// hero flight's existing chrome fade doubles as the thumbnail↔gradient
    /// crossfade: a text post's card lifts off showing the pin's cover and
    /// lands showing exactly the page the cell renders — no pop at the swap.
    static let textPostGradientColors: [UIColor] = [
        UIColor(red: 0.15, green: 0.16, blue: 0.24, alpha: 1),
        UIColor(red: 0.05, green: 0.05, blue: 0.09, alpha: 1),
    ]

    private let textBackdrop = GradientView(colors: SnapChromeView.textPostGradientColors)
    /// The bottom legibility scrim. The mid-stop pulls meaningful darkness up
    /// behind the comment ticker's lanes — the band's naked text has no
    /// capsules, so the scrim is its only contrast — while the bottom stays
    /// as dark as before under the caption and toolbar.
    private let scrimView = GradientView(
        colors: [.clear, UIColor.black.withAlphaComponent(0.45), UIColor.black.withAlphaComponent(0.75)],
        locations: [0, 0.55, 1]
    )

    private let captionLabel = UILabel()

    /// The danmaku band, floating over the media directly above the caption.
    /// Content reaches it only through `updateTickerComments` — never through
    /// `configure` — so the flight replica renders an empty, invisible band
    /// by construction and the card stays pixel-identical to the landed page.
    private let commentTicker = SnapCommentTickerView()

    private let likeButton = UIButton(configuration: .plain())
    private let likeCountLabel = UILabel()
    private let commentButton = UIButton(configuration: .plain())

    private let railStack: UIStackView

    /// Set by the owning cell; called on tap with the represented post.
    /// The flight replica leaves these nil and disables interaction entirely.
    var onLikeTapped: ((PostID) -> Void)?
    var onCommentTapped: ((PostID) -> Void)?

    /// Subtrees where a touch means "use the control", not "toggle playback" —
    /// consumed by the cell's tap arbitration.
    var interactionRoots: [UIView] { [railStack] }

    private var representedID: PostID?

    override init(frame: CGRect) {
        railStack = UIStackView(arrangedSubviews: [likeButton, likeCountLabel, commentButton])
        railStack.axis = .vertical
        railStack.spacing = Spacing.xs
        railStack.alignment = .center
        super.init(frame: frame)

        // The chrome pins to its margins guide, NOT the safe-area guide
        // directly: with zero margins the guide tracks the safe area exactly
        // in the live cell, and `setFixedInsets` swaps in *captured* insets
        // for the flight replica — ambient safe-area propagation into a
        // transition container is unreliable (it resolved with a zero bottom
        // inset on the dismiss leg, dropping the caption/rail ~34pt at the
        // live→card swap).
        layoutMargins = .zero
        insetsLayoutMarginsFromSafeArea = true
        preservesSuperviewLayoutMargins = false

        captionLabel.numberOfLines = 4
        captionLabel.textColor = .white
        // Legibility over arbitrary media, independent of the scrim.
        captionLabel.layer.shadowColor = UIColor.black.cgColor
        captionLabel.layer.shadowOpacity = 0.5
        captionLabel.layer.shadowRadius = 3
        captionLabel.layer.shadowOffset = .zero

        var likeConfig = UIButton.Configuration.plain()
        likeConfig.image = UIImage(systemName: "heart")
        likeConfig.baseForegroundColor = .white
        likeButton.configuration = likeConfig
        likeButton.addAction(UIAction { [weak self] _ in
            guard let id = self?.representedID else { return }
            self?.onLikeTapped?(id)
        }, for: .primaryActionTriggered)

        likeCountLabel.font = UIFont.preferredFont(forTextStyle: .footnote).withWeight(.semibold)
        likeCountLabel.textColor = .white
        likeCountLabel.textAlignment = .center

        var commentConfig = UIButton.Configuration.plain()
        commentConfig.image = UIImage(systemName: "bubble.right")
        commentConfig.baseForegroundColor = .white
        commentButton.configuration = commentConfig
        commentButton.addAction(UIAction { [weak self] _ in
            guard let id = self?.representedID else { return }
            self?.onCommentTapped?(id)
        }, for: .primaryActionTriggered)

        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildLayout() {
        // At the very back, under the scrim: for text posts it IS the page.
        textBackdrop.isUserInteractionEnabled = false
        textBackdrop.isHidden = true
        textBackdrop.pin(to: self)
        sendSubviewToBack(textBackdrop)

        scrimView.isUserInteractionEnabled = false
        scrimView.constrain(in: self) { parent in
            scrimView.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            scrimView.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            scrimView.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
            // 0.62, not 0.5: tall enough that the gradient's mid-stop sits
            // behind the ticker band even over a 4-line caption.
            scrimView.heightAnchor.constraint(equalTo: parent.heightAnchor, multiplier: 0.62)
        }

        // Caption, bottom-left over the scrim; the trailing gap keeps it clear
        // of the engagement rail. The margins guide tracks the safe area, so
        // when the navigation controller's toolbar is visible the caption and
        // rail sit above it automatically — live cell and flight replica
        // alike (`setFixedInsets` captures the toolbar-inflated insets).
        captionLabel.constrain(in: self) { parent in
            captionLabel.leadingAnchor.constraint(equalTo: parent.layoutMarginsGuide.leadingAnchor, constant: Spacing.lg)
            captionLabel.bottomAnchor.constraint(equalTo: parent.layoutMarginsGuide.bottomAnchor, constant: -Spacing.lg)
            captionLabel.trailingAnchor.constraint(lessThanOrEqualTo: parent.trailingAnchor, constant: -72)
        }

        // The comment ticker rides directly above the caption, full-width so
        // bubbles traverse the whole page. It is an overlay over the media:
        // its presence or absence never moves the caption, which keeps the
        // flight replica's geometry identical whether or not comments exist.
        // (Constrained after the caption — its bottom hangs off the caption's
        // top — and before the rail, so bubbles pass under the rail's top.)
        commentTicker.constrain(in: self) { _ in
            commentTicker.leadingAnchor.constraint(equalTo: leadingAnchor)
            commentTicker.trailingAnchor.constraint(equalTo: trailingAnchor)
            commentTicker.bottomAnchor.constraint(equalTo: captionLabel.topAnchor, constant: -Spacing.sm)
        }

        // Engagement rail, bottom-right (TikTok-style vertical stack): like +
        // count, then comment.
        railStack.setCustomSpacing(Spacing.md, after: likeCountLabel)
        railStack.constrain(in: self) { parent in
            railStack.trailingAnchor.constraint(equalTo: parent.layoutMarginsGuide.trailingAnchor, constant: -Spacing.md)
            railStack.bottomAnchor.constraint(equalTo: parent.layoutMarginsGuide.bottomAnchor, constant: -Spacing.lg)
        }
    }

    /// Flight replica: freeze the guide to *captured* insets (the live feed's
    /// real safe area) instead of ambient propagation, so the replica's
    /// geometry equals the live cell's regardless of what the transition
    /// container resolves.
    func setFixedInsets(_ insets: UIEdgeInsets) {
        insetsLayoutMarginsFromSafeArea = false
        layoutMargins = insets
    }

    // MARK: - Configuration

    func configure(with model: FeedItemDisplayModel, engagement: FeedViewModel.EngagementState) {
        representedID = model.id
        updateEngagement(engagement)

        let captionText = model.caption
        captionLabel.text = captionText
        captionLabel.isHidden = (captionText?.isEmpty ?? true)

        let hasMedia = model.mediaURL != nil
        scrimView.isHidden = !hasMedia
        textBackdrop.isHidden = hasMedia
        // Text-only posts lean on the caption, so give it more room and weight.
        captionLabel.numberOfLines = hasMedia ? 4 : 8
        captionLabel.font = hasMedia
            ? .preferredFont(forTextStyle: .body)
            : UIFont.preferredFont(forTextStyle: .title2).withWeight(.semibold)
    }

    /// Updates only the engagement rail — live counter ticks and optimistic
    /// like toggles. Never relayouts.
    func updateEngagement(_ state: FeedViewModel.EngagementState) {
        likeCountLabel.text = Self.countText(state.likeCount)
        var config = likeButton.configuration
        config?.image = UIImage(systemName: state.isLiked ? "heart.fill" : "heart")
        config?.baseForegroundColor = state.isLiked ? .systemRed : .white
        likeButton.configuration = config
    }

    /// Replaces the comment ticker's wrap-around queue. Live cells only —
    /// the flight replica must never receive this (a moving band cannot be
    /// pixel-identical across two instances), which is why it is not part of
    /// `configure`. An empty queue hides the band.
    func updateTickerComments(_ comments: [TickerCommentModel]) {
        commentTicker.setComments(comments)
    }

    /// Streams while the owning cell is on screen (visibility-scoped — a
    /// page dragged partway in already flows; see the cell's
    /// `setTickerStreaming`).
    func setTickerActive(_ active: Bool) {
        commentTicker.setActive(active)
    }

    /// Clears post-specific content (cell reuse).
    func reset() {
        representedID = nil
        commentTicker.reset()
    }

    private static func countText(_ count: Int64) -> String {
        count >= 1000 ? String(format: "%.1fk", Double(count) / 1000) : String(count)
    }
}

/// A view backed by a `CAGradientLayer`, sized automatically with its bounds.
final class GradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    private var gradientLayer: CAGradientLayer { layer as! CAGradientLayer }

    init(colors: [UIColor],
         locations: [NSNumber]? = nil,
         startPoint: CGPoint = CGPoint(x: 0.5, y: 0),
         endPoint: CGPoint = CGPoint(x: 0.5, y: 1)) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        gradientLayer.colors = colors.map(\.cgColor)
        gradientLayer.locations = locations
        gradientLayer.startPoint = startPoint
        gradientLayer.endPoint = endPoint
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
