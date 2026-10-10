import CoreModels
import FeedInterface
import Foundation
import PostGrid
import Testing
@testable import Feed

/// THE PAGE'S SOUND, WITHOUT THE SCREEN.
///
/// `SnapSoundState` decides which sound a post is set to, what its bubble and
/// attribution draw, whether its song is heard, and what the sound sheet
/// opens with. The mute and Power Saving are READ through closures each test
/// owns — `FeedSound` and `PowerSavingPreference` are process-wide, and no
/// test here touches them.
@MainActor
struct SnapSoundStateTests {
    /// A mute and a Power Saving switch of the test's own.
    @MainActor
    private final class Switches {
        var soundOn = true
        var powerSaving = false
    }

    private static func state(
        _ switches: Switches, provider: (any PostSoundProviding)? = nil
    ) -> SnapSoundState {
        SnapSoundState(
            provider: provider,
            isOn: { switches.soundOn },
            toggle: { switches.soundOn.toggle() },
            powerSaving: { switches.powerSaving }
        )
    }

    private static let clipURL = URL(string: "https://example.test/clip.mp4")!
    private static let otherClipURL = URL(string: "https://example.test/other.mp4")!
    private static let songFile = URL(fileURLWithPath: "/tmp/song.m4a")

    private static func clip(_ id: String = "v1") -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID(id), authorID: ProfileID("a"), authorName: "Ava", metaText: "@ava · 3m",
            avatarURL: URL(string: "https://example.test/ava.jpg"), caption: nil,
            mediaURL: clipURL, mediaKind: .video,
            thumbnailURL: URL(string: "https://example.test/v-thumb.jpg"), audioText: nil
        )
    }

    private static func photo(_ id: String = "p1") -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID(id), authorID: ProfileID("a"), authorName: "Ava", metaText: "",
            avatarURL: nil, caption: "caption",
            mediaURL: URL(string: "https://example.test/a.jpg"), mediaKind: .image,
            thumbnailURL: URL(string: "https://example.test/a-thumb.jpg"), audioText: nil
        )
    }

    // MARK: - Mute

    @Test func theToggleMutesAndUnmutesAndTheFaceFollows() {
        let switches = Switches()
        let sound = Self.state(switches)
        #expect(sound.isOn)
        #expect(sound.face(for: Self.clip(), playingClip: nil).isMuted == false)
        sound.toggle()
        #expect(!sound.isOn)
        #expect(sound.face(for: Self.clip(), playingClip: nil).isMuted)
        sound.toggle()
        #expect(sound.isOn)
        #expect(sound.face(for: Self.clip(), playingClip: nil).isMuted == false)
    }

    @Test func theRecordTurnsOnlyWhenPlayingAudibly() {
        let switches = Switches()
        let sound = Self.state(switches)
        #expect(sound.isAudible(playing: true))
        #expect(!sound.isAudible(playing: false))
        sound.toggle()
        #expect(!sound.isAudible(playing: true), "a muted page's record turned")
    }

    // MARK: - A page without audio

    @Test func aPhotoWithNoSoundHasNothingToHear() {
        let sound = Self.state(Switches())
        let page = Self.photo()
        #expect(sound.sound(for: page, playingClip: nil) == nil)
        #expect(sound.face(for: page, playingClip: nil).isAvailable == false)
        #expect(sound.attribution(for: page, playingClip: nil).sound == SnapMediaAttributionView.SoundCredit.none)
        #expect(sound.song(for: page, playingClip: nil) == nil)
        #expect(sound.sheetInputs(for: page, playingClip: nil) == nil, "a sheet for nothing")
    }

    // MARK: - Which sound

    @Test func aClipWithNobodyToAskPlaysItsOwnOriginalSound() {
        let sound = Self.state(Switches())
        let page = Self.clip()
        let postSound = sound.sound(for: page, playingClip: nil)
        #expect(postSound?.id == "original-v1")
        #expect(postSound?.previewURL == Self.clipURL)
        #expect(postSound?.isOriginal == true)
        #expect(SnapSoundState.line(for: postSound, of: page) == "Original sound · @ava")
        #expect(SnapSoundState.cover(for: postSound) == .artwork(page.thumbnailURL!))
    }

    @Test func aClipNoPlayerCanOpenHasASoundButNoPreview() {
        let sound = Self.state(Switches())
        let clip = FeedItemDisplayModel(
            id: PostID("v2"), authorID: ProfileID("a"), authorName: "Ava", metaText: "",
            avatarURL: nil, caption: nil, mediaURL: URL(string: "mock://clip")!, mediaKind: .video,
            thumbnailURL: nil, audioText: nil
        )
        let postSound = sound.sound(for: clip, playingClip: nil)
        #expect(postSound != nil)
        #expect(postSound?.previewURL == nil)
        #expect(SnapSoundState.line(for: postSound, of: clip) == "Original sound · @Ava", "the name, no handle")
    }

    @Test func theProviderAnswersBeforeTheClip() {
        let provider = FixedSoundProvider(sound: PostSound(
            id: "song-1", title: "Song", artist: "Artist", previewURL: Self.songFile, artworkURL: nil, duration: 30
        ))
        let sound = Self.state(Switches(), provider: provider)
        let postSound = sound.sound(for: Self.clip(), playingClip: nil)
        #expect(postSound?.id == "song-1")
        #expect(SnapSoundState.line(for: postSound, of: Self.clip()) == "Song · Artist")
        #expect(SnapSoundState.cover(for: postSound) == .note, "a named song with no artwork draws the note")
    }

    // MARK: - Page change

    /// The clip a sound belongs to is the one on screen — but only the active
    /// page has one on screen; a neighbour is asked about its head.
    @Test func onlyTheActivePagesPlayingClipCounts() {
        let provider = RecordingSoundProvider()
        let sound = Self.state(Switches(), provider: provider)
        _ = sound.sound(for: Self.clip(), playingClip: Self.otherClipURL)
        _ = sound.sound(for: Self.clip(), playingClip: nil)
        _ = sound.sound(for: Self.photo(), playingClip: nil)
        #expect(provider.asked == [Self.otherClipURL, Self.clipURL, nil])
        #expect(SnapSoundState.clip(of: Self.photo(), playingClip: nil) == nil)
    }

    @Test func aCarouselsSoundIsItsFirstClipPage() {
        let carousel = FeedItemDisplayModel(
            id: PostID("c1"), authorID: ProfileID("a"), authorName: "Ava", metaText: "",
            avatarURL: nil, caption: nil, mediaURL: URL(string: "https://example.test/a.jpg"), mediaKind: .image,
            thumbnailURL: nil, audioText: nil,
            extraMedia: [GalleryPost.MediaPage(
                thumbnailURL: URL(string: "https://example.test/b.jpg"), videoURL: Self.otherClipURL
            )]
        )
        #expect(SnapSoundState.clip(of: carousel, playingClip: nil) == Self.otherClipURL)
        let sound = Self.state(Switches())
        #expect(sound.song(for: carousel, playingClip: nil) == nil, "a carousel with a clip plays the clip")
    }

    // MARK: - What is heard

    @Test func aPhotosSongPlaysOnlyWithTheSoundOnAndNoPowerSaving() {
        let provider = FixedSoundProvider(sound: PostSound(
            id: "song-1", title: "Song", artist: nil, previewURL: Self.songFile, artworkURL: nil, duration: 30
        ))
        let switches = Switches()
        let sound = Self.state(switches, provider: provider)
        #expect(sound.song(for: Self.photo(), playingClip: nil) == Self.songFile)
        switches.powerSaving = true
        #expect(sound.song(for: Self.photo(), playingClip: nil) == nil, "a song under Power Saving")
        switches.powerSaving = false
        sound.toggle()
        #expect(sound.song(for: Self.photo(), playingClip: nil) == nil, "a song while muted")
        #expect(sound.song(for: Self.clip(), playingClip: nil) == nil, "a clip page has no song")
    }

    // MARK: - The sound sheet

    @Test func aClipsOwnSoundOpensTheSheetAsItsOwnOriginal() {
        let sound = Self.state(Switches())
        let page = Self.clip()
        let inputs = sound.sheetInputs(for: page, playingClip: nil)
        #expect(inputs?.sound.id == "original-v1")
        #expect(inputs?.original == page.id)
        #expect(inputs?.rankings == .empty)
        #expect(inputs?.authorHandle == "ava")
        #expect(inputs?.fallbackArtworkURL == page.thumbnailURL)
        #expect(inputs?.offersUseSound == false, "a streamed clip's sound offered to the editor")
    }

    @Test func aHeldSongOpensTheSheetWithTheProvidersAnswers() {
        let provider = FixedSoundProvider(
            sound: PostSound(
                id: "song-1", title: "Song", artist: "Artist", previewURL: Self.songFile, artworkURL: nil, duration: 30
            ),
            rankings: PostSoundRankings(popular: [PostID("x")], recent: [PostID("x"), PostID("y")]),
            original: PostID("y")
        )
        let sound = Self.state(Switches(), provider: provider)
        let inputs = sound.sheetInputs(for: Self.photo(), playingClip: nil)
        #expect(inputs?.rankings.popular == [PostID("x")])
        #expect(inputs?.original == PostID("y"))
        #expect(inputs?.fallbackArtworkURL == nil, "a named song borrowed the post's photo")
        #expect(inputs?.offersUseSound == true)
    }
}

private struct FixedSoundProvider: PostSoundProviding {
    var sound: PostSound
    var rankings: PostSoundRankings = .empty
    var original: PostID?

    func sound(forPost postID: PostID, clip: URL?) -> PostSound? { sound }
    func postIDs(using sound: PostSound) -> [PostID] { rankings.recent }
    func rankings(using sound: PostSound) -> PostSoundRankings { rankings }
    func originalPostID(of sound: PostSound) -> PostID? { original }
}

/// Answers nothing, and remembers which clip each question named.
private final class RecordingSoundProvider: PostSoundProviding, @unchecked Sendable {
    private(set) var asked: [URL?] = []

    func sound(forPost postID: PostID, clip: URL?) -> PostSound? {
        asked.append(clip)
        return nil
    }

    func postIDs(using sound: PostSound) -> [PostID] { [] }
}
