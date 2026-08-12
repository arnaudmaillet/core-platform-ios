import CoreModels
import Foundation
import MediaCore
import Testing
import UIKit
@testable import Maps

/// The marker's resting geometry, which is now face-dependent: a media post is
/// a 56pt rounded square, a text-only post a smaller 44pt circle. Three
/// surfaces render that face — the pin, the cluster marker and the hero's
/// flying card — and the whole point of routing all three through
/// `PinCardView.Face` is that they cannot drift apart, so what these pin down
/// is the face's arithmetic and that the views actually adopt it.
///
/// No `MKMapView` is built here (see `MapAnnotationPopTests` for why); an
/// `MKAnnotationView` on its own needs none.
@MainActor
struct PinMarkerGeometryTests {
    private func pin(_ id: String, kind: MapPin.Kind) -> MapPin {
        MapPin(
            postID: PostID(id),
            latitude: 48.8566,
            longitude: 2.3522,
            thumbnailURL: kind == .text ? nil : URL(string: "mock://media/\(id)"),
            kind: kind
        )
    }

    private func makePipeline() -> ImagePipeline {
        ImagePipeline(fetcher: PlaceholderImageFetcher())
    }

    @Test("A text marker is smaller than a media one")
    func textFaceIsSmaller() {
        #expect(PinCardView.Face.text.side < PinCardView.Face.media.side)
        #expect(PinCardView.Face.text.side == 44)
        #expect(PinCardView.Face.media.side == 56)
    }

    @Test("A text marker is a circle, a media marker is not")
    func textFaceIsCircular() {
        // Half the side is the definition of the circle — asserted as the
        // relationship, so changing the diameter can't quietly leave a squircle.
        #expect(PinCardView.Face.text.cornerRadius == PinCardView.Face.text.side / 2)
        #expect(PinCardView.Face.media.cornerRadius == PinCardView.cornerRadius)
        #expect(PinCardView.Face.media.cornerRadius < PinCardView.Face.media.side / 2)
    }

    /// The cluster grid's collision cell and the no-overlap guarantee are both
    /// derived from `MapAnnotationView.side`, so it has to bound EVERY marker —
    /// otherwise a face bigger than the cell could overlap its neighbour.
    @Test("The collision size bounds every face")
    func collisionSideBoundsEveryFace() {
        #expect(MapAnnotationView.side == PinCardView.Face.media.side)
        #expect(PinCardView.Face.text.side <= MapAnnotationView.side)
    }

    /// `zoomRestingCornerRadius` is read by the flight WHILE the card is
    /// page-shaped, so it must come from the face and never from live bounds —
    /// a bounds-derived radius would return half a page mid-flight and the card
    /// would sweep to a lozenge.
    @Test("The flight's resting radius follows the face, not the card's bounds")
    func restingRadiusIsFaceDerived() {
        let card = PinCardView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        card.setFace(.text)
        #expect(card.zoomRestingCornerRadius == PinCardView.Face.text.cornerRadius)

        // Mid-flight pose: page-sized card, same face.
        card.bounds = CGRect(x: 0, y: 0, width: 402, height: 874)
        #expect(card.zoomRestingCornerRadius == PinCardView.Face.text.cornerRadius)

        card.setFace(.media)
        #expect(card.zoomRestingCornerRadius == PinCardView.cornerRadius)
    }

    @Test("A text pin sizes its annotation view to the circle")
    func annotationViewAdoptsTheTextFace() {
        let view = MapAnnotationView(annotation: nil, reuseIdentifier: nil)
        view.configure(with: pin("post-text", kind: .text), imagePipeline: makePipeline())

        #expect(view.bounds.width == PinCardView.Face.text.side)
        #expect(view.bounds.height == PinCardView.Face.text.side)
        // Center-anchored on the coordinate, whatever the size.
        #expect(view.centerOffset == .zero)
    }

    /// Marker views are recycled, so the face has to come OFF again — a media
    /// pin dequeuing a view that last showed a text post must get its 56pt
    /// square back, not a 44pt circle with a photograph in it.
    @Test("A recycled view drops the text face when a media pin takes it")
    func annotationViewRestoresTheMediaFaceOnReuse() {
        let view = MapAnnotationView(annotation: nil, reuseIdentifier: nil)
        let pipeline = makePipeline()
        view.configure(with: pin("post-text", kind: .text), imagePipeline: pipeline)
        #expect(view.bounds.width == PinCardView.Face.text.side)

        view.prepareForReuse()
        #expect(view.bounds.width == PinCardView.Face.media.side)

        view.configure(with: pin("post-media", kind: .photo), imagePipeline: pipeline)
        #expect(view.bounds.width == PinCardView.Face.media.side)
    }

    /// A media pin must be untouched by any of this.
    @Test("A media pin keeps the 56pt square")
    func mediaPinKeepsItsSquare() {
        let view = MapAnnotationView(annotation: nil, reuseIdentifier: nil)
        view.configure(with: pin("post-media", kind: .photo), imagePipeline: makePipeline())
        #expect(view.bounds.width == PinCardView.Face.media.side)
        #expect(view.bounds.height == PinCardView.Face.media.side)
    }
}
