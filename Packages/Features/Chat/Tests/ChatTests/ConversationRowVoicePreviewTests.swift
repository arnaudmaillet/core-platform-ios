import Testing
import UIKit
@testable import Chat

/// A voice message's preview in the inbox (the owner, 2026-11-07): the
/// waveform symbol, not the microphone emoji.
@MainActor
struct ConversationRowVoicePreviewTests {
    @Test func aVoicePreviewLeadsWithTheWaveformSymbol() throws {
        let line = try #require(ConversationRowView.voicePreview("🎤 Voice message (0:12)"))
        var attachments = 0
        line.enumerateAttribute(.attachment, in: NSRange(location: 0, length: line.length)) { value, _, _ in
            if value is NSTextAttachment { attachments += 1 }
        }
        #expect(attachments == 1)
        #expect(line.string.hasSuffix(" Voice message (0:12)"))
        #expect(!line.string.contains("🎤"))
    }

    @Test func anyOtherPreviewIsLeftAlone() {
        #expect(ConversationRowView.voicePreview("Photo or video") == nil)
        #expect(ConversationRowView.voicePreview("I sang 🎤 last night") == nil)
    }
}
