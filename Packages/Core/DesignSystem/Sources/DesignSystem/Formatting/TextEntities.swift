import Foundation
import UIKit

/// A `@handle` or a `#tag` inside user text (#524).
public struct TextEntity: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case mention
        case hashtag
    }

    public let kind: Kind
    /// The whole token, sigil included, in the scanned string's UTF-16 units.
    public let range: NSRange
    /// What the token names, without its sigil and lowercased: the handle a
    /// profile is stored under, or the tag search indexes.
    public let value: String
}

/// Finds the `@handle`s and `#tag`s in user text, by the server's rules:
///
/// - A handle is what `profile` accepts: 2–30 of `a-z 0-9 . _` (any case),
///   starting and ending with a letter or digit, with no `..`, `__`, `._` or
///   `_.`. A trailing `.` or `_` is punctuation (`@alex.` names `alex`).
/// - A tag is a run of letters, digits and `_` (any script) holding at least
///   one letter — `#1` is a number, not a tag. Search lowercases it.
/// - A sigil glued to a word is not one (`a@b.com`, `x#1`), nor a doubled
///   one (`@@alex`, `##tag`), nor one inside a link.
public enum TextEntityScanner {
    public static let handleLength = 2...30

    public static func entities(in text: String) -> [TextEntity] {
        guard text.contains("@") || text.contains("#") else { return [] }
        let units = Array(text.utf16)
        let links = linkRanges(in: text)
        var found: [TextEntity] = []
        var index = 0
        while index < units.count {
            let unit = units[index]
            guard unit == at || unit == hash, startsToken(units, at: index) else {
                index += 1
                continue
            }
            let entity = unit == at ? mention(units, sigil: index) : hashtag(text, units, sigil: index)
            // A link holding the sigil owns it (`site.com/@alex`); one that
            // merely starts after it is the token read as a domain
            // (`@kenji.dev`).
            if let entity, !links.contains(where: { NSLocationInRange(entity.range.location, $0) }) {
                found.append(entity)
                index = NSMaxRange(entity.range)
            } else {
                index += 1
            }
        }
        return found
    }

    // MARK: - Rules

    private static let at = UInt16(UInt8(ascii: "@"))
    private static let hash = UInt16(UInt8(ascii: "#"))
    private static let dot = UInt16(UInt8(ascii: "."))
    private static let underscore = UInt16(UInt8(ascii: "_"))

    /// A sigil opens a token at the start of the text or after anything that
    /// is not part of a word, an address or another sigil.
    private static func startsToken(_ units: [UInt16], at index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = units[index - 1]
        if previous == at || previous == hash || previous == dot || previous == underscore { return false }
        // A letter or digit of any script glues the sigil to a word.
        if let scalar = Unicode.Scalar(previous), scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
            return false
        }
        // Low surrogate: the previous character is outside the BMP. Only
        // letters there would glue; emoji, the usual case, do not.
        if UTF16.isTrailSurrogate(previous), index >= 2,
           let scalar = Unicode.Scalar(UInt32(0x10000 + ((Int(units[index - 2]) - 0xD800) << 10) + (Int(previous) - 0xDC00))) {
            return !scalar.properties.isAlphabetic
        }
        return true
    }

    private static func isHandleUnit(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, dot, underscore: true
        default: false
        }
    }

    private static func mention(_ units: [UInt16], sigil: Int) -> TextEntity? {
        var end = sigil + 1
        while end < units.count, isHandleUnit(units[end]) { end += 1 }
        var body = Array(units[(sigil + 1)..<end])
        // Stop at the first sequence a handle may not hold; what precedes it
        // may still be one.
        for i in body.indices.dropFirst() where isSeparator(body[i]) && isSeparator(body[i - 1]) {
            body = Array(body[..<(i - 1)])
            break
        }
        // A trailing separator is the sentence's punctuation.
        while let last = body.last, isSeparator(last) { body.removeLast() }
        guard let first = body.first, !isSeparator(first), handleLength.contains(body.count) else { return nil }
        let value = String(decoding: body, as: UTF16.self).lowercased()
        return TextEntity(kind: .mention, range: NSRange(location: sigil, length: body.count + 1), value: value)
    }

    private static func isSeparator(_ unit: UInt16) -> Bool { unit == dot || unit == underscore }

    private static func hashtag(_ text: String, _ units: [UInt16], sigil: Int) -> TextEntity? {
        let bodyStart = String.Index(utf16Offset: sigil + 1, in: text)
        var end = bodyStart
        var hasLetter = false
        // By character, so combining marks and scripts beyond the BMP stay
        // whole.
        for character in text[bodyStart...] {
            if character.isLetter {
                hasLetter = true
            } else if !(character.isNumber || character == "_" || character.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .nonspacingMark || $0.properties.generalCategory == .spacingMark })) {
                break
            }
            end = text.index(after: end)
        }
        guard hasLetter else { return nil }
        let length = text.utf16.distance(from: bodyStart, to: end)
        return TextEntity(
            kind: .hashtag,
            range: NSRange(location: sigil, length: length + 1),
            value: text[bodyStart..<end].lowercased()
        )
    }

    /// Links and addresses, whose `@` and `#` belong to them.
    private static func linkRanges(in text: String) -> [NSRange] {
        guard text.contains("."), let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        return detector.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(\.range)
    }
}

// MARK: - Styling

/// How a `@handle` or `#tag` stands out from the text around it (#524).
public struct TextEntityStyle: Equatable, Sendable {
    /// The token's colour; nil keeps the text's own (over media, where a link
    /// colour would not read).
    public var color: UIColor?
    /// The token's weight, over the text's own font and size.
    public var weight: UIFont.Weight

