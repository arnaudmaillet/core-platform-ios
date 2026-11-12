import CoreModels
import Foundation
import Testing

/// A comment as one line of words (#2309, piece 2): its text when it has
/// some, "🎙 12″" for a voice alone, a neutral line for a kind this build
/// doesn't know — never an empty string for a comment that carries something.
struct CommentAttachmentTextTests {
    private let voice = PostVoice(assetID: "a", url: nil, duration: 12.8, waveform: [])
    private let future = CommentAttachment.unsupported(CommentAttachment.Kind(rawValue: "x-future"))

    @Test func aVoiceAloneSaysTheMarkAndItsSeconds() {
        #expect(CommentAttachment.oneLineText(body: "", attachment: .voice(voice)) == "🎙 12\u{2033}")
        #expect(CommentAttachment.oneLineText(body: "  \n ", attachment: .voice(voice)) == "🎙 12\u{2033}",
                "blank words are no words")
    }

    @Test func aVoiceWithWordsIsItsWords() {
        #expect(CommentAttachment.oneLineText(body: " Out loud 😂 ", attachment: .voice(voice)) == "Out loud 😂")
    }

    @Test func anUnknownKindIsItsWordsOrTheNeutralLine() {
        #expect(CommentAttachment.oneLineText(body: "From a newer app", attachment: future) == "From a newer app")
        #expect(CommentAttachment.oneLineText(body: "", attachment: future) == CommentAttachment.unsupportedLine)
        #expect(!CommentAttachment.unsupportedLine.isEmpty)
    }

    @Test func aPlainCommentIsItsWords() {
        #expect(CommentAttachment.oneLineText(body: " GG ", attachment: nil) == "GG")
        #expect(CommentAttachment.oneLineText(body: "", attachment: nil) == "")
    }

    @Test func wordsAreWhatCopyNeeds() {
        #expect(CommentAttachment.hasWords("Hi"))
        #expect(!CommentAttachment.hasWords(" \n"))
        #expect(!CommentAttachment.hasWords(""))
    }
}
