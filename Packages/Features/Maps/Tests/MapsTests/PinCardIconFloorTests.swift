import Testing
import UIKit
import MediaCore
@testable import Maps

/// The icon face's FLOOR: a marker is never blank.
///
/// `Face.of` promises `.icon` on the strength of an ID — an id the catalogue
/// may not be able to honour. A cold cache, a decode failure, a
/// memory-pressure eviction, or a fleet build where the id resolves to nothing
/// all end with the card holding a face whose artwork never came. `.icon` also
/// hides the cover host, because an icon's alpha IS its shape and the host's
/// opaque ground would otherwise draw a grey square exactly the size of the
/// marker. Those two facts together used to leave a marker drawing NOTHING.
///
/// The fix deliberately does NOT make the face follow the art: the face is read
/// from outside (the flight's resting radius, the reveal origin, the cluster's
/// idempotence key), and `MapClusterAnnotationView` gates the icon FETCH on
/// `face == .icon` — so a face derived from a cold cache would never ask for the
/// artwork at all. What follows the art is one boolean underneath it.
@MainActor
struct PinCardIconFloorTests {
    private static let side: CGFloat = 56

    private func makeCard(_ face: PinCardView.Face) -> PinCardView {
        let card = PinCardView(frame: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
        card.setFace(face)
        return card
    }

    /// A 2x2 sheet of one frame — enough to be art, small enough to cost nothing.
    private func art() -> AnimatedIconArt {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        return .sheet(AnimatedIconSheet(sheet: image, frameCount: 1, columns: 1, frameDuration: 0.1))
    }

    @Test func anIconWithNoArtDrawsTheTextDisc() {
        let card = makeCard(.icon)
        #expect(card.wornIcon == nil)
        #expect(card.debugTextFaceIsVisible, "a bare icon must fall back to the disc, not to nothing")
        // The ring belongs to the disc, not to the face: a bare icon should
        // read as the text marker it is standing in for, ring included. The
        // "ringless" half of the icon contract is about a DRESSED icon, and
        // `PinCardBlendTests` now asserts it on one.
        #expect(!card.ringView.isHidden, "the floor wears the text marker's ring")
        // ⚠️ And the ring must take the DISC's shape. It draws on the card's
        // rectangle, which under `.icon` is a square — so left alone it framed
        // the round floor in a squircle.
        #expect(card.ringView.layer.cornerRadius == card.bounds.height / 2)
        #expect(card.ringView.layer.cornerCurve == .circular)
    }

    /// The floor is a floor, not a layer: an icon's alpha is its shape, so a
    /// disc left underneath would show through it as the circle the product
    /// asked not to see.
    @Test func theDiscGoesTheInstantArtLands() {
        let card = makeCard(.icon)
        #expect(card.debugTextFaceIsVisible)
        card.setIcon((art(), 0))
        #expect(!card.debugTextFaceIsVisible, "art landed; the floor must go")
        #expect(card.debugIconFaceIsVisible)
        // And the ring goes back to the icon's own square geometry.
        #expect(card.ringView.isHidden)
        #expect(card.ringView.layer.cornerRadius == PinCardView.Face.icon.cornerRadius)
    }

    /// ⚠️ The two callers write the art on OPPOSITE sides of the face — a pin
    /// faces then strips, a cluster strips then faces. A rule evaluated in only
    /// one of them is right for only one of them.
    @Test func theFloorIsCorrectInBothCallerOrders() {
        let pinOrder = PinCardView(frame: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
        pinOrder.setFace(.icon)
        pinOrder.setIcon(nil)
        #expect(pinOrder.debugTextFaceIsVisible, "face-then-strip must land on the floor")

        let clusterOrder = PinCardView(frame: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
        clusterOrder.setIcon(nil)
        clusterOrder.setFace(.icon)
        #expect(clusterOrder.debugTextFaceIsVisible, "strip-then-face must land on the floor too")

        let recycled = PinCardView(frame: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
        recycled.setIcon((art(), 0))
        recycled.setFace(.icon)
        recycled.setIcon(nil)
        #expect(recycled.debugTextFaceIsVisible, "a recycled view stripped after facing must not be blank")
    }

    /// The whole point of not moving the face: everything read from outside
    /// stays put whether or not the artwork arrived.
    @Test func aBareIconIsGeometricallyIdenticalToADressedOne() {
        let bare = makeCard(.icon)
        let dressed = makeCard(.icon)
        dressed.setIcon((art(), 0))

        #expect(bare.face == dressed.face)
        #expect(bare.face == .icon, "the face must NOT follow the art")
        #expect(bare.layer.cornerRadius == dressed.layer.cornerRadius)
        #expect(bare.bounds.size == dressed.bounds.size)
    }

    /// The stand-ins the transitions fly are built from scratch and never see
    /// the marker's own floor, so they need their own.
    ///
    /// ⚠️ This is the hole the resting marker did not have: `setFace(.icon)`
    /// hides the cover host, and a fresh card that is never told about the
    /// artwork draws nothing at all. A blank flight is harder to notice than a
    /// blank marker — it is on screen for a third of a second.
    @Test func aStandInWithNoIconIsNotBlank() {
        let standIn = PinCardView(frame: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
        standIn.setFace(.icon)
        standIn.setIcon(nil)
        #expect(standIn.debugTextFaceIsVisible, "a bare stand-in must draw the disc")

        let dressed = PinCardView(frame: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
        dressed.setFace(.icon)
        dressed.setIcon((art(), 0))
        #expect(!dressed.debugTextFaceIsVisible)
        #expect(dressed.debugIconFaceIsVisible)
    }

    /// The shadow follows the ART, not the face.
    ///
    /// A dressed icon gets none: a pathless shadow is re-derived from the
    /// composited alpha every frame once the contents animate, and a
    /// rectangular path behind transparent artwork draws a box. A BARE icon is
    /// drawing an opaque, still disc, so it lifts like the text marker it stands
    /// in for — without this it looked sunken into the map.
    @Test func theShadowFollowsTheArtNotTheFace() {
        let dressed = CALayer()
        PinCardView.applyPinShadow(to: dressed, face: .icon, hasArt: true)
        #expect(dressed.shadowOpacity == 0)

        let bare = CALayer()
        PinCardView.applyPinShadow(to: bare, face: .icon, hasArt: false)
        #expect(bare.shadowOpacity > 0, "the floor lifts like the text marker it replaces")

        let text = CALayer()
        PinCardView.applyPinShadow(to: text, face: .text)
        #expect(bare.shadowOpacity == text.shadowOpacity, "and lifts by exactly as much")
    }

    /// ⚠️ The flight used to take the `.media` default because the argument was
    /// simply never passed — the one face for which that answer is always wrong.
    @Test func aFlyingIconCarriesItsOwnFacesShadow() {
        let dressed = PinCardView(frame: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
        dressed.setFace(.icon)
        dressed.setIcon((art(), 0))
        let dressedLayer = CALayer()
        dressed.applyZoomRestingShadow(to: dressedLayer)
        #expect(dressedLayer.shadowOpacity == 0, "transparent artwork must not fly over a box")

        let bare = PinCardView(frame: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
        bare.setFace(.icon)
        let bareLayer = CALayer()
        bare.applyZoomRestingShadow(to: bareLayer)
        #expect(bareLayer.shadowOpacity > 0, "the floor flies with its lift")
    }

    /// ⚠️ VISIBLE IS NOT ROUND, and the difference is the whole fallback.
    ///
    /// The first version of these tests asserted only that the text face was
    /// not hidden. That was true, and the marker still drew a flat coloured
    /// SQUARE: the face carried no radius of its own and relied on the CARD's,
    /// which under `.icon` is 0 by design. Only the simulator showed it. This
    /// pins the shape.
    @Test func theFloorIsRoundEvenThoughTheCardIsNot() {
        let card = makeCard(.icon)
        card.layoutIfNeeded()
        #expect(card.layer.cornerRadius == 0, "the icon face stays square — that is the contract")

        let textFace = card.subviews[4]
        textFace.layoutIfNeeded()
        #expect(!textFace.isHidden)
        #expect(textFace.layer.cornerRadius == textFace.bounds.height / 2,
                "the floor must round ITSELF; the card will not do it under .icon")
        #expect(textFace.layer.masksToBounds, "a radius that clips nothing is a square")
        // ⚠️ A superellipse at half the side is not a circle.
        #expect(textFace.layer.cornerCurve == .circular)
    }

    // MARK: - The blend, which is what a differing-post dismissal rides

    /// ⚠️ The unit the VIEWER SEES must be the unit the blend moves.
    ///
    /// `theOperandUnderneathIsNeverPartlyDrawn` pins that the departure picture
    /// stays opaque, and that stayed true while this was broken: the `.icon`
    /// branch faded `iconFaceView` and never touched `textFaceView`, so a bare
    /// icon's disc sat at alpha 1 for the whole flight while an invisible face
    /// faded in behind it. A dismissal landing on a marker whose artwork had not
    /// resolved therefore COVERED the departing page in one step instead of
    /// crossfading over it — the arrival reading itself.
    @Test func aBareIconFadesItsDiscAcrossTheBlend() {
        let card = makeCard(.icon)
        card.setDeparturePicture(UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image {
            UIColor.black.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        })
        let textFace = card.subviews[4]

        card.setBlend(0)
        #expect(textFace.alpha == 0, "at blend 0 the arrival must not be drawn at all")
        card.setBlend(0.5)
        #expect(abs(textFace.alpha - 0.5) < 0.001, "it has to cross fade, not switch")
        card.setBlend(1)
        #expect(textFace.alpha == 1)
    }

    /// The dressed case keeps fading the icon, and the disc stays out of it.
    @Test func aDressedIconFadesItsArtNotItsFloor() {
        let card = makeCard(.icon)
        card.setIcon((art(), 0))
        card.setDeparturePicture(UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image {
            UIColor.black.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        })
        let textFace = card.subviews[4]
        let iconFace = card.subviews[5]

        card.setBlend(0.5)
        #expect(abs(iconFace.alpha - 0.5) < 0.001)
        #expect(textFace.alpha == 1, "the floor is not in the flight when there is art")
    }

    /// Art landing MID-FLIGHT has to re-point the channel, or the blend keeps
    /// fading a view nobody can see.
    @Test func artLandingMidBlendMovesTheChannel() {
        let card = makeCard(.icon)
        card.setDeparturePicture(UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image {
            UIColor.black.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        })
        card.setBlend(0.5)
        let textFace = card.subviews[4]
        let iconFace = card.subviews[5]
        #expect(abs(textFace.alpha - 0.5) < 0.001)

        card.setIcon((art(), 0))
        #expect(abs(iconFace.alpha - 0.5) < 0.001, "the icon takes over the blend at its current value")
        #expect(textFace.alpha == 1)
    }

    /// The face still answers the model, not the cache — the property the
    /// cluster's fetch gate depends on.
    @Test func theFaceIsStillAPureFunctionOfTheModel() {
        let card = makeCard(.icon)
        card.setIcon(nil)
        #expect(card.face == .icon)
        card.setIcon((art(), 0))
        #expect(card.face == .icon)
    }
}
