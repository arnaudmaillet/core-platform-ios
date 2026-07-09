import CoreModels
import Foundation
import MediaCore
import Testing
@testable import Maps

struct MapAnnotationDifferTests {
    private func pin(_ id: String, lat: Double = 0, lng: Double = 0, thumb: String = "mock://t") -> MapPin {
        MapPin(
            postID: PostID(id),
            latitude: lat,
            longitude: lng,
            thumbnailURL: URL(string: thumb),
            mediaKind: .image
        )
    }

    private func indexed(_ pins: [MapPin]) -> [PostID: MapPin] {
        Dictionary(uniqueKeysWithValues: pins.map { ($0.postID, $0) })
    }

    @Test func addsNewPinsAgainstEmptyState() {
        let diff = MapAnnotationDiffer.diff(from: [:], to: [pin("a"), pin("b")])
        #expect(diff.added.map(\.postID) == [PostID("a"), PostID("b")])
        #expect(diff.removed.isEmpty)
        #expect(diff.updated.isEmpty)
    }

    @Test func removesPinsNoLongerInViewport() {
        let current = indexed([pin("a"), pin("b")])
        let diff = MapAnnotationDiffer.diff(from: current, to: [pin("a")])
        #expect(diff.added.isEmpty)
        #expect(diff.removed.map(\.postID) == [PostID("b")])
        #expect(diff.updated.isEmpty)
    }

    @Test func unchangedPinsProduceNoDiff() {
        let current = indexed([pin("a"), pin("b")])
        let diff = MapAnnotationDiffer.diff(from: current, to: [pin("a"), pin("b")])
        #expect(diff.isEmpty)
    }

    @Test func detectsContentChangeAsUpdateNotAddRemove() {
        let current = indexed([pin("a", lat: 1, lng: 1)])
        // Same id, moved coordinate — should be an in-place update.
        let diff = MapAnnotationDiffer.diff(from: current, to: [pin("a", lat: 2, lng: 2)])
        #expect(diff.added.isEmpty)
        #expect(diff.removed.isEmpty)
        #expect(diff.updated.map(\.postID) == [PostID("a")])
    }

    @Test func mediaKindChangeCountsAsUpdate() {
        let image = pin("a")
        let video = MapPin(
            postID: PostID("a"),
            latitude: 0,
            longitude: 0,
            thumbnailURL: URL(string: "mock://t"),
            mediaKind: .video
        )
        let diff = MapAnnotationDiffer.diff(from: indexed([image]), to: [video])
        #expect(diff.updated.map(\.postID) == [PostID("a")])
    }

    @Test func handlesSimultaneousAddRemoveAndKeep() {
        let current = indexed([pin("keep"), pin("drop")])
        let diff = MapAnnotationDiffer.diff(from: current, to: [pin("keep"), pin("new")])
        #expect(diff.added.map(\.postID) == [PostID("new")])
        #expect(diff.removed.map(\.postID) == [PostID("drop")])
        #expect(diff.updated.isEmpty)
    }
}
