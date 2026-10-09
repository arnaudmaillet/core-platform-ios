import DesignSystem
import MediaCore
import UIKit

/// The composer's counterpart of `EmoteLabel` (#699): an editable text view
/// whose emotes ANIMATE in place while the viewer types — a house emote shows
/// its artwork rather than its `:code:`, an emoji its animation rather than
/// the system's still glyph.
///
/// ## How
///
/// Every emote in the field is ONE character: a TextKit 2 attachment
/// (`EmoteAttachment`) sized like the emoji glyph on its line, which UIKit
/// lays out, wraps, scrolls and moves the caret around like any character.
/// Its view (`EmoteAttachmentView`, through `NSTextAttachmentViewProvider`)
/// shows the still glyph at once and plays the art on top once it is baked
/// and a playback slot is free — never a blank. The budgets are the label's:
/// the app-wide `EmoteEngine.maxAnimatedEmotes`, and stills under Reduce
/// Motion, Power Saving, idle calm or thermal pressure (`EmoteMotion`).
///
/// ## The text is still the wire format
///
/// Each attachment remembers the exact text it stands for (`source`: the
/// emoji as typed, or the `:code:` as typed), so `plainText` gives back,
/// byte for byte, what a plain `UITextView` would have held — what is sent,
/// drafted and copied. Read and write the field through `plainText`, and
/// map ranges with `plainRange(forStorage:)` / `storageRange(forPlain:)`:
/// `text` and `selectedRange` are in the storage's coordinates, where an
/// emote is one character.
///
/// Typing, pasting, autocorrect and dictation insert plain text; once an edit
/// ends (and no marked text is being composed) the emotes in it become
/// attachments, registered with the undo manager so undo walks back through
/// the conversion first.
///
/// ⚠️ TEXTKIT 2 ONLY. Attachment views need it, and touching `layoutManager`
/// silently drops a text view to TextKit 1 — don't.
@MainActor
open class EmoteTextView: UITextView {
    public let engine: EmoteEngine

    public init(frame: CGRect = .zero, engine: EmoteEngine = .shared) {
        self.engine = engine
        super.init(frame: frame, textContainer: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(editingChanged), name: UITextView.textDidChangeNotification, object: self
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(storageEdited),
            name: NSTextStorage.didProcessEditingNotification, object: textStorage
        )
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: EmoteTextView, _) in
            // `adjustsFontForContentSizeCategory` restyles the text on this
            // pass; the attachments are sized from the font after it.
            DispatchQueue.main.async { self.resizeAttachments() }
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    open override var font: UIFont? {
        didSet { resizeAttachments() }
    }

    // MARK: - Plain text

    /// The field's text as a plain text view would hold it: every emote
    /// back to the emoji or `:code:` it was typed as.
    public var plainText: String {
        get { Self.plainText(of: textStorage) }
        set {
            // Through `attributedText`, as a plain view's `text` would: the
            // view's own state (`hasText`, its layout) follows.
            let attributes = baseAttributes
            super.attributedText = attributedText(forPlain: newValue, attributes: attributes)
            typingAttributes = attributes
            selectedRange = NSRange(location: textStorage.length, length: 0)
            setNeedsLayout()
        }
    }

    /// `selectedRange` in `plainText`'s coordinates.
    public var plainSelectedRange: NSRange {
        get { plainRange(forStorage: selectedRange) }
        set { selectedRange = storageRange(forPlain: newValue) }
    }

    /// The range of `plainText` a range of the storage covers.
    public func plainRange(forStorage range: NSRange) -> NSRange {
        let start = plainOffset(forStorage: range.location)
        let end = plainOffset(forStorage: range.location + range.length)
        return NSRange(location: start, length: end - start)
    }

    /// The storage range for a range of `plainText`. A bound inside an
    /// emote's source widens to take the whole emote.
    public func storageRange(forPlain range: NSRange) -> NSRange {
        let start = storageOffset(forPlain: range.location, roundingUp: false)
        let end = storageOffset(forPlain: range.location + range.length, roundingUp: true)
        return NSRange(location: start, length: max(0, end - start))
    }

