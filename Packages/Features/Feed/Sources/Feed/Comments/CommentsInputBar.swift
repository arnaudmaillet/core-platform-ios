import DesignSystem
import UIKit

/// The comments composer, in the app's native Liquid Glass grammar —
/// deliberately the SAME recipe as Private Messages' `ChatInputBar`
/// (features don't import each other, so the recipe is replicated, not the
/// class): a floating glass capsule field that grows with its text, and a
/// round prominent-glass send button sharing its bottom baseline. It owns
/// no keyboard logic — the host pins its bottom to
/// `view.keyboardLayoutGuide.topAnchor`.
final class CommentsInputBar: UIView {
    /// Fired with trimmed, non-empty text; the field clears itself first.
    var onSend: ((String) -> Void)?
    /// Fired by the media (+) button; media composition is the host's affair
    /// (the chat bar's contract, verbatim).
    var onAttachMedia: (() -> Void)?
    /// Fired by the close button (shown in the send slot while the field is
    /// empty). Wiring this ENABLES the close/send toggle — hosts that leave
    /// it nil (the pushed comments screen) keep a permanent send button.
    var onClose: (() -> Void)? {
        didSet { updateTrailingButtons(animated: false) }
    }
    /// A decisive vertical swipe anywhere on the bar (field, buttons, gaps):
    /// the engaged context's swipe exit. Direction is +1 for an upward
    /// swipe (next post), -1 downward (previous). The bar OWNS this pan
    /// because the feed pager cannot reliably wrest a drag from the
    /// text-input stack (empirically: neither cancellation opt-in nor
    /// arbitration passthrough gets the pager's pan going here) — so the
    /// bar detects the gesture and the host pages programmatically.
    var onSwipeExit: ((Int) -> Void)?

    /// Disables sending while a comment is in flight (spinner in the button).
    var isSending = false {
        didSet {
            sendButton.configuration?.showsActivityIndicator = isSending
            updateTrailingButtons(animated: false)
        }
    }

    private enum Metrics {
        static let maxLines: CGFloat = 4
        static let controlSize: CGFloat = 38
    }

