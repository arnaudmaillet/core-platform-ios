import CoreNetworkingMocks
import Foundation
import Testing

/// The world seed joins the corpus without moving it: appended at the tail,
/// dated older than everything, authored by authors who already have
/// galleries, carrying its own like counts and coordinates.
struct MockWorldSeedDatasetTests {
    private let plain = MockSocialDataset()
    private let world = MockSocialDataset(seedsWorld: true)

    private var worldPosts: [MockSocialDataset.PostRecord] {
        world.posts.filter { $0.postID.hasPrefix(MockWorldSeed.postIDPrefix) }
    }

    /// The corpus's head is untouched — the counter store's like formula and
    /// the venue walk read array positions, so an insertion would move them.
    @Test func theWorldIsAppendedAndTheCorpusDoesNotMove() {
        #expect(plain.posts.allSatisfy { !$0.postID.hasPrefix(MockWorldSeed.postIDPrefix) },
                "off by default: tests keep their calibrated corpus")
        #expect(world.posts.prefix(plain.posts.count).map(\.postID) == plain.posts.map(\.postID))
        #expect(worldPosts.map(\.postID) == MockWorldSeed.placements.map(\.postID))
        #expect(world.posts.suffix(worldPosts.count).map(\.postID) == worldPosts.map(\.postID))

        let plainCounts = MockCounterStore(dataset: plain)
        let worldCounts = MockCounterStore(dataset: world)
        #expect(plain.posts.allSatisfy { worldCounts.likeCount(for: $0.postID) == plainCounts.likeCount(for: $0.postID) })
    }

    /// The timeline is served in ARRAY order, so the world must also be the
    /// oldest — newest-first holds end to end.
    @Test func theWorldIsTheTimelinesOldestTail() {
        let stamps = world.posts.map(\.publishedAtMS)
        let oldestCorpus = plain.posts.map(\.publishedAtMS).min() ?? 0
        #expect(worldPosts.allSatisfy { $0.publishedAtMS < oldestCorpus })
        let tail = Array(stamps.suffix(worldPosts.count))
        #expect(tail == tail.sorted(by: >), "newest first within the world too")
    }

    /// Existing authors only (their profiles and galleries already exist),
    /// every kind present, every media post a bundled asset.
    @Test func worldPostsAreOrdinaryPosts() {
        let roster = Set(world.authors.prefix(8).map(\.profileID))
        #expect(worldPosts.allSatisfy { roster.contains($0.authorProfileID) })
        #expect(worldPosts.contains { $0.media == nil })
        #expect(worldPosts.contains { $0.media.map { MockMediaFixtures.isVideoURL($0.url) } == true })
        #expect(worldPosts.contains { $0.media.map { !MockMediaFixtures.isVideoURL($0.url) } == true })
        #expect(worldPosts.compactMap(\.media).allSatisfy { $0.url.hasPrefix("mock://") })
        #expect(worldPosts.allSatisfy { $0.location != nil && $0.seededLikes != nil })
    }

    /// Each city's trending post leads it clearly — no tie at the top — and
    /// the geo mock puts every world post where the seed says.
    @Test func everyCityHasOneTrendingPostAndItsPlace() {
        for city in MockWorldSeed.countries.flatMap(\.cities) {
            let likes = city.posts.map(\.likes).sorted(by: >)
            #expect(likes.count >= 2 && likes[0] > likes[1], "\(city.name) has no clear trending post")
        }
        let placed = Dictionary(
            uniqueKeysWithValues: MockGeoDiscoveryService(dataset: world).placements().map { ($0.postID, $0) }
        )
        for placement in MockWorldSeed.placements {
            #expect(placed[placement.postID]?.latitude == placement.latitude)
            #expect(placed[placement.postID]?.longitude == placement.longitude)
        }
    }

    /// Some text posts wear an animated icon on the map (the emote/GIF
    /// face), others their author — exactly as the seed says.
    @Test func iconFacesAreTheSeedsChoice() {
        let icons = world.animatedIconIDsByPostID(catalogue: ["a", "b", "c"])
        for placement in MockWorldSeed.placements {
            if case .text(let iconFace) = placement.post.kind {
                #expect((icons[placement.postID] != nil) == iconFace, "\(placement.postID)")
            } else {
                #expect(icons[placement.postID] == nil)
            }
        }
    }
}
