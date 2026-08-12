import CoreModels
import Foundation
import Testing
@testable import Maps

struct MapAnnotationDifferTests {
    private func pin(_ id: String, lat: Double = 0, lng: Double = 0, thumb: String = "mock://t") -> MapPin {
        MapPin(
            postID: PostID(id),
            latitude: lat,
            longitude: lng,
            thumbnailURL: URL(string: thumb),
            kind: .photo
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

    @Test func kindChangeCountsAsUpdate() {
        let image = pin("a")
        let video = MapPin(
            postID: PostID("a"),
            latitude: 0,
            longitude: 0,
            thumbnailURL: URL(string: "mock://t"),
            kind: .video
        )
        let diff = MapAnnotationDiffer.diff(from: indexed([image]), to: [video])
        #expect(diff.updated.map(\.postID) == [PostID("a")])
    }

    /// A post the backend re-indexed without a cover (or a text post replacing
    /// a media one at the same id) has to re-face its marker in place, not
    /// churn it through a remove/add.
    @Test func aMediaPinBecomingTextCountsAsUpdate() {
        let media = pin("a")
        let text = MapPin(
            postID: PostID("a"), latitude: 0, longitude: 0, thumbnailURL: nil, kind: .text
        )
        let diff = MapAnnotationDiffer.diff(from: indexed([media]), to: [text])
        #expect(diff.added.isEmpty)
        #expect(diff.removed.isEmpty)
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
