import DesignSystem
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
///   the keyboard glyph swaps back. It is exactly as tall as the system
///   keyboard it replaces (`EmoteKeyboardHeight`), so a composer riding the
///   keyboard does not move. Recent first, then the house emotes, then
///   Noto's sections; a section bar to jump; delete that takes a whole
///   `:code:` or a whole emoji at once. The panel leaves when editing ends, so
///   the next focus opens the keyboard.
/// - **Search** is typing: `:` and two letters in the composer shows matching
///   emotes on a strip floating just above the field (`EmoteSuggestionStrip`),
///   house codes first; a tap replaces the `:query` with the emote. The panel's magnifier
///   switches to the keyboard and types the `:` for you.
/// - Every pick lands in `EmoteRecents`.
/// - **`@` and `#` complete too** (#524): a person's handle or a tag, from
///   the `TextCompletionProviding` up the field's responder chain (the shell
///   holds the app's), on a strip in the same place; a tap replaces the
///   token being typed with the whole one and a space.
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
        let picker = EmotePickerView(engine: engine, heights: heights)
        picker.onSelect = { [weak self] emote in self?.pick(emote) }
        picker.onBackspace = { [weak self] in self?.deleteBackward() }
        picker.onSearch = { [weak self] in self?.startSearch() }
        return picker
    }()
    private let strip: EmoteSuggestionStrip
    private let suggestsInline: Bool
    /// Where the panel's height comes from: the system keyboard it replaces.
    private let heights: EmoteKeyboardHeight

    /// The view the suggestion strip floats above — the composer's field.
    /// The text view itself when nil.
    ///
    /// ⚠️ **AN OVERLAY, NOT AN `inputAccessoryView`.** An accessory grows the
    /// keyboard's frame, and every composer here follows the keyboard its own
    /// way (a layout guide in one, a show-time notification in another), so
    /// the strip covered the feed's composer outright. Floating in the window
    /// above the field touches no one's layout.
    public weak var suggestionAnchor: UIView?

    /// Whether `@` and `#` complete. On by default.
    public var completesTextEntities = true
    /// Where completions come from. Nil, the default: the
    /// `TextCompletionSource` up the field's responder chain, asked each time
    /// — a composer needs no wiring, and one off-screen completes nothing.
    public var textCompleter: (any TextCompletionProviding)?
    private let completionStrip = TextCompletionStrip()
    private var completionTask: Task<Void, Never>?
    /// A beat after the last keystroke, not one round trip per letter.
    var completionDebounce: Duration = .milliseconds(150)

    /// Whether the panel stands in for the keyboard right now.
    public var isShowingPanel: Bool {
        textView?.inputView is EmotePickerView
    }

    /// - Parameter suggestsInline: false turns the `:query` strip off.
    public convenience init(
        textView: UITextView,
        engine: EmoteEngine = .shared,
        recents: EmoteRecents = .shared,
        suggestsInline: Bool = true
    ) {
        self.init(textView: textView, engine: engine, recents: recents,
                  suggestsInline: suggestsInline, heights: .shared)
    }

    init(
        textView: UITextView,
        engine: EmoteEngine,
        recents: EmoteRecents,
        suggestsInline: Bool,
        heights: EmoteKeyboardHeight
    ) {
        self.heights = heights
        self.textView = textView
        self.engine = engine
        self.recents = recents
        self.strip = EmoteSuggestionStrip(engine: engine)
        self.suggestsInline = suggestsInline
        super.init()

        strip.onSelect = { [weak self] emote in self?.acceptSuggestion(emote) }
        completionStrip.onSelect = { [weak self] completion in self?.acceptCompletion(completion) }
        heights.track(self)

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
            // Exactly the keyboard's height, settled BEFORE the swap: the
            // system reads it once, as it slides the panel in.
            picker.matchKeyboardHeight(in: textView.window)
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
        completionTask?.cancel()
        showCompletions([])
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
        guard let textView, textView.isFirstResponder || textView.window == nil else {
            showSuggestions([])
            hideCompletions()
            return
        }
        let text = textView.text ?? ""
        let caret = textView.selectedRange.location
        // One token is typed at a time: an emote query wins, then a handle
        // or a tag.
        if suggestsInline, let query = EmoteComposing.inlineQuery(in: text, caret: caret) {
            hideCompletions()
            showSuggestions(EmoteComposing.suggestions(for: query.query, catalog: engine.catalog))
            return
        }
        showSuggestions([])
        refreshCompletions(in: text, caret: caret)
    }

    /// Floats the strip just above the anchor, in the anchor's window, or
    /// takes it away.
    private func showSuggestions(_ emotes: [Emote]) {
        strip.show(emotes)
        place(strip, showing: !emotes.isEmpty)
    }

    /// Puts `overlay` just above the anchor, in the anchor's window, or takes
    /// it away.
    private func place(_ overlay: UIView, showing: Bool) {
        guard showing, let anchor = suggestionAnchor ?? textView, let window = anchor.window else {
            overlay.removeFromSuperview()
            return
        }
        if overlay.superview !== window { window.addSubview(overlay) }
        let field = anchor.convert(anchor.bounds, to: window)
        let inset: CGFloat = 8
        let width = min(window.bounds.width - inset * 2, 520)
        overlay.frame = CGRect(
            x: (window.bounds.width - width) / 2,
            y: field.minY - EmoteSuggestionStrip.height - inset,
            width: width,
            height: EmoteSuggestionStrip.height
        )
        window.bringSubviewToFront(overlay)
    }

    // MARK: - @ and # completions

    /// The handle or tag being typed, asked for a beat after the last
    /// keystroke. What is on the strip stays while the next answer comes;
    /// an answer for a token no longer being typed is dropped.
    private func refreshCompletions(in text: String, caret: Int) {
        guard completesTextEntities, let textView,
              let token = TextEntityScanner.partialToken(in: text, caret: caret),
              let provider = textCompleter ?? TextCompletions.provider(from: textView)
        else {
            hideCompletions()
            return
        }
        completionTask?.cancel()
        let debounce = completionDebounce
        completionTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            let found = await provider.completions(for: token.kind, prefix: token.query)
            guard !Task.isCancelled, let self, self.typedToken() == token else { return }
            self.showCompletions(found)
        }
    }

    private func typedToken() -> PartialTextEntity? {
        guard let textView else { return nil }
        return TextEntityScanner.partialToken(in: textView.text ?? "", caret: textView.selectedRange.location)
    }

    private func hideCompletions() {
        completionTask?.cancel()
        completionTask = nil
        showCompletions([])
    }

    private func showCompletions(_ completions: [TextCompletion]) {
        completionStrip.show(completions)
        place(completionStrip, showing: !completions.isEmpty)
    }

    /// The token being typed becomes the whole one, and a space.
    private func acceptCompletion(_ completion: TextCompletion) {
        guard let token = typedToken() else { return }
        hideCompletions()
        replace(token.range, with: completion.token + " ")
    }

    // MARK: - Test seams

    var suggestionIDs: [String] { strip.suggestions.map(\.id) }
    var panel: EmotePickerView { picker }
    func selectSuggestion(at index: Int) {
        guard index < strip.suggestions.count else { return }
        acceptSuggestion(strip.suggestions[index])
    }
    func search() { startSearch() }
    var completionTokens: [String] { completionStrip.completions.map(\.token) }
    var isShowingCompletions: Bool { completionStrip.superview != nil && !completionStrip.isHidden }
    func selectCompletion(at index: Int) {
        guard index < completionStrip.completions.count else { return }
        acceptCompletion(completionStrip.completions[index])
    }
}
