import Connect
import CoreContracts
import Foundation
import Testing
@testable import CoreNetworking
@testable import CoreNetworkingMocks

/// The mock corpus's pictures are the bundled photographs
/// (`MockPhotoCatalog`): every image post and every photo page of a
/// collection draw from `posts` ("media 2", 2026-10-31), in both catalogs;
/// the galleries and singles are the avatars'.
struct MockPhotoCatalogTests {
    private var catalog: MockPhotoCatalog { .shared }

    private func allMedia(of post: MockSocialDataset.PostRecord) -> [(url: String, width: Int, height: Int)] {
        (post.media.map { [$0] } ?? []) + post.extraMedia
    }

    private func photos(of post: MockSocialDataset.PostRecord) -> [(media: (url: String, width: Int, height: Int),
                                                                     photo: MockPhotoCatalog.Photo?)] {
        allMedia(of: post)
            .filter { !MockMediaFixtures.isVideoURL($0.url) }
            .map { ($0, URL(string: $0.url).flatMap { catalog.photo(for: $0) }) }
    }

    // MARK: - The catalog

    @Test func theBundleCarriesGalleriesOfFiles() throws {
        try #require(!catalog.galleries.isEmpty, "the bundle carries no photo galleries")
        #expect(catalog.galleries.count > 1, "a single gallery cannot show a collection is ONE of them")
        for photo in catalog.photos {
            let url = try #require(URL(string: photo.media.url))
            let file = try #require(catalog.fileURL(forPhoto: url), "\(photo.id) has no file")
            #expect(FileManager.default.fileExists(atPath: file.path))
            #expect(catalog.photo(for: url) == photo)
        }
    }

    /// The import's budget: long side ≤ 1440, and sizes that can drive a
    /// pre-layout (no zero).
    @Test func everyPhotoDeclaresAUsableSizeWithinTheBudget() {
        for photo in catalog.photos {
            #expect(photo.width > 0 && photo.height > 0, "bad size for \(photo.id)")
            #expect(max(photo.width, photo.height) <= 1440, "\(photo.id) is \(photo.width)x\(photo.height)")
        }
    }

    @Test func photoIDsAreUniqueAndNamedAfterTheirGallery() {
        let ids = catalog.photos.map(\.id)
        #expect(Set(ids).count == ids.count)
        for gallery in catalog.galleries {
            for photo in gallery.photos {
                #expect(photo.id.hasPrefix("\(gallery.id)-"), "\(photo.id) sits in \(gallery.id)")
            }
        }
        #expect(!catalog.posts.isEmpty, "the bundle carries no post photos")
        for photo in catalog.posts { #expect(photo.id.hasPrefix("post-"), "\(photo.id) sits in posts") }
    }

    /// A URL that is not a catalog photo stays synthetic: the fetcher paints it.
    @Test func onlyCatalogPhotosResolveToFiles() throws {
        #expect(catalog.fileURL(forPhoto: try #require(URL(string: "mock://media/3?w=10&h=10"))) == nil)
        #expect(catalog.fileURL(forPhoto: try #require(URL(string: "mock://photo/unbundled-3?w=10&h=10"))) == nil)
        #expect(catalog.fileURL(forPhoto: try #require(URL(string: "mock://avatar/1?w=10&h=10"))) == nil)
    }

    /// A collection's pages are a run of `posts`, each collection starting
    /// further on, cycling past the pool's end.
    @Test func collectionPagesRunThroughThePostPhotos() throws {
        let pool = catalog.posts
        try #require(!pool.isEmpty, "the bundle carries no post photos")
        for slot in 0..<3 {
            for page in 0..<(pool.count + 1) {
                let photo = try #require(catalog.photo(inGalleryForSlot: slot, page: page))
                #expect(photo == pool[(slot * MockPhotoCatalog.collectionStride + page) % pool.count])
            }
        }
    }

    // MARK: - The dataset

    /// Every image post and every photo page is a catalog photo, declaring the
    /// photo's TRUE size in the tuple and in the URL — pre-layout crops to the
    /// declared size.
    @Test func everyImageIsACatalogPhotoWithItsTrueSize() throws {
        try #require(!catalog.photos.isEmpty, "the bundle carries no photos")
        for dataset in [MockSocialDataset(), MockSocialDataset(mediaCatalog: .realAssets)] {
            var checked = 0
            for post in dataset.posts {
                for (media, photo) in photos(of: post) {
                    let photo = try #require(photo, "\(post.postID) shows a non-catalog image: \(media.url)")
                    #expect(media.width == photo.width && media.height == photo.height,
                            "\(post.postID) declares \(media.width)x\(media.height) for \(photo.id)")
                    #expect(media.url == photo.media.url)
                    checked += 1
                }
            }
            #expect(checked > 0, "no photo landed in the corpus")
        }
    }

