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
    /// One phase of an interactive vertical page-swipe born on the bar.
    enum PageSwipePhase { case began, changed, ended }
    /// A vertical drag anywhere on the bar (field, buttons, gaps) drives the
    /// feed pager INTERACTIVELY — the bar forwards the raw translation and
    /// velocity, and the host offsets the parent scroll view in real time
    /// (the finger-linked page drag), settling on release. The bar OWNS the
    /// pan because the feed pager cannot wrest a drag from the text-input
    /// stack (empirically: neither cancellation opt-in nor arbitration
    /// passthrough starts the pager's own pan here) — so the bar detects it
    /// and the host drives `contentOffset` directly. `translation`/
    /// `velocity` are the pan's vertical components; up (negative) pages to
    /// the next post. Wiring this ENABLES the drive; hosts that leave it nil
    /// (the pushed comments screen) have no page-swipe.
    var onPageSwipe: ((PageSwipePhase, _ translation: CGFloat, _ velocity: CGFloat) -> Void)?

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
    /// The trailing slot's UTILITY face (send's overlay partner): a
    /// keyboard-state morphing control. Keyboard closed → the close ✕
    /// (collapses the engagement); keyboard open with an empty field →
    /// the dismiss-keyboard chevron (retires the keyboard, engagement
    /// untouched). Send takes the slot only while there is text to send
    /// (or a submission in flight).
    private let closeButton = UIButton(configuration: .glass())
    /// Whether the keyboard is up — the third axis of the trailing
    /// toggle, driven by the keyboardWillShow/Hide notifications (the
    /// engaged bar is the screen's only text input, so the global signal
    /// is unambiguous). Internal setter for tests: the state machine is
    /// unit-tested without driving a real keyboard.
    private(set) var isKeyboardOpen = false
    /// Which glyph the utility button currently wears (avoids re-running
    /// the crossfade transition on every unrelated update).
    private var utilityShowsKeyboardDismiss = false
    /// Removes the keyboard observers on release — a nonisolated deinit
    /// cannot touch main-actor state, so the tokens live in a bag whose
    /// own deinit does the unregistering (the VC-side pattern).
    private let keyboardObservers = NotificationObserverTokenBag()
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
        sendButton.accessibilityLabel = "Send comment"
        sendButton.addAction(UIAction { [weak self] _ in self?.sendTapped() }, for: .primaryActionTriggered)

        closeButton.configuration?.image = UIImage(
            systemName: "xmark",
            withConfiguration: UIImage.SymbolConfiguration(weight: .semibold)
        )
        closeButton.configuration?.cornerStyle = .capsule
        closeButton.accessibilityLabel = "Close comments"
        closeButton.addAction(UIAction { [weak self] _ in self?.utilityTapped() }, for: .primaryActionTriggered)

        // The keyboard axis of the trailing toggle: the utility face
        // morphs ✕ ↔ dismiss-keyboard as the keyboard comes and goes.
        keyboardObservers.tokens = [
            NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.setKeyboardOpen(true) }
            },
            NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.setKeyboardOpen(false) }
            },
        ]

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

    /// The nudge's damped, saturating displacement: near-1:1 for the first
    /// few points, asymptotic to ±40 — the bar feels physically attached
    /// to the finger without ever leaving its band. Pure, for tests.
    static func nudgeOffset(for translation: CGFloat) -> CGFloat {
        40 * CGFloat(tanh(Double(translation) / 80))
    }

    @objc private func handleSwipe(_ pan: UIPanGestureRecognizer) {
        // No drive on the pushed screen (no page-swipe), and NOT while the
        // keyboard is up — a downward drag there is a keyboard dismissal,
        // not a page change (the list's interactive dismiss handles that).
        guard onPageSwipe != nil, !isKeyboardOpen else { return }
        let dy = pan.translation(in: self).y
        let vy = pan.velocity(in: self).y
        switch pan.state {
        case .began:
            // The whole engaged layer (media card, comments, THIS bar — all
            // in the leaving cell) rides the pager's contentOffset from
            // here on; the bar no longer self-nudges (that would double the
            // motion).
            onPageSwipe?(.began, 0, 0)
        case .changed:
            onPageSwipe?(.changed, dy, vy)
        case .ended:
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-gesture-log") {
                print("GESTURELOG: bar page-swipe ended dy=\(dy) vy=\(vy)")
            }
            #endif
            onPageSwipe?(.ended, dy, vy)
        case .cancelled, .failed:
            onPageSwipe?(.ended, dy, vy) // release: the host settles back
        default:
            break
        }
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

    /// The field's current draft. Internal for tests (the trailing state
    /// machine is exercised without a real keyboard) and any future draft
    /// restoration; routes through the delegate path so the toggle and
    /// the field height stay honest.
    var draftText: String {
        get { textView.text ?? "" }
        set {
            textView.text = newValue
            textViewDidChange(textView)
        }
    }

    /// The utility face's tap: with the keyboard up it ONLY retires the
    /// keyboard (the engagement stays); with it down, it collapses the
    /// engagement. One slot, one thumb position, state-appropriate intent.
    private func utilityTapped() {
        if isKeyboardOpen {
            textView.resignFirstResponder()
        } else {
            onClose?()
        }
    }

    /// The keyboard seam behind the notification observers. Internal (not
    /// private) so the three-state trailing machine is unit-testable
    /// without driving a real keyboard.
    func setKeyboardOpen(_ open: Bool) {
        guard open != isKeyboardOpen else { return }
        isKeyboardOpen = open
        updateTrailingButtons(animated: true)
        // An idle dismissal (keyboard retired over an empty field) resets
        // any armed reply state — the host clears its target so a later
        // composition starts top-level, not silently bound to a thread.
        if !open, textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onIdleDismiss?()
        }
    }

    /// Fired when the keyboard retires over an EMPTY field — the reply
    /// state's natural exit (a draft in progress keeps its target).
    var onIdleDismiss: (() -> Void)?

    /// The reply state's face: a non-nil name switches the placeholder to
    /// "Reply to NAME…"; nil restores the default prompt. Pure placeholder
    /// — the reply payload (the thread parent's id) is the HOST's state.
    func setReplyPlaceholder(name: String?) {
        placeholderLabel.text = name.map { "Reply to \($0)…" } ?? "Add a comment…"
    }

    /// Raises the keyboard into the composer — the row-tap reply trigger.
    func focusComposer() {
        textView.becomeFirstResponder()
    }

    /// The trailing slot's three-state toggle (when a close handler is
    /// wired — the pushed screen keeps its permanent send):
    ///   keyboard CLOSED            → ✕ (collapse the engagement)
    ///   keyboard OPEN, field empty → dismiss-keyboard chevron
    ///   keyboard OPEN, has text    → send (also while a send is in flight)
    /// Swapped as short crossfades — the slot swap animates alpha, the
    /// utility face's glyph swap is its own cross-dissolve — never a pop.
    private func updateTrailingButtons(animated: Bool) {
        let hasText = !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendButton.isEnabled = hasText && !isSending
        let showsSend = onClose == nil || isSending || (hasText && isKeyboardOpen)
        let apply = {
            self.sendButton.alpha = showsSend ? 1 : 0
            self.closeButton.alpha = showsSend ? 0 : 1
        }
        sendButton.isUserInteractionEnabled = showsSend
        closeButton.isUserInteractionEnabled = !showsSend

        let wantsKeyboardDismiss = isKeyboardOpen && onClose != nil
        if wantsKeyboardDismiss != utilityShowsKeyboardDismiss {
            utilityShowsKeyboardDismiss = wantsKeyboardDismiss
            let swapGlyph = {
                self.closeButton.configuration?.image = UIImage(
                    systemName: wantsKeyboardDismiss ? "keyboard.chevron.compact.down" : "xmark",
                    withConfiguration: UIImage.SymbolConfiguration(weight: .semibold)
                )
                self.closeButton.accessibilityLabel =
                    wantsKeyboardDismiss ? "Dismiss keyboard" : "Close comments"
            }
            if animated {
                UIView.transition(
                    with: closeButton, duration: 0.15,
                    options: [.transitionCrossDissolve, .allowUserInteraction],
                    animations: swapGlyph
                )
            } else {
                swapGlyph()
            }
        }

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

/// Holds notification tokens and unregisters them on its own deallocation
/// (when the owning bar is released). `@unchecked Sendable` so its `deinit`
/// may run off the main actor; `removeObserver` is itself thread-safe, and
/// the tokens are only mutated on the main actor at setup time.
private final class NotificationObserverTokenBag: @unchecked Sendable {
    var tokens: [NSObjectProtocol] = []
    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}