    // Effect set on window attach: materializing one in init contacts the
    // render server and stalls headless CI simulators (see ci memory).
    private let field = UIVisualEffectView(effect: nil)
    private let textView = UITextView()
    private let placeholderLabel = UILabel()
    private let mediaButton = UIButton(configuration: .glass())
    private let sendButton = UIButton(configuration: .prominentGlass())
    /// The send slot's resting occupant while the field is empty (and a
    /// close handler is wired): tapping it collapses the engagement. Send
    /// and close share one slot and crossfade as typing starts/stops.
    private let closeButton = UIButton(configuration: .glass())
    private var fieldHeight: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)

        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainerInset = UIEdgeInsets(top: Spacing.sm, left: Spacing.sm, bottom: Spacing.sm, right: Spacing.sm)
        textView.delegate = self
        textView.pin(to: field.contentView)

        placeholderLabel.text = "Add a comment…"
        placeholderLabel.font = textView.font
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.constrain(in: field.contentView) { parent in
            placeholderLabel.leadingAnchor.constraint(
                equalTo: parent.leadingAnchor,
                constant: Spacing.sm + textView.textContainer.lineFragmentPadding
            )
            placeholderLabel.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }

        // The native bubble-glass token (the chat bar's exact contract):
        // the corner configuration drives the glass shape itself, so the
        // caps stay circular at one line, hold that radius as the field
        // grows, and keep the effect's own crisp boundary refraction.
        field.clipsToBounds = true
        field.cornerConfiguration = .capsule(maximumRadius: Metrics.controlSize / 2)

        mediaButton.configuration?.image = UIImage(
            systemName: "plus",
            withConfiguration: UIImage.SymbolConfiguration(weight: .semibold)
        )
        mediaButton.configuration?.cornerStyle = .capsule
        mediaButton.addAction(UIAction { [weak self] _ in self?.onAttachMedia?() }, for: .primaryActionTriggered)

        sendButton.configuration?.image = UIImage(
            systemName: "arrow.up",
            withConfiguration: UIImage.SymbolConfiguration(weight: .semibold)
        )
        sendButton.configuration?.cornerStyle = .capsule
        sendButton.addAction(UIAction { [weak self] _ in self?.sendTapped() }, for: .primaryActionTriggered)

        closeButton.configuration?.image = UIImage(
            systemName: "xmark",
            withConfiguration: UIImage.SymbolConfiguration(weight: .semibold)
        )
        closeButton.configuration?.cornerStyle = .capsule
        closeButton.accessibilityLabel = "Close comments"
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .primaryActionTriggered)

        addSubview(mediaButton)
        addSubview(field)
        addSubview(sendButton)
        addSubview(closeButton)
        mediaButton.translatesAutoresizingMaskIntoConstraints = false
        field.translatesAutoresizingMaskIntoConstraints = false
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        fieldHeight = field.heightAnchor.constraint(equalToConstant: Metrics.controlSize)
        // Bottom-baseline anchoring: the field grows upward, the round
        // controls hold their stations; the field owns all flexible width.
        // Send and close OVERLAY the same trailing slot (they crossfade).
        NSLayoutConstraint.activate([
            fieldHeight,
            mediaButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            mediaButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            mediaButton.widthAnchor.constraint(equalToConstant: Metrics.controlSize),
            mediaButton.heightAnchor.constraint(equalToConstant: Metrics.controlSize),
            field.leadingAnchor.constraint(equalTo: mediaButton.trailingAnchor, constant: Spacing.sm),
            field.topAnchor.constraint(equalTo: topAnchor),
            field.bottomAnchor.constraint(equalTo: bottomAnchor),
            sendButton.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: Spacing.sm),
            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            sendButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: Metrics.controlSize),
            sendButton.heightAnchor.constraint(equalToConstant: Metrics.controlSize),
            closeButton.centerXAnchor.constraint(equalTo: sendButton.centerXAnchor),
            closeButton.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: Metrics.controlSize),
            closeButton.heightAnchor.constraint(equalToConstant: Metrics.controlSize),
        ])

        updateTrailingButtons(animated: false)
        updateFieldHeight()

        // Vertical-intent pan for the swipe exit (the rail's begin rule:
        // vertical wins, horizontal/taps pass through untouched).
        swipeRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
        addGestureRecognizer(swipeRecognizer!)
    }

    private var swipeRecognizer: UIPanGestureRecognizer?

    /// Vertical-intent gate for the swipe-exit pan only; every other
    /// recognizer keeps UIKit's default answer.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === swipeRecognizer,
              let pan = gestureRecognizer as? UIPanGestureRecognizer else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        let velocity = pan.velocity(in: self)
        return abs(velocity.y) > abs(velocity.x)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func handleSwipe(_ pan: UIPanGestureRecognizer) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-gesture-log") {
            print("GESTURELOG: bar pan state=\(pan.state.rawValue) dy=\(pan.translation(in: self).y) vy=\(pan.velocity(in: self).y) wired=\(onSwipeExit != nil)")
        }
        #endif
        guard pan.state == .ended, onSwipeExit != nil else { return }
        let dy = pan.translation(in: self).y
        let vy = pan.velocity(in: self).y
        guard abs(dy) > 50 || abs(vy) > 300 else { return }
        onSwipeExit?((dy + vy) < 0 ? 1 : -1)
    }

    #if DEBUG
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if ProcessInfo.processInfo.arguments.contains("-gesture-log"), let touch = touches.first {
            print("GESTURELOG: bar touchesBegan at \(touch.location(in: self))")
        }
        super.touchesBegan(touches, with: event)
    }
    #endif

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, field.effect == nil {
            field.effect = UIGlassEffect()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateFieldHeight()
    }

    private func sendTapped() {
        let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        textView.text = ""
        textViewDidChange(textView)
        onSend?(text)
    }

    /// The trailing slot's toggle: CLOSE while the field is empty (and a
    /// close handler is wired), SEND once typing starts or a submission is
    /// in flight — swapped as a short crossfade, never a pop.
    private func updateTrailingButtons(animated: Bool) {
        let hasText = !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendButton.isEnabled = hasText && !isSending
        let showsSend = onClose == nil || hasText || isSending
        let apply = {
            self.sendButton.alpha = showsSend ? 1 : 0
            self.closeButton.alpha = showsSend ? 0 : 1
        }
        sendButton.isUserInteractionEnabled = showsSend
        closeButton.isUserInteractionEnabled = !showsSend
        if animated {
            UIView.animate(withDuration: 0.15, animations: apply)
        } else {
            apply()
        }
    }

    /// Grows the field with its content up to `maxLines`, then hands the
    /// overflow to the text view's own scrolling.
    private func updateFieldHeight() {
        guard textView.bounds.width > 0 else { return }
        let insets = textView.textContainerInset
        let lineHeight = textView.font?.lineHeight ?? UIFont.preferredFont(forTextStyle: .body).lineHeight
        let maxHeight = ceil(lineHeight * Metrics.maxLines) + insets.top + insets.bottom
        let fitting = textView.sizeThatFits(
            CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)
        ).height
        let target = min(max(ceil(fitting), Metrics.controlSize), maxHeight)

        let scrolls = fitting > maxHeight
        if textView.isScrollEnabled != scrolls { textView.isScrollEnabled = scrolls }
        if fieldHeight.constant != target { fieldHeight.constant = target }
    }
}

extension CommentsInputBar: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        placeholderLabel.isHidden = textView.hasText
        updateTrailingButtons(animated: true)
        updateFieldHeight()
    }
}
