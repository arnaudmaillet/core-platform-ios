import CoreModels
import Foundation

/// The sound a video post is set to: a named track, or the author's own
/// "original sound".
///
/// ⚠️ **CLIENT-SIDE UNTIL THE CONTRACT CARRIES IT.** `post.v1` has no audio
/// field yet, so a sound is resolved from the post's clip by whoever the shell
/// hands the feed (`PostSoundProviding`). With nobody to ask, a clip's sound is
/// its own soundtrack — true of the overwhelming majority of short videos —
/// and the feed plays it straight from the clip.
public struct PostSound: Sendable, Equatable, Identifiable {
    public let id: String
    /// The track's name. Nil for an original sound, which is named after its
    /// author instead — only the feed knows the author.
    public let title: String?
    /// Who made the track, when it is a known one.
    public let artist: String?
    /// The FULL sound, playable. It often runs longer than the clip it plays
    /// under; nil means "play the clip's own audio".
    public let previewURL: URL?
    /// A picture to stand for the sound.
    public let artworkURL: URL?
    /// How long `previewURL` runs, when known.
    public let duration: TimeInterval?

    public init(
        id: String, title: String?, artist: String?,
        previewURL: URL?, artworkURL: URL?, duration: TimeInterval?
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.previewURL = previewURL
        self.artworkURL = artworkURL
        self.duration = duration
    }

    /// Whether this is the author's own sound rather than a named track.
    public var isOriginal: Bool { title == nil }
}

/// The posts set to a sound, as the sound page shows them: its "Popular"
/// section — only when the sound has one — and its "Recent" grid.
///
/// **THE BACKEND DECIDES WHETHER THERE IS A POPULAR SECTION** (asked for,
/// 2026-09-30): a sound used by a handful of posts has no "popular" to speak
/// of, and the page then goes from the sound straight to "Recent". An EMPTY
/// `popular` is that answer — the page never invents the section. The page
/// only decides what each section SHOWS of what it is given: the row's first
/// posts, and "Recent" without the posts that row already shows.
///
/// ⚠️ `timeline.v1.GetAudioFeed` can serve `recent` (a chronological page per
/// audio id); nothing serves `popular` yet — see `dev/BACKEND_GAPS.md` #27.
public struct PostSoundRankings: Sendable, Equatable {
    /// Most engaged first — the whole ranking "Popular"'s chevron opens; the
    /// row shows its head. EMPTY when the sound has no Popular section.
    public let popular: [PostID]
    /// Most recently published first — EVERY post that used the sound, the
    /// popular ones included (the page leaves out those its Popular row
    /// already shows).
    public let recent: [PostID]

    public init(popular: [PostID], recent: [PostID]) {
        self.popular = popular
        self.recent = recent
    }

    public static let empty = PostSoundRankings(popular: [], recent: [])

    /// Whether the backend gave the sound a Popular section.
    public var hasPopular: Bool { !popular.isEmpty }
}

/// Answers which sound a post is set to, and which posts use it.
public protocol PostSoundProviding: Sendable {
    /// The sound `postID` plays: under its clip at `clip` when it shows one,
    /// or the song a photograph, a collection or a text post is set to. Nil
    /// when this provider does not know one — for a clip, the feed then treats
    /// it as the clip's original sound; for anything else, the post has none.
    func sound(forPost postID: PostID, clip: URL?) -> PostSound?
    /// The posts set to `sound`, most relevant first.
    func postIDs(using sound: PostSound) -> [PostID]
    /// The posts set to `sound`, ranked for each of the sound page's sections
    /// — `popular` empty when the backend gives the sound no Popular section.
    func rankings(using sound: PostSound) -> PostSoundRankings
    /// The post `sound` was first published with — the clip it was cut from,
    /// or the first post of the author it is credited to. Nil for a track
    /// that came from outside the app (a named artist's song), or when
    /// unknown. The sound page lists it first, marked "Original", when it is
    /// a media post.
    func originalPostID(of sound: PostSound) -> PostID?
}

public extension PostSoundProviding {
    func originalPostID(of sound: PostSound) -> PostID? { nil }

    /// With no ranking of its own, a provider has no Popular section to
    /// give: its one order is the "Recent" grid.
    func rankings(using sound: PostSound) -> PostSoundRankings {
        PostSoundRankings(popular: [], recent: postIDs(using: sound))
    }
}
