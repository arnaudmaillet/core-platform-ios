import CoreModels
import Foundation
import MapKit
import Testing
@testable import Maps

/// ONE CORPUS ON THE MAP.
///
/// A text post is a post: it groups by the same proximity rule as a photograph,
/// it travels into the opened feed with everything else it was grouped with,
/// and only the way the group is PRESENTED depends on what its face is. These
/// pin all three, because each would fail silently — a kind-sensitive grouping
/// looks like a slightly different cluster layout, and a dropped member looks
/// like a feed that simply ends early.
struct MapUnifiedGroupingTests {
    private static let cell = 64.0
    private static let unitScale = 1.0

    private static func pin(_ id: String, lat: Double, lng: Double, kind: MapPin.Kind) -> MapPin {
        MapPin(
            postID: PostID(id),
            latitude: lat,
            longitude: lng,
            thumbnailURL: kind == .text ? nil : URL(string: "mock://media/\(id)"),
            kind: kind
        )
    }

    /// A deterministic scatter of 120 posts, tight enough that the grid AND the
    /// merge pass both do real work.
    private static func scatter(kinds: (Int) -> MapPin.Kind) -> [MapPin] {
        (0..<120).map { index in
            pin(
                String(format: "p-%03d", index),
                lat: 48.8566 + Double((index * 73) % 40 - 20) * 0.0009,
                lng: 2.3522 + Double((index * 137) % 40 - 20) * 0.0009,
                kind: kinds(index)
            )
        }
    }

    private static func groups(_ pins: [MapPin], scale: Double = unitScale) -> Set<Set<PostID>> {
        Set(MapClusterEngine.cluster(pins, zoomScale: scale, cellPoints: cell)
            .map { Set($0.memberIDs) })
    }

    // MARK: - 1. The grouping does not know what a post is

    /// The strongest statement of "unified": hold the coordinates fixed, vary
    /// ONLY the kinds, and the grouping must come out identical — every post
    /// all-photo, every post all-text, and a mix of all three.
    @Test("Kinds cannot change how posts group")
    func groupingIsInvariantUnderKind() {
        let allPhoto = Self.groups(Self.scatter { _ in .photo })
        let allText = Self.groups(Self.scatter { _ in .text })
        let mixed = Self.groups(Self.scatter { index in
            switch index % 3 {
            case 0: .video
            case 1: .photo
            default: .text
            }
        })

        #expect(allText == allPhoto, "text posts grouped differently from photos")
        #expect(mixed == allPhoto, "a mixed corpus grouped differently from a uniform one")
        #expect(!allPhoto.isEmpty)
    }

    /// And it holds across zoom, which is where a per-kind rule would most
    /// plausibly hide: a text marker is smaller (44pt vs 56pt), so a grouping
    /// that keyed the cell off the marker's own size instead of one collision
    /// size would diverge only at certain scales.
    @Test("Invariance holds at every zoom, not just one")
    func groupingIsInvariantAcrossZoom() {
        for scale in [2.0, 8.0, 30.0, 90.0] {
            let photos = Self.groups(Self.scatter { _ in .photo }, scale: scale)
            let texts = Self.groups(Self.scatter { _ in .text }, scale: scale)
            #expect(photos == texts, "kinds diverged at zoomScale \(scale)")
        }
    }

    /// Nothing is dropped or duplicated whatever the corpus is made of — the
    /// completeness guarantee, restated for a mixed field.
    @Test("A mixed corpus is represented exactly once")
    func everyPostSurvivesGrouping() {
        let pins = Self.scatter { index in index.isMultiple(of: 2) ? .text : .photo }
        let members = MapClusterEngine.cluster(
            pins, zoomScale: Self.unitScale, cellPoints: Self.cell
        ).flatMap(\.memberIDs)

        #expect(members.count == pins.count, "a member was dropped or duplicated")
        #expect(Set(members) == Set(pins.map(\.postID)))
    }

    // MARK: - 2. The whole group opens

