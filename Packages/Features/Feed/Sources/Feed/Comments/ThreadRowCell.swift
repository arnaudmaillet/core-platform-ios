import DesignSystem
import FeedInterface
import UIKit

/// A comment row that can be LIFTED into a context menu — the cell a
/// conversation's messages and a text post's resting comments share.
///
/// The same `CommentRowView` as `CommentCell`, at the same insets, so the
/// stream reads identically. What differs is what a lift needs:
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
    /// A text message of the viewer's on its way (#719): a small spinner at
    /// the row's trailing edge; a failed one wears the red mark instead.
    private let sendingSpinner = UIActivityIndicatorView(style: .medium)
    private let failedMark = UIImageView(image: UIImage(systemName: "exclamationmark.circle.fill"))
    /// What the row says of its delivery now; nil for a delivered or someone
    /// else's message. Internal for tests.
    private(set) var delivery: ConversationThreadDelivery?

    /// How faded a message on its way is drawn.
    static let sendingAlpha: CGFloat = 0.55
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
        row.prepareForReuse()
        row.setLikeControlHidden(false)
        endTextSelection()
        setQuote(nil)
        mediaView.configure(nil, delivery: .sent, pipeline: nil)
        mediaView.onTap = nil
        liftPlate.layer.removeAllAnimations()
        liftPlate.backgroundColor = .clear
        // A rise or a delivery fade in flight does not follow the cell.
        contentView.layer.removeAllAnimations()
        row.layer.removeAllAnimations()
        contentView.transform = .identity
        contentView.alpha = 1
        timeReveal.layer.removeAllAnimations()
        timeReveal.isHidden = true
        isBouncingInTime = false
        // ⚠️ A pending row's cell can come straight back as its delivered
        // message (the swap is unanimated, #756) while its spinner is still
        // scaling out: the delivery stays with the row that played it.
        isScalingOutSpinner = false
        isBouncingInSpinner = false
        setDelivery(nil)
    }

    /// Shows (or, with nil, hides) the message this one answers.
    /// The row's delivery state (#719): a message on its way is drawn faded
    /// with a small spinner just right of its time, a failed one at full ink
    /// with a red mark there (tap to retry), a delivered one plainly. Text
    /// rows only — a photo or video draws its own (`ThreadMediaView`).
    /// `time`: what the line will say once delivered — its width is held
    /// while the spinner or the mark stands in it (see `reserveHeaderWidth`).
    func setDelivery(_ delivery: ConversationThreadDelivery?, time: String? = nil) {
        installDeliveryIndicatorsIfNeeded()
        let awaiting = delivery == .sending || delivery == .failed
        reserveHeaderWidth(awaiting ? time.map { (row.headerTextLabel.text ?? "") + $0 } : nil)
        let wasSending = self.delivery == .sending
        self.delivery = delivery == .sent ? nil : delivery
        row.alpha = delivery == .sending ? Self.sendingAlpha : 1
        failedMark.isHidden = delivery != .failed
        accessibilityValue = switch delivery {
        case .sending: "Sending"
        case .failed: "Not sent. Tap to try again."
        default: nil
        }
        placeDeliveryIndicators()
        guard delivery == .sending else {
            sendingSpinner.layer.removeAllAnimations()
            sendingSpinner.stopAnimating()
            sendingSpinner.transform = Self.spinnerScale
            sendingSpinner.alpha = 1
            return
        }
        sendingSpinner.startAnimating()
        if !wasSending { bounceInSpinner() }
    }

    /// The spinner arrives with a bounce: from nothing, past its size and
    /// back (#725).
    private func bounceInSpinner() {
        isBouncingInSpinner = true
        sendingSpinner.layer.removeAllAnimations()
        sendingSpinner.transform = Self.spinnerScale.scaledBy(x: 0.01, y: 0.01)
        sendingSpinner.alpha = 0
        UIView.animate(withDuration: 0.5, delay: 0.08, usingSpringWithDamping: 0.5,
                       initialSpringVelocity: 0.8, options: [.allowUserInteraction]) {
            self.sendingSpinner.transform = Self.spinnerScale
            self.sendingSpinner.alpha = 1
        } completion: { _ in
            self.isBouncingInSpinner = false
        }
    }

    /// Whether the spinner is on its way in. Internal for tests.
    private(set) var isBouncingInSpinner = false

    static let arrivalDuration: TimeInterval = 0.45
    static let arrivalRise: CGFloat = 24
    /// The spinner is drawn at the time's size, not a control's (#725).
    static let spinnerScale = CGAffineTransform(scaleX: 0.6, y: 0.6)
    /// Room between the time and the spinner or the mark.
    static let indicatorGap: CGFloat = 0

    /// The message rises into place from the composer (#719): a short spring
    /// up and in, landing at its on-its-way ink. A delivery that comes back
    /// sooner waits for it to land (`ConversationThreadViewController`).
    func playArrival() {
        contentView.transform = CGAffineTransform(translationX: 0, y: Self.arrivalRise)
        contentView.alpha = 0
        UIView.animate(withDuration: Self.arrivalDuration, delay: 0, usingSpringWithDamping: 0.78,
                       initialSpringVelocity: 0.4, options: [.allowUserInteraction]) {
            self.contentView.transform = .identity
            self.contentView.alpha = 1
        }
    }

    /// Delivered: the faded message comes up to full ink, its spinner —
    /// carried over from the pending row it replaces — scales out, and the
    /// time it stood in for fades in in its place (#725).
    ///
    /// `carryingSpinner: false` plays it on the pending row itself, the
    /// moment the server answers — from wherever its spinner is, mid
    /// bounce-in included — while its delivered row waits to take its place.
    func playDelivered(revealing time: String, carryingSpinner: Bool = true) {
        installDeliveryIndicatorsIfNeeded()
        let label = row.headerTextLabel
        let current = label.text ?? ""
        let full: String
        if carryingSpinner {
            // Configured with its time: the spinner stands in it first.
            full = current
            if current.hasSuffix(time) { label.text = String(current.dropLast(time.count)) }
            row.alpha = Self.sendingAlpha
            sendingSpinner.transform = Self.spinnerScale
            sendingSpinner.alpha = 1
            sendingSpinner.startAnimating()
            placeDeliveryIndicators()
            layoutIfNeeded()
        } else {
            full = current.hasSuffix(time) ? current : current + time
        }
        delivery = nil
        accessibilityValue = nil
        isBouncingInSpinner = false
        isScalingOutSpinner = true
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .curveEaseIn, .allowUserInteraction]) {
            self.row.alpha = 1
            self.sendingSpinner.transform = Self.spinnerScale.scaledBy(x: 0.01, y: 0.01)
            self.sendingSpinner.alpha = 0
        } completion: { _ in
            self.isScalingOutSpinner = false
            guard self.delivery != .sending else { return }
            self.sendingSpinner.stopAnimating()
            self.sendingSpinner.transform = Self.spinnerScale
            self.sendingSpinner.alpha = 1
        }
        // The time bounces in where the spinner was, on the same beat as the
        // spinner leaving; the line takes it back once it has landed.
        let prefix = String(full.dropLast(time.count))
        reserveHeaderWidth(full)
        label.text = prefix
        timeReveal.font = label.font
        timeReveal.textColor = label.textColor
        timeReveal.text = time
        timeRevealLeading?.constant = ceil(Self.textWidth(prefix, in: label))
        timeReveal.isHidden = false
        layoutIfNeeded()
        timeReveal.layer.removeAllAnimations()
        timeReveal.transform = CGAffineTransform(scaleX: 0.01, y: 0.01)
        timeReveal.alpha = 0
        isBouncingInTime = true
        UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.55,
                       initialSpringVelocity: 0.8, options: [.allowUserInteraction]) {
            self.timeReveal.transform = .identity
            self.timeReveal.alpha = 1
        } completion: { _ in
            self.isBouncingInTime = false
            label.text = full
            self.reserveHeaderWidth(nil)
            self.timeReveal.isHidden = true
        }
    }

    /// Whether the time is on its way in. Internal for tests.
    private(set) var isBouncingInTime = false

    /// The time while it bounces in, drawn over its own place in the line.
    private let timeReveal = UILabel()
    private var timeRevealLeading: NSLayoutConstraint?

    /// ⚠️ THE LINE KEEPS ITS FULL WIDTH WHILE THE TIME IS AWAY (#753). With
    /// a reply's quote on the header line the label hugs its text, so the
    /// spinner, the mark and the time's reveal — all drawn at the text's end
    /// — landed on the quote, and the quote jumped when the time came back.
    /// Holding the width of the full line keeps the quote where it will be.
    private lazy var headerWidthFloor: NSLayoutConstraint = {
        let floor = row.headerTextLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
        // Over the label's and the quote's compression (749, 700).
        floor.priority = .defaultHigh
        floor.isActive = true
        return floor
    }()

    private func reserveHeaderWidth(_ text: String?) {
        let width = text.map { ceil(Self.textWidth($0, in: row.headerTextLabel)) } ?? 0
        guard headerWidthFloor.constant != width else { return }
        headerWidthFloor.constant = width
    }

    /// The width the header line holds. Tests.
    var debugHeaderWidthFloor: CGFloat { headerWidthFloor.constant }

    private static func textWidth(_ text: String, in label: UILabel) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: label.font as Any]).width
    }

    /// Whether the spinner is on its way out. Internal for tests.
    private(set) var isScalingOutSpinner = false

    var sendingSpinnerView: UIActivityIndicatorView { sendingSpinner }

    /// The spinner's and the mark's leading edges, from the time line's.
    private var spinnerLeading: NSLayoutConstraint?
    private var markLeading: NSLayoutConstraint?

    /// In the time's place, which the line leaves empty (`You · `) while the
    /// message is on its way: the line is a stretching label, so the text's
    /// own width — trailing space included — places them (#725).
    private func placeDeliveryIndicators() {
        let label = row.headerTextLabel
        let textWidth = label.text.map { ($0 as NSString).size(withAttributes: [.font: label.font as Any]).width } ?? 0
        let drawn = sendingSpinner.intrinsicContentSize.width * Self.spinnerScale.a
        // The spinner is laid out at its natural size and drawn scaled about
        // its centre: its frame starts half the difference before what shows.
        spinnerLeading?.constant = ceil(textWidth) + Self.indicatorGap - (sendingSpinner.intrinsicContentSize.width - drawn) / 2
        markLeading?.constant = ceil(textWidth) + Self.indicatorGap
    }

    private var installedDeliveryIndicators = false
    private func installDeliveryIndicatorsIfNeeded() {
        guard !installedDeliveryIndicators else { return }
        installedDeliveryIndicators = true
        sendingSpinner.hidesWhenStopped = true
        sendingSpinner.transform = Self.spinnerScale
        failedMark.tintColor = .systemRed
        failedMark.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1)
        failedMark.isHidden = true
        let label = row.headerTextLabel
        for view in [sendingSpinner, failedMark] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
            view.centerYAnchor.constraint(equalTo: label.centerYAnchor).isActive = true
        }
        spinnerLeading = sendingSpinner.leadingAnchor.constraint(equalTo: label.leadingAnchor)
        markLeading = failedMark.leadingAnchor.constraint(equalTo: label.leadingAnchor)
        spinnerLeading?.isActive = true
        markLeading?.isActive = true
        timeReveal.translatesAutoresizingMaskIntoConstraints = false
        timeReveal.isHidden = true
        timeReveal.isAccessibilityElement = false
        contentView.addSubview(timeReveal)
        timeReveal.centerYAnchor.constraint(equalTo: label.centerYAnchor).isActive = true
        timeRevealLeading = timeReveal.leadingAnchor.constraint(equalTo: label.leadingAnchor)
        timeRevealLeading?.isActive = true
    }

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
