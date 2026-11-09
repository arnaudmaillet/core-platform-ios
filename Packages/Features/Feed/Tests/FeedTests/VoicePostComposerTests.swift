import CoreModels
import FeedInterface
import Foundation
import Testing
import VoiceKit
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
