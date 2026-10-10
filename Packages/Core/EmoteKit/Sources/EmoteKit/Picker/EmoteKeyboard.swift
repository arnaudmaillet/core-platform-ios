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
/// ⚠️ **ANIMATED IN AN `EmoteTextView`, STATIC IN A PLAIN `UITextView`
/// (#699).** A plain text view draws its own text and offers no hook to
/// leave a glyph undrawn under an animation, so it shows emoji as the
/// system's still glyphs and house emotes as their `:code:`. An
/// `EmoteTextView` holds each emote as one attachment that plays in place;
/// this keyboard then reads and writes its PLAIN text (`plainText`,
/// `replacePlain`), so what is sent is the same `:code:`s and emoji either
/// way.
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
    // `nonisolated(unsafe)`: read once more, on the main thread, by `deinit`.
    nonisolated(unsafe) private let strip: EmoteSuggestionStrip
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
    nonisolated(unsafe) private let completionStrip: TextCompletionStrip
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
        self.completionStrip = TextCompletionStrip()
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

    /// ⚠️ THE STRIPS GO WITH THE KEYBOARD (#785). They float in the WINDOW,
    /// above everything, and left only when the field stopped editing — an
    /// owner released without its field resigning (a recycled cell, a closed
    /// composer) left a strip floating over whatever came next.
    deinit {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated { [strip, completionStrip] in
            strip.removeFromSuperview()
            completionStrip.removeFromSuperview()
        }
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
        guard textView != nil else { return }
        replace(plainSelection, with: emote.insertionText)
        recents.record(emote)
    }

    /// One backspace: a whole `:code:` or one whole emoji, or the selection.
    public func deleteBackward() {
        guard textView != nil else { return }
        let selection = plainSelection
        if selection.length > 0 {
            replace(selection, with: "")
        } else if let range = EmoteComposing.deletionRange(
            in: plainText, caret: selection.location, catalog: engine.catalog
        ) {
            replace(range, with: "")
        }
    }

    private func startSearch() {
        guard textView != nil else { return }
        if isShowingPanel { toggle() }
        // A search is a `:` that opens a word.
        let text = plainText as NSString
        let caret = min(plainSelection.location, text.length)
        let before = caret > 0 ? text.substring(with: text.rangeOfComposedCharacterSequence(at: caret - 1)) : ""
        replace(plainSelection, with: EmoteComposing.opensWord(after: before) ? ":" : " :")
    }

    private func acceptSuggestion(_ emote: Emote) {
        guard textView != nil,
              let query = EmoteComposing.inlineQuery(in: plainText, caret: plainSelection.location)
        else { return }
        replace(query.range, with: emote.insertionText)
        recents.record(emote)
    }

    // MARK: - The field's text

    /// The field, when it animates its emotes (#699): its storage holds one
    /// attachment per emote, so everything here reads and writes its PLAIN
    /// text — the emoji and `:code:`s — and maps ranges through it.
    private var emoteField: EmoteTextView? { textView as? EmoteTextView }

    /// The text as sent: the emoji and `:code:`s, whatever the field draws.
    private var plainText: String {
        emoteField?.plainText ?? textView?.text ?? ""
    }

    /// The selection, in `plainText`'s coordinates.
    private var plainSelection: NSRange {
        emoteField?.plainSelectedRange ?? textView?.selectedRange ?? NSRange(location: 0, length: 0)
    }

    /// Replaces `range` of the plain text as typing would: through the
    /// delegate's veto, with the typing attributes, the caret after the
    /// insertion, and the delegate told.
    private func replace(_ range: NSRange, with text: String) {
        guard let textView else { return }
        if let emoteField {
            guard emoteField.replacePlain(range, with: text) else { return }
            refreshSuggestions()
            textView.scrollRangeToVisible(textView.selectedRange)
            return
        }
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
        let text = plainText
        let caret = plainSelection.location
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

    /// How long the strip's resize — and its tiles coming and going — takes.
    static let suggestionSpring: TimeInterval = 0.38

    /// Bumped by every show and hide, so a hide's completion does not take
    /// away a strip shown again in the meantime.
    private var stripGeneration = 0

    /// Floats the strip just above the anchor, in the anchor's window, or
    /// takes it away (#720): it arrives growing out of the field, resizes
    /// with its matches — its width and its tiles in one spring — and
    /// leaves shrinking back.
    private func showSuggestions(_ emotes: [Emote]) {
        let isShowing = strip.superview != nil && !strip.isHidden && strip.alpha > 0
        let animates = !UIAccessibility.isReduceMotionEnabled
        stripGeneration += 1
        let generation = stripGeneration
        guard !emotes.isEmpty, let anchor = suggestionAnchor ?? textView, let window = anchor.window else {
            // Off-window (no field on screen): the matches are kept, nothing floats.
            if !emotes.isEmpty {
                strip.removeFromSuperview()
                strip.show(emotes)
                return
            }
            guard isShowing, animates, strip.window != nil else {
                strip.removeFromSuperview()
                strip.show([])
                return
            }
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .curveEaseIn]) {
                self.strip.alpha = 0
                self.strip.transform = Self.stripCollapsed
            } completion: { _ in
                guard self.stripGeneration == generation else { return }
                self.strip.removeFromSuperview()
                self.strip.transform = .identity
                self.strip.show([])
            }
            return
        }
        let frame = suggestionFrame(count: emotes.count, anchor: anchor, in: window)
        if strip.superview !== window { window.addSubview(strip) }
        window.bringSubviewToFront(strip)
        guard isShowing, strip.window != nil else {
            strip.layer.removeAllAnimations()
            strip.transform = .identity
            strip.frame = frame
            strip.show(emotes)
            strip.layoutIfNeeded()
            guard animates else {
                strip.alpha = 1
                return
            }
            strip.alpha = 0
            strip.transform = Self.stripCollapsed
            UIView.animate(withDuration: Self.suggestionSpring, delay: 0, usingSpringWithDamping: 0.82,
                           initialSpringVelocity: 0, options: [.allowUserInteraction]) {
                self.strip.alpha = 1
                self.strip.transform = .identity
            }
            return
        }
        strip.layer.removeAllAnimations()
        strip.alpha = 1
        strip.transform = .identity
        guard animates else {
            strip.frame = frame
            strip.show(emotes)
            return
        }
        // ONE spring for the capsule and its tiles: the batch updates inside
        // the block take its timing, so a tile shrinks out exactly as the
        // capsule closes over it.
        UIView.animate(withDuration: Self.suggestionSpring, delay: 0, usingSpringWithDamping: 0.86,
                       initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.strip.frame = frame
            self.strip.show(emotes, animated: true)
            self.strip.layoutIfNeeded()
        }
    }

    /// Where a strip leaves to and arrives from: a little smaller, toward
    /// the field.
    private static let stripCollapsed = CGAffineTransform(translationX: 0, y: 8).scaledBy(x: 0.92, y: 0.92)

    /// Just above the anchor, starting at its leading edge, as wide as
    /// `count` matches (capped to the window, then scrolling).
    private func suggestionFrame(count: Int, anchor: UIView, in window: UIWindow) -> CGRect {
        let field = anchor.convert(anchor.bounds, to: window)
        let inset: CGFloat = 8
        let width = min(EmoteSuggestionStrip.fittingWidth(count: count), window.bounds.width - inset * 2, 520)
        let x = min(max(field.minX, inset), window.bounds.width - inset - width)
        return CGRect(
            x: x, y: field.minY - EmoteSuggestionStrip.height - inset,
            width: width, height: EmoteSuggestionStrip.height
        )
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
        guard textView != nil else { return nil }
        return TextEntityScanner.partialToken(in: plainText, caret: plainSelection.location)
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
    var suggestionStrip: EmoteSuggestionStrip { strip }
    var panel: EmotePickerView { picker }
    func selectSuggestion(at index: Int) {
        guard index < strip.suggestions.count else { return }
        acceptSuggestion(strip.suggestions[index])
    }
    func search() { startSearch() }
    var completionTokens: [String] { completionStrip.completions.map(\.token) }
    var isShowingCompletions: Bool { completionStrip.superview != nil && !completionStrip.isHidden }
    /// The `@`/`#` strip itself, so a test can hold it past its keyboard (#785).
    var textCompletionStrip: TextCompletionStrip { completionStrip }
    func selectCompletion(at index: Int) {
        guard index < completionStrip.completions.count else { return }
        acceptCompletion(completionStrip.completions[index])
    }
}
