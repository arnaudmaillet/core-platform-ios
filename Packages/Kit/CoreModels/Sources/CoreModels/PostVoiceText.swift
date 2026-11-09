import Foundation

/// A voice post's words where no player can be drawn (#2208) — a
/// notification's row, the share card: the voice as text, until the backend
/// sends it (core-platform-backend#994).
extension PostVoice {
    /// The mark that says a post speaks.
    public static let textMark = "🎙"

    /// "🎙 Voice post · 0:32" for a voice alone; "🎙 Golden hour…" — the
    /// caption, marked — when it has words too. `caption` is shown as given
    /// (trimmed): the caller shortens it as its surface shortens captions.
    public func previewText(caption: String?) -> String {
        let words = caption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard words.isEmpty else { return "\(Self.textMark) \(words)" }
        return "\(Self.textMark) Voice post · \(Self.clock(duration))"
    }

    /// A length as the voice component's timer writes it: "0:32", "12:04",
    /// "1:02:03" (`VoiceView.clock`, which CoreModels cannot reach).
    public static func clock(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        let hours = whole / 3_600, minutes = whole % 3_600 / 60, rest = whole % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }
}
