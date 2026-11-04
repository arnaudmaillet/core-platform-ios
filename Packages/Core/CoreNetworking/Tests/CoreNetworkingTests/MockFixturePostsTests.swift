import Foundation
import Testing
@testable import CoreNetworkingMocks

/// The posts for shapes the corpus lacks (the comments sandbox, #2087): each
/// reached by its id, drawing a bundled fixture photo, and listed nowhere.
struct MockFixturePostsTests {
    private let catalog = MockPhotoCatalog.shared
    private let dataset = MockSocialDataset()

    @Test func everyFixturePhotoHasItsFileAndAPost() throws {
        try #require(!catalog.fixtures.isEmpty, "the bundle carries no fixture photos")
        for photo in catalog.fixtures {
            let url = try #require(URL(string: photo.media.url))
            #expect(catalog.fileURL(forPhoto: url) != nil, "\(photo.id) has no file")
            let post = try #require(dataset.post(for: "post-\(photo.id)"))
            #expect(post.media?.url == photo.media.url)
        }
    }

    /// The shapes they are for: a 2:3 photo, and one taller than 9:16.
    @Test func theFixturesCoverTheMissingShapes() {
        let ratios = catalog.fixtures.map { Double($0.width) / Double($0.height) }
        #expect(ratios.contains { abs($0 - 2.0 / 3.0) < 0.001 })
        #expect(ratios.contains { $0 < 9.0 / 16.0 })
    }

    /// No post, avatar or banner draws from them.
    @Test func theFixturesStayOutOfEveryPool() {
        let ids = Set(catalog.fixtures.map(\.id))
        #expect(catalog.photos.allSatisfy { !ids.contains($0.id) })
        #expect(catalog.galleries.allSatisfy { $0.id != MockPhotoCatalog.fixturesID })
        let urls = Set(catalog.fixtures.map(\.media.url))
        #expect(dataset.posts.allSatisfy { post in
            !([post.media].compactMap { $0 } + post.extraMedia).contains { urls.contains($0.url) }
        })
    }
}
