import Foundation
import Testing
@testable import CoreStorage

@MainActor
struct PostDraftStoreTests {
    /// A file of its own per test, removed before it starts: nothing here may
    /// read the app's drafts, or another test's.
    private func makeStore(_ name: String = UUID().uuidString) throws -> (PostDraftStore, String) {
        let file = "post-drafts-test-\(name)"
        try CodableFileStore<[PostDraft]>(name: file).clear()
        return (PostDraftStore(name: file), file)
    }

    @Test func aSavedDraftLeadsTheList() throws {
        let (store, _) = try makeStore()

        store.save("First", now: Date(timeIntervalSince1970: 1))
        store.save("Second", now: Date(timeIntervalSince1970: 2))

        #expect(store.drafts.map(\.text) == ["Second", "First"])
    }

    /// Editing a draft saves it IN PLACE of itself — and brings it back to the top.
    @Test func savingOverADraftReplacesIt() throws {
        let (store, _) = try makeStore()
        let first = try #require(store.save("First"))
        store.save("Second")

        store.save("First, revised", replacing: first.id)

        #expect(store.drafts.map(\.text) == ["First, revised", "Second"])
        #expect(store.drafts.first?.id == first.id)
    }

    // MARK: - Voices (#2209)

    private func take(_ seconds: TimeInterval = 4) throws -> PostDraftVoiceTake {
        let url = FileManager.default.temporaryDirectory.appending(path: "store-take-\(UUID().uuidString).m4a")
        try Data([7, 7, 7]).write(to: url)
        return PostDraftVoiceTake(fileURL: url, duration: seconds, waveform: [2, 4])
    }

    /// A voice alone is a draft; its file is copied into the store's folder
    /// and read back after a relaunch.
    @Test func aVoiceIsADraftAndOutlivesTheStore() throws {
        let (store, file) = try makeStore()
        let source = try take(9)

        let draft = try #require(store.save("  ", voice: source))

        let voice = try #require(draft.voice)
        #expect(draft.text.isEmpty)
        #expect(voice.duration == 9)
        #expect(voice.waveform == [2, 4])
        let kept = store.voiceURL(voice)
        #expect(kept.deletingLastPathComponent().standardizedFileURL == store.voiceDirectory.standardizedFileURL)
        #expect(try Data(contentsOf: kept) == Data([7, 7, 7]))
        #expect(FileManager.default.fileExists(atPath: source.fileURL.path), "the caller's file is the caller's")

        let reopened = PostDraftStore(name: file)
        #expect(reopened.drafts.first?.voice == voice)
        store.delete(draft.id)
    }

    /// Saved over with its own file, a voice keeps it; saved over without
    /// one, or deleted, it goes with its file.
    @Test func aVoiceLeavesWithItsDraft() throws {
        let (store, _) = try makeStore()
        let first = try #require(store.save("Hi", voice: try take()))
        let voice = try #require(first.voice)
        let url = store.voiceURL(voice)

        let again = try #require(store.save(
            "Hi again", voice: PostDraftVoiceTake(fileURL: url, duration: 4, waveform: [2, 4]), replacing: first.id
        ))
        #expect(again.voice?.fileName == voice.fileName, "its own file was copied again")
        #expect(FileManager.default.fileExists(atPath: url.path))

        let replaced = try #require(store.save("Hi, new take", voice: try take(2), replacing: first.id))
        #expect(replaced.voice?.fileName != voice.fileName)
        #expect(!FileManager.default.fileExists(atPath: url.path), "the old take stayed behind")

        let words = try #require(store.save("Words only", replacing: first.id))
        #expect(words.voice == nil)
        let newURL = try #require(replaced.voice.map(store.voiceURL))
        #expect(!FileManager.default.fileExists(atPath: newURL.path), "a dropped voice stayed behind")

        let other = try #require(store.save("Other", voice: try take()))
        let otherURL = try #require(other.voice.map(store.voiceURL))
        store.delete(other.id)
        #expect(!FileManager.default.fileExists(atPath: otherURL.path), "a deleted draft left its voice")
    }

    /// A take whose file can't be copied leaves only the words — and no
    /// draft when there were none.
    @Test func aMissingTakeIsNoVoice() throws {
        let (store, _) = try makeStore()
        let gone = PostDraftVoiceTake(
            fileURL: FileManager.default.temporaryDirectory.appending(path: "missing-\(UUID().uuidString).m4a"),
            duration: 3, waveform: []
        )
        #expect(store.save("", voice: gone) == nil)
        let words = try #require(store.save("Words", voice: gone))
        #expect(words.voice == nil)
    }

    /// A list written before voices reads back, each draft without one.
    @Test func draftsWrittenBeforeVoicesDecode() throws {
        let json = #"[{"id":"d1","text":"Old","updatedAtMS":5}]"#
        let drafts = try JSONDecoder().decode([PostDraft].self, from: Data(json.utf8))
        #expect(drafts == [PostDraft(id: "d1", text: "Old", updatedAtMS: 5)])
    }

    @Test func blankTextIsNotADraft() throws {
        let (store, _) = try makeStore()

        #expect(store.save("   \n ") == nil)
        #expect(store.drafts.isEmpty)
    }

    @Test func aDeletedDraftIsGone() throws {
        let (store, _) = try makeStore()
        let draft = try #require(store.save("Gone soon"))

        store.delete(draft.id)

        #expect(store.drafts.isEmpty)
        #expect(store.draft(draft.id) == nil)
    }

    /// Drafts outlive the screen that wrote them.
    @Test func draftsSurviveANewStore() throws {
        let (store, file) = try makeStore()
        store.save("Kept")

        #expect(PostDraftStore(name: file).drafts.map(\.text) == ["Kept"])
    }
}