    /// Replaces a range of `plainText` as typing would: through the delegate's
    /// veto, the emotes in `text` as attachments, the caret after it and the
    /// delegate told. What `EmoteKeyboard` writes through.
    @discardableResult
    public func replacePlain(_ range: NSRange, with text: String) -> Bool {
        let plainLength = (plainText as NSString).length
        let location = min(range.location, plainLength)
        let clamped = NSRange(location: location, length: min(range.length, plainLength - location))
        let storage = storageRange(forPlain: clamped)
        if delegate?.textView?(self, shouldChangeTextIn: storage, replacementText: text) == false {
            return false
        }
        let caret = plainRange(forStorage: storage).location + (text as NSString).length
        let replacement = attributedText(forPlain: text, attributes: typingAttributes)
        textStorage.replaceCharacters(in: storage, with: replacement)
        plainSelectedRange = NSRange(location: caret, length: 0)
        setNeedsLayout()
        delegate?.textViewDidChange?(self)
        return true
    }

    // MARK: - Conversion

    /// An edit has ended: the emotes typed, pasted or dictated into it become
    /// attachments, the caret staying where it was in the plain text.
    @objc private func editingChanged() {
        guard markedTextRange == nil,
              undoManager?.isUndoing != true, undoManager?.isRedoing != true
        else { return }
        if convertTypedEmotes() {
            // The emotes take their own width: the host re-measures.
            delegate?.textViewDidChange?(self)
        }
        setNeedsLayout()
    }

    /// Converts every emote still written as text. True when one was.
    @discardableResult
    func convertTypedEmotes() -> Bool {
        let caret = plainSelectedRange
        var runs: [NSRange] = []
        let whole = NSRange(location: 0, length: textStorage.length)
        textStorage.enumerateAttribute(.attachment, in: whole) { value, range, _ in
            if value == nil { runs.append(range) }
        }
        let string = textStorage.string as NSString
        var replacements: [(NSRange, NSAttributedString)] = []
        for run in runs {
            let text = string.substring(with: run)
            guard EmoteParser.mayContainEmotes(text) else { continue }
            for match in EmoteParser.matches(in: text, catalog: engine.catalog) {
                let local = NSRange(match.range, in: text)
                let range = NSRange(location: run.location + local.location, length: local.length)
                let attributes = textStorage.attributes(at: range.location, effectiveRange: nil)
                let source = String(text[match.range])
                replacements.append((range, attachmentString(match.emote, source: source, attributes: attributes)))
            }
        }
        guard !replacements.isEmpty else { return false }
        // Back to front, so earlier ranges hold.
        textStorage.beginEditing()
        for (range, replacement) in replacements.reversed() {
            replaceStorage(range, with: replacement)
        }
        textStorage.endEditing()
        plainSelectedRange = caret
        return true
    }

    /// Replaces storage characters, registering the inverse with the undo
    /// manager: undo first turns the emotes back into the text that was typed,
    /// and the typing's own undo then finds the ranges it recorded.
    private func replaceStorage(_ range: NSRange, with replacement: NSAttributedString) {
        let old = textStorage.attributedSubstring(from: range)
        textStorage.replaceCharacters(in: range, with: replacement)
        let inserted = NSRange(location: range.location, length: replacement.length)
        setNeedsLayout()
        undoManager?.registerUndo(withTarget: self) { view in
            view.textStorage.beginEditing()
            view.replaceStorage(inserted, with: old)
            view.textStorage.endEditing()
        }
    }

