import CoreModels
import FeedInterface
import Foundation
import Testing
import UIKit
import VoiceKit
import VoiceKitUI
@testable import Feed

/// The text composer records a voice post (#2209): the thread's composer
/// with a minute's limit, and a draft that publishes the take.
@MainActor
struct VoicePostComposerTests {
    @Test func theVoiceComposerTakesAPostsMinute() {
        let recorder = VoiceRecorder()
        _ = VoiceComposer(recorder: recorder, draftKey: "text-post-voice", limit: TextPostVoice.maximumDuration)
        #expect(recorder.limit == 60)
        // A conversation's keeps its five minutes.
        let thread = VoiceRecorder()
        _ = VoiceComposer(recorder: thread, draftKey: "conversation")
        #expect(thread.limit == VoiceRecorder.maximumDuration)
    }

    /// The post's composer writes its take's time in seconds (#2294); a
    /// conversation's keeps the clock.
    @Test func thePostsComposerCountsInSeconds() {
        let post = VoiceComposer(
            recorder: VoiceRecorder(), draftKey: "text-post-voice", limit: TextPostVoice.maximumDuration,
            timerStyle: VoiceView.TimerStyle(role: .post(author: nil))
        )
        #expect(post.debugStrip.timerStyle == .seconds)
        let thread = VoiceComposer(recorder: VoiceRecorder(), draftKey: "conversation")
        #expect(thread.debugStrip.timerStyle == .clock)
    }

    /// Recording a post: "12″" counting up, then "-7″" in red for the last
    /// ten seconds; VoiceOver says seconds, and what is left.
    @Test func aPostsTakeCountsUpThenDownInSeconds() {
        let strip = VoiceRecordingStrip(frame: CGRect(x: 0, y: 0, width: 300, height: 44))
        strip.timerStyle = .seconds
        strip.setTime(12.4, remaining: 47.6)
        #expect(strip.debugTimerText == "12\u{2033}")
        #expect(!strip.debugTimerIsRunningOut)
        #expect(strip.debugTimerAccessibilityLabel == "12 seconds")

        strip.setTime(53.2, remaining: 6.8)
        #expect(strip.debugTimerText == "-7\u{2033}", "the countdown rounds up, as the clock's")
        #expect(strip.debugTimerIsRunningOut)
        #expect(strip.debugTimerAccessibilityLabel == "7 seconds left")

        strip.setTime(50, remaining: 10)
        #expect(strip.debugTimerText == "-10\u{2033}")
    }

    /// A voice message's take is unchanged: the clock, "-0:07" in red.
    @Test func aMessagesTakeKeepsTheClock() {
        let strip = VoiceRecordingStrip(frame: CGRect(x: 0, y: 0, width: 300, height: 44))
        strip.setTime(12.4, remaining: nil)
        #expect(strip.debugTimerText == "0:12")
        #expect(strip.debugTimerAccessibilityLabel == "12 seconds")
        strip.setTime(293.2, remaining: 6.8)
        #expect(strip.debugTimerText == "-0:07")
        #expect(strip.debugTimerIsRunningOut)
    }

    /// A style set after a time was shown writes that time again in it.
    @Test func aNewStyleRewritesTheTimeShown() {
        let strip = VoiceRecordingStrip(frame: CGRect(x: 0, y: 0, width: 300, height: 44))
        strip.setTime(42, remaining: nil)
        #expect(strip.debugTimerText == "0:42")
        strip.timerStyle = .seconds
        #expect(strip.debugTimerText == "42\u{2033}")
    }

    @Test func aDraftWithoutVoiceKeepsTodaysComposer() {
        let draft = PostDetailDraft { text, _ in
            FeedEntry(
                post: Post(id: PostID("p"), authorID: ProfileID("a"), caption: text, attachments: [], publishedAt: Date()),
                author: AuthorSummary(id: ProfileID("a"), handle: "a", displayName: "A", avatarURL: nil)
            )
        }
        #expect(draft.publishVoice == nil, "a text-only draft offered a voice")
    }
}
