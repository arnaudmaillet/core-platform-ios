import Foundation
import Testing
import UIKit
@testable import VoiceKitUI

/// A voice's length follows what the voice is (#2294, the owner
/// 2026-11-11): a voice post in seconds, "30″", wherever its length shows;
/// a voice message on the clock, "0:30", as before.
@MainActor
struct VoiceTimerFormatTests {
    // MARK: - The formats

    /// Whole seconds, rounded down as the clock rounds them, never a minute.
    @Test func secondsAreWholeAndNeverAMinute() {
        #expect(VoiceView.seconds(0) == "0\u{2033}")
        #expect(VoiceView.seconds(7.9) == "7\u{2033}", "rounded down, as the clock")
        #expect(VoiceView.seconds(60) == "60\u{2033}", "the limit, not a minute")
        #expect(VoiceView.seconds(75) == "75\u{2033}", "longer than the limit stays in seconds")
        #expect(VoiceView.seconds(-1) == "0\u{2033}")
    }

    /// The sign is the double prime, right after the digits: not a straight
    /// quote, not a curly one, no space.
    @Test func theSignIsTheDoublePrime() {
        let text = VoiceView.seconds(30)
        #expect(VoiceView.secondsSign.unicodeScalars.map(\.value) == [0x2033])
        #expect(text.unicodeScalars.last?.value == 0x2033)
        #expect(!text.contains("\"") && !text.contains("\u{201D}") && !text.contains(" "))
        let digits = text.dropLast()
        #expect(digits.allSatisfy { $0.isNumber })
    }

    /// The clock is unchanged for a message.
    @Test func theClockIsUnchanged() {
        #expect(VoiceView.timerText(30, style: .clock) == "0:30")
        #expect(VoiceView.timerText(299, style: .clock) == "4:59")
        #expect(VoiceView.timerText(30, style: .seconds) == "30\u{2033}")
    }

    /// One place decides: a post's seconds, a message's clock.
    @Test func theRoleDecidesTheStyle() {
        #expect(VoiceView.TimerStyle(role: .post(author: "Ava")) == .seconds)
        #expect(VoiceView.TimerStyle(role: .post(author: nil)) == .seconds)
        #expect(VoiceView.TimerStyle(role: .message) == .clock)
        #expect(VoiceMarkView.timerStyle == .seconds, "the mark is only ever a post's")
    }

    /// VoiceOver says seconds for a post, never the sign; a message's clock
    /// reads as it always did.
    @Test func voiceOverSaysSeconds() {
        #expect(VoiceView.spokenTime(30, style: .seconds) == "30 seconds")
        #expect(VoiceView.spokenTime(1.4, style: .seconds) == "1 second")
        #expect(VoiceView.spokenTime(30, style: .clock) == "0:30")
    }

    // MARK: - The panel and the mark

    private func panel(role: VoiceView.Role, duration: TimeInterval) -> VoiceView {
        let view = VoiceView(size: .compact)
        view.role = role
        view.configure(VoiceView.State(levels: VoiceView.genericLevels, duration: duration))
        view.frame = CGRect(x: 0, y: 0, width: 320, height: VoiceView.panelHeight(for: .compact))
        view.layoutIfNeeded()
        return view
    }

    /// A post's panel says seconds at rest and while it plays; a message's
    /// says the clock.
    @Test(arguments: [TimeInterval(8), 42, 60])
    func aPostsPanelSaysSecondsAMessagesTheClock(_ duration: TimeInterval) {
        let post = panel(role: .post(author: nil), duration: duration)
        let message = panel(role: .message, duration: duration)
        #expect(post.timerStyle == .seconds && message.timerStyle == .clock)
        #expect(post.debugTimerText == "\(Int(duration))\u{2033}")
        #expect(message.debugTimerText == VoiceView.clock(duration))
        // Paused mid-way, the time reached, in the same format.
        let paused = VoiceView.State(
            levels: VoiceView.genericLevels, duration: duration, playback: .paused(progress: 0.5)
        )
        post.update(paused)
        message.update(paused)
        #expect(post.debugTimerText == VoiceView.seconds(duration / 2))
        #expect(message.debugTimerText == VoiceView.clock(duration / 2))
    }

    /// VoiceOver reads a post's panel in seconds — its label and its value —
    /// and a message's value on the clock, as before.
    @Test func voiceOverReadsAPostsPanelInSeconds() {
        let post = panel(role: .post(author: "Ava"), duration: 30)
        #expect(post.accessibilityLabel == "Voice post by Ava, 30 seconds")
        #expect(post.accessibilityValue == "30 seconds, speed 1×")
        #expect(post.accessibilityValue?.contains(VoiceView.secondsSign) == false)
        let message = panel(role: .message, duration: 30)
        #expect(message.accessibilityValue == "0:30, speed 1×")
    }

    /// The mark on a voice post's caption says its seconds.
    @Test func theMarkSaysSeconds() {
        let mark = VoiceMarkView()
        mark.configure(duration: 42, levels: nil)
        #expect(mark.debugDurationText == "42\u{2033}")
        #expect(mark.accessibilityDescription == "Voice post, 42 seconds", "VoiceOver says seconds, not the sign")
    }
}
