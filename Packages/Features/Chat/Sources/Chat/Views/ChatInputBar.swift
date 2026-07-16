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

    /// Disables sending while a message is in flight (spinner in the button).
    var isSending = false {
        didSet {
            sendButton.configuration?.showsActivityIndicator = isSending
            updateSendButton()
        }
    }

    private enum Metrics {
        static let maxLines: CGFloat = 5
        static let controlSize: CGFloat = 38
    }

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

        sendButton.configuration?.image = UIImage(
            systemName: "arrow.up",
            withConfiguration: UIImage.SymbolConfiguration(weight: .semibold)
        )
        sendButton.configuration?.cornerStyle = .capsule
        sendButton.addAction(UIAction { [weak self] _ in self?.sendTapped() }, for: .primaryActionTriggered)

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
            field.topAnchor.constraint(equalTo: topAnchor),
            field.bottomAnchor.constraint(equalTo: bottomAnchor),
            sendButton.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: Spacing.sm),
            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            sendButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: Metrics.controlSize),
            sendButton.heightAnchor.constraint(equalToConstant: Metrics.controlSize)
        ])

        updateSendButton()
        updateFieldHeight()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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

    private func updateSendButton() {
        let hasText = !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendButton.isEnabled = hasText && !isSending
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
        updateSendButton()
        updateFieldHeight()
    }
}
