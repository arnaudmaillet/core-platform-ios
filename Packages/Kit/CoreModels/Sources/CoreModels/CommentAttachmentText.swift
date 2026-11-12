import Foundation

/// A comment as ONE LINE OF WORDS (#2309, piece 2): wherever a surface draws
/// a comment's text in a line — the band, the danmaku, the subtitle zone, a
/// share — and no attachment can be drawn.
extension CommentAttachment {
    /// The neutral line for an attachment this build can't draw, when the
    /// comment has no words of its own. Never an empty string.
    public static let unsupportedLine = "Attachment"

    /// The comment's words, trimmed, when it has some — its attachment is
    /// then the row's business only. Without words: a voice says "🎙 12″"
    /// (the mark and its length in seconds, #2294's format), a kind this
    /// build doesn't know says `unsupportedLine`. A comment with neither
    /// is its (empty) words. Pure.
    public static func oneLineText(body: String, attachment: CommentAttachment?) -> String {
        let words = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard words.isEmpty, let attachment else { return words }
        switch attachment {
        case .voice(let voice): return "\(PostVoice.textMark) \(PostVoice.seconds(voice.duration))"
        case .unsupported: return unsupportedLine
        }
    }

    /// Whether `body` has words: what Copy and Select Text need (#2309, D).
    public static func hasWords(_ body: String) -> Bool {
        !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
