import UIKit

/// Gives a composer's `UITextView` emotes: a panel that swaps in for the
/// keyboard, and inline `:query` suggestions above the keyboard.
///
/// ## Adopting it
///
/// Keep an `EmoteKeyboard` for the text view, and put `toggleButton` in the
/// composer. Nothing else: an insertion is reported through the text view's
/// own delegate (`textViewDidChange`), exactly as typing is, so a composer's
/// placeholder, send button and height follow without new wiring.
///
/// ## What the person gets
///
/// - **The panel** (`EmotePickerView`): the smiley swaps the keyboard for it,
///   the keyboard glyph swaps back. Recent first, then the house emotes, then
///   Noto's sections; a section bar to jump; delete that takes a whole
///   `:code:` or a whole emoji at once. The panel leaves when editing ends, so
///   the next focus opens the keyboard.
/// - **Search** is typing: `:` and two letters in the composer shows matching
///   emotes on a strip floating just above the field (`EmoteSuggestionStrip`),
///   house codes first; a tap replaces the `:query` with the emote. The panel's magnifier
///   switches to the keyboard and types the `:` for you.
/// - Every pick lands in `EmoteRecents`.
///
/// ## What the field shows
///
/// ⚠️ **STATIC WHILE COMPOSING.** An editable `UITextView` draws its own text
/// and offers no hook to leave a glyph undrawn under an animation, so the
/// field shows emoji as the system's still glyphs and house emotes as their
/// `:code:`, which is also what is sent. They animate once posted, on every
/// surface that shows them.
@MainActor
public final class EmoteKeyboard: NSObject {
    public let toggleButton = UIButton(type: .system)

    private weak var textView: UITextView?
    private let engine: EmoteEngine
    private let recents: EmoteRecents
    private lazy var picker: EmotePickerView = {
        let picker = EmotePickerView(engine: engine)
        picker.onSelect = { [weak self] emote in self?.pick(emote) }
        picker.onBackspace = { [weak self] in self?.deleteBackward() }
        picker.onSearch = { [weak self] in self?.startSearch() }
        return picker
    }()
    private let strip: EmoteSuggestionStrip
    private let suggestsInline: Bool

    /// The view the suggestion strip floats above — the composer's field.
    /// The text view itself when nil.
    ///
    /// ⚠️ **AN OVERLAY, NOT AN `inputAccessoryView`.** An accessory grows the
    /// keyboard's frame, and every composer here follows the keyboard its own
    /// way (a layout guide in one, a show-time notification in another), so
    /// the strip covered the feed's composer outright. Floating in the window
    /// above the field touches no one's layout.
    public weak var suggestionAnchor: UIView?

    /// Whether the panel stands in for the keyboard right now.
    public var isShowingPanel: Bool {
        textView?.inputView is EmotePickerView
    }

