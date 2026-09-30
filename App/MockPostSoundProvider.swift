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
///   borrows a sound it did not make — most often one of a few HITS
///   (`chart`), otherwise one from the long tail.
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
    /// The post each sound was first published with: the first post playing
    /// a clip (a borrower earlier in the dataset does not count — the sound
    /// was cut from the clip), or the first post set to a song.
    private let originals: [String: PostID]
    /// When each post was published — the "Recent" grid's order.
    private let publishedAt: [PostID: Int64]
    /// The corpus's views and likes — the "Popular" row's order. Read when a
    /// sheet opens, so a like given in the session counts.
    private let counters: MockCounterStore?

    init(
        clips: MockClipCatalog = .shared, songs: MockSongCatalog = .shared,
        dataset: MockSocialDataset, counters: MockCounterStore? = nil
    ) {
        self.clips = clips
        self.songs = songs
        self.counters = counters
        self.publishedAt = Dictionary(
            dataset.posts.map { (PostID($0.postID), $0.publishedAtMS) }, uniquingKeysWith: { first, _ in first }
        )
        var borrowed: [PostID: String] = [:]
        var postsBySound: [String: [PostID]] = [:]
        var creators: [String: String] = [:]
        var originals: [String: PostID] = [:]
        let handles = Dictionary(dataset.authors.map { ($0.profileID, $0.handle) }, uniquingKeysWith: { a, _ in a })
        for (index, post) in dataset.posts.enumerated() {
            let id = PostID(post.postID)
            let clipIDs = ([post.media?.url] + post.extraMedia.map(\.url))
                .compactMap { $0.flatMap(URL.init(string:)).flatMap { clips.clip(for: $0)?.id } }
            if !clipIDs.isEmpty {
                for clip in Set(clipIDs) {
                    postsBySound[clip, default: []].append(id)
                    if originals[clip] == nil { originals[clip] = id }
                    if creators[clip] == nil, let handle = handles[post.authorProfileID] {
                        creators[clip] = "@\(handle)"
                    }
                }
                continue
            }
            guard index % 5 != 3 else { continue }
            guard let sound = Self.borrowedSoundID(postID: post.postID, index: index, clips: clips, songs: songs)
            else { continue }
            borrowed[id] = sound
            postsBySound[sound, default: []].append(id)
            if sound.hasPrefix("song-") {
                if originals[sound] == nil { originals[sound] = id }
                if creators[sound] == nil, let handle = handles[post.authorProfileID] {
                    creators[sound] = "@\(handle)"
                }
            }
        }
        self.borrowed = borrowed
        self.postsBySound = postsBySound
        self.creators = creators
        self.originals = originals
    }

    func sound(forPost postID: PostID, clip: URL?) -> PostSound? {
        if let clip, let playing = clips.clip(for: clip) { return sound(clip: playing) }
        guard let id = borrowed[postID] else { return nil }
        if let song = songs.song(id: id) { return sound(song: song) }
        return clips.clip(id: id).map { sound(clip: $0) }
    }

    /// Most engaged first — the popular order.
    func postIDs(using sound: PostSound) -> [PostID] {
        rankings(using: sound).popular
    }

    /// The two orders of the sound page, over the same posts:
    /// - **popular**: views plus ten per like (a like is worth ten looks) —
    ///   the counters the feed itself shows;
    /// - **recent**: by publication date, newest first — every post, the
    ///   popular ones included.
    ///
    /// Ties fall back to the dataset's order.
    func rankings(using sound: PostSound) -> PostSoundRankings {
        let posts = postsBySound[sound.id] ?? []
        guard posts.count > 1 else { return PostSoundRankings(popular: posts, recent: posts) }
        let position = Dictionary(posts.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let engagement: [PostID: Int64] = Dictionary(posts.map { id in
            let views = counters?.viewCount(for: id.rawValue) ?? 0
            let likes = counters?.likeCount(for: id.rawValue) ?? 0
            return (id, views + 10 * likes)
        }, uniquingKeysWith: { first, _ in first })
        func ranked(_ key: (PostID) -> Int64) -> [PostID] {
            posts.sorted { key($0) != key($1) ? key($0) > key($1) : position[$0, default: 0] < position[$1, default: 0] }
        }
        return PostSoundRankings(popular: ranked { engagement[$0] ?? 0 }, recent: ranked { publishedAt[$0] ?? 0 })
    }

    /// A clip's sound is its clip's; a song is its first poster's only when
    /// the song names no artist — the one it is credited to. A named artist's
    /// song came from outside and has no original post.
    func originalPostID(of sound: PostSound) -> PostID? {
        if let song = songs.song(id: sound.id), song.artist != nil { return nil }
        return originals[sound.id]
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

// MARK: - Popularity

extension MockPostSoundProvider {
    /// The CHART a borrowing post draws from: a few sounds everybody uses,
    /// then a long tail. Percent of the borrowing posts, most popular first.
    ///
    /// Sized on the corpus (120 posts, 80 without a clip, every fifth of those
    /// silent): in the main timeline the hits land on 15, 8, 6, 5 and 4
    /// borrowers — plus, for the two clips, the clip's own post, and a few
    /// more among the just-arrived and the viewer's own posts (the top one
    /// reads "23 posts") — photographs and text posts mixed, by every kind of
    /// author. What is left (about a third) keeps the old spread, one or two
    /// posts per sound. (Before this, no sound was used by more than two
    /// posts, and the sound sheet's first row and "View all" never showed on
    /// real mock data.)
    private static let chart: [(share: Int, sound: Hit)] = [
        (22, .clip(slot: 0)),   // post-0000's original sound
        (16, .song(slot: 6)),   // "Haru Haru" · BIGBANG, a named track
        (11, .clip(slot: 2)),   // post-0006's original sound
        (8, .song(slot: 11)),   // "This song drops"
        (6, .song(slot: 0)),    // "Champagne Coast (piano cover)"
    ]

    private enum Hit {
        case clip(slot: Int)
        case song(slot: Int)
    }

    /// The sound a post without a clip of its own borrows: a hit when its
    /// roll falls in the chart, else the long tail — two in three a song, one
    /// in three another clip's sound, as before.
    ///
    /// ⚠️ ROLLED ON THE POST ID with FNV-1a, not `hashValue` (seeded per
    /// launch): the same post keeps the same sound on every run, and a hit's
    /// posts are spread over the whole timeline rather than bunched in one
    /// stretch of it — so any feed's slice of the corpus meets the hits.
    static func borrowedSoundID(
        postID: String, index: Int, clips: MockClipCatalog, songs: MockSongCatalog
    ) -> String? {
        let roll = Int(fnv1a(postID) % 100)
        var ceiling = 0
        for entry in chart {
            ceiling += entry.share
            guard roll < ceiling else { continue }
            switch entry.sound {
            case .clip(let slot): return clips.clip(forSlot: slot)?.id
            case .song(let slot): return songs.song(forSlot: slot)?.id
            }
        }
        return index % 3 == 0
            ? clips.clip(forSlot: index / 3)?.id
            : songs.song(forSlot: index)?.id
    }

    private static func fnv1a(_ text: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return hash
    }
}
