import CoreModels
import Foundation
import Testing
@testable import Notifications

/// A notification about a voice post (#2208): its row says the voice — "🎙
/// Voice post · 32″", or the post's words marked — and, with the switch
/// off, reads as the text post it is.
struct NotificationVoicePostTests {
    private let voice = PostVoice(assetID: "a", url: nil, duration: 32.2, waveform: [])
    private let now = Date(timeIntervalSince1970: 1000)

    private func item(excerpt: String?, voice: PostVoice?, thumbnail: URL? = nil) -> NotificationItem {
        NotificationItem(
            id: "n1", action: .reaction, senderID: ProfileID("prof-9"), senderName: "Ava Moreau",
            otherSenderCount: 0, postSubjectID: PostID("post-1"),
            subjectPreview: NotificationSubjectPreview(thumbnailURL: thumbnail, excerpt: excerpt, voice: voice),
            isRead: false, createdAt: now
        )
    }

    @Test func aVoiceAloneSaysItIsAVoicePost() {
        let model = NotificationDisplayModel(item: item(excerpt: nil, voice: voice), now: now, showsVoice: true)
        #expect(model.excerpt == "🎙 Voice post · 32\u{2033}")
        #expect(model.accessibilityText.contains("🎙 Voice post · 32\u{2033}"))
    }

    @Test func aVoiceWithWordsShowsTheWordsMarked() {
        let model = NotificationDisplayModel(item: item(excerpt: "From the ridge", voice: voice), now: now, showsVoice: true)
        #expect(model.excerpt == "🎙 From the ridge")
    }

    @Test func theSwitchOffReadsAsTheTextPost() {
        #expect(NotificationDisplayModel(item: item(excerpt: "From the ridge", voice: voice), now: now, showsVoice: false)
            .excerpt == "From the ridge")
        #expect(NotificationDisplayModel(item: item(excerpt: nil, voice: voice), now: now, showsVoice: false).excerpt == nil)
    }

    @Test func aPictureKeepsNoLine() {
        let picture = item(excerpt: nil, voice: voice, thumbnail: URL(string: "https://example.com/t.jpg"))
        #expect(NotificationDisplayModel(item: picture, now: now, showsVoice: true).excerpt == nil)
    }
}
