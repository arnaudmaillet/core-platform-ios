import DesignSystem
import UIKit

/// A comment row that can be LIFTED into a context menu — the cell the unified
/// thread uses (`-unified-thread`) for a conversation's messages and a text
/// post's comments alike.
///
/// The same `CommentRowView` as `CommentCell`, at the same insets, so the
/// stream reads identically. What differs is what a lift needs:
///  - the row carries NO menu interaction of its own — the stream's
///    `ThreadRowContextMenu` owns the long press, once, for every row;
///  - a clear LIFT PLATE stands behind the row, outset by the platter's
///    padding, so the preview has room around the text and its bounds ARE the
///    lifted shape (see `LiftedPreview` for why that must hold);
///  - an optional quote strip above the row, for a reply in a conversation.
final class ThreadRowCell: UICollectionViewCell {
    /// The platter's margin around the row's content when lifted.
    static let liftPadding: CGFloat = Spacing.sm
    static let liftCornerRadius: CGFloat = 16

    let row = CommentRowView(installsContextMenu: false)
    private let liftPlate = UIView()
    private let quoteView = ThreadQuoteView()
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

        quoteView.isHidden = true
        let stack = UIStackView(arrangedSubviews: [quoteView, row])
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
        row.prepareForReuse()
        row.setLikeControlHidden(false)
        endTextSelection()
        setQuote(nil)
        liftPlate.layer.removeAllAnimations()
        liftPlate.backgroundColor = .clear
    }

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

/// The one line above a reply that says what it answers:
/// `▎Ava  Are you around?` — indented to the row's text column, quiet, and a
/// tap target that takes the reader to the original.
final class ThreadQuoteView: UIView {
    var onTap: (() -> Void)?

    private let bar = UIView()
    private let label = UILabel()

    init() {
        super.init(frame: .zero)
        bar.backgroundColor = .tertiaryLabel
        bar.layer.cornerRadius = 1
        bar.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        addSubview(label)
        let indent = CommentRowView.avatarSize + CommentRowView.avatarGap
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: indent),
            bar.widthAnchor.constraint(equalToConstant: 2),
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            label.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: Spacing.sm),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
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
            attributes: [.font: UIFont.preferredFont(forTextStyle: .footnote).withWeight(.semibold)]
        )
        text.append(NSAttributedString(string: "  \(snippet)"))
        label.attributedText = text
        accessibilityLabel = "Replying to \(author): \(snippet)"
    }

    @objc private func tapped() { onTap?() }
}