    /// The storage for `plain`: its emotes as attachments, the rest as text.
    func attributedText(forPlain plain: String, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        guard EmoteParser.mayContainEmotes(plain) else {
            return NSAttributedString(string: plain, attributes: attributes)
        }
        var cursor = plain.startIndex
        for match in EmoteParser.matches(in: plain, catalog: engine.catalog) {
            if cursor < match.range.lowerBound {
                result.append(NSAttributedString(string: String(plain[cursor..<match.range.lowerBound]), attributes: attributes))
            }
            result.append(attachmentString(match.emote, source: String(plain[match.range]), attributes: attributes))
            cursor = match.range.upperBound
        }
        if cursor < plain.endIndex {
            result.append(NSAttributedString(string: String(plain[cursor...]), attributes: attributes))
        }
        return result
    }

    private func attachmentString(
        _ emote: Emote, source: String, attributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        // The app's scaled body, capped like every other text (ScaledFontTests).
        let font = (attributes[.font] as? UIFont) ?? self.font ?? .appFont(forTextStyle: .body)
        let attachment = EmoteAttachment(emote: emote, source: source, font: font, engine: engine)
        let string = NSMutableAttributedString(attachment: attachment)
        // The line's attributes ride along, so the caret beside an emote is
        // the text's height and the next character typed keeps them.
        var carried = attributes
        carried[.attachment] = attachment
        string.setAttributes(carried, range: NSRange(location: 0, length: string.length))
        return string
    }

    /// Re-sizes every emote for the current font: rebuilt from the plain
    /// text, the caret kept.
    private func resizeAttachments() {
        guard textStorage.length > 0, hasEmotes else { return }
        let caret = plainSelectedRange
        let plain = plainText
        let attributes = baseAttributes
        super.attributedText = attributedText(forPlain: plain, attributes: attributes)
        typingAttributes = attributes
        plainSelectedRange = caret
        setNeedsLayout()
    }

