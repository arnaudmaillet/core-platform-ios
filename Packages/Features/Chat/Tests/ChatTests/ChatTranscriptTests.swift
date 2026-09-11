import Testing
@testable import Chat

/// A quoted message's label — the reply draft's author and the quote strip's
/// line. (Quote RESOLUTION, reply to original, is the driver's and is pinned in
/// `ConversationThreadDriverTests`.)
struct ChatTranscriptTests {
    @Test func aQuoteOfTheViewersOwnMessageIsSignedYou() {
        #expect(ChatTranscript.quoteAuthor(isMine: true, peerName: "Ava") == "You")
    }

    @Test func aQuoteOfThePeersMessageIsSignedWithTheirName() {
        #expect(ChatTranscript.quoteAuthor(isMine: false, peerName: "Ava") == "Ava")
    }

    @Test func anUnresolvedPeerFallsBackToANeutralLabel() {
        #expect(ChatTranscript.quoteAuthor(isMine: false, peerName: "") == "Message")
    }

    @Test func aSnippetIsOneTidyLine() {
        #expect(ChatTranscript.snippet("  Line one\nline two \n") == "Line one line two")
    }
}
