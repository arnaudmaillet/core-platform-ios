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

/// Answers which sound a post is set to, and which posts use it.
public protocol PostSoundProviding: Sendable {
    /// The sound `postID` plays: under its clip at `clip` when it shows one,
    /// or the song a photograph, a collection or a text post is set to. Nil
    /// when this provider does not know one — for a clip, the feed then treats
    /// it as the clip's original sound; for anything else, the post has none.
    func sound(forPost postID: PostID, clip: URL?) -> PostSound?
    /// The posts set to `sound`, most relevant first — the sound page's grid.
    func postIDs(using sound: PostSound) -> [PostID]
}
