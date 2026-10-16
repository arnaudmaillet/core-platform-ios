import Foundation
import Testing
@testable import CoreNetworkingMocks

/// ⚠️ ONE MEDIA, ONE POST (the owner, 2026-10-16): across the whole mock
/// world — the timeline, the viewer's posts, the arrivals and their test
/// collections, the world on the map — no two posts share a clip or a
/// picture while the catalogs last, and a gallery is one carousel, whole.
@MainActor
struct MockMediaUniquenessTests {
    private let clips = MockClipCatalog.shared
    private let photos = MockPhotoCatalog.shared
    private let dataset = MockSocialDataset(seedsWorld: true)

    /// Every media URL a post carries, head first.
    private func urls(_ post: MockSocialDataset.PostRecord) -> [String] {
        ([post.media?.url] + post.extraMedia.map(\.url)).compactMap { $0 }
    }

    /// Clip uses, in the order the world draws them.
    private var clipUses: [String] {
        dataset.posts.flatMap(urls).compactMap { URL(string: $0).flatMap(clips.clip(for:))?.id }
    }

    /// No clip twice until every clip has been used once.
    @Test func noClipRepeatsWhileTheCatalogLasts() {
        let uses = clipUses
        #expect(!uses.isEmpty)
        #expect(Set(uses).count == min(uses.count, clips.clips.count),
                "\(uses.count) clip uses over \(clips.clips.count) clips, \(Set(uses).count) distinct")
    }

    /// Past the catalog's end a clip repeats as LITTLE as it can (the
    /// owner, 2026-10-16): no clip is used more than once more than any
    /// other that may repeat, and a unique-sound clip is used once only.
    @Test func repeatsAreSpreadAndSpareUniqueSounds() {
        var counts: [String: Int] = [:]
        for id in clipUses { counts[id, default: 0] += 1 }
        let unique = Set(clips.clips.filter { !$0.lendsItsSound }.map(\.id))
        for id in unique { #expect(counts[id, default: 0] <= 1, "\(id) is two posts' sound") }
        let shared = counts.filter { !unique.contains($0.key) }.map(\.value)
        #expect((shared.max() ?? 0) - (shared.min() ?? 0) <= 1, "repeats bunch on some clips")
    }

    /// A single-photo post's picture is no other single-photo post's.
    @Test func noSinglePhotoRepeats() {
        let singles = dataset.posts.filter { $0.extraMedia.isEmpty }
            .compactMap(\.media?.url).filter { $0.hasPrefix(MockPhotoCatalog.scheme) }
        #expect(!singles.isEmpty)
        let pool = photos.singles.count + photos.galleries.reduce(0) { $0 + $1.photos.count - 1 }
        #expect(Set(singles).count == min(singles.count, pool))
    }

    /// Each gallery feeds ONE post, and a carousel post is ONE gallery: the
    /// main corpus's carousels carry their gallery whole, in order.
    @Test func eachGalleryIsOneCarouselPost() {
        var owners: [String: Set<String>] = [:]
        for post in dataset.posts where !post.extraMedia.isEmpty {
            let galleries = Set(urls(post).compactMap { URL(string: $0).flatMap(photos.photo(for:)) }
                .compactMap { photos.gallery(containing: $0)?.id })
            #expect(galleries.count <= 1, "\(post.postID) mixes \(galleries.sorted())")
            for gallery in galleries { owners[gallery, default: []].insert(post.postID) }
        }
        for (gallery, posts) in owners {
            #expect(posts.count == 1, "\(gallery) feeds \(posts.sorted())")
        }
        #expect(owners.count == photos.galleries.count, "a gallery feeds no carousel")
        for post in dataset.posts where post.postID.hasPrefix("post-0") && !post.extraMedia.isEmpty {
            let pages = urls(post).compactMap { URL(string: $0).flatMap(photos.photo(for:)) }
            guard let gallery = pages.first.flatMap(photos.gallery(containing:)) else { continue }
            #expect(pages == gallery.photos, "\(post.postID) is not its gallery whole")
        }
    }

    /// A clip whose sound is its post's alone is never lent.
    @Test func aUniqueSoundIsNeverBorrowable() {
        let unique = clips.clips.filter { !$0.lendsItsSound }
        #expect(!unique.isEmpty, "the catalog marks no unique sound")
        for slot in 0..<(clips.clips.count * 2) {
            #expect(clips.borrowableClip(forSlot: slot)?.lendsItsSound == true)
        }
    }
}