    /// - Parameter suggestsInline: false turns the `:query` strip off.
    public init(
        textView: UITextView,
        engine: EmoteEngine = .shared,
        recents: EmoteRecents = .shared,
        suggestsInline: Bool = true
    ) {
        self.textView = textView
        self.engine = engine
        self.recents = recents
        self.strip = EmoteSuggestionStrip(engine: engine)
        self.suggestsInline = suggestsInline
        super.init()

        strip.onSelect = { [weak self] emote in self?.acceptSuggestion(emote) }

        toggleButton.accessibilityIdentifier = "emote-toggle"
        toggleButton.addAction(UIAction { [weak self] _ in self?.toggle() }, for: .primaryActionTriggered)
        updateToggle()

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(textDidChange(_:)),
                           name: UITextView.textDidChangeNotification, object: textView)
        center.addObserver(self, selector: #selector(textDidEndEditing(_:)),
                           name: UITextView.textDidEndEditingNotification, object: textView)
    }

    // MARK: - Panel

    /// Swaps between the panel and the keyboard, focusing the field if needed.
    public func toggle() {
        guard let textView else { return }
        if isShowingPanel {
            textView.inputView = nil
        } else {
            let picker = self.picker
            picker.reload(recents: recents.emotes(in: engine.catalog))
            textView.inputView = picker
        }
        if textView.isFirstResponder {
            textView.reloadInputViews()
        } else {
            textView.becomeFirstResponder()
        }
        updateToggle()
    }

    private func updateToggle() {
        let panel = isShowingPanel
        toggleButton.setImage(UIImage(
            systemName: panel ? "keyboard" : "face.smiling",
            withConfiguration: UIImage.SymbolConfiguration(weight: .medium)
        ), for: .normal)
        toggleButton.accessibilityLabel = panel ? "Keyboard" : "Emotes"
    }

    @objc private func textDidEndEditing(_ note: Notification) {
        showSuggestions([])
        guard let textView, isShowingPanel else { return }
        textView.inputView = nil
        updateToggle()
    }

    // MARK: - Editing

    /// Inserts `emote` at the caret (replacing any selection) and remembers it.
    public func pick(_ emote: Emote) {
        guard let textView else { return }
        replace(textView.selectedRange, with: emote.insertionText)
        recents.record(emote)
    }

    /// One backspace: a whole `:code:` or one whole emoji, or the selection.
    public func deleteBackward() {
        guard let textView else { return }
        let selection = textView.selectedRange
        if selection.length > 0 {
            replace(selection, with: "")
        } else if let range = EmoteComposing.deletionRange(
            in: textView.text ?? "", caret: selection.location, catalog: engine.catalog
        ) {
            replace(range, with: "")
        }
    }

    private func startSearch() {
        guard let textView else { return }
        if isShowingPanel { toggle() }
        // A search is a `:` that opens a word.
        let text = (textView.text ?? "") as NSString
        let caret = min(textView.selectedRange.location, text.length)
        let before = caret > 0 ? text.substring(with: text.rangeOfComposedCharacterSequence(at: caret - 1)) : ""
        replace(textView.selectedRange, with: EmoteComposing.opensWord(after: before) ? ":" : " :")
    }

    private func acceptSuggestion(_ emote: Emote) {
        guard let textView,
              let query = EmoteComposing.inlineQuery(in: textView.text ?? "", caret: textView.selectedRange.location)
        else { return }
        replace(query.range, with: emote.insertionText)
        recents.record(emote)
    }

    /// Replaces `range` as typing would: through the delegate's veto, with the
    /// typing attributes, the caret after the insertion, and the delegate told.
    private func replace(_ range: NSRange, with text: String) {
        guard let textView else { return }
        let length = ((textView.text ?? "") as NSString).length
        let range = NSRange(location: min(range.location, length),
                            length: min(range.length, length - min(range.location, length)))
        if textView.delegate?.textView?(textView, shouldChangeTextIn: range, replacementText: text) == false {
            return
        }
        textView.textStorage.replaceCharacters(
            in: range, with: NSAttributedString(string: text, attributes: textView.typingAttributes)
        )
        textView.selectedRange = NSRange(location: range.location + (text as NSString).length, length: 0)
        textView.delegate?.textViewDidChange?(textView)
        refreshSuggestions()
        textView.scrollRangeToVisible(textView.selectedRange)
    }

    // MARK: - Inline search

    @objc private func textDidChange(_ note: Notification) {
        refreshSuggestions()
    }

    private func refreshSuggestions() {
        guard suggestsInline, let textView, textView.isFirstResponder || textView.window == nil,
              let query = EmoteComposing.inlineQuery(in: textView.text ?? "", caret: textView.selectedRange.location)
        else {
            showSuggestions([])
            return
        }
        showSuggestions(EmoteComposing.suggestions(for: query.query, catalog: engine.catalog))
    }

    /// Floats the strip just above the anchor, in the anchor's window, or
    /// takes it away.
    private func showSuggestions(_ emotes: [Emote]) {
        strip.show(emotes)
        guard !emotes.isEmpty, let anchor = suggestionAnchor ?? textView, let window = anchor.window else {
            strip.removeFromSuperview()
            return
        }
        if strip.superview !== window { window.addSubview(strip) }
        let field = anchor.convert(anchor.bounds, to: window)
        let inset: CGFloat = 8
        let width = min(window.bounds.width - inset * 2, 520)
        strip.frame = CGRect(
            x: (window.bounds.width - width) / 2,
            y: field.minY - EmoteSuggestionStrip.height - inset,
            width: width,
            height: EmoteSuggestionStrip.height
        )
        window.bringSubviewToFront(strip)
    }

    // MARK: - Test seams

    var suggestionIDs: [String] { strip.suggestions.map(\.id) }
    var panel: EmotePickerView { picker }
    func selectSuggestion(at index: Int) {
        guard index < strip.suggestions.count else { return }
        acceptSuggestion(strip.suggestions[index])
    }
    func search() { startSearch() }
}
