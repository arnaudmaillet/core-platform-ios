import Foundation

/// How a quoted message is labelled wherever a conversation quotes one — the
/// reply draft the composer names and the quote strip above a reply.
///
/// This used to build the whole bubble transcript — day sections, same-sender
/// runs, bubble times. The conversation is drawn by Feed's text-post screen
/// now, which groups its own days, so the quote's labelling is all chat still
/// owns here.
enum ChatTranscript {
    /// The display name for a quoted message's author: "You" for the viewer's
    /// own, the correspondent's name otherwise (a neutral fallback covers the
    /// brief window before the peer name resolves).
    static func quoteAuthor(isMine: Bool, peerName: String) -> String {
        isMine ? "You" : (peerName.isEmpty ? "Message" : peerName)
    }

    /// Collapses a body to a single tidy line for a quoted preview; the label
    /// handles visual truncation.
    static func snippet(_ body: String) -> String {
        body.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
