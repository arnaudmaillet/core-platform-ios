import PostGrid
import UIKit

/// The card's metric line, as the grid spells it: absent counts are `nil`, not
/// zero.
///
/// `PostMetricLabel` hides itself for a `nil` and renders a `0` — "absence,
/// not an asserted zero" — so carrying optionals all the way through is what
/// keeps a seeded page from claiming a post has no views when nobody has said
/// how many it has.
struct PostCardMetrics: Equatable, Sendable {
    let views: Int64?
    let reactions: Int64?
    let comments: Int64?

    var isEmpty: Bool { views == nil && reactions == nil && comments == nil }
}

/// The caption of a TEXT post, wearing the gallery card's own face: the
/// caption at the card's body size and inset, and the card's closing metric
/// line beneath it — views, reactions, comments leading, the post's age
/// trailing.
///
/// # Why this exists rather than the glass bubble
///
/// The bubble (`SnapPostInfoCardView`) is a treatment FOR MEDIA: it buys text
/// contrast against an arbitrary photo, which is why it is real
/// `UIGlassEffect` and why it sits beside an avatar like a message in a
/// thread. A text page has no photo to fight, and — more to the point — a text
/// page is arrived at by a reveal that opens the gallery row into the page. So
/// what the row was showing and what the page shows first must be the same
/// thing, or the transition carries the eye from one object to a different
/// one. Measured before this existed: the row's caption starts 32pt from the
/// screen edge and the bubble's started at 71pt, wrapped in a material the row
/// does not have, with an avatar the row does not have either.
///
/// # How it stays a twin
///
/// It borrows `PostGridListRowCell`'s constants rather than restating them —
/// the same discipline `PostGridFlightCard` follows for the media hero, and
/// the reason those constants were made public in the first place. The card's
/// FILL and ROUNDING are deliberately not reproduced: the page's ground is its
/// own (`.systemBackground`), and a card floating at the head of a comment
/// stream would be a second container inside a screen that has none.
///
/// ```
///  ┌────────────────────────────────┐
///  │  Shipping the new build        │  ← .body, captionInset from the edge
///  │  tonight.                      │
///  │  👁 12   ♥ 40   💬 3      now  │  ← the card's own closing line
///  └────────────────────────────────┘
/// ```
final class PostCaptionRowView: UIView {
    private let captionLabel = UILabel()
    private let ageLabel = UILabel()
    private static let metaFont = UIFont.preferredFont(forTextStyle: .footnote)
    private let views = PostMetricLabel(symbol: "eye", font: metaFont, color: .secondaryLabel)
    private let reactions = PostMetricLabel(symbol: "heart", font: metaFont, color: .secondaryLabel)
    private let comments = PostMetricLabel(
        symbol: "bubble.right", font: metaFont, color: .secondaryLabel
    )
    private let metaRow: UIStackView
    /// The gap the card puts between its caption and its metric line, held so
    /// the row can close up when there is no metric line to separate from.
    private var metaTopGap: NSLayoutConstraint!

    override init(frame: CGRect) {
        // Views lead, reactions and comments follow, age trailing — the card's
        // own order, so the line reads identically at both ends of a reveal.
        metaRow = UIStackView(arrangedSubviews: [views, reactions, comments])
        super.init(frame: frame)

        captionLabel.font = .preferredFont(forTextStyle: .body)
        captionLabel.adjustsFontForContentSizeCategory = true
        captionLabel.textColor = .label
        captionLabel.numberOfLines = 0
        // Word wrapping, never tail truncation: a short frame must OVERFLOW
        // visibly rather than swallow the end of the caption behind an
        // ellipsis, because this row self-sizes and overflow is what makes it
        // grow. The bubble learnt the same lesson.
        captionLabel.lineBreakMode = .byWordWrapping
        captionLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        captionLabel.setContentHuggingPriority(.required, for: .vertical)

        ageLabel.font = Self.metaFont
        ageLabel.textColor = .secondaryLabel
        ageLabel.adjustsFontForContentSizeCategory = true
        ageLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let spacer = UIView()
        spacer.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        metaRow.addArrangedSubview(spacer)
        metaRow.addArrangedSubview(ageLabel)
        metaRow.axis = .horizontal
        metaRow.alignment = .center
        metaRow.spacing = PostGridListRowCell.metaSpacing

        let inset = PostGridListRowCell.captionInset
        captionLabel.constrain(in: self) { parent in
            captionLabel.topAnchor.constraint(
                equalTo: parent.topAnchor, constant: PostGridListRowCell.captionTopInset
            )
            captionLabel.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset)
            captionLabel.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset)
        }
        metaRow.constrain(in: self) { parent in
            metaRow.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset)
            metaRow.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset)
            metaRow.bottomAnchor.constraint(
                equalTo: parent.bottomAnchor, constant: -PostGridListRowCell.metaBottomInset
            )
        }
        metaTopGap = metaRow.topAnchor.constraint(equalTo: captionLabel.bottomAnchor, constant: 12)
        metaTopGap.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Teaches the caption its wrapping width before anything asks how tall it
    /// is — the same race `SnapPostInfoCardView` closes, for the same reason: a
    /// multi-line label's intrinsic height is a function of a width it does not
    /// know, and a self-sizing cell is measured once.
    override func layoutSubviews() {
        super.layoutSubviews()
        let available = bounds.width - PostGridListRowCell.captionInset * 2
        if available > 0, abs(captionLabel.preferredMaxLayoutWidth - available) > 0.5 {
            captionLabel.preferredMaxLayoutWidth = available
            captionLabel.setNeedsUpdateConstraints()
        }
    }

    func configure(caption: String, timestamp: String, metrics: PostCardMetrics?) {
        captionLabel.text = caption
        ageLabel.text = timestamp
        views.set(metrics?.views)
        reactions.set(metrics?.reactions)
        comments.set(metrics?.comments)
        // A metric line that is nothing but the age still belongs to the
        // caption, not adrift below it — the card's 12pt gap separates two
        // lines of content, and with the counters absent there is only one.
        metaTopGap.constant = (metrics?.isEmpty ?? true) ? 4 : 12
    }

    func reset() {
        captionLabel.text = nil
        ageLabel.text = nil
        views.set(nil)
        reactions.set(nil)
        comments.set(nil)
    }
}
