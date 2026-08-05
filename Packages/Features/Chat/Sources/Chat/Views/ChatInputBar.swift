import DesignSystem
import UIKit

/// Telegram-style compose bar: a round glass media button, a floating Liquid
/// Glass capsule field that grows with its text (up to `maxLines`), and a
/// round send button. It owns no keyboard logic — the hosting controller
/// docks it by pinning its bottom to `view.keyboardLayoutGuide.topAnchor`.
final class ChatInputBar: UIView {
    /// Fired with trimmed, non-empty text; the field clears itself first.
    var onSend: ((String) -> Void)?
    /// Fired by the media (+) button; media composition is the host's affair.
    var onAttachMedia: (() -> Void)?
    /// Fired by the trailing mic button when the field is empty; voice capture
    /// is the host's affair, the same way media composition is.
    var onRecordVoice: (() -> Void)?
    /// Fired by the reply preview's close control — the host cancels the reply.
    var onCancelReply: (() -> Void)?

    /// Disables sending while a message is in flight (spinner in the button).
    var isSending = false {
        didSet { updateActionButton() }
    }

    private enum Metrics {
        static let maxLines: CGFloat = 5
        static let controlSize: CGFloat = 38
    }

    // Reply preview: the "Replying to …" accessory that grows in above the
    // compose row when a reply is active. `replyPreview` is a height-toggled
    // container (collapsed to 0 at rest, so a plain composer is unchanged);
    // `replyGlass` is the signature Liquid Glass banner it hosts, inset from
    // the container bottom so it doesn't kiss the compose field below.
    private let replyPreview = UIView()
    private let replyGlass = UIVisualEffectView(effect: nil)
    private let replyQuoteView = QuotedReplyView()
    private let replyCloseButton = UIButton(configuration: .plain())
    private var replyCollapsed: NSLayoutConstraint!

    /// What the trailing round button does right now. With text present it
    /// sends; with the field empty it offers voice capture (nothing to send, so
    /// a send glyph would be a dead control) — the button morphs between the
    /// two as the text changes. Focus is deliberately NOT part of this: an
    /// empty composer offers the mic whether or not the keyboard is up, so the
    /// glyph never flickers as the keyboard comes and goes. The keyboard is
    /// dismissed by tapping or dragging the transcript instead.
    private enum ActionMode { case send, voice }
    private var actionMode: ActionMode = .voice

    // Effect set on window attach: materializing one in init contacts the
    // render server and stalls headless CI simulators (see ci memory).
    private let field = UIVisualEffectView(effect: nil)
    private let textView = UITextView()
    private let placeholderLabel = UILabel()
    private let mediaButton = UIButton(configuration: .glass())
    private let sendButton = UIButton(configuration: .prominentGlass())
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

        placeholderLabel.text = "Message"
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

        // The native bubble-glass token, not a hand-rolled layer radius: the
        // corner configuration drives the glass shape itself, so the caps
        // stay circular at one line (capsule bound at the resting height),
        // hold that radius as the field grows, and keep the effect's own
        // crisp boundary refraction.
        field.clipsToBounds = true
        field.cornerConfiguration = .capsule(maximumRadius: Metrics.controlSize / 2)

        mediaButton.configuration?.image = UIImage(
            systemName: "plus",
            withConfiguration: UIImage.SymbolConfiguration(weight: .semibold)
        )
        mediaButton.configuration?.cornerStyle = .capsule
        mediaButton.addAction(UIAction { [weak self] _ in self?.onAttachMedia?() }, for: .primaryActionTriggered)

        // Starts in the resting (empty-field) mode, matching `actionMode`.
        applyButtonStyle(for: .voice)
        sendButton.addAction(UIAction { [weak self] _ in self?.actionTapped() }, for: .primaryActionTriggered)

        configureReplyPreview()

