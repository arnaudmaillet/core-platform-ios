import UIKit

/// Turns plain text into the attributed string an `EmoteLabel` animates.
///
/// ## No placeholders, and that is the design
///
/// Every emote stays a CHARACTER: an emoji is left as itself, and a `:code:` is
/// replaced by its emote's stand-in emoji. Each is only MARKED with
/// `emoteAttribute`. So the text system lays out, measures, wraps and
/// truncates exactly what it would for the same emoji typed by hand:
///
/// - the line height and baseline cannot change when an animation bakes,
///   because nothing about the string changes when it does;
/// - the static fallback is free and is never blank — it is the system emoji,
///   drawn by the label itself;
/// - VoiceOver reads the emoji's name, copy gives an emoji, and a surface that
///   has not adopted `EmoteLabel` still shows sensible text.
///
/// The animation is a layer the label places OVER that glyph once it is ready,
/// and only then does the label stop drawing the glyph underneath.
public enum EmoteText {
    /// Marks an emote's characters. The value is the emote's `id` (a `String`).
    public static let emoteAttribute = NSAttributedString.Key("EmoteKit.emote")

    /// `text` with `attributes` throughout, every known `:code:` replaced by
    /// its emote's glyph, and every emote marked.
    public static func attributedString(
        _ text: String,
        attributes: [NSAttributedString.Key: Any],
        catalog: EmoteCatalog = .shared
    ) -> NSAttributedString {
        let matches = EmoteParser.matches(in: text, catalog: catalog)
        guard !matches.isEmpty else { return NSAttributedString(string: text, attributes: attributes) }
        let out = NSMutableAttributedString()
        var cursor = text.startIndex
        for match in matches {
            if cursor < match.range.lowerBound {
                out.append(NSAttributedString(string: String(text[cursor..<match.range.lowerBound]), attributes: attributes))
            }
            var marked = attributes
            marked[emoteAttribute] = match.emote.id
            let glyph = match.isCode ? match.emote.glyph : String(text[match.range])
            out.append(NSAttributedString(string: glyph, attributes: marked))
            cursor = match.range.upperBound
        }
        if cursor < text.endIndex {
            out.append(NSAttributedString(string: String(text[cursor...]), attributes: attributes))
        }
        return out
    }

    /// A copy of `attributed` with every emote in its string marked and every
    /// known `:code:` replaced, the surrounding attributes kept — for text
    /// composed elsewhere (mentions, links, mixed fonts).
    public static func marked(_ attributed: NSAttributedString, catalog: EmoteCatalog = .shared) -> NSAttributedString {
        let string = attributed.string
        let matches = EmoteParser.matches(in: string, catalog: catalog)
        guard !matches.isEmpty else { return attributed }
        let out = NSMutableAttributedString(attributedString: attributed)
        // Back to front, so a replacement never shifts a range still to come.
        for match in matches.reversed() {
            let range = NSRange(match.range, in: string)
            if match.isCode {
                let attributes = out.attributes(at: range.location, effectiveRange: nil)
                out.replaceCharacters(in: range, with: NSAttributedString(string: match.emote.glyph, attributes: attributes))
                out.addAttribute(emoteAttribute, value: match.emote.id,
                                 range: NSRange(location: range.location, length: (match.emote.glyph as NSString).length))
            } else {
                out.addAttribute(emoteAttribute, value: match.emote.id, range: range)
            }
        }
        return out
    }

    /// `text` as it will READ once rendered: every known `:code:` replaced by
    /// its glyph. For plain-text consumers — accessibility, a measurement that
    /// cannot take an attributed string, a notification body.
    public static func displayString(_ text: String, catalog: EmoteCatalog = .shared) -> String {
        let matches = EmoteParser.matches(in: text, catalog: catalog).filter(\.isCode)
        guard !matches.isEmpty else { return text }
        var out = text
        for match in matches.reversed() {
            out.replaceSubrange(match.range, with: match.emote.glyph)
        }
        return out
    }

    /// Whether `attributed` carries any marked emote.
    public static func containsEmotes(_ attributed: NSAttributedString?) -> Bool {
        guard let attributed, attributed.length > 0 else { return false }
        var found = false
        attributed.enumerateAttribute(emoteAttribute, in: NSRange(location: 0, length: attributed.length)) { value, _, stop in
            if value != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// The marked emotes of `attributed`: each one's range and emote id.
    static func marks(in attributed: NSAttributedString?) -> [(range: NSRange, id: String)] {
        guard let attributed, attributed.length > 0 else { return [] }
        var marks: [(range: NSRange, id: String)] = []
        let whole = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(emoteAttribute, in: whole) { value, range, _ in
            guard let id = value as? String else { return }
            // Adjacent emotes of the SAME id merge into one attribute run
            // ("🔥🔥"). Split the run back into its graphemes.
            let run = (attributed.string as NSString).substring(with: range)
            var location = range.location
            for character in run {
                let length = String(character).utf16.count
                marks.append((NSRange(location: location, length: length), id))
                location += length
            }
        }
        return marks
    }
}
