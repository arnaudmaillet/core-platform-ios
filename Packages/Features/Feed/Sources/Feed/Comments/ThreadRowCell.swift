import DesignSystem
import FeedInterface
import UIKit

/// A comment row that can be LIFTED into a context menu — the cell a
/// conversation's messages and a text post's resting comments share.
///
/// The same `CommentRowView` as `CommentCell`, at the same insets, so the
/// stream reads identically. The row draws everything a message and a comment
/// have in common — avatar, name, the time or the loader in its place, the
/// content — and its `variant` says which it is (#920). What this cell adds is
/// what a lift needs:
///  - the row carries NO menu interaction of its own — the stream's
///    `ThreadRowContextMenu` owns the long press, once, for every row;
///  - a clear LIFT PLATE stands behind the row, outset by the platter's
///    padding, so the preview has room around the text and its bounds ARE the
///    lifted shape (see `LiftedPreview` for why that must hold);
///  - an optional quote on the row's header line, right of the time, for a
///    reply in a conversation (#753);
///  - an optional photo or video under it, for a conversation's media
///    message (#681).
final class ThreadRowCell: UICollectionViewCell {
    /// The platter's margin around the row's content when lifted.
    static let liftPadding: CGFloat = Spacing.sm
    static let liftCornerRadius: CGFloat = 16

    let row = CommentRowView(installsContextMenu: false)
    /// A media message's photo or video (#681); hidden otherwise.
    let mediaView = ThreadMediaView()
    private let liftPlate = UIView()
    private let quoteView = ThreadQuoteView(indented: false)

    private var selection: SelectableTextOverlay?

    /// The quote strip was tapped — the host scrolls to the original.
    var onQuoteTap: (() -> Void)? {
        get { quoteView.onTap }
        set { quoteView.onTap = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        liftPlate.backgroundColor = .clear
        liftPlate.layer.cornerRadius = Self.liftCornerRadius
        liftPlate.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(liftPlate)
        // A freshly dequeued row has no frame yet: its delivery animations lay
        // out the whole cell before they start.
        row.layoutHost = self

        quoteView.isHidden = true
        // On the header line, right of the time (#753, the owner's call
        // 2026-10-09) — not a line of its own above the row.
        row.installHeaderAccessory(quoteView)
        let stack = UIStackView(arrangedSubviews: [row, mediaView])
        stack.axis = .vertical
        stack.spacing = Spacing.xs
        stack.translatesAutoresizingMaskIntoConstraints = false
        liftPlate.addSubview(stack)

        // The plate hangs OUTSIDE the content view by the padding on every side
        // but the bottom, where it stops short of the inter-row breathing — so
        // the row's own frame lands exactly where `CommentCell` puts it, and
        // only the lift sees the margin.
        let pad = Self.liftPadding
        NSLayoutConstraint.activate([
            liftPlate.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: -pad),
            liftPlate.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: pad),
            liftPlate.topAnchor.constraint(equalTo: contentView.topAnchor, constant: -pad),
            liftPlate.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Spacing.lg + pad),
            stack.leadingAnchor.constraint(equalTo: liftPlate.leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: liftPlate.trailingAnchor, constant: -pad),
            stack.topAnchor.constraint(equalTo: liftPlate.topAnchor, constant: pad),
            stack.bottomAnchor.constraint(equalTo: liftPlate.bottomAnchor, constant: -pad),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        // Back to a comment, with nothing pending — see the row's own.
        row.prepareForReuse()
        accessibilityValue = nil
        endTextSelection()
        setQuote(nil)
        mediaView.configure(nil, delivery: .sent, pipeline: nil)
        mediaView.onTap = nil
        liftPlate.layer.removeAllAnimations()
        liftPlate.backgroundColor = .clear
        // An arrival or a departure in flight does not follow the cell.
        contentView.layer.removeAllAnimations()
        row.layer.removeAllAnimations()
        contentView.transform = .identity
        contentView.alpha = 1
    }

    // MARK: - Delivery (#719)

    /// What the row says of its delivery now; nil for a delivered or someone
    /// else's message. Internal for tests.
    var delivery: ConversationThreadDelivery? {
        switch row.delivery {
        case .sending: .sending
        case .failed: .failed
        case nil: nil
        }
    }

    /// The message's delivery state, drawn by the row in its time's place: a
    /// spinner while on its way, a red mark when it failed (tap to retry), the
    /// time once delivered. Text rows only — a photo or video draws its own
    /// (`ThreadMediaView`). `time`: what the line will say once delivered.
    ///
    /// ⚠️ ALWAYS AT FULL INK (#919, the owner's call 2026-10-11). A pending
    /// message used to be drawn faded until it was sent; the spinner standing
    /// in for the time is now the only sign it is on its way.
    func setDelivery(_ delivery: ConversationThreadDelivery?, time: String? = nil) {
        let awaiting: CommentRowView.Delivery? = switch delivery {
        case .sending: .sending
        case .failed: .failed
        case .sent, nil: nil
        }
        row.setDelivery(awaiting, time: time)
        accessibilityValue = switch delivery {
        case .sending: "Sending"
        case .failed: "Not sent. Tap to try again."
        default: nil
        }
    }

