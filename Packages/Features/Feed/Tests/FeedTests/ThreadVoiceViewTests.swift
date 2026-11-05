import CoreModels
import FeedInterface
import Testing
import UIKit
@testable import Feed

/// The voice message's bubble (#2104).
@MainActor
struct ThreadVoiceViewTests {
    @Test func theWidthSaysTheLength() {
        #expect(ThreadVoiceView.width(forDuration: 1) == 140)
        #expect(ThreadVoiceView.width(forDuration: 0.4) == 140)
        #expect(ThreadVoiceView.width(forDuration: 30) == 240)
        #expect(ThreadVoiceView.width(forDuration: 900) == 240)
        let middle = ThreadVoiceView.width(forDuration: 15.5)
        #expect(middle > 140 && middle < 240)
    }

    /// 2 pt bars 2 pt apart: about 45 at 180 pt, re-binned from 100 levels
    /// by their peak.
    @Test func theBarsComeFromTheWidthAndTheLevels() {
        #expect(ThreadVoiceView.barCount(forWidth: 180) == 45)
        var levels = [UInt8](repeating: 3, count: 100)
        levels[2] = 31
        let bars = ThreadVoiceView.rebin(levels, to: 45)
        #expect(bars.count == 45)
        #expect(bars[0] == 31 || bars[1] == 31, "a bin's peak was lost")
        #expect(bars.filter { $0 == 31 }.count == 1)
        #expect(ThreadVoiceView.rebin([], to: 10) == Array(repeating: 0, count: 10))
    }

    @Test func theTimerReadsAsAClock() {
        #expect(ThreadVoiceView.clock(12.9) == "0:12")
        #expect(ThreadVoiceView.clock(65) == "1:05")
        #expect(ThreadVoiceView.clock(3_723) == "1:02:03")
        #expect(ThreadVoiceView.clock(-1) == "0:00")
    }

    private func view(_ state: ThreadVoiceView.State) -> ThreadVoiceView {
        let view = ThreadVoiceView()
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 40)
        view.configure(state, senderName: "Ava")
        view.layoutIfNeeded()
        return view
    }

    /// At rest the duration and, unplayed, the dot; playing the chip takes
    /// the timer's place and the dot goes; paused mid-way the elapsed time.
    @Test func theTimerTheChipAndTheDotFollowThePlayback() {
        var state = ThreadVoiceView.State(levels: Array(repeating: 9, count: 100), duration: 12, unplayed: true)
        let view = view(state)
        #expect(view.debugTimerText == "0:12")
        #expect(view.debugShowsDot)
        #expect(!view.debugShowsChip)
        #expect(view.accessibilityLabel == "Voice message from Ava, 12 seconds, not played")

        state.playback = .playing(progress: 0.5)
        state.speedLabel = "1.5×"
        view.update(state)
        #expect(view.debugShowsChip)
        #expect(view.debugChipTitle == "1.5×")
        #expect(view.debugTimerText == "0:06")
        #expect(view.debugGlyph == "pause.fill")

        state.unplayed = false
        state.playback = .paused(progress: 0.25)
        view.update(state)
        #expect(!view.debugShowsDot)
        #expect(view.debugTimerText == "0:03")
        #expect(view.debugGlyph == "play.fill")
        #expect(view.accessibilityLabel?.hasSuffix(", played") == true)

        state.playback = .loading
        view.update(state)
        #expect(view.debugShowsLoader)
        state.playback = .failed
        view.update(state)
        #expect(view.debugGlyph == "arrow.clockwise")
    }

    /// A reused bubble keeps nothing of the message it showed.
    @Test func reuseResets() {
        let view = view(ThreadVoiceView.State(duration: 40, playback: .playing(progress: 0.8)))
        view.configure(nil)
        #expect(view.isHidden)
        view.configure(ThreadVoiceView.State(duration: 5), senderName: nil)
        #expect(view.debugTimerText == "0:05", "the previous message's progress showed")
        #expect(!view.debugShowsChip)
        #expect(view.state.progress == 0)
        #expect(view.waveform.debugWaiting, "no waveform yet draws the flat row")
    }

    /// A tap on the waveform seeks there.
    @Test func scrubbingSeeks() {
        let view = view(ThreadVoiceView.State(levels: Array(repeating: 9, count: 100), duration: 10))
        var seeks: [Double] = []
        view.onSeek = { fraction, _ in seeks.append(fraction) }
        view.accessibilityIncrement()
        #expect(seeks == [0.5], "VoiceOver's +5 s on a 10 s message")
    }

    /// The next one plays on its own only when it is the very next message,
    /// received, a voice message, unplayed.
    @Test func autoplayPicksOnlyTheNextReceivedUnplayedVoice() {
        func message(_ id: String, voice: Bool, mine: Bool = false) -> ConversationThreadMessage {
            ConversationThreadMessage(
                id: id, senderID: ProfileID(mine ? "me" : "them"), body: voice ? "" : "hi", sentAt: Date(),
                isMine: mine, quote: nil,
                media: voice ? ConversationThreadMedia(kind: .voice, url: URL(string: "file:///\(id).m4a")) : nil,
                delivery: .sent
            )
        }
        let messages = [
            message("a", voice: true), message("b", voice: true), message("c", voice: true, mine: true),
            message("d", voice: true), message("e", voice: false), message("f", voice: true),
        ]
        let next = { (id: String, played: Set<String>) in
            ConversationThreadViewController.nextVoice(after: id, in: messages, isPlayed: { played.contains($0) })
        }
        #expect(next("a", []) == "b")
        #expect(next("a", ["b"]) == nil, "an already played one")
        #expect(next("b", []) == nil, "the viewer's own")
        #expect(next("d", []) == nil, "a text stops it")
        #expect(next("c", []) == nil, "after the viewer's own")
        #expect(next("f", []) == nil, "the last")
    }
}
