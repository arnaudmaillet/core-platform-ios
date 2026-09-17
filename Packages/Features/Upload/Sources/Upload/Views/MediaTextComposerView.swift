import DesignSystem
import MediaPlayback
import UIKit

/// Where the words of a text overlay are typed: the editor dimmed, the words in
/// the middle in the style they will wear, the style bar over the keyboard.
///
/// ```
/// ┌──────────────────────────┐
/// │░░░░░░░░░░░░░░░░░░░ Done ░│
/// │░░░░░░░░░░░░░░░░░░░░░░░░░░│
/// │░░░░░░ Hello there ░░░░░░░│
/// │[≡][A̲] Classic Rounded … ●│
/// │ q w e r t y u i o p      │
/// └──────────────────────────┘
/// ```
///
/// ⚠️ **A VIEW OVER THE EDITOR, NOT A PRESENTED SCREEN.** The editor already
/// sits in a sheet; presenting over it would stack a second sheet whose
/// dismissal pan competes with the first, and the canvas lock
/// (`isModalInPresentation`) belongs to the editor's navigation controller,
/// not to a new one. A dimmed view inside the same screen needs neither.
///
/// ⚠️ **THE WORDS FOLLOW THE KEYBOARD THROUGH `keyboardLayoutGuide`.** The
/// simulator this repo tests on usually hides the software keyboard; the guide
/// then sits at the foot of the view, and the words stay centred in the whole
/// screen — which is also what a hardware keyboard gives on a device.
@MainActor
final class MediaTextComposerView: UIView, UITextViewDelegate {
    /// Called once, when the author is done, with what they typed and how it is
    /// dressed. Empty words are the caller's to turn into "remove it".
    var onFinish: ((TextOverlay) -> Void)?

    private(set) var style = TextOverlay.fresh
    let textView = UITextView()
    let styleBar = MediaTextStyleBar(frame: CGRect(x: 0, y: 0, width: 390, height: MediaTextStyleBar.height))
    private let doneButton = UIButton(type: .system)
    /// The page's picture width in points, which the words are sized against
    /// — so what is typed is the size it lands on the picture.
    private var mediaWidth: CGFloat = 375
    private var isFinished = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.55)
        accessibilityViewIsModal = true

        var done = UIButton.Configuration.filled()
        done.title = "Done"
        done.baseBackgroundColor = .white
        done.baseForegroundColor = .black
        done.cornerStyle = .capsule
        doneButton.configuration = done
        doneButton.addAction(UIAction { [weak self] _ in self?.finish() }, for: .touchUpInside)
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(doneButton)

        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainerInset = UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        textView.layer.cornerRadius = 10
        textView.layer.cornerCurve = .continuous
        textView.tintColor = .white
        textView.keyboardAppearance = .dark
        textView.autocorrectionType = .default
        textView.accessibilityLabel = "Text"
        textView.delegate = self
        textView.inputAccessoryView = styleBar
        textView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textView)

        // ⚠️ **BETWEEN THE BUTTON AND THE KEYBOARD, CENTRED IN WHAT IS LEFT.**
        // The words may be many lines; they are held under the button and over
        // the keyboard, and centred between the two while they fit.
        let above = UILayoutGuide()
        addLayoutGuide(above)
        NSLayoutConstraint.activate([
            doneButton.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: Spacing.sm),
            doneButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.lg),
            doneButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            above.topAnchor.constraint(equalTo: doneButton.bottomAnchor, constant: Spacing.sm),
            above.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor, constant: -Spacing.sm),
            textView.centerYAnchor.constraint(equalTo: above.centerYAnchor).withPriority(.defaultHigh),
            textView.topAnchor.constraint(greaterThanOrEqualTo: above.topAnchor),
            textView.bottomAnchor.constraint(lessThanOrEqualTo: above.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.xl),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.xl)
        ])

        styleBar.onChange = { [weak self] style in
            guard let self else { return }
            self.style.font = style.font
            self.style.colour = style.colour
            self.style.background = style.background
            self.style.alignment = style.alignment
            dress()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Opens on `text`, dressed as it is, sized for a picture `mediaWidth`
    /// points wide.
    func begin(with text: TextOverlay, mediaWidth: CGFloat) {
        style = text
        self.mediaWidth = max(mediaWidth, 1)
        isFinished = false
        styleBar.show(text)
        textView.text = text.text
        dress()
        textView.becomeFirstResponder()
    }

    /// "Done": hands the words over once, and lets the keyboard go.
    func finish() {
        guard !isFinished else { return }
        isFinished = true
        style.text = textView.text ?? ""
        textView.resignFirstResponder()
        onFinish?(style)
    }

    func textViewDidChange(_ textView: UITextView) {
        style.text = textView.text ?? ""
        dress()
    }

    /// Puts the style on the words being typed.
    ///
    /// ⚠️ **HIGHLIGHT IS A PER-CHARACTER BACKGROUND WHILE TYPING, AND THAT IS AN
    /// ACCEPTED DIFFERENCE.** The canvas draws rounded bands behind each line;
    /// a text view can only paint the glyph runs. It is close, and only here.
    private func dress() {
        let size = MediaOverlayGeometry.textSizeFraction * mediaWidth
        let font = style.font.editorFont(ofSize: size)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = style.alignment.nsAlignment
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font, .paragraphStyle: paragraph
        ]
        switch style.background {
        case .none, .box:
            attributes[.foregroundColor] = style.colour.uiColor
        case .highlight:
            attributes[.backgroundColor] = style.colour.uiColor
            attributes[.foregroundColor] = style.colour.isLight ? UIColor.black : UIColor.white
        }
        textView.backgroundColor = style.background == .box ? UIColor.black.withAlphaComponent(0.6) : .clear
        let selection = textView.selectedRange
        textView.attributedText = NSAttributedString(string: textView.text ?? "", attributes: attributes)
        textView.typingAttributes = attributes
        textView.selectedRange = selection
        textView.textAlignment = style.alignment.nsAlignment
    }

    /// Internal for tests: "Done", through the routine the button calls.
    func debugTapDone() { finish() }
    /// Internal for tests: typing, without a keyboard.
    func debugType(_ text: String) {
        textView.text = text
        textViewDidChange(textView)
    }
}

extension OverlayTextAlignment {
    var nsAlignment: NSTextAlignment {
        switch self {
        case .leading: .left
        case .centre: .center
        case .trailing: .right
        }
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