    private var hasEmotes: Bool {
        var found = false
        textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage.length)) { value, _, stop in
            if value is EmoteAttachment { found = true; stop.pointee = true }
        }
        return found
    }

    private var baseAttributes: [NSAttributedString.Key: Any] {
        var attributes = typingAttributes
        attributes[.attachment] = nil
        if let font { attributes[.font] = font }
        if let textColor { attributes[.foregroundColor] = textColor }
        return attributes
    }

    // MARK: - Coordinates

    /// The emotes, in storage order, with their source lengths.
    private func emoteRuns() -> [(location: Int, sourceLength: Int)] {
        var runs: [(Int, Int)] = []
        textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage.length)) { value, range, _ in
            guard let attachment = value as? EmoteAttachment else { return }
            // One attachment per character; a run of identical attachments
            // is still one source each.
            for offset in 0..<range.length {
                runs.append((range.location + offset, (attachment.source as NSString).length))
            }
        }
        return runs
    }

    private func plainOffset(forStorage offset: Int) -> Int {
        var delta = 0
        for run in emoteRuns() where run.location < offset {
            delta += run.sourceLength - 1
        }
        return offset + delta
    }

    private func storageOffset(forPlain offset: Int, roundingUp: Bool) -> Int {
        var delta = 0
        for run in emoteRuns() {
            let start = run.location + delta
            if offset <= start { break }
            if offset < start + run.sourceLength {
                return roundingUp ? run.location + 1 : run.location
            }
            delta += run.sourceLength - 1
        }
        return min(max(0, offset - delta), textStorage.length)
    }

    static func plainText(of storage: NSAttributedString) -> String {
        var plain = ""
        let string = storage.string as NSString
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let attachment = value as? EmoteAttachment {
                plain += String(repeating: attachment.source, count: range.length)
            } else {
                plain += string.substring(with: range)
            }
        }
        return plain
    }

    // MARK: - Pasteboard

    /// Where copy and cut write; a test seam.
    var pasteboard: UIPasteboard = .general

    /// Copies the plain text — the emoji and `:code:`s — never an image.
    open override func copy(_ sender: Any?) {
        let range = selectedRange
        guard range.length > 0 else { return }
        pasteboard.string = Self.plainText(of: textStorage.attributedSubstring(from: range))
    }

    open override func cut(_ sender: Any?) {
        guard selectedRange.length > 0, let selection = selectedTextRange else { return }
        copy(sender)
        replace(selection, withText: "")
    }

    // MARK: - Accessibility

    /// Reads a house emote by its name, an emoji as itself — never
    /// "attachment".
    open override var accessibilityValue: String? {
        get {
            var spoken = ""
            let string = textStorage.string as NSString
            textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage.length)) { value, range, _ in
                if let attachment = value as? EmoteAttachment {
                    let word = attachment.emote.isUnicodeEmoji ? attachment.source : attachment.emote.name
                    spoken += Array(repeating: word, count: range.length).joined(separator: " ")
                } else {
                    spoken += string.substring(with: range)
                }
            }
            return spoken
        }
        set { super.accessibilityValue = newValue }
    }

    // MARK: - The emotes' views

    /// One view per emote, keyed by its attachment.
    private var emoteViewsByAttachment: [ObjectIdentifier: EmoteAttachmentView] = [:]

    /// Bumped by every edit of the storage, from wherever it comes.
    private var storageRevision = 0
    /// What the views were last placed for: the text and the width it wraps
    /// in.
    private var placedFor: (revision: Int, width: CGFloat, inset: UIEdgeInsets)?

    @objc private func storageEdited() {
        storageRevision += 1
        setNeedsLayout()
    }

    /// ⚠️ A SCROLL VIEW LAYS OUT ON EVERY FRAME OF A SCROLL. The emotes'
    /// views are in the content and scroll with it by themselves, so they
    /// are placed again only when the text or the width it wraps in changed
    /// — never per frame of a scroll.
    open override func layoutSubviews() {
        super.layoutSubviews()
        let key = (revision: storageRevision, width: bounds.width, inset: textContainerInset)
        if let placed = placedFor, placed.revision == key.revision, placed.width == key.width,
           placed.inset == key.inset {
            return
        }
        placedFor = key
        placeEmoteViews()
    }

    /// Puts a view over every emote's square, where TextKit laid it out —
    /// in the text view's content, so it scrolls with the text — and drops
    /// the views of emotes that are gone.
    ///
    /// ⚠️ OVERLAID, NOT ATTACHMENT VIEWS: an editable `UITextView` drew
    /// `NSTextAttachmentViewProvider` attachments as its placeholder glyph
    /// rather than hosting their views (iOS 27 simulator, 2026-10-09). The
    /// attachment keeps the layout exact — one character, the square
    /// reserved — and draws nothing.
    func placeEmoteViews() {
        placementPasses += 1
        guard let layoutManager = textLayoutManager,
              let contentManager = layoutManager.textContentManager else { return }
        var live = Set<ObjectIdentifier>()
        let origin = CGPoint(x: textContainerInset.left, y: textContainerInset.top)
        textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage.length)) { value, range, _ in
            guard let attachment = value as? EmoteAttachment,
                  let start = contentManager.location(contentManager.documentRange.location, offsetBy: range.location),
                  let end = contentManager.location(start, offsetBy: 1),
                  let textRange = NSTextRange(location: start, end: end)
            else { return }
            layoutManager.ensureLayout(for: textRange)
            var frame: CGRect?
            layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, segment, _, _ in
                frame = segment
                return false
            }
            guard let segment = frame else { return }
            let key = ObjectIdentifier(attachment)
            live.insert(key)
            let view = emoteViewsByAttachment[key] ?? {
                let made = EmoteAttachmentView(
                    emote: attachment.emote, engine: engine, still: attachment.stillImage,
                    side: attachment.bounds.width
                )
                emoteViewsByAttachment[key] = made
                addSubview(made)
                return made
            }()
            // The square at the segment's leading edge, on the line's bottom
            // where the attachment sits.
            let side = attachment.bounds.width
            view.frame = CGRect(
                x: origin.x + segment.minX,
                y: origin.y + segment.maxY - side,
                width: side, height: side
            ).integral
        }
        for (key, view) in emoteViewsByAttachment where !live.contains(key) {
            view.removeFromSuperview()
            emoteViewsByAttachment[key] = nil
        }
    }

    // MARK: - Test seams

    /// How many times the views were placed.
    private(set) var placementPasses = 0

    /// The emotes' views over the field, in reading order.
    var emoteViews: [EmoteAttachmentView] {
        emoteViewsByAttachment.values.sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
    }
}

