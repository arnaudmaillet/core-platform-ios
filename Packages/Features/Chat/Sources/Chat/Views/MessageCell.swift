import DesignSystem
import UIKit

/// Routes a bubble's interactions back to the host: a quoted-preview tap
/// (scroll-to + highlight the original) and a swipe-to-reply. A delegate, not
/// per-configure closures: the cell registration runs on every dequeue/
/// reconfigure, so a weak reference set there costs a pointer write, not fresh
/// allocations each time.
@MainActor
protocol MessageCellDelegate: AnyObject {
    func messageCell(_ cell: MessageCell, didTapQuotedMessage id: String)
    func messageCell(_ cell: MessageCell, didSwipeToReply id: String)
}

/// One transcript bubble, self-sized by Auto Layout. A single cell class
/// serves both alignments: sender side, corner shaping, colors, and run
/// spacing all come from the row model on configure, so reuse never has to
/// tear structure down. A reply bubble stacks a tappable quoted preview of
/// the message it answers above its body.
final class MessageCell: UICollectionViewCell {
    private enum Metrics {
        static let cornerRadius: CGFloat = 18
        /// The reduced radius on corners facing a same-run neighbor.
        static let groupedCornerRadius: CGFloat = 5
        static let maxWidthFraction: CGFloat = 0.75
        /// Gap above a bubble continuing a run vs. starting a new one.
        static let runSpacing: CGFloat = 2
        static let groupSpacing: CGFloat = Spacing.sm
        static let quoteCornerRadius: CGFloat = 9
        /// Leftward drag distance that arms the reply action.
        static let replySwipeThreshold: CGFloat = 64
        static let replyIconSize: CGFloat = 22
    }

    /// The four resolved radii, left/right like `UICornerConfiguration`.
    private struct CornerRadii {
        var topLeft: CGFloat
        var topRight: CGFloat
        var bottomLeft: CGFloat
        var bottomRight: CGFloat
    }

    weak var delegate: MessageCellDelegate?

    /// The bubble is a clear container; its rounded fill lives on this
    /// subview. The split is load-bearing for the context-menu lift: the
    /// system platter strips a targeted preview VIEW's own background (it
    /// repaints from `UIPreviewParameters`), but faithfully portals subview
    /// content — a fill carried by a subview rides the lift, hover, and
    /// return flight without ghosting.
    private let bubble = UIView()
    private let bubbleBackground = UIView()
    private let bodyLabel = UILabel()
    private let timeLabel = UILabel()

    // Quoted-reply preview (shown only on reply bubbles): a rounded, tappable
    // container wrapping the shared `QuotedReplyView`.
    private let quoteContainer = UIView()
    private let quoteBackground = UIView()
    private let quoteView = QuotedReplyView()
    private let contentStack = UIStackView()
    private var quotedMessageID: String?
    /// Drives the flash-highlight tint so it reads on either bubble color.
    private var isMineBubble = false

    // Select-text: a native selectable `UITextView` built on demand and laid
    // over the body only while selecting (the display path stays a `UILabel`).
    private var selectionTextView: UITextView?
    private var bodyText: String?
    private let editMenuInteraction = UIEditMenuInteraction(delegate: nil)

    // Swipe-to-reply: the reply glyph revealed on the trailing side as the
    // bubble is dragged left, plus the drag's own state.
    private let replyIndicator = UIImageView()
    private var replyPan: UIPanGestureRecognizer!
    /// This cell's own message id — the reply target.
    private var messageID: String?
    /// One haptic per threshold crossing (reset when the drag falls back under).
    private var didCrossReplyThreshold = false

    /// Off in the context-menu preview (a static peek, no compose bar to
    /// reply into); the host sets it per mode.
    var isReplySwipeEnabled = true {
        didSet { updateReplyPanEnabled() }
    }

    /// The pan is live only when swipe-to-reply is allowed AND the bubble isn't
    /// selecting text — a leftward handle drag must never arm a reply. Derived
    /// (not set directly) so a mid-selection reconfigure can't re-enable it.
    private func updateReplyPanEnabled() {
        replyPan.isEnabled = isReplySwipeEnabled && !isSelectingText
    }

    private var radii = CornerRadii(
        topLeft: Metrics.cornerRadius, topRight: Metrics.cornerRadius,
        bottomLeft: Metrics.cornerRadius, bottomRight: Metrics.cornerRadius
    )

