import CoreModels
import Foundation
import Testing

/// A comment's attachment (#2309): a value by kind, voice first, and a kind
/// this build doesn't know kept safely rather than failing the comment.
struct CommentAttachmentTests {
    private let voice = PostVoice(
        assetID: "voice-short", url: URL(string: "https://cdn.example/c.m4a"), duration: 2.9,
        waveform: [0, 7, 31, 12]
    )

    @Test func aVoiceIsTheVoiceKind() {
        let attachment = CommentAttachment.voice(voice)
        #expect(attachment.kind == .voice)
        #expect(attachment.voice == voice)
        #expect(attachment.isSupported)
    }

    @Test func anUnknownKindKeepsItsNameAndIsNoVoice() {
        let attachment = CommentAttachment.unsupported(CommentAttachment.Kind(rawValue: "hologram"))
        #expect(attachment.kind.rawValue == "hologram")
        #expect(attachment.voice == nil)
        #expect(!attachment.isSupported)
    }

    @Test func aStoredVoiceReadsBack() throws {
        let attachment = CommentAttachment.voice(voice)
        let decoded = try JSONDecoder().decode(CommentAttachment.self, from: JSONEncoder().encode(attachment))
        #expect(decoded == attachment)
    }

    /// A record written by a later build, with a kind this one doesn't know,
    /// reads as `.unsupported` instead of failing the record it sits in.
    @Test func aStoredUnknownKindReadsAsUnsupported() throws {
        let json = Data(#"{"kind":"video","video":{"assetID":"v1","durationMs":4000}}"#.utf8)
        let decoded = try JSONDecoder().decode(CommentAttachment.self, from: json)
        #expect(decoded == .unsupported(CommentAttachment.Kind(rawValue: "video")))
        let again = try JSONDecoder().decode(CommentAttachment.self, from: JSONEncoder().encode(decoded))
        #expect(again == decoded)
    }
}
