import CoreModels
import Foundation
import Testing

/// A voice post's words where no player is drawn (#2208): notifications and
/// the share card.
struct PostVoiceTextTests {
    private let voice = PostVoice(assetID: "a", url: nil, duration: 32.7, waveform: [])

    @Test func aVoiceAloneSaysItIsAVoicePostAndHowLong() {
        #expect(voice.previewText(caption: nil) == "🎙 Voice post · 0:32")
        #expect(voice.previewText(caption: "  \n ") == "🎙 Voice post · 0:32", "blank words are no words")
    }

    @Test func aVoiceWithWordsShowsTheWordsMarked() {
        #expect(voice.previewText(caption: " Golden hour at the pier ") == "🎙 Golden hour at the pier")
    }

    @Test func theClockIsTheTimers() {
        #expect(PostVoice.clock(0) == "0:00")
        #expect(PostVoice.clock(6.9) == "0:06")
        #expect(PostVoice.clock(724) == "12:04")
        #expect(PostVoice.clock(3_723) == "1:02:03")
    }
}