    /// Delivered: the spinner scales out and the time bounces in in its place
    /// (#725) — see `CommentRowView.playDelivered`.
    func playDelivered(revealing time: String, carryingSpinner: Bool = true) {
        row.playDelivered(revealing: time, carryingSpinner: carryingSpinner)
        accessibilityValue = nil
    }

    /// Internal for tests — the row's.
    var isBouncingInSpinner: Bool { row.isBouncingInSpinner }
    var isScalingOutSpinner: Bool { row.isScalingOutSpinner }
    var isBouncingInTime: Bool { row.isBouncingInTime }
    var sendingSpinnerView: AppLoaderView { row.sendingSpinnerView }
    var debugHeaderWidthFloor: CGFloat { row.debugHeaderWidthFloor }

    // MARK: - Arrival and departure (#920)

    /// How long a message's arrival takes to land — a delivery that comes back
    /// sooner waits for it (`ConversationThreadViewController`).
    static let arrivalDuration = CommentRowView.Variant.message.effect.appearDuration

    /// The row arrives with its effect (#920): a message rises in from the
    /// composer, a comment bounces in.
    func playArrival() {
        row.playAppear(in: contentView)
    }

    /// The row leaves with its effect; the host removes it in `completion`.
    func playDeparture(completion: @escaping () -> Void) {
        row.playDisappear(in: contentView, completion: completion)
    }

    // MARK: - Quote

    /// Shows (or, with nil, hides) the message this one answers.
    func setQuote(_ quote: (author: String, snippet: String)?) {
        quoteView.isHidden = quote == nil
        if let quote { quoteView.configure(author: quote.author, snippet: quote.snippet) }
        if quote == nil { onQuoteTap = nil }
    }

    // MARK: - The lift

    /// What the context menu lifts: the plate, with the platter's own fill.
    func liftPreview() -> UITargetedPreview {
        LiftedPreview.targeted(
            view: liftPlate,
            cornerRadius: Self.liftCornerRadius,
            platterColor: .secondarySystemBackground
        )
    }

    /// Whether `point` (cell coordinates) lands on the row's lifted shape.
    func liftContains(_ point: CGPoint) -> Bool {
        liftPlate.convert(liftPlate.bounds, to: self).contains(point)
    }

    /// A brief wash over the row — where a quote tap lands.
    func flash() {
        liftPlate.backgroundColor = .tertiarySystemFill
        UIView.animate(withDuration: 0.6, delay: 0.25, options: [.allowUserInteraction]) {
            self.liftPlate.backgroundColor = .clear
        }
    }

    // MARK: - Select Text

    func beginTextSelection() {
        let overlay = selection ?? SelectableTextOverlay(label: row.bodyTextLabel, host: row)
        selection = overlay
        overlay.begin()
    }

    func endTextSelection() {
        selection?.end()
    }

    /// Whether a touch on `view` belongs to the selection in progress.
    func selectionContains(_ view: UIView?) -> Bool {
        selection?.contains(view) ?? false
    }
}

/// What a reply answers: `▎Ava  Are you around?` — quiet, and a tap target
/// that takes the reader to the original. On a conversation's row it rides
/// the header line, right of the time (#753, `indented: false`); indented,
/// it is a line of its own at the row's text column.
final class ThreadQuoteView: UIView {
    var onTap: (() -> Void)?

    private let bar = UIView()
    private let label = UILabel()
    /// The indent to the row's text column, which moves with the avatar's
    /// type-driven size.
    private var barLeading: NSLayoutConstraint?

    init(indented: Bool = true) {
        super.init(frame: .zero)
        bar.backgroundColor = .tertiaryLabel
        bar.layer.cornerRadius = 1
        bar.translatesAutoresizingMaskIntoConstraints = false
        label.font = .appFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        addSubview(label)
        let padding: CGFloat = indented ? 2 : 0
        let leading = bar.leadingAnchor.constraint(
            equalTo: leadingAnchor, constant: indented ? CommentRowView.avatarSize + CommentRowView.avatarGap : 0
        )
        barLeading = leading
        if indented {
            registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (quote: ThreadQuoteView, _: UITraitCollection) in
                quote.barLeading?.constant = CommentRowView.avatarSize(for: quote.traitCollection) + CommentRowView.avatarGap
            }
        }
        // Inline, the label IS the view's width, so a stack can stretch or
        // truncate it; indented, it hugs its text within the line.
        label.setContentHuggingPriority(UILayoutPriority(249), for: .horizontal)
        label.setContentCompressionResistancePriority(UILayoutPriority(700), for: .horizontal)
        NSLayoutConstraint.activate([
            leading,
            bar.widthAnchor.constraint(equalToConstant: 2),
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            label.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: Spacing.sm),
            indented
                ? label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)
                : label.trailingAnchor.constraint(equalTo: trailingAnchor),
            // Inline, no padding: the header line keeps the height it has
            // without a quote.
            label.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),
        ])
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(author: String, snippet: String) {
        let text = NSMutableAttributedString(
            string: author,
            attributes: [.font: UIFont.scaledFont(forTextStyle: .footnote, weight: .semibold)]
        )
        text.append(NSAttributedString(string: "  \(snippet)"))
        label.attributedText = text
        accessibilityLabel = "Replying to \(author): \(snippet)"
    }

    @objc private func tapped() { onTap?() }
}