    /// A tapped cluster hands the feed every post it stands for — mixed kinds
    /// included — so the viewer can swipe the group rather than the subset the
    /// marker happened to picture.
    @Test("A mixed cluster opens with all of its posts")
    func aTappedClusterCarriesItsWholeGroup() {
        let pins = [
            Self.pin("p-1", lat: 48.8566, lng: 2.3522, kind: .text),
            Self.pin("p-2", lat: 48.8566, lng: 2.3522, kind: .photo),
            Self.pin("p-3", lat: 48.8566, lng: 2.3522, kind: .video),
            Self.pin("p-4", lat: 48.8566, lng: 2.3522, kind: .text)
        ]
        let items = MapClusterEngine.cluster(pins, zoomScale: Self.unitScale, cellPoints: Self.cell)
        #expect(items.count == 1)

        // Through the annotation the map actually taps, not through the item —
        // that hop is where a passthrough would lose them.
        let ids = MapsViewController.postIDs(of: MapComputedCluster(items[0]))
        #expect(Set(ids) == Set(pins.map(\.postID)))
        #expect(ids.count == pins.count, "duplicated a member on the way out")
    }

    /// An all-text cluster is no different: it is pushed rather than flown, and
    /// it still opens as a swipeable set.
    @Test("An all-text cluster opens with all of its posts")
    func anAllTextClusterCarriesItsWholeGroup() {
        let pins = (0..<5).map {
            Self.pin("t-\($0)", lat: 48.8566, lng: 2.3522, kind: .text)
        }
        let items = MapClusterEngine.cluster(pins, zoomScale: Self.unitScale, cellPoints: Self.cell)
        let ids = MapsViewController.postIDs(of: MapComputedCluster(items[0]))

        #expect(Set(ids) == Set(pins.map(\.postID)))
        #expect(MapMarkerPresentation(face: .text) == .plainPush, "and it is pushed, not flown")
    }

    /// A lone pin opens its own post, whatever kind it is.
    @Test(arguments: [MapPin.Kind.text, .photo, .video])
    func aLonePinOpensItself(kind: MapPin.Kind) {
        let pin = Self.pin("solo", lat: 48.87, lng: 2.30, kind: kind)
        #expect(MapsViewController.postIDs(of: MapAnnotation(pin: pin)) == [PostID("solo")])
    }

    // MARK: - 3. You land on what you tapped

    /// The feed opens on `memberIDs[0]` (`FixedPostsFeedProvider` preserves the
    /// tapped order), so the representative — the face the viewer just tapped —
    /// has to lead, and the rest of the group follows it.
    ///
    /// Asserted against the FACE rather than a hardcoded id, so it survives a
    /// change to how the face is picked. A media-preferring rule broke it once:
    /// the marker showed a photograph and the feed opened on a text post.
    @Test("The tapped face is the post the feed opens on")
    func theRepresentativeLeadsTheOpenedSet() {
        let pins = [
            Self.pin("p-1", lat: 48.8566, lng: 2.3522, kind: .text),
            Self.pin("p-2", lat: 48.8566, lng: 2.3522, kind: .text),
            Self.pin("p-3", lat: 48.8566, lng: 2.3522, kind: .photo),
            Self.pin("p-4", lat: 48.8566, lng: 2.3522, kind: .video)
        ]
        let item = MapClusterEngine.cluster(
            pins, zoomScale: Self.unitScale, cellPoints: Self.cell
        )[0]

        #expect(item.memberIDs.first == item.representative.postID)
        // Kind-neutral: the lowest id leads, and here that is a TEXT post
        // sitting ahead of two media members — which is exactly what lets a
        // mixed group wear the symbol face.
        #expect(item.representative.isText)
        #expect(item.memberIDs == [PostID("p-1"), PostID("p-2"), PostID("p-3"), PostID("p-4")])
    }

    /// Including when the representative already was the lowest id — the
    /// rotation must not disturb the ordinary case.
    @Test("An all-text group keeps its ascending order")
    func anAllTextGroupIsUnreordered() {
        let pins = ["t-3", "t-1", "t-2"].map {
            Self.pin($0, lat: 48.8566, lng: 2.3522, kind: .text)
        }
        let item = MapClusterEngine.cluster(
            pins, zoomScale: Self.unitScale, cellPoints: Self.cell
        )[0]

        #expect(item.memberIDs == [PostID("t-1"), PostID("t-2"), PostID("t-3")])
    }
}
