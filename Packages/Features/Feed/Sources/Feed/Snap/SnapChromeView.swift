import CoreModels
import DesignSystem
import UIKit

/// The snap *page's* UI chrome — the caption over the bottom scrim.
/// Screen-scoped chrome (back item, author identity) lives in the navigation
/// bar instead (`SnapAuthorIdentityView` / `SnapNavControls`), so it stays
/// fixed while pages scroll. (Like/comment affordances were removed with the
/// engagement rail; they will return on a different surface.)
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
    /// Content reaches it only through `updateCommentStreams` — never through
    /// `configure` — so the flight replica renders an empty, invisible band
    /// by construction and the card stays pixel-identical to the landed page.
    private let commentTicker = SnapCommentTickerView()

    /// The subtitle zone, directly above the band: semantic comments fading
    /// in and out one at a time. Same content contract as the band (arrives
    /// only via `updateCommentStreams`, so the flight replica's zone is
    /// empty by construction), but activation is settle-scoped like video,
    /// not visibility-scoped like the conveyor.
    private let subtitleView = SnapSubtitleView()

    /// Subtrees where a touch means "use the control", not "toggle playback" —
    /// consumed by the cell's tap arbitration. Empty since the engagement rail
    /// was removed; the seam stays for future interactive chrome.
    var interactionRoots: [UIView] { [] }

    private var representedID: PostID?

    override init(frame: CGRect) {
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

        captionLabel.numberOfLines = 2
        captionLabel.lineBreakMode = .byTruncatingTail

        // The caption's font lives in its attributed string (see
        // `renderedCaption`), which `adjustsFontForContentSizeCategory`
        // cannot track — re-resolve on Dynamic Type changes so live and
        // reused cells can never show two different caption sizes.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: SnapChromeView, _) in
            self.renderCaption()
        }

        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildLayout() {
        scrimView.isUserInteractionEnabled = false
        scrimView.constrain(in: self) { parent in
            scrimView.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            scrimView.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            scrimView.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
            // 0.68 (was 0.62 pre-subtitles): tall enough that the gradient's
            // mid-stop sits behind the subtitle zone AND the ticker band
            // stacked above the caption block.
            scrimView.heightAnchor.constraint(equalTo: parent.heightAnchor, multiplier: 0.68)
        }

        // Caption, full-width over the scrim (the engagement rail that once
        // reserved the trailing edge is gone). The margins guide tracks the
        // safe area, so when the navigation controller's toolbar is visible
        // the caption sits above it automatically — live cell and flight
        // replica alike (`setFixedInsets` captures the toolbar-inflated
        // insets).
        captionLabel.constrain(in: self) { parent in
            captionLabel.leadingAnchor.constraint(equalTo: parent.layoutMarginsGuide.leadingAnchor, constant: Spacing.lg)
            captionLabel.bottomAnchor.constraint(equalTo: parent.layoutMarginsGuide.bottomAnchor, constant: -Spacing.lg)
            captionLabel.trailingAnchor.constraint(equalTo: parent.layoutMarginsGuide.trailingAnchor, constant: -Spacing.lg)
        }

        // The comment ticker rides directly above the caption, full-width so
        // bubbles traverse the whole page. It is an overlay over the media:
        // its presence or absence never moves the caption, which keeps the
        // flight replica's geometry identical whether or not comments exist.
        // (Constrained after the caption — its bottom hangs off the caption's
        // top.)
        commentTicker.constrain(in: self) { _ in
            commentTicker.leadingAnchor.constraint(equalTo: leadingAnchor)
            commentTicker.trailingAnchor.constraint(equalTo: trailingAnchor)
            commentTicker.bottomAnchor.constraint(equalTo: captionLabel.topAnchor, constant: -Spacing.sm)
        }

        // The subtitle zone extends the same one-directional chain one link
        // up (caption ← band ← subtitles): nothing constrains back onto it,
        // so cue presence/absence can never move the stack below. Inset to
        // the caption's edges — subtitles are read, not skimmed.
        subtitleView.constrain(in: self) { parent in
            subtitleView.leadingAnchor.constraint(equalTo: parent.layoutMarginsGuide.leadingAnchor, constant: Spacing.lg)
            subtitleView.trailingAnchor.constraint(equalTo: parent.layoutMarginsGuide.trailingAnchor, constant: -Spacing.lg)
            subtitleView.bottomAnchor.constraint(equalTo: commentTicker.topAnchor, constant: -Spacing.sm)
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

    func configure(with model: FeedItemDisplayModel) {
        representedID = model.id

        // Text-only posts render an EMPTY shell (product call, 2026-07-14):
        // no caption, no scrim, no ticker — just the black page under the
        // screen chrome (identity pill, toolbar attribution), until their
        // dedicated layout arrives with the Phase 2/3 cell split. `hasMedia`
        // therefore gates every piece of page content at once.
        hasMedia = model.mediaURL != nil
        scrimView.isHidden = !hasMedia
        caption = hasMedia ? model.caption : nil
        captionLabel.isHidden = (caption?.isEmpty ?? true)
        if !hasMedia {
            commentTicker.setComments([])
            subtitleView.setCues([])
        }
    }

    /// The raw caption, kept so Dynamic Type changes can re-resolve the
    /// attributed rendering (the font is baked into the string).
    private var caption: String? {
        didSet { renderCaption() }
    }

    /// Whether the represented post carries media. Text-only posts show an
    /// empty shell, so this gates page content — including ticker queues
    /// arriving *after* configure (`updateTickerComments`).
    private var hasMedia = true

    private func renderCaption() {
        captionLabel.attributedText = caption.map(Self.renderedCaption)
    }

    /// The caption's attributed rendering — the single source of caption
    /// typography for every post kind and both chrome instances (live cell
    /// and flight replica); no caller may size it conditionally. The text
    /// shadow lives here (an `NSShadow` drawn with the glyphs) rather than
    /// as a `CALayer` shadow: a layer shadow on a full-width label has no
    /// `shadowPath` and costs an offscreen pass every scrolled frame.
    private static func renderedCaption(_ text: String) -> NSAttributedString {
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = .zero
        return NSAttributedString(string: text, attributes: [
            .font: UIFont.preferredFont(forTextStyle: .body),
            .foregroundColor: UIColor.white,
            .shadow: shadow,
        ])
    }

    /// Replaces both comment surfaces' content (the ticker's wrap-around
    /// queue and the subtitle zone's cue list). Live cells only — the flight
    /// replica must never receive this (moving/timed content cannot be
    /// pixel-identical across two instances), which is why it is not part of
    /// `configure`. Empty streams hide their surface. Text-only posts refuse
    /// content entirely (empty shell) — gated here, not at the callers, so
    /// every arrival path (dequeue pull, async push) hits the same wall.
    func updateCommentStreams(_ streams: FeedViewModel.CommentStreams) {
        guard hasMedia else { return }
        commentTicker.setComments(streams.reactions)
        subtitleView.setCues(streams.subtitles)
    }

    /// Streams while the owning cell is on screen (visibility-scoped — a
    /// page dragged partway in already flows; see the cell's
    /// `setTickerStreaming`).
    func setTickerActive(_ active: Bool) {
        commentTicker.setActive(active)
    }

    /// Cycles while the owning cell is the settled ACTIVE page — the same
    /// seam as playback, deliberately narrower than the band's visibility
    /// scope: subtitles belong to the playback timeline, and a half-dragged
    /// page has no playing media to subtitle.
    func setSubtitlesActive(_ active: Bool) {
        subtitleView.setActive(active)
    }

    /// Clears post-specific content (cell reuse).
    func reset() {
        representedID = nil
        caption = nil
        hasMedia = true
        commentTicker.reset()
        subtitleView.reset()
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
