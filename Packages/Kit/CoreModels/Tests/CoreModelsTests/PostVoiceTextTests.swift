import CoreModels
import Foundation
import Testing

/// A voice post's words where no player is drawn (#2208): notifications and
/// the share card.
struct PostVoiceTextTests {
    private let voice = PostVoice(assetID: "a", url: nil, duration: 32.7, waveform: [])

    @Test func aVoiceAloneSaysItIsAVoicePostAndHowLong() {
        #expect(voice.previewText(caption: nil) == "🎙 Voice post · 32\u{2033}")
        #expect(voice.previewText(caption: "  \n ") == "🎙 Voice post · 32\u{2033}", "blank words are no words")
    }

    @Test func aVoiceWithWordsShowsTheWordsMarked() {
        #expect(voice.previewText(caption: " Golden hour at the pier ") == "🎙 Golden hour at the pier")
    }

    /// A voice post's length in seconds, as its timer writes it (#2294):
    /// whole, rounded down, never a minute, with the double prime.
    @Test func theLengthIsTheTimersSeconds() {
        #expect(PostVoice.seconds(0) == "0\u{2033}")
        #expect(PostVoice.seconds(6.9) == "6\u{2033}")
        #expect(PostVoice.seconds(60) == "60\u{2033}")
        #expect(PostVoice.seconds(75) == "75\u{2033}", "longer than the limit stays in seconds")
        #expect(PostVoice.seconds(-1) == "0\u{2033}")
        #expect(PostVoice.secondsSign.unicodeScalars.map(\.value) == [0x2033])
    }
}