// MARK: - The attachment

/// One emote in an `EmoteTextView`: one character, sized like the emoji glyph
/// on its line, standing for exactly `source`.
final class EmoteAttachment: NSTextAttachment {
    let emote: Emote
    /// The text it was typed as: the emoji, or the `:code:` with its case.
    let source: String
    let engine: EmoteEngine
    /// The glyph drawn to the square: what shows before the art.
    private(set) var stillImage: UIImage?

    init(emote: Emote, source: String, font: UIFont, engine: EmoteEngine) {
        self.emote = emote
        self.source = source
        self.engine = engine
        super.init(data: nil, ofType: nil)
        let side = Self.side(for: font)
        // The line box exactly, so an emote never makes its line taller than
        // the text's: from the descender to the ascender.
        bounds = CGRect(x: 0, y: font.descender, width: side, height: side)
        stillImage = Self.still(of: emote, side: side)
        // TextKit only reserves the square: the field's own view for the
        // emote draws over it (`EmoteTextView.placeEmoteViews`).
        image = Self.blank(side: side)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// An emote's square on a line set in `font`: the line box.
    static func side(for font: UIFont) -> CGFloat {
        font.ascender - font.descender
    }

    /// The emote's glyph, drawn to fill `side` — the still shown before the
    /// art, and instead of it when motion is off.
    static func still(of emote: Emote, side: CGFloat) -> UIImage {
        let key = "\(emote.glyph)@\(side)" as NSString
        if let cached = stills.object(forKey: key) { return cached }
        let size = CGSize(width: side, height: side)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            // An emoji's ink is about its point size wide.
            let font = UIFont.systemFont(ofSize: side * 0.82)
            let glyph = emote.glyph as NSString
            let measured = glyph.size(withAttributes: [.font: font])
            glyph.draw(
                at: CGPoint(x: (side - measured.width) / 2, y: (side - measured.height) / 2),
                withAttributes: [.font: font]
            )
        }
        stills.setObject(image, forKey: key)
        return image
    }

    /// A transparent square: what TextKit draws for the emote.
    static func blank(side: CGFloat) -> UIImage {
        let key = "blank@\(side)" as NSString
        if let cached = stills.object(forKey: key) { return cached }
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in }
        stills.setObject(image, forKey: key)
        return image
    }

    // NSCache is thread-safe.
    nonisolated(unsafe) private static let stills = NSCache<NSString, UIImage>()
}

// MARK: - The view

/// What TextKit places for one emote: the still glyph at once, the art over
/// it once baked and a slot is free. Plays only while in a window.
@MainActor
final class EmoteAttachmentView: UIView {
    let emote: Emote
    private let engine: EmoteEngine
    private let still = UIImageView()
    private let player = AnimatedIconView(frame: .zero)
    private var request: EmoteRequest?
    private var holdsSlot = false
    private var waitingArt: AnimatedIconArt?
    private(set) var isShowingArt = false

