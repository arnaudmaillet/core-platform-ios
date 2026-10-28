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
/// opens with. The mute and Low Power Mode are READ through closures each test
/// owns — `FeedSound` and `LowPowerMode` are process-wide, and no
/// test here touches them.
@MainActor
struct SnapSoundStateTests {
    /// A mute and a Low Power Mode of the test's own.
    @MainActor
    private final class Switches {
        var soundOn = true
        var lowPowerMode = false
    }

    private static func state(
        _ switches: Switches, provider: (any PostSoundProviding)? = nil
    ) -> SnapSoundState {
        SnapSoundState(
            provider: provider,
            isOn: { switches.soundOn },
            toggle: { switches.soundOn.toggle() },
            lowPowerMode: { switches.lowPowerMode }
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
        #expect(sound.face(for: Self.clip())?.isMuted == false)
        sound.toggle()
        #expect(!sound.isOn)
        #expect(sound.face(for: Self.clip())?.isMuted == true)
        sound.toggle()
        #expect(sound.isOn)
        #expect(sound.face(for: Self.clip())?.isMuted == false)
    }

    // MARK: - A page without audio

    @Test func aPhotoWithNoSoundHasNothingToHear() {
        let sound = Self.state(Switches())
        let page = Self.photo()
        #expect(sound.sound(for: page) == nil)
        #expect(sound.face(for: page)?.isAvailable == false, "a photo with no sound keeps its greyed slot (#683)")
        #expect(sound.attribution(for: page).sound == SnapMediaAttributionView.SoundCredit.none)
        #expect(sound.song(for: page) == nil)
        #expect(sound.sheetInputs(for: page) == nil, "a sheet for nothing")
    }

    /// ⚠️ A TEXT POST WITH NO SOUND HAS NO SLOT (#1790): no face at all, so
    /// neither the composer's slot nor the page's bubble; a text post WITH a
    /// sound, and every media post, keep theirs.
    @Test func aTextPostWithNoSoundHasNoSlot() {
        let sound = Self.state(Switches())
        let text = FeedItemDisplayModel(
            id: PostID("t1"), authorID: ProfileID("a"), authorName: "Ava", metaText: "",
            avatarURL: nil, caption: "words", mediaURL: nil, mediaKind: .image, thumbnailURL: nil, audioText: nil
        )
        #expect(SnapSoundState.isText(text))
        #expect(sound.face(for: text) == nil, "a text post with no sound kept a slot")
        #expect(!SnapSoundState.isText(Self.photo()))
        #expect(SnapSoundState.hasSoundSlot(isText: false, sound: nil), "a media post lost its greyed slot")
        let song = PostSound(id: "s", title: "Song", artist: nil, previewURL: Self.songFile, artworkURL: nil, duration: nil)
        #expect(SnapSoundState.hasSoundSlot(isText: true, sound: song), "a text post with a sound lost its record")
        #expect(!SnapSoundState.hasSoundSlot(isText: true, sound: nil))
    }

    // MARK: - Which sound

    @Test func aClipWithNobodyToAskPlaysItsOwnOriginalSound() {
        let sound = Self.state(Switches())
        let page = Self.clip()
        let postSound = sound.sound(for: page)
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
        let postSound = sound.sound(for: clip)
        #expect(postSound != nil)
        #expect(postSound?.previewURL == nil)
        #expect(SnapSoundState.line(for: postSound, of: clip) == "Original sound · @Ava", "the name, no handle")
    }

    @Test func theProviderAnswersBeforeTheClip() {
        let provider = FixedSoundProvider(sound: PostSound(
            id: "song-1", title: "Song", artist: "Artist", previewURL: Self.songFile, artworkURL: nil, duration: 30
        ))
        let sound = Self.state(Switches(), provider: provider)
        let postSound = sound.sound(for: Self.clip())
        #expect(postSound?.id == "song-1")
        #expect(SnapSoundState.line(for: postSound, of: Self.clip()) == "Song · Artist")
        #expect(SnapSoundState.cover(for: postSound) == .note, "a named song with no artwork draws the note")
    }

    // MARK: - One sound per post (#1849)

    private static func carousel(
        _ id: String = "c1", headIsClip: Bool = false, clipPage: Bool = true
    ) -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID(id), authorID: ProfileID("a"), authorName: "Ava", metaText: "@ava · 3m",
            avatarURL: nil, caption: nil,
            mediaURL: headIsClip ? clipURL : URL(string: "https://example.test/a.jpg"),
            mediaKind: headIsClip ? .video : .image,
            thumbnailURL: nil, audioText: nil,
            extraMedia: [GalleryPost.MediaPage(
                thumbnailURL: URL(string: "https://example.test/b.jpg"), videoURL: clipPage ? otherClipURL : nil
            )]
        )
    }

    private static let song = PostSound(
        id: "song-1", title: "Song", artist: "Artist", previewURL: songFile, artworkURL: nil, duration: 30
    )

    /// The provider is asked about the POST, once per post, whatever is on
    /// screen: there is no clip to name any more.
    @Test func theProviderIsAskedAboutThePost() {
        let provider = RecordingSoundProvider()
        let sound = Self.state(Switches(), provider: provider)
        _ = sound.sound(for: Self.clip())
        _ = sound.sound(for: Self.carousel())
        #expect(provider.asked == [PostID("v1"), PostID("c1")])
    }

    /// ⚠️ A CAROUSEL NEVER TAKES A SOUND FROM ONE OF ITS MEDIA. With nobody to
    /// ask, a single clip keeps its original sound; a carousel with a clip,
    /// at its head or on a later page, has none: the greyed bubble (#683).
    @Test func aCarouselWithNoSoundIsSilentWhateverItsClips() {
        let sound = Self.state(Switches())
        for carousel in [Self.carousel(), Self.carousel(headIsClip: true)] {
            #expect(SnapSoundState.isCarousel(carousel))
            #expect(!SnapSoundState.isSingleClip(carousel))
            #expect(sound.sound(for: carousel) == nil, "a carousel borrowed a clip's own sound")
            #expect(sound.face(for: carousel)?.isAvailable == false, "the bubble isn't greyed")
            #expect(sound.song(for: carousel) == nil)
            #expect(!SnapSoundState.clipIsHeard(in: carousel), "a carousel's clip is heard")
        }
        #expect(SnapSoundState.isSingleClip(Self.clip()))
        #expect(SnapSoundState.clipIsHeard(in: Self.clip()))
    }

    /// A carousel set to a song plays it as ONE track, on every page —
    /// mixed or pictures only — and its bubble, line and sheet read the same.
    @Test func aCarouselsSongIsThePostsTrack() {
        let sound = Self.state(Switches(), provider: FixedSoundProvider(sound: Self.song))
        for carousel in [Self.carousel(), Self.carousel(clipPage: false), Self.carousel(headIsClip: true)] {
            #expect(sound.song(for: carousel) == Self.songFile)
            #expect(sound.attribution(for: carousel).sound == .sound("Song · Artist"))
            #expect(sound.sheetInputs(for: carousel)?.sound.id == "song-1")
        }
        // A single clip keeps its own player's sound: no song.
        #expect(sound.song(for: Self.clip()) == nil)
    }

    /// ⚠️ LOW POWER MODE, FOLLOWED, DOES NOT SILENCE A CAROUSEL (the owner,
    /// 2026-10-28): its track is the post's sound, as a clip's own is. A
    /// single photograph's song stays silent (#580). The mute silences both.
    @Test func lowPowerModeSilencesAPhotographNotACarousel() {
        let switches = Switches()
        let sound = Self.state(switches, provider: FixedSoundProvider(sound: Self.song))
        switches.lowPowerMode = true
        #expect(sound.song(for: Self.carousel()) == Self.songFile, "a mixed carousel went quiet")
        #expect(sound.song(for: Self.carousel(clipPage: false)) == Self.songFile, "a collection of pictures went quiet")
        #expect(sound.song(for: Self.photo()) == nil, "a photograph's song in Low Power Mode")
        sound.toggle()
        #expect(sound.song(for: Self.carousel()) == nil, "a carousel's track while muted")
        #expect(sound.song(for: Self.photo()) == nil)
    }

    // MARK: - What is heard

    @Test func aPhotosSongPlaysOnlyWithTheSoundOnAndNoLowPowerMode() {
        let provider = FixedSoundProvider(sound: PostSound(
            id: "song-1", title: "Song", artist: nil, previewURL: Self.songFile, artworkURL: nil, duration: 30
        ))
        let switches = Switches()
        let sound = Self.state(switches, provider: provider)
        #expect(sound.song(for: Self.photo()) == Self.songFile)
        switches.lowPowerMode = true
        #expect(sound.song(for: Self.photo()) == nil, "a song in Low Power Mode, followed")
        switches.lowPowerMode = false
        sound.toggle()
        #expect(sound.song(for: Self.photo()) == nil, "a song while muted")
        #expect(sound.song(for: Self.clip()) == nil, "a clip page has no song")
    }

    // MARK: - The sound sheet

    @Test func aClipsOwnSoundOpensTheSheetAsItsOwnOriginal() {
        let sound = Self.state(Switches())
        let page = Self.clip()
        let inputs = sound.sheetInputs(for: page)
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
        let inputs = sound.sheetInputs(for: Self.photo())
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

    func sound(forPost postID: PostID) -> PostSound? { sound }
    func postIDs(using sound: PostSound) -> [PostID] { rankings.recent }
    func rankings(using sound: PostSound) -> PostSoundRankings { rankings }
    func originalPostID(of sound: PostSound) -> PostID? { original }
}

/// Answers nothing, and remembers which post each question named.
private final class RecordingSoundProvider: PostSoundProviding, @unchecked Sendable {
    private(set) var asked: [PostID] = []

    func sound(forPost postID: PostID) -> PostSound? {
        asked.append(postID)
        return nil
    }

    func postIDs(using sound: PostSound) -> [PostID] { [] }
}
