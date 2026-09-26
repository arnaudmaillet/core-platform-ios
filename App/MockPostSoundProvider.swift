import CoreModels
import CoreNetworkingMocks
import FeedInterface
import Foundation

/// The mock corpus's sounds: each real clip's full sound
/// (`MockClipCatalog`), and the posts set to it — every post playing that clip.
///
/// Built once from the dataset, so the answers are table lookups.
struct MockPostSoundProvider: PostSoundProviding {
    private let catalog: MockClipCatalog
    /// Post ids by clip id, in the dataset's order.
    private let postsByClip: [String: [PostID]]

    init(catalog: MockClipCatalog = .shared, dataset: MockSocialDataset) {
        self.catalog = catalog
        var postsByClip: [String: [PostID]] = [:]
        for post in dataset.posts {
            let urls = ([post.media?.url] + post.extraMedia.map(\.url)).compactMap { $0 }
            for url in urls {
                guard let parsed = URL(string: url), let clip = catalog.clip(for: parsed) else { continue }
                postsByClip[clip.id, default: []].append(PostID(post.postID))
            }
        }
        self.postsByClip = postsByClip
    }

    func sound(forVideo videoURL: URL) -> PostSound? {
        guard let clip = catalog.clip(for: videoURL) else { return nil }
        return PostSound(
            id: clip.id,
            title: clip.soundTitle,
            artist: clip.soundArtist,
            previewURL: catalog.soundFileURL(forVideo: videoURL),
            artworkURL: catalog.posterFileURL(forVideo: videoURL),
            duration: clip.soundDuration
        )
    }

    func postIDs(using sound: PostSound) -> [PostID] {
        postsByClip[sound.id] ?? []
    }
}
