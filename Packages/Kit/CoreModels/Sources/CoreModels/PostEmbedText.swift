import Foundation

/// A showcase's words where no card can be drawn (#2216) — a notification's
/// row, a search hit, the share card: "📣 Harbour notes", the author's own
/// text after it — as `PostVoice.previewText` does for a voice (#2208).
extension PostEmbed {
    /// The mark that says a post shows a channel.
    public static let channelMark = "📣"

    /// "📣 Harbour notes" alone; "📣 Harbour notes · Boats in at six" with
    /// the author's words. `caption` is shown as given (trimmed): the caller
    /// shortens it as its surface shortens captions.
    public func previewText(caption: String?) -> String {
        let words = caption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title: String
        switch self {
        case .channel(let channel): title = "\(Self.channelMark) \(channel.displayName)"
        }
        return words.isEmpty ? title : "\(title) · \(words)"
    }
}