    /// Within a collection the photo pages do not repeat while the pool has
    /// photos left to show.
    @Test func aCollectionDoesNotRepeatAPhotoThePoolCanAvoid() {
        let dataset = MockSocialDataset()
        let collections = dataset.posts.filter { !$0.extraMedia.isEmpty }
        #expect(collections.contains { photos(of: $0).count > 2 }, "no collection carries photo pages")
        for post in collections {
            let pages = photos(of: post).compactMap { $0.photo }
            guard pages.count <= catalog.posts.count else { continue }
            #expect(Set(pages.map(\.id)).count == pages.count, "\(post.postID) repeats a photo")
        }
    }

    /// The main timeline's photos are all different pictures until the pool
    /// is spent.
    @Test func timelinePhotosAreDistinctUntilThePoolIsSpent() {
        let dataset = MockSocialDataset()
        let timeline = dataset.posts.filter { $0.postID.hasPrefix("post-0") }
        let pictures = timeline.compactMap(\.media).filter { $0.url.hasPrefix(MockPhotoCatalog.scheme) }.map(\.url)
        #expect(!pictures.isEmpty)
        #expect(Set(pictures).count == min(pictures.count, catalog.posts.count))
    }

    // MARK: - On the wire and on the map

    /// A photo post's attachment is the photo itself: its URL, its size, a
    /// JPEG MIME, and itself as the thumbnail.
    @Test func aPhotoAttachmentIsItsOwnThumbnail() async throws {
        let bff = MockBFF()
        let dataset = MockSocialDataset()
        MockSocialServices(dataset: dataset, postStore: MockPostStore()).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let posts = Post_V1_PostServiceClient(client: client)

        let post = try #require(dataset.posts.first { !$0.extraMedia.isEmpty && photos(of: $0).count > 1 })
        var request = Post_V1_GetPostRequest()
        request.postID = post.postID
        let view = try await posts.getPost(request: request, headers: [:]).result.get()

        let pictures = view.attachments.filter { !MockMediaFixtures.isVideoURL($0.cdnURL) }
        #expect(pictures.count == photos(of: post).count)
        for attachment in pictures {
            let url = try #require(URL(string: attachment.cdnURL))
            let photo = try #require(catalog.photo(for: url), "\(attachment.cdnURL) is not a catalog photo")
            #expect(attachment.thumbnailURL == attachment.cdnURL)
            #expect(attachment.mimeType == "image/jpeg")
            #expect(Int(attachment.width) == photo.width && Int(attachment.height) == photo.height)
        }
    }

    /// A photo post's map pin is the post's own photo, untouched, in both
    /// catalogs.
    @Test func photoPinsAreThePostsOwnPhoto() {
        for catalog in [MockSocialDataset.MediaCatalog.synthetic, .realAssets] {
            let dataset = MockSocialDataset(mediaCatalog: catalog)
            for post in dataset.posts {
                guard let media = post.media, media.url.hasPrefix(MockPhotoCatalog.scheme) else { continue }
                #expect(MockGeoDiscoveryService.pinURL(forMediaURL: media.url, catalog: catalog) == media.url)
            }
        }
    }
}
