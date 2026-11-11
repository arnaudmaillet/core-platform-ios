import Foundation

/// A voice post's words where no player can be drawn (#2208) — a
/// notification's row, the share card: the voice as text, until the backend
/// sends it (core-platform-backend#994).
extension PostVoice {
    /// The mark that says a post speaks.
    public static let textMark = "🎙"

    /// "🎙 Voice post · 32″" for a voice alone; "🎙 Golden hour…" — the
    /// caption, marked — when it has words too. `caption` is shown as given
    /// (trimmed): the caller shortens it as its surface shortens captions.
    public func previewText(caption: String?) -> String {
        let words = caption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard words.isEmpty else { return "\(Self.textMark) \(words)" }
        return "\(Self.textMark) Voice post · \(Self.seconds(duration))"
    }

    /// The seconds sign (#2294): the double prime, U+2033.
    public static let secondsSign = "\u{2033}"

    /// A voice post's length as its timer writes it (#2294): whole seconds,
    /// rounded down, and the seconds sign — "0″", "7″", "60″", "75″"
    /// (`VoiceView.seconds`, which CoreModels cannot reach).
    public static func seconds(_ length: TimeInterval) -> String {
        "\(max(0, Int(length.rounded(.down))))\(secondsSign)"
    }
}