        addSubview(mediaButton)
        addSubview(field)
        addSubview(sendButton)
        mediaButton.translatesAutoresizingMaskIntoConstraints = false
        field.translatesAutoresizingMaskIntoConstraints = false
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        fieldHeight = field.heightAnchor.constraint(equalToConstant: Metrics.controlSize)
        // Both round controls anchor to the BOTTOM edge: the field grows
        // upward from the shared baseline, the buttons hold their station.
        // The field owns all flexible width — the buttons are fixed boxes —
        // so adding the media control narrows the field by exactly one slot
        // and never squeezes the text run mid-line.
        NSLayoutConstraint.activate([
            fieldHeight,
            mediaButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            mediaButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            mediaButton.widthAnchor.constraint(equalToConstant: Metrics.controlSize),
            mediaButton.heightAnchor.constraint(equalToConstant: Metrics.controlSize),
            field.leadingAnchor.constraint(equalTo: mediaButton.trailingAnchor, constant: Spacing.sm),
            // The compose row sits below the reply preview; when the preview is
            // collapsed (height 0) this lands the field flush at the top edge,
            // so a plain composer is unchanged.
            field.topAnchor.constraint(equalTo: replyPreview.bottomAnchor),
            field.bottomAnchor.constraint(equalTo: bottomAnchor),
            sendButton.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: Spacing.sm),
            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            sendButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: Metrics.controlSize),
            sendButton.heightAnchor.constraint(equalToConstant: Metrics.controlSize)
        ])

        updateActionButton()
        updateFieldHeight()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Reply preview

    private func configureReplyPreview() {
        // The container must NOT clip: clipping it to its rectangle would cut
        // the glass pill's soft rounded shadow into a hard rectangular box.
        // Content is hidden on collapse by `replyGlass`'s own clip (below), so
        // the container stays a pure, invisible layout frame — like the field,
        // which floats cleanly with no wrapping clip of its own. Opacity is
        // driven HERE (on the container), never on the glass effect view — so
        // the glass renders once at full strength and its shadow can't glitch
        // mid-fade. Starts transparent (collapsed anyway) for a clean first show.
        replyPreview.alpha = 0

        // Signature Liquid Glass, matching the compose field: the shape is
        // driven by the corner configuration (not a layer radius) so the glass
        // keeps its edge refraction, and the effect is materialized on window
        // attach (see `didMoveToWindow`) — building one in init contacts the
        // render server and stalls headless CI simulators.
        replyGlass.clipsToBounds = true
        replyGlass.cornerConfiguration = .capsule(maximumRadius: Metrics.controlSize / 2)

        replyQuoteView.tint(accent: .systemBlue, author: .systemBlue, snippet: .secondaryLabel)

        replyCloseButton.configuration?.image = UIImage(systemName: "xmark.circle.fill")
        replyCloseButton.configuration?.baseForegroundColor = .secondaryLabel
        replyCloseButton.configuration?.contentInsets = .zero
        replyCloseButton.accessibilityLabel = "Cancel Reply"
        replyCloseButton.addAction(UIAction { [weak self] _ in self?.onCancelReply?() }, for: .primaryActionTriggered)

        let content = replyGlass.contentView
        for subview in [replyQuoteView, replyCloseButton] {
            content.addSubview(subview)
            subview.translatesAutoresizingMaskIntoConstraints = false
        }

        replyPreview.addSubview(replyGlass)
        replyGlass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(replyPreview)
        replyPreview.translatesAutoresizingMaskIntoConstraints = false

        replyCollapsed = replyPreview.heightAnchor.constraint(equalToConstant: 0)
        replyCollapsed.isActive = true

        // Content top/bottom define the glass banner's height; kept below
        // `required` so the collapse constraint wins cleanly while it's active.
        let contentTop = replyQuoteView.topAnchor.constraint(equalTo: content.topAnchor, constant: Spacing.sm)
        let contentBottom = replyQuoteView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Spacing.sm)
        contentTop.priority = .defaultHigh
        contentBottom.priority = .defaultHigh

        NSLayoutConstraint.activate([
            replyPreview.topAnchor.constraint(equalTo: topAnchor),
            replyPreview.leadingAnchor.constraint(equalTo: leadingAnchor),
            replyPreview.trailingAnchor.constraint(equalTo: trailingAnchor),

            // Glass fills the container but stops a hair above the field, so the
            // two glass pills read as distinct elements instead of pinching.
            replyGlass.topAnchor.constraint(equalTo: replyPreview.topAnchor),
            replyGlass.leadingAnchor.constraint(equalTo: replyPreview.leadingAnchor),
            replyGlass.trailingAnchor.constraint(equalTo: replyPreview.trailingAnchor),
            replyGlass.bottomAnchor.constraint(equalTo: replyPreview.bottomAnchor, constant: -Spacing.xs),

            contentTop,
            contentBottom,
            // Inset from the rounded glass edges so nothing clips into a corner.
            replyQuoteView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Spacing.md),

            replyCloseButton.leadingAnchor.constraint(equalTo: replyQuoteView.trailingAnchor, constant: Spacing.sm),
            replyCloseButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Spacing.md),
            replyCloseButton.centerYAnchor.constraint(equalTo: replyQuoteView.centerYAnchor),
            replyCloseButton.widthAnchor.constraint(equalToConstant: 24),
            replyCloseButton.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    /// Focuses the composer — used when a reply begins, so the keyboard rises
    /// with the preview (Messages behavior).
    func focus() { textView.becomeFirstResponder() }


    /// Seeds the composer with text the user has not typed — today, a profile
    /// link carried in from the share sheet. Deliberately NOT sent
    /// automatically: the message is theirs to review, edit, or abandon, and a
    /// tap in a share sheet is not consent to post something in a thread.
    /// Runs the same state sync a keystroke would, so the field grows and Send
    /// enables exactly as if it had been typed.
    func setDraftText(_ text: String) {
        guard !text.isEmpty else { return }
        textView.text = text
        textViewDidChange(textView)
    }

    /// Shows (or updates) the "Replying to …" preview, growing it in when it
    /// wasn't already visible. The host pins the collection inset off this
    /// bar's frame, so the transcript reflows as the bar grows.
    func setReplyContext(author: String, snippet: String) {
        replyQuoteView.setContent(author: author, snippet: snippet)
        let wasCollapsed = replyCollapsed.isActive
        replyCollapsed.isActive = false
        // Already visible (content-only update) or off-window: show at once.
        guard wasCollapsed, window != nil else {
            replyPreview.alpha = 1
            superview?.layoutIfNeeded()
            return
        }
        // Pure fade-in: the container takes its FINAL height immediately (a
        // non-animated layout pass), so the glass and its interior never
        // stretch or shift. Then animate opacity on the PLAIN CONTAINER, never
        // on `replyGlass` itself — animating a UIVisualEffectView's own alpha
        // makes UIKit recompute its glass/shadow compositing every frame (the
        // shadow-box glitch that pops at the end). The container has no effect
        // or shadow, so a group-opacity fade there is clean while the glass
        // renders once at full strength (`replyGlass.alpha` stays 1).
        replyPreview.alpha = 0
        superview?.layoutIfNeeded()
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut]) {
            self.replyPreview.alpha = 1
        }
    }

    /// Collapses the reply preview back out of the bar. Fades the glass out in
    /// place FIRST (a height collapse under a visible pill reads as an awkward
    /// vertical squash), then collapses the now-invisible height so the compose
    /// field slides up cleanly.
    func clearReplyContext() {
        guard !replyCollapsed.isActive else { return }
        guard window != nil else {
            replyPreview.alpha = 0
            replyCollapsed.isActive = true
            superview?.layoutIfNeeded()
            return
        }
        // Fade the PLAIN CONTAINER, not the glass effect view (same shadow-safe
        // reason as `setReplyContext`).
        UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut]) {
            self.replyPreview.alpha = 0
        } completion: { _ in
            self.replyCollapsed.isActive = true
            UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseInOut]) {
                self.superview?.layoutIfNeeded()
            }
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        // Both glass surfaces are materialized here, not in init (render-server
        // stall on headless CI sims); each gets its own effect instance.
        if field.effect == nil { field.effect = UIGlassEffect() }
        if replyGlass.effect == nil { replyGlass.effect = UIGlassEffect() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateFieldHeight()
    }

    /// Routes the trailing button to whatever its current mode means.
    private func actionTapped() {
        switch actionMode {
        case .send: sendTapped()
        case .voice: onRecordVoice?()
        }
    }

    /// Drops text — today a favorite sticker's emoji — into the composer rather
    /// than sending it outright: the message is the user's to review, extend,
    /// or abandon, the same rule `setDraftText` follows for shared links. The
    /// Send button lighting up blue is the receipt that the tap landed.
    ///
    /// Inserts at the caret while the composer is focused and appends
    /// otherwise: an unfocused text view reports a stale zero-length selection
    /// at the start, which would file the sticker in front of text already
    /// typed. Ends by running the same sync a keystroke would, so the field
    /// grows and the button morphs exactly as if it had been typed.
    func insertIntoComposer(_ text: String) {
        let current = textView.text ?? ""
        if textView.isFirstResponder, let caret = Range(textView.selectedRange, in: current) {
            textView.text = current.replacingCharacters(in: caret, with: text)
            let location = textView.selectedRange.location + (text as NSString).length
            textView.selectedRange = NSRange(location: location, length: 0)
        } else {
            textView.text = current + text
        }
        textViewDidChange(textView)
    }

    private func sendTapped() {
        let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        textView.text = ""
        textViewDidChange(textView)
        onSend?(text)
    }

    private static func actionImage(for mode: ActionMode) -> UIImage? {
        let symbol = mode == .send ? "arrow.up" : "mic.fill"
        return UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(weight: .semibold)
        )
    }

    /// Rebuilds the trailing button's Liquid-Glass configuration for a mode:
    /// a prominent blue fill + white glyph to send; the plain clear-glass
    /// material (no color fill) for the mic — with nothing to send the control
    /// recedes into the bar and reads as a peer of the leading `+`, so the blue
    /// fill stays reserved for "there is a message waiting to go".
    /// `UIView.transition` wrapping this call cross-dissolves the glyph AND the
    /// material together.
    private func applyButtonStyle(for mode: ActionMode) {
        sendButton.accessibilityLabel = mode == .send ? "Send" : "Record Voice Message"
        switch mode {
        case .send:
            var config = UIButton.Configuration.prominentGlass()
            config.cornerStyle = .capsule
            config.image = Self.actionImage(for: mode)
            config.baseBackgroundColor = .systemBlue
            config.baseForegroundColor = .white
            sendButton.configuration = config
        case .voice:
            var config = UIButton.Configuration.glass()
            config.cornerStyle = .capsule
            config.image = Self.actionImage(for: mode)
            sendButton.configuration = config
        }
    }

    /// Resolves the button's mode from the text alone, cross-dissolving the
    /// glyph and background when the mode flips, and setting the spinner +
    /// enablement per mode:
    ///  - text present → Send (enabled while not in flight)
    ///  - empty → Voice record (live, keyboard up or down)
    private func updateActionButton() {
        let hasText = !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let newMode: ActionMode = hasText ? .send : .voice

        if newMode != actionMode {
            actionMode = newMode
            UIView.transition(
                with: sendButton, duration: 0.2,
                options: [.transitionCrossDissolve, .allowUserInteraction]
            ) {
                self.applyButtonStyle(for: newMode)
            }
        }

        // Spinner + enablement change more often than the mode (every keystroke,
        // every in-flight toggle), so drive them directly — no re-dissolve.
        sendButton.configuration?.showsActivityIndicator = isSending && newMode == .send
        switch newMode {
        case .send: sendButton.isEnabled = hasText && !isSending
        case .voice: sendButton.isEnabled = !isSending
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

extension ChatInputBar: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        placeholderLabel.isHidden = textView.hasText
        updateActionButton()
        updateFieldHeight()
    }

}
