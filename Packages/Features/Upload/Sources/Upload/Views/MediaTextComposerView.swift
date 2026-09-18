import DesignSystem
import MediaPlayback
import UIKit

/// Where the words of a text overlay are typed: the editor dimmed, the words in
/// the middle in the style they will wear, the style bar over the keyboard.
///
/// ```
/// ┌──────────────────────────┐
/// │ ‹  Save  ◀ ▶        Done │  ← the editor's own header, still live
/// │░░░░░░░░░░░░░░░░░░░░░░░░░░│
/// │░░░░░░ Hello there ░░░░░░░│
/// │[≡][A̲] Classic Rounded … ●│
/// │ q w e r t y u i o p      │
/// └──────────────────────────┘
/// ```
///
/// ⚠️ **IT CARRIES NO "Done" OF ITS OWN** — asked for that way: *"le bouton
/// 'Done' ne doit pas etre sous 'Next', c'est 'Next' qui devient 'Done'"*. It
/// used to wear a white capsule at the top right, a few points under the bar's
/// own trailing item, and the two did different things — one put the keyboard
/// away, the other left the screen for the finalisation page. The screen turns
/// its trailing item into "Done" for the length of the session instead
/// (`MediaEditorViewController.isTypingText`), and this view lies UNDER the
/// translucent navigation bar, so that item stays reachable over it.
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

    /// Called whenever the field crosses between empty and not, and once when a
    /// session opens — so the bar can offer a TICK over words and a CROSS over
    /// nothing.
    ///
    /// ⚠️ **ONLY ON THE CROSSING, NOT PER KEYSTROKE.** The only thing the
    /// listener does with this is choose one of two glyphs; announcing every
    /// character would have the screen re-decide a bar item sixty times a
    /// sentence for an answer that changed twice.
    var onWordsChanged: ((Bool) -> Void)?

    private var hadWords: Bool?

    private func tellWhetherThereAreWords() {
        let has = !(textView.text ?? "").isEmpty
        guard has != hadWords else { return }
        hadWords = has
        onWordsChanged?(has)
    }

    private(set) var style = TextOverlay.fresh
    let textView = UITextView()
    let styleBar = MediaTextStyleBar(frame: CGRect(x: 0, y: 0, width: 390, height: MediaTextStyleBar.height))
    /// The page's picture width in points, which the words are sized against
    /// — so what is typed is the size it lands on the picture.
    private var mediaWidth: CGFloat = 375
    private var isFinished = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.55)
        accessibilityViewIsModal = true

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

        // ⚠️ **BETWEEN THE HEADER AND THE KEYBOARD, CENTRED IN WHAT IS LEFT.**
        // The words may be many lines; they are held under the bar and over the
        // keyboard, and centred between the two while they fit. The safe area
        // is where the header ends — this view lies under a translucent
        // navigation bar, which is also what keeps that bar's "Done" tappable
        // while this one is up.
        let above = UILayoutGuide()
        addLayoutGuide(above)
        NSLayoutConstraint.activate([
            above.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: Spacing.sm),
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
        // ⚠️ **STATED ON THE WAY IN, BEFORE A KEY IS PRESSED.** Opening on an
        // existing text must show the tick at once; opening on a new one must
        // show the cross. `hadWords` is nil here, so this always announces.
        tellWhetherThereAreWords()
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
        tellWhetherThereAreWords()
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

    /// Internal for tests: "Done", through the routine the header's item calls.
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