    public init(color: UIColor?, weight: UIFont.Weight = .semibold) {
        self.color = color
        self.weight = weight
    }

    /// On a plain surface: the link colour, semibold.
    public static let link = TextEntityStyle(color: .link)
    /// Over media or a hero banner, whose ink the text already chose:
    /// semibold only.
    public static let emphasis = TextEntityStyle(color: nil)
}

public extension NSAttributedString.Key {
    /// On every `@handle` and `#tag`: the token as written, sigil included
    /// (`@alex`, `#paris`) — what a tap routes on.
    static let textEntity = NSAttributedString.Key("DesignSystem.textEntity")
}

public extension NSMutableAttributedString {
    /// Marks and styles the `@handle`s and `#tag`s in the string, keeping
    /// every other attribute (emote marks, shadows, paragraph styles).
    func applyTextEntityStyle(_ style: TextEntityStyle) {
        for entity in TextEntityScanner.entities(in: string) {
            let sigil = entity.kind == .mention ? "@" : "#"
            addAttribute(.textEntity, value: sigil + entity.value, range: entity.range)
            if let color = style.color {
                addAttribute(.foregroundColor, value: color, range: entity.range)
            }
            enumerateAttribute(.font, in: entity.range) { value, range, _ in
                guard let font = value as? UIFont else { return }
                addAttribute(.font, value: font.withWeight(style.weight), range: range)
            }
        }
    }
}

// MARK: - The token being typed

/// The `@handle` or `#tag` being typed at the caret — what a composer
/// completes (#524).
public struct PartialTextEntity: Equatable, Sendable {
    public let kind: TextEntity.Kind
    /// What follows the sigil up to the caret, as typed.
    public let query: String
    /// The sigil and the query, in UTF-16 units: what a completion replaces.
    public let range: NSRange
}

extension TextEntityScanner {
    /// The token the caret is at the end of, once it holds at least one
    /// character after its sigil; nil anywhere else. The sigil opens a token
    /// by `entities(in:)`'s rules (not glued to a word, not doubled), and a
    /// handle holds a handle's characters, a tag a tag's.
    public static func partialToken(in text: String, caret: Int) -> PartialTextEntity? {
        let units = Array(text.utf16)
        guard caret > 0, caret <= units.count else { return nil }
        // Back over what a handle or a tag may hold, to the sigil.
        var start = caret
        while start > 0 {
            let unit = units[start - 1]
            if unit == at || unit == hash { break }
            guard isHandleUnit(unit) || isTagUnit(unit) else { return nil }
            start -= 1
        }
        let sigil = start - 1
        guard sigil >= 0, units[sigil] == at || units[sigil] == hash, startsToken(units, at: sigil),
              caret > start
        else { return nil }
        let query = String(decoding: units[start..<caret], as: UTF16.self)
        let kind: TextEntity.Kind = units[sigil] == at ? .mention : .hashtag
        switch kind {
        case .mention:
            // A handle's own characters, starting with a letter or a digit,
            // no longer than a handle may be.
            guard units[start..<caret].allSatisfy(isHandleUnit), !isSeparator(units[start]),
                  caret - start <= handleLength.upperBound
            else { return nil }
        case .hashtag:
            guard query.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        }
        return PartialTextEntity(kind: kind, query: query, range: NSRange(location: sigil, length: caret - sigil))
    }

    /// Anything a tag may hold, unit by unit: a letter or digit of any
    /// script, a mark, `_`, or half of a pair beyond the BMP.
    private static func isTagUnit(_ unit: UInt16) -> Bool {
        if unit == underscore || UTF16.isLeadSurrogate(unit) || UTF16.isTrailSurrogate(unit) { return true }
        guard let scalar = Unicode.Scalar(unit) else { return false }
        let properties = scalar.properties
        return properties.isAlphabetic || properties.numericType != nil
            || properties.generalCategory == .nonspacingMark || properties.generalCategory == .spacingMark
    }
}

// MARK: - Completions

/// One completion for a token being typed: a person's handle or a tag.
public struct TextCompletion: Equatable, Sendable, Identifiable {
    public let kind: TextEntity.Kind
    /// The handle or the tag, without its sigil, as it is inserted.
    public let value: String
    /// A person's name, when the source knows one.
    public let title: String?

    public init(kind: TextEntity.Kind, value: String, title: String? = nil) {
        self.kind = kind
        self.value = value
        self.title = title
    }

    /// The token as it lands in the text: `@kenji.dev`, `#travel`.
    public var token: String { (kind == .mention ? "@" : "#") + value }
    public var id: String { token.lowercased() }
}

/// Where completions come from — the app's search index, behind a feature
/// boundary no composer may cross.
public protocol TextCompletionProviding: Sendable {
    /// Completions for `prefix` (no sigil), best first; empty when there are
    /// none or the source could not answer.
    func completions(for kind: TextEntity.Kind, prefix: String) async -> [TextCompletion]
}

/// Whoever holds the app's `TextCompletionProviding`, found UP THE RESPONDER
/// CHAIN from the field being typed in — the shell's tab bar controller, as
/// for `TextEntityOpening` — so every composer completes without a
/// dependency threaded through the screens that draw one.
@MainActor
public protocol TextCompletionSource: AnyObject {
    var textCompletions: (any TextCompletionProviding)? { get }
}

@MainActor
public enum TextCompletions {
    /// The first provider up `source`'s responder chain.
    public static func provider(from source: UIResponder) -> (any TextCompletionProviding)? {
        sequence(first: source, next: \.next).lazy
            .compactMap { ($0 as? any TextCompletionSource)?.textCompletions }
            .first
    }
}
