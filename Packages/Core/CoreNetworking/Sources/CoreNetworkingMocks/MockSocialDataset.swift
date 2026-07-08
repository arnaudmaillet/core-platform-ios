import Foundation

/// Deterministic fixture data shared by the timeline/post/profile mocks:
/// 8 authors and 120 posts with varied caption lengths and media shapes, so
/// the feed exercises real layout diversity without any randomness between
/// runs.
public struct MockSocialDataset: Sendable {
    public struct Author: Sendable {
        public let profileID: String
        public let handle: String
        public let displayName: String
        public let avatarURL: String
    }

    public struct PostRecord: Sendable {
        public let postID: String
        public let authorProfileID: String
        public let caption: String
        /// (url, width, height); nil for text-only posts.
        public let media: (url: String, width: Int, height: Int)?
        public let publishedAtMS: Int64
    }

    /// The profile owned by the mock login account (MockAuthService.accountID).
    public static let viewerProfileID = "prof-demo-viewer"

    public let authors: [Author]
    public let posts: [PostRecord]

    public init(postCount: Int = 120) {
        let names: [(String, String)] = [
            ("ava.moreau", "Ava Moreau"),
            ("kenji.dev", "Kenji Tanaka"),
            ("lena_klein", "Lena Klein"),
            ("marcus.holt", "Marcus Holt"),
            ("sofia.reyes", "Sofía Reyes"),
            ("tom.okafor", "Tom Okafor"),
            ("yuki.snow", "Yuki Shirakawa"),
            ("zed.aldrin", "Zed Aldrin")
        ]
        authors = names.enumerated().map { index, name in
            Author(
                profileID: "prof-\(index)",
                handle: name.0,
                displayName: name.1,
                avatarURL: "mock://avatar/\(index)?w=128&h=128"
            )
        }

        let captionBank = [
            "Golden hour at the pier.",
            "Shipped a thing today. Small, but mine.",
            "Coffee count: unreasonable. Progress: acceptable. The refactor is finally starting to pay for itself and the test suite agrees.",
            "No caption needed.",
            "Weekend build log: rebuilt the pipeline end to end, found two race conditions that only reproduce on cold caches, and learned more about backpressure than I ever wanted to. Writing it up properly this week — the short version is that the queue was never the problem, the clock was.",
            "New city, same habits.",
            "Testing in production is fine if production is your simulator.",
            "The mountains were louder than the city this time. Three days offline and the feed can wait."
        ]
        // Aspect ratios the layout must handle: portrait, landscape, square.
        let mediaShapes: [(Int, Int)] = [(1080, 1350), (1600, 900), (1080, 1080), (900, 1600)]

        var records: [PostRecord] = []
        let newestMS: Int64 = 1_780_000_000_000 // fixed epoch so ordering is stable
        for index in 0..<postCount {
            let author = authors[index % authors.count]
            let caption = captionBank[index % captionBank.count]
            // One of every three posts is video, one image, one text-only —
            // a mix that exercises all three snap-feed cell paths.
            let hasMedia = index % 3 != 2
            let isVideo = index % 3 == 0
            let mediaHost = isVideo ? "video" : "media"
            let shape = mediaShapes[index % mediaShapes.count]
            records.append(PostRecord(
                postID: String(format: "post-%04d", index),
                authorProfileID: author.profileID,
                caption: caption,
                media: hasMedia ? ("mock://\(mediaHost)/\(index)?w=\(shape.0)&h=\(shape.1)", shape.0, shape.1) : nil,
                publishedAtMS: newestMS - Int64(index) * 180_000 // 3 minutes apart, newest first
            ))
        }
        posts = records
    }

    public func author(for profileID: String) -> Author? {
        authors.first { $0.profileID == profileID }
    }

    public func post(for postID: String) -> PostRecord? {
        posts.first { $0.postID == postID }
    }
}
