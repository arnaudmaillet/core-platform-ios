import UIKit

/// Whoever opens what a `@handle` or `#tag` names (#524).
///
/// Adopted by the shell's tab bar controller, and found UP THE RESPONDER
/// CHAIN from the label that was tapped — the `StakeShopOpening` shape — so a
/// comment, a caption or a bio routes its tokens without a closure threaded
/// through every screen that draws one.
@MainActor
public protocol TextEntityOpening: AnyObject {
    /// `token` as written, sigil included: `@alex`, `#paris`
    /// (`NSAttributedString.Key.textEntity`).
    func openTextEntity(_ token: String, from source: UIView)
    /// Whether a token of this kind opens anything yet: one that does not is
    /// left to the text's own taps.
    func opensTextEntities(of kind: TextEntity.Kind) -> Bool
}

@MainActor
public enum TextEntityLinks {
    /// The first `TextEntityOpening` up `source`'s responder chain.
    public static func opener(from source: UIResponder) -> (any TextEntityOpening)? {
        sequence(first: source, next: \.next).lazy.compactMap { $0 as? any TextEntityOpening }.first
    }

    /// The `textEntity` mark of the character under `point` in `label`, laid
    /// out exactly as the label lays it out; nil off every token.
    ///
    /// TextKit rather than arithmetic: where a token sits depends on where the
    /// lines broke. The container matches the label — no padding, its
    /// line-break mode and line cap — and the text is placed where `UILabel`
    /// draws it, centred vertically in a taller label. A point past a line's
    /// end is a miss, not that line's last character.
    public static func token(at point: CGPoint, in label: UILabel) -> String? {
        guard let attributed = label.attributedText, attributed.length > 0 else { return nil }
        let storage = NSTextStorage(attributedString: attributed)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.lineBreakMode = label.lineBreakMode
        container.maximumNumberOfLines = label.numberOfLines
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        let offset = max(0, (label.bounds.height - used.height) / 2)
        let local = CGPoint(x: point.x, y: point.y - offset)
        let glyph = manager.glyphIndex(for: local, in: container, fractionOfDistanceThroughGlyph: nil)
        let rect = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        // Generous by a few points: a token is a small target.
        guard rect.insetBy(dx: -4, dy: -4).contains(local) else { return nil }
        let index = manager.characterIndexForGlyph(at: glyph)
        guard index < attributed.length else { return nil }
        return attributed.attribute(.textEntity, at: index, effectiveRange: nil) as? String
    }

    /// The kind a token's sigil names.
    public static func kind(of token: String) -> TextEntity.Kind {
        token.hasPrefix("#") ? .hashtag : .mention
    }
}
