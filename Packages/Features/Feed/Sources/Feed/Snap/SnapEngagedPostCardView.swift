import CoreModels
import DesignSystem
import UIKit

/// The engaged card's content: the post itself, reformatted to fit the top
/// floating glass container as ONE horizontal split (`SnapCommentsLayout`'s
/// card constants are the shared geometry contract):
///
///   [ media hole │ caption column      ]
///   [            │ ♫ music line        ]
///   [            │ ♥ 1.2k 💬 56 ⇄ 🔖   ]
///
/// The right side is a single vertical column, bottom-anchored: actions row
/// at the column's floor, music line directly above it (video posts only),
/// caption filling the space that remains. Author identity deliberately
/// does NOT render here — the nav pill (screen chrome) already carries it,
/// and one identity on screen beats a duplicated header band.
///
/// This view owns NEITHER the media nor the caption: the media is the
/// full-bleed render surface docking via transform (playback untouchable
/// by construction), and the caption is the cell's flight label (it
/// travels from the chrome's full-width home, stopping above the column's
/// reserved rows via `captionColumnMaxY`). The card renders the pieces
/// that have no feed-default counterpart in the cell (music attribution
/// lives in the native toolbar, metrics nowhere) and therefore ENTER with
/// the card rather than fly.
///
/// Lives inside the strip backdrop's `contentView`, pinned edge-to-edge, so
/// the glass card's frame authority (`stripCardFrame`) is the only geometry
/// it needs — every interior offset is card-local.
final class SnapEngagedPostCardView: UIView {
    private let musicRow = UIStackView()
    private let musicLabel = UILabel()

    /// Metrics with data render counts (likes from the hydration snapshot,
    /// comments from the loaded streams); repost/save are affordance-only
    /// seams — the BFF carries no counts for them yet, mirroring the
    /// composer's unwired `onAttachMedia`.
    private let likeButton = SnapEngagedPostCardView.makeMetricButton(
        symbol: "heart", accessibilityLabel: "Like"
    )
    private let commentButton = SnapEngagedPostCardView.makeMetricButton(
        symbol: "bubble.right", accessibilityLabel: "Comments"
    )
    private let repostButton = SnapEngagedPostCardView.makeMetricButton(
        symbol: "arrow.2.squarepath", accessibilityLabel: "Repost"
    )
    private let saveButton = SnapEngagedPostCardView.makeMetricButton(
        symbol: "bookmark", accessibilityLabel: "Save"
    )

    override init(frame: CGRect) {
        super.init(frame: frame)
        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildLayout() {
        let pad = SnapCommentsLayout.stripCardPadding
        // The column's leading edge, card-local: past the media hole, with
        // the same breathing the caption flight uses (`slot.maxX + md`).
        let columnLeading = pad + SnapCommentsLayout.mediaSlotHeight + Spacing.md

        // Actions row: the column's floor.
        let actions = UIStackView(arrangedSubviews: [likeButton, commentButton, repostButton, saveButton])
        actions.axis = .horizontal
        actions.spacing = Spacing.lg
        actions.alignment = .center
        actions.constrain(in: self) { parent in
            actions.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: columnLeading)
            actions.trailingAnchor.constraint(lessThanOrEqualTo: parent.trailingAnchor, constant: -pad)
            actions.heightAnchor.constraint(equalToConstant: SnapCommentsLayout.cardActionsHeight)
            actions.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -pad)
        }

        // Music line: directly above the actions row. The caption (the
        // cell's flight label, above this view) stops above both via
        // `captionColumnMaxY`.
        let musicIcon = UIImageView(image: UIImage(systemName: "music.note")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)))
        musicIcon.tintColor = UIColor.white.withAlphaComponent(0.75)
        musicIcon.contentMode = .center
        musicLabel.font = .preferredFont(forTextStyle: .caption2)
        musicLabel.textColor = UIColor.white.withAlphaComponent(0.75)
        musicLabel.lineBreakMode = .byTruncatingTail

        musicRow.addArrangedSubview(musicIcon)
        musicRow.addArrangedSubview(musicLabel)
        musicRow.axis = .horizontal
        musicRow.spacing = Spacing.xs
        musicRow.alignment = .center
        musicRow.isHidden = true
        musicRow.constrain(in: self) { parent in
            musicRow.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: columnLeading)
            musicRow.trailingAnchor.constraint(lessThanOrEqualTo: parent.trailingAnchor, constant: -pad)
            musicRow.heightAnchor.constraint(equalToConstant: SnapCommentsLayout.cardMusicLineHeight)
            musicRow.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -Spacing.xs)
        }
    }

    // MARK: - Content

    /// Fills the column from the post's display model. Called at cell
    /// configure — the card is populated long before an engagement, so
    /// engaging is pure choreography, never a data fetch.
    func configure(with model: FeedItemDisplayModel) {
        // KEEP-AND-STACK: the native toolbar stays onstage through the
        // engagement and its attribution item ALREADY carries the audio
        // line — the card renders no music row (the no-duplication rule,
        // same as the author header's removal). The row's scaffolding is
        // parked hidden pending the cleanup commit.
        musicRow.isHidden = true
        musicLabel.text = nil
        Self.setCount(model.likeCount > 0 ? Int(clamping: model.likeCount) : nil, on: likeButton)
        Self.setCount(nil, on: commentButton)
    }

    /// The comment metric follows the streams (the count the ticker/subtitle
    /// surfaces already receive): shown once loaded, blank while unknown —
    /// the `isLoaded` seam, so a fetch in flight never renders a lying "0".
    func setCommentCount(_ count: Int, isLoaded: Bool) {
        Self.setCount(isLoaded ? count : nil, on: commentButton)
    }

    /// Cell reuse: drop content.
    func reset() {
        musicLabel.text = nil
        musicRow.isHidden = true
        Self.setCount(nil, on: likeButton)
        Self.setCount(nil, on: commentButton)
    }

    // MARK: - Metric buttons

    /// One metric/action: a glyph with an optional count beside it. Buttons
    /// (not labels) so each is a `UIControl` — the cell's tap arbitration
    /// automatically exempts them from the strip's tap-to-close, and the
    /// action seams can wire straight in when the mutation paths exist.
    private static func makeMetricButton(symbol: String, accessibilityLabel: String) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        config.baseForegroundColor = UIColor.white.withAlphaComponent(0.9)
        config.imagePadding = Spacing.xs
        config.contentInsets = .zero
        let button = UIButton(configuration: config)
        button.accessibilityLabel = accessibilityLabel
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    private static func setCount(_ count: Int?, on button: UIButton) {
        var config = button.configuration
        config?.attributedTitle = count.map {
            var title = AttributedString(SnapSubtitleView.countText($0))
            title.font = UIFont.preferredFont(forTextStyle: .footnote).withWeight(.semibold)
            return title
        }
        button.configuration = config
    }
}