    init(emote: Emote, engine: EmoteEngine, still image: UIImage?, side: CGFloat) {
        self.emote = emote
        self.engine = engine
        super.init(frame: CGRect(x: 0, y: 0, width: side, height: side))
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        still.image = image
        still.contentMode = .scaleAspectFit
        player.isHidden = true
        for view in [still, player] as [UIView] {
            view.frame = bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(view)
        }
        let center = NotificationCenter.default
        for name in [
            UIAccessibility.reduceMotionStatusDidChangeNotification,
            Notification.Name.emoteAnimationPreferenceDidChange,
            Notification.Name.decorativeMotionDidChange,
            Notification.Name.NSProcessInfoPowerStateDidChange,
            ProcessInfo.thermalStateDidChangeNotification
        ] {
            center.addObserver(self, selector: #selector(motionPolicyChanged), name: name, object: nil)
        }
        center.addObserver(self, selector: #selector(willEnterForeground),
                           name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stop() } else { start() }
    }

    private var motion: EmoteEngine.Motion {
        EmoteMotion.policy == .still ? .still : .loop
    }

    private func start() {
        guard request == nil, !isShowingArt, window != nil else { return }
        let motion = motion
        // Motion off: an emoji's still IS the glyph already showing.
        if motion == .still, emote.isUnicodeEmoji { return }
        let side = EmoteEngine.pixelSide(forPoints: bounds.width, scale: window?.screen.scale ?? 3)
        var answeredAtOnce = true
        var answered = false
        request = engine.requestArt(for: emote, pixelSide: side, motion: motion) { [weak self] art in
            answered = true
            guard let self else { return }
            self.request = nil
            guard let art, self.window != nil else {
                // No art after all: the glyph is all there is.
                self.still.isHidden = false
                return
            }
            self.present(art)
            if !answeredAtOnce { self.bounceIn() }
        }
        answeredAtOnce = false
        // ⚠️ NOTHING BEHIND AN ANIMATED EMOTE ON ITS WAY (#731): while the art
        // is being made the emote's place stays empty — no still glyph — and
        // the art bounces in when it lands.
        if !answered, motion == .loop { still.isHidden = true }
    }

    private func present(_ art: AnimatedIconArt) {
        let animates = motion == .loop && art.frameCount > 1
        if animates, !holdsSlot {
            guard engine.acquirePlaybackSlot(waiter: self) else {
                // No slot to play in: the art itself, held on its poster
                // frame — not the glyph — until one frees (#731).
                waitingArt = art
                player.setArt(art, phase: art.posterFrame(), paused: true)
                player.isHidden = false
                still.isHidden = true
                return
            }
            holdsSlot = true
        }
        waitingArt = nil
        player.setArt(art)
        player.isHidden = false
        still.isHidden = true
        isShowingArt = true
    }

    /// The art landing after the emote showed: from nothing, past its size
    /// and back, fading in (#731).
    private func bounceIn() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        isBouncingIn = true
        player.layer.removeAllAnimations()
        player.alpha = 0
        player.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
        UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.55,
                       initialSpringVelocity: 0.6, options: [.allowUserInteraction]) {
            self.player.alpha = 1
            self.player.transform = .identity
        } completion: { _ in
            self.isBouncingIn = false
        }
    }

    /// Whether the art is landing with its bounce. Internal for tests.
    private(set) var isBouncingIn = false

    private func stop() {
        request?.cancel()
        request = nil
        waitingArt = nil
        player.setArt(nil)
        player.isHidden = true
        player.layer.removeAllAnimations()
        player.alpha = 1
        player.transform = .identity
        isBouncingIn = false
        still.isHidden = false
        isShowingArt = false
        if holdsSlot {
            holdsSlot = false
            engine.releasePlaybackSlot()
        }
    }

    @objc nonisolated private func motionPolicyChanged() {
        Task { @MainActor [weak self] in
            self?.stop()
            self?.start()
        }
    }

    @objc nonisolated private func willEnterForeground() {
        Task { @MainActor [weak self] in self?.player.reinstall() }
    }

    // MARK: - Test seams

    var showsStill: Bool { !still.isHidden }
    /// The art on show, held on its poster frame for want of a slot (#731).
    var showsPosterArt: Bool { waitingArt != nil && !player.isHidden }
}

extension EmoteAttachmentView: EmotePlaybackWaiting {
    func emotePlaybackSlotFreed() {
        guard let art = waitingArt, window != nil else { return }
        present(art)
    }
}
