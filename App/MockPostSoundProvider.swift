import CoreModels
import CoreNetworkingMocks
import FeedInterface
import Foundation

/// The mock corpus's sounds.
///
/// - A post that plays a real clip (`MockClipCatalog`) is set to that clip's
///   full sound.
/// - A photograph, a collection without a clip or a text post is set to a
///   song (`MockSongCatalog`) or to another clip's sound, the way a post
///   borrows a sound it did not make.
/// - Every fifth of those has none at all, because "No audio" is a state the
///   feed has to show.
///
/// Built once from the dataset, so the answers are table lookups.
struct MockPostSoundProvider: PostSoundProviding {
    private let clips: MockClipCatalog
    private let songs: MockSongCatalog
    /// The sound id each post without a clip is set to.
    private let borrowed: [PostID: String]
    /// Post ids by sound id, in the dataset's order.
    private let postsBySound: [String: [PostID]]
    /// "@handle" credited for each sound with no named artist: the author
    /// whose clip made an original sound, or who first posted with a song —
    /// who a post BORROWING it credits.
    private let creators: [String: String]

    init(clips: MockClipCatalog = .shared, songs: MockSongCatalog = .shared, dataset: MockSocialDataset) {
        self.clips = clips
        self.songs = songs
        var borrowed: [PostID: String] = [:]
        var postsBySound: [String: [PostID]] = [:]
        var creators: [String: String] = [:]
        let handles = Dictionary(dataset.authors.map { ($0.profileID, $0.handle) }, uniquingKeysWith: { a, _ in a })
        for (index, post) in dataset.posts.enumerated() {
            let id = PostID(post.postID)
            let clipIDs = ([post.media?.url] + post.extraMedia.map(\.url))
                .compactMap { $0.flatMap(URL.init(string:)).flatMap { clips.clip(for: $0)?.id } }
            if !clipIDs.isEmpty {
                for clip in Set(clipIDs) {
                    postsBySound[clip, default: []].append(id)
                    if creators[clip] == nil, let handle = handles[post.authorProfileID] {
                        creators[clip] = "@\(handle)"
                    }
                }
                continue
            }
            guard index % 5 != 3 else { continue }
            // Two in three borrow a song, one in three another clip's sound —
            // a spread wide enough that most sounds are used more than once.
            let sound = index % 3 == 0
                ? clips.clip(forSlot: index / 3)?.id
                : songs.song(forSlot: index)?.id
            guard let sound else { continue }
            borrowed[id] = sound
            postsBySound[sound, default: []].append(id)
            if sound.hasPrefix("song-"), creators[sound] == nil, let handle = handles[post.authorProfileID] {
                creators[sound] = "@\(handle)"
            }
        }
        self.borrowed = borrowed
        self.postsBySound = postsBySound
        self.creators = creators
    }

    func sound(forPost postID: PostID, clip: URL?) -> PostSound? {
        if let clip, let playing = clips.clip(for: clip) { return sound(clip: playing) }
        guard let id = borrowed[postID] else { return nil }
        if let song = songs.song(id: id) { return sound(song: song) }
        return clips.clip(id: id).map { sound(clip: $0) }
    }

    func postIDs(using sound: PostSound) -> [PostID] {
        postsBySound[sound.id] ?? []
    }

    private func sound(clip: MockClipCatalog.Clip) -> PostSound {
        PostSound(
            id: clip.id,
            title: clip.soundTitle,
            // An original sound is credited to whoever made the clip.
            artist: clip.soundArtist ?? creators[clip.id],
            previewURL: clips.soundFileURL(clipID: clip.id),
            artworkURL: clips.posterFileURL(clipID: clip.id),
            duration: clip.soundDuration
        )
    }

    private func sound(song: MockSongCatalog.Song) -> PostSound {
        PostSound(
            id: song.id,
            title: song.title,
            artist: song.artist ?? creators[song.id],
            previewURL: songs.fileURL(songID: song.id),
            artworkURL: nil,
            duration: song.duration
        )
    }
}