    private var topConstraint: NSLayoutConstraint!
    private var leadingConstraint: NSLayoutConstraint!
    private var trailingConstraint: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)

        bubbleBackground.pin(to: bubble)

        configureQuoteView()

        bodyLabel.numberOfLines = 0
        bodyLabel.adjustsFontForContentSizeCategory = true

        // The bubble's inner column: quoted preview (when present) above the
        // body. The stack collapses the quote entirely when hidden, so a
        // plain message lays out exactly as before.
        contentStack.axis = .vertical
        contentStack.spacing = Spacing.xs
        contentStack.addArrangedSubview(quoteContainer)
        contentStack.addArrangedSubview(bodyLabel)
        contentStack.pin(to: bubble, insets: NSDirectionalEdgeInsets(
            top: Spacing.sm, leading: Spacing.md, bottom: Spacing.sm, trailing: Spacing.md
        ))

        timeLabel.adjustsFontForContentSizeCategory = true
        timeLabel.constrain(in: bubble) { parent in
            // The body text ends with a clear-color twin of the time string
            // (see configure), so anchoring to the body's last baseline drops
            // the visible time exactly into that reserved footprint.
            timeLabel.lastBaselineAnchor.constraint(equalTo: bodyLabel.lastBaselineAnchor)
            timeLabel.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -Spacing.md)
        }

        contentView.addSubview(bubble)
        bubble.translatesAutoresizingMaskIntoConstraints = false
        topConstraint = bubble.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Metrics.groupSpacing)
        leadingConstraint = bubble.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
        trailingConstraint = bubble.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        NSLayoutConstraint.activate([
            topConstraint,
            bubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            bubble.widthAnchor.constraint(
                lessThanOrEqualTo: contentView.widthAnchor, multiplier: Metrics.maxWidthFraction
            )
        ])

        configureReplySwipe()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        // A flash pulse or reply swipe may have been interrupted mid-reuse;
        // reset the pose.
        bubble.transform = .identity
        replyIndicator.alpha = 0
        replyIndicator.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
        didCrossReplyThreshold = false
        endTextSelection()
        quotedMessageID = nil
        messageID = nil
        bodyText = nil
    }

    // MARK: - Select text

    /// True while this bubble is in interactive text-selection mode.
    var isSelectingText: Bool { selectionTextView.map { !$0.isHidden } ?? false }

    /// Overlays a native selectable text view on the body and selects all of
    /// it, so the user gets the blue selection handles + Copy/Share callout.
    /// The display `bodyLabel`/`timeLabel` fade out (not `isHidden` — that
    /// would collapse the stack and resize the bubble); the text view carries
    /// only the body, so copy is clean (no inline-time twin).
    func beginTextSelection() {
        let textView = selectionTextView ?? makeSelectionTextView()
        selectionTextView = textView
        textView.text = bodyText
        textView.textColor = isMineBubble ? .white : .label
        // Handles/selection read on the bubble: light on my blue, tint on gray.
        textView.tintColor = isMineBubble ? .white : .tintColor
        textView.isHidden = false
        bodyLabel.alpha = 0
        timeLabel.alpha = 0
        // The reply swipe and a leftward handle-drag are the same motion —
        // suspend the swipe (now that `isSelectingText` is true) so dragging a
        // selection handle moves the caret instead of arming a reply.
        updateReplyPanEnabled()
        // Resolve the overlay's frame before selecting — selecting a zero-bounds
        // text view yields no visible handles.
        layoutIfNeeded()
        textView.becomeFirstResponder()
        textView.selectAll(nil)
        // A programmatic selection doesn't raise the Copy/Share callout on its
        // own (iOS 16+ presents it in response to user gestures) — present it
        // explicitly (next runloop, once the selection has settled) so it lands
        // like Messages' "Select Text".
        DispatchQueue.main.async { [weak self] in self?.presentEditMenu() }
    }

    private func presentEditMenu() {
        guard let textView = selectionTextView, !textView.isHidden,
              let range = textView.selectedTextRange else { return }
        let rect = textView.firstRect(for: range)
        let source = CGPoint(x: rect.midX, y: rect.minY)
        editMenuInteraction.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: source))
    }

    /// Leaves selection mode and restores the display body. Idempotent.
    func endTextSelection() {
        guard let textView = selectionTextView, !textView.isHidden else { return }
        textView.resignFirstResponder()
        textView.selectedTextRange = nil
        textView.isHidden = true
        bodyLabel.alpha = 1
        timeLabel.alpha = 1
        // Restore the swipe to its mode-driven state (off in a preview peek);
        // `isSelectingText` is now false again.
        updateReplyPanEnabled()
    }

    private func makeSelectionTextView() -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        // Zero the container padding so the glyphs land exactly where the
        // label's did — the overlay must not shift the text.
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.isHidden = true
        textView.addInteraction(editMenuInteraction)
        textView.constrain(in: bubble) { _ in
            textView.leadingAnchor.constraint(equalTo: bodyLabel.leadingAnchor)
            textView.trailingAnchor.constraint(equalTo: bodyLabel.trailingAnchor)
            textView.topAnchor.constraint(equalTo: bodyLabel.topAnchor)
            textView.bottomAnchor.constraint(equalTo: bodyLabel.bottomAnchor)
        }
        return textView
    }

    private func configureQuoteView() {
        quoteBackground.pin(to: quoteContainer)
        quoteBackground.layer.cornerRadius = Metrics.quoteCornerRadius
        quoteBackground.layer.cornerCurve = .continuous
        quoteBackground.clipsToBounds = true

        quoteView.pin(to: quoteContainer, insets: NSDirectionalEdgeInsets(
            top: Spacing.xs, leading: Spacing.sm, bottom: Spacing.xs, trailing: Spacing.sm
        ))

        quoteContainer.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(handleQuoteTap))
        )
    }

    @objc private func handleQuoteTap() {
        guard let quotedMessageID else { return }
        delegate?.messageCell(self, didTapQuotedMessage: quotedMessageID)
    }

    // MARK: - Swipe to reply

    private func configureReplySwipe() {
        replyIndicator.image = UIImage(
            systemName: "arrowshape.turn.up.left.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: Metrics.replyIconSize, weight: .semibold)
        )
        replyIndicator.tintColor = .secondaryLabel
        replyIndicator.contentMode = .center
        replyIndicator.alpha = 0
        // Rests small; scales up toward the threshold.
        replyIndicator.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
        // Behind the bubble so a resting (or barely-dragged) bubble hides it,
        // then it's revealed in the trailing gap as the bubble slides left.
        contentView.insertSubview(replyIndicator, belowSubview: bubble)
        replyIndicator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            replyIndicator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            replyIndicator.centerYAnchor.constraint(equalTo: bubble.centerYAnchor)
        ])

        replyPan = UIPanGestureRecognizer(target: self, action: #selector(handleReplyPan))
        replyPan.delegate = self
        contentView.addGestureRecognizer(replyPan)
    }

    @objc private func handleReplyPan(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            didCrossReplyThreshold = false
        case .changed:
            // Leftward only; 1:1 up to the threshold, then rubber-banded.
            let dx = replyResistance(min(0, pan.translation(in: self).x))
            bubble.transform = CGAffineTransform(translationX: dx, y: 0)

            let progress = min(1, -dx / Metrics.replySwipeThreshold)
            replyIndicator.alpha = progress
            let scale = 0.4 + 0.6 * progress
            replyIndicator.transform = CGAffineTransform(scaleX: scale, y: scale)

            let armed = -dx >= Metrics.replySwipeThreshold
            if armed, !didCrossReplyThreshold {
                didCrossReplyThreshold = true
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } else if !armed {
                didCrossReplyThreshold = false
            }
        case .ended:
            if -bubble.transform.tx >= Metrics.replySwipeThreshold, let messageID {
                delegate?.messageCell(self, didSwipeToReply: messageID)
            }
            springReplyBack()
        case .cancelled, .failed:
            springReplyBack()
        default:
            break
        }
    }

    /// Tracks the finger 1:1 up to the threshold, then dampens further travel
    /// so the bubble has a natural, springy limit. `dx` is `<= 0` (leftward).
    private func replyResistance(_ dx: CGFloat) -> CGFloat {
        let magnitude = -dx
        let threshold = Metrics.replySwipeThreshold
        guard magnitude > threshold else { return dx }
        return -(threshold + (magnitude - threshold) * 0.35)
    }

    private func springReplyBack() {
        didCrossReplyThreshold = false
        UIView.animate(
            withDuration: 0.45, delay: 0,
            usingSpringWithDamping: 0.6, initialSpringVelocity: 0.4,
            options: [.allowUserInteraction, .curveEaseOut]
        ) {
            self.bubble.transform = .identity
            self.replyIndicator.alpha = 0
            self.replyIndicator.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
        }
    }

    func configure(with model: MessageRowModel) {
        let bodyFont = UIFont.preferredFont(forTextStyle: .body)
        let timeFont = UIFont.preferredFont(forTextStyle: .caption2)

        messageID = model.id
        bodyText = model.body
        isMineBubble = model.isMine
        bubbleBackground.backgroundColor = model.isMine ? .systemBlue : .secondarySystemBackground
        radii = resolvedRadii(for: model)
        bubbleBackground.cornerConfiguration = .corners(
            topLeftRadius: .fixed(radii.topLeft),
            topRightRadius: .fixed(radii.topRight),
            bottomLeftRadius: .fixed(radii.bottomLeft),
            bottomRightRadius: .fixed(radii.bottomRight)
        )

        configureQuote(model.quote, isMine: model.isMine)

        // Body text plus an invisible reservation of the time's exact width:
        // when the last line has room the time shares it (Telegram's inline
        // tuck), otherwise wrapping gives it its own line — no measurement.
        let text = NSMutableAttributedString(string: model.body, attributes: [
            .font: bodyFont,
            .foregroundColor: model.isMine ? UIColor.white : UIColor.label
        ])
        text.append(NSAttributedString(string: "\u{2002}" + model.timeText, attributes: [
            .font: timeFont,
            .foregroundColor: UIColor.clear
        ]))
        bodyLabel.attributedText = text

        timeLabel.text = model.timeText
        timeLabel.font = timeFont
        timeLabel.textColor = model.isMine ? .white.withAlphaComponent(0.75) : .secondaryLabel

        leadingConstraint.isActive = false
        trailingConstraint.isActive = false
        (model.isMine ? trailingConstraint : leadingConstraint).isActive = true
        topConstraint.constant = switch model.position {
        case .single, .first: Metrics.groupSpacing
        case .middle, .last: Metrics.runSpacing
        }
    }

    /// Populates (or hides) the quoted preview and tints it to read on the
    /// bubble it sits in — light-on-blue for my bubbles, tinted-on-gray for
    /// the correspondent's.
    private func configureQuote(_ quote: QuotedReply?, isMine: Bool) {
        guard let quote else {
            quoteContainer.isHidden = true
            quotedMessageID = nil
            return
        }
        quoteContainer.isHidden = false
        quotedMessageID = quote.messageID
        quoteView.setContent(author: quote.author, snippet: quote.snippet)

        if isMine {
            quoteBackground.backgroundColor = UIColor.white.withAlphaComponent(0.18)
            quoteView.tint(accent: .white, author: .white, snippet: UIColor.white.withAlphaComponent(0.85))
        } else {
            quoteBackground.backgroundColor = UIColor.label.withAlphaComponent(0.06)
            quoteView.tint(accent: .systemBlue, author: .label, snippet: .secondaryLabel)
        }
    }

    /// Telegram grouping: the corners facing same-run neighbors flatten, on
    /// the bubble's aligned side only. Corner configuration is left/right
    /// (not leading/trailing), so resolve the aligned side per direction.
    private func resolvedRadii(for model: MessageRowModel) -> CornerRadii {
        let large = Metrics.cornerRadius
        let small = Metrics.groupedCornerRadius
        let top = (model.position == .middle || model.position == .last) ? small : large
        let bottom = (model.position == .middle || model.position == .first) ? small : large

        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let onRight = model.isMine != isRTL
        return onRight
            ? CornerRadii(topLeft: large, topRight: top, bottomLeft: large, bottomRight: bottom)
            : CornerRadii(topLeft: top, topRight: large, bottomLeft: bottom, bottomRight: large)
    }

    // MARK: - Highlight

    /// A pulse used when a reply's quoted original is jumped to: a scale bump
    /// plus a contrasting tint that reads on either bubble color — a light wash
    /// on my blue bubbles, a blue wash on the correspondent's gray ones. A
    /// transform never perturbs the self-sizing layout.
    func flashHighlight() {
        let overlay = UIView()
        overlay.isUserInteractionEnabled = false
        overlay.backgroundColor = isMineBubble ? .white : .systemBlue
        overlay.alpha = 0
        overlay.cornerConfiguration = bubbleBackground.cornerConfiguration
        overlay.frame = bubble.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        bubble.addSubview(overlay)

        let peak: CGFloat = isMineBubble ? 0.55 : 0.4
        UIView.animateKeyframes(withDuration: 0.9, delay: 0, options: [.allowUserInteraction]) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.22) {
                self.bubble.transform = CGAffineTransform(scaleX: 1.07, y: 1.07)
                overlay.alpha = peak
            }
            UIView.addKeyframe(withRelativeStartTime: 0.22, relativeDuration: 0.78) {
                self.bubble.transform = .identity
                overlay.alpha = 0
            }
        } completion: { _ in overlay.removeFromSuperview() }
    }

    // MARK: - Context-menu lift

    /// The context-menu lift target: the bubble alone, not the cell — the
    /// row is full-width but mostly empty flank, and lifting it would drag a
    /// clear rectangle into the platter. The visible path retraces the
    /// bubble's exact per-run corner geometry so the lift clips nothing and
    /// reveals nothing.
    func bubblePreview() -> UITargetedPreview {
        // Two hard constraints, both learned the expensive way:
        // 1. The preview view's bounds must COINCIDE with `visiblePath`'s
        //    bounds. The platter aligns to the path region but restores the
        //    view — an off-center path (e.g. previewing the full-width
        //    content view clipped to the bubble) permanently displaces the
        //    cell content by (path center − view center) after dismissal.
        // 2. The fill must be SUBVIEW content (`bubbleBackground`), never
        //    the preview view's own background — the platter strips and
        //    repaints that, so it ghosts to bare text mid-flight.
        // `view: bubble` + a bounds-filling path + a content-carried fill
        // satisfy both; the platter needs no compensation color.
        let parameters = UIPreviewParameters()
        parameters.visiblePath = bubblePath()
        parameters.backgroundColor = .clear
        return UITargetedPreview(view: bubble, parameters: parameters)
    }

    /// Whether `point` (cell coordinates) lands on the bubble — the menu's
    /// begin gate, so the empty flank of a row is not a press target.
    func bubbleContains(_ point: CGPoint) -> Bool {
        bubble.bounds.contains(convert(point, to: bubble))
    }

    /// The bubble outline. `UIPreviewParameters.visiblePath` can't read the
    /// layer's `cornerConfiguration`, so the same four radii are retraced as
    /// a bezier path (circular arcs; the platter clips, so the corner-style
    /// difference from the layer's rendering is sub-pixel).
    private func bubblePath() -> UIBezierPath {
        let bounds = bubble.bounds
        let path = UIBezierPath()
        path.move(to: CGPoint(x: bounds.minX, y: bounds.minY + radii.topLeft))
        path.addArc(
            withCenter: CGPoint(x: bounds.minX + radii.topLeft, y: bounds.minY + radii.topLeft),
            radius: radii.topLeft, startAngle: .pi, endAngle: 1.5 * .pi, clockwise: true
        )
        path.addLine(to: CGPoint(x: bounds.maxX - radii.topRight, y: bounds.minY))
        path.addArc(
            withCenter: CGPoint(x: bounds.maxX - radii.topRight, y: bounds.minY + radii.topRight),
            radius: radii.topRight, startAngle: 1.5 * .pi, endAngle: 2 * .pi, clockwise: true
        )
        path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY - radii.bottomRight))
        path.addArc(
            withCenter: CGPoint(x: bounds.maxX - radii.bottomRight, y: bounds.maxY - radii.bottomRight),
            radius: radii.bottomRight, startAngle: 0, endAngle: 0.5 * .pi, clockwise: true
        )
        path.addLine(to: CGPoint(x: bounds.minX + radii.bottomLeft, y: bounds.maxY))
        path.addArc(
            withCenter: CGPoint(x: bounds.minX + radii.bottomLeft, y: bounds.maxY - radii.bottomLeft),
            radius: radii.bottomLeft, startAngle: 0.5 * .pi, endAngle: .pi, clockwise: true
        )
        path.close()
        return path
    }
}

// MARK: - Reply-swipe gesture arbitration

extension MessageCell: UIGestureRecognizerDelegate {
    /// Begin the reply pan only for a clearly horizontal, leftward drag, so
    /// vertical (and rightward) gestures fall straight through to the
    /// collection view's scrolling.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === replyPan else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        let velocity = replyPan.velocity(in: self)
        return abs(velocity.x) > abs(velocity.y) && velocity.x < 0
    }

    /// Track alongside the collection view's scroll pan so it never cancels the
    /// swipe mid-drag (the two never move together — one is horizontal-left,
    /// the other vertical).
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
