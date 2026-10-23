import Testing
import UIKit
import MediaCore
@testable import Maps

/// The icon face's FLOOR: a marker is never blank.
///
/// ⚠️ SINCE #1504 (the owner 2026-10-21) A BARE EMOTE FACE IS NOT SHOWN AT
/// ALL: the marker appears with its emote, and never draws a stand-in — no
/// author's disc, no skeleton. "Never blank" now means "never a drawn
/// placeholder": an unshown card that is not tappable either.
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

    @Test func anIconWithNoArtIsNotShown() {
        let card = makeCard(.icon)
        #expect(card.wornIcon == nil)
        #expect(card.isAwaitingIcon)
        #expect(card.alpha == 0, "a bare emote marker must not be drawn (#1504)")
        #expect(!card.debugTextFaceIsVisible, "no author's disc standing in")
        #expect(card.ringView.isHidden)
    }

    /// Art landing — at once off a window — shows the marker.
    @Test func theMarkerAppearsWithItsArt() {
        let card = makeCard(.icon)
        card.setIcon((art(), 0))
        #expect(!card.isAwaitingIcon)
        #expect(card.alpha == 1)
        #expect(card.debugIconFaceIsVisible)
    }

    /// ⚠️ A STAND-IN'S ALPHA IS THE WINDOW'S (#1638): a reveal fades the card
    /// itself, and re-rounding or re-dressing it on every pose must not put
    /// it back — that was the marker's media flashing in a grab's window, and
    /// filling it on a grab let go short.
    @Test(arguments: PinCardIconFloorTests.shownFaces)
    func anOwnersAlphaSurvivesTheCardBeingReshaped(face: PinCardView.Face) {
        let card = makeCard(face)
        #expect(card.alpha == 1, "guard: a shown face starts shown")
        card.alpha = 0
        card.setCornerRadius(200)
        card.setDress(MapMarkerDress())
        card.setIcon(face == .icon ? (art(), 0) : nil)
        card.setFace(face)
        #expect(card.alpha == 0, "the card's own rule overrode the reveal's alpha")
    }

    nonisolated static let shownFaces: [PinCardView.Face] = [.media, .text]

    /// …and an emote still hidden waiting for its art still appears once,
    /// when the art lands — the rule's own change, which it does write.
    @Test func anAwaitedEmoteStillAppearsOnceItsArtLands() {
        let card = makeCard(.icon)
        #expect(card.alpha == 0)
        card.setCornerRadius(20)
        #expect(card.alpha == 0)
        card.setIcon((art(), 0))
        #expect(card.alpha == 1)
    }

    /// The disc never comes back for an icon, with or without art.
    @Test func theDiscNeverStandsInForAnIcon() {
        let card = makeCard(.icon)
        #expect(!card.debugTextFaceIsVisible)
        card.setIcon((art(), 0))
        #expect(!card.debugTextFaceIsVisible)
        #expect(card.debugIconFaceIsVisible)
        // And the ring keeps the icon's own square geometry.
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
        #expect(pinOrder.alpha == 0, "face-then-strip must leave the bare marker unshown")

        let clusterOrder = PinCardView(frame: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
        clusterOrder.setIcon(nil)
        clusterOrder.setFace(.icon)
        #expect(clusterOrder.alpha == 0, "strip-then-face too")

        let recycled = PinCardView(frame: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
        recycled.setIcon((art(), 0))
        recycled.setFace(.icon)
        recycled.setIcon(nil)
        #expect(recycled.alpha == 0, "a recycled view stripped after facing must not draw its old art")
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
        #expect(standIn.alpha == 0, "a bare stand-in draws nothing either")

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

    // MARK: - The blend, which is what a differing-post dismissal rides

    /// The blend moves the icon whether or not it has art: art landing mid-
    /// flight is drawn at the blend's current value.
    @Test func theBlendMovesTheIcon() {
        let card = makeCard(.icon)
        card.setDeparturePicture(UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image {
            UIColor.black.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        })
        card.setBlend(0.5)
        #expect(abs(card.debugIconFace.alpha - 0.5) < 0.001)
        #expect(card.debugTextFace.alpha == 1, "the disc is not in an icon's blend")
    }

    /// The dressed case keeps fading the icon, and the disc stays out of it.
    @Test func aDressedIconFadesItsArtNotItsFloor() {
        let card = makeCard(.icon)
        card.setIcon((art(), 0))
        card.setDeparturePicture(UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image {
            UIColor.black.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        })
        let textFace = card.debugTextFace
        let iconFace = card.debugIconFace

        card.setBlend(0.5)
        #expect(abs(iconFace.alpha - 0.5) < 0.001)
        #expect(textFace.alpha == 1, "the floor is not in the flight when there is art")
    }

    /// Art landing MID-FLIGHT is drawn at the blend's current value.
    @Test func artLandingMidBlendKeepsTheChannel() {
        let card = makeCard(.icon)
        card.setDeparturePicture(UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image {
            UIColor.black.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        })
        card.setBlend(0.5)
        card.setIcon((art(), 0))
        #expect(abs(card.debugIconFace.alpha - 0.5) < 0.001, "the icon takes over the blend at its current value")
    }

    // MARK: - The reveal's container channel

    /// A DRESSED ICON WEARS NO GROUND, ON ANY LEG AND AT ANY CALL ORDER — and
    /// this test used to assert the opposite.
    ///
    /// It pinned a "borrow": `setContentOpacity` un-hid `textFaceView` so the
    /// disc could assemble itself around the mark over the transition. The idea
    /// is defensible and the code never delivered it. `applyFaceVisibility`
    /// hides the same `isHidden`, and it runs from `setCornerRadius`, which
    /// every pose drives — so which of the two won was decided by CALL ORDER,
    /// and the two dismiss drivers order them differently. The chevron applies
    /// its pose last and the disc stayed hidden; a finger applies
    /// `setContentOpacity` last and the disc appeared, full-bleed at the
    /// window's size, `floorCornerRadius = 0`, in `.secondarySystemBackground`.
    /// That is the "greyish ground that does not fade" a viewer filmed five
    /// times, and it is why the promised behaviour was never once seen: the
    /// only leg that showed the disc showed it as a block.
    ///
    /// `MapPinRevealSource` had already ruled the other way — a dressed icon is
    /// a mark on the map and nothing else, so a window closing onto it ends on
    /// nothing. One driver for the disc now, and it is `applyFaceVisibility`.
    @Test func aDressedIconWearsNoDiscAtAnyRamp() {
        let card = makeCard(.icon)
        card.setIcon((art(), 0))
        let textFace = card.debugTextFace
        let iconFace = card.debugIconFace

        for ramp in [CGFloat(0), 0.5, 1] {
            card.setContentOpacity(ramp)
            #expect(textFace.isHidden, "a dressed icon has no ground at ramp \(ramp)")
            #expect(iconFace.alpha == 1, "the mark is already there, at ramp \(ramp)")
        }
    }

    /// ⚠️ AND THE CALL ORDER MUST NOT DECIDE IT.
    ///
    /// The finger-drag driver applies its pose (which reaches
    /// `applyFaceVisibility` through `setCornerRadius`) and THEN drives the
    /// content ramp; the chevron does the two the other way round. Both orders
    /// have to end on the same picture, or a defect is reachable by exactly one
    /// of the two ways a person can dismiss — which is how this one survived
    /// four fixes and five recordings.
    @Test func neitherCallOrderCanPutADiscUnderADressedIcon() {
        // The finger's order: pose, then ramp.
        let dragged = makeCard(.icon)
        dragged.setIcon((art(), 0))
        dragged.setCornerRadius(0)
        dragged.setContentOpacity(1)
        #expect(dragged.debugTextFace.isHidden, "a finger's order must not un-hide the disc")

        // The chevron's order: ramp, then pose.
        let popped = makeCard(.icon)
        popped.setIcon((art(), 0))
        popped.setContentOpacity(1)
        popped.setCornerRadius(0)
        #expect(popped.debugTextFace.isHidden, "and neither must the chevron's")
    }

    @Test func aBareIconAppearsWhenItsArtLands() {
        let card = makeCard(.icon)
        #expect(card.alpha == 0, "an icon with no art is not shown")
        #expect(!card.debugTextFaceIsVisible)

        card.setIcon((art(), 0))
        #expect(card.alpha == 1, "and appears the instant art lands")
        #expect(!card.debugTextFaceIsVisible)

        card.setContentOpacity(0.5)
        card.setFace(.icon)
        #expect(!card.debugTextFaceIsVisible, "re-facing cannot put the disc back either")
    }

    /// The mark's size is authored, not derived from the window.
    @Test func theMarkKeepsItsAuthoredSizeInAWindow() {
        let window = PinCardView(frame: CGRect(x: 0, y: 0, width: 320, height: 700))
        window.setFace(.icon)
        window.setIcon((art(), 0))
        window.layoutIfNeeded()
        let iconFace = window.debugIconFace
        #expect(iconFace.bounds.width == PinCardView.Face.icon.side,
                "a mark drawn for 44pt must not be blown up to the window")
        #expect(abs(iconFace.center.x - window.bounds.midX) < 0.01)
        #expect(abs(iconFace.center.y - window.bounds.midY) < 0.01)
    }

    /// A video marker's cover IS its preview's first frame.
    ///
    /// The ladder is: the sheet animating, then the sheet's frame zero, then
    /// the wire's cover. The middle rung did not exist, so under Reduce Motion
    /// — or mid-load, or after an eviction — the marker showed a photograph and
    /// then swapped to a clip. Two claims about one post, and the swap is
    /// visible.
    @Test func aPreviewLaysItsOwnFirstFrameUnderneath() {
        let card = makeCard(.media)
        let unrelated = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image {
            UIColor.systemBlue.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        card.imageView.image = unrelated
        card.setPreviewSheet((art(), 0))
        #expect(card.imageView.image !== unrelated,
                "the wire's cover must give way to the preview's own frame zero")
        #expect(card.imageView.image != nil, "and there must still be a cover")
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

    /// ⚠️ THE COVER IS `.media`'s CONTENT, AND NO OTHER FACE'S.
    ///
    /// Invisible at rest on every face, which is why it went unwritten for so
    /// long: a marker is 44 or 56pt, exactly the size at which its face covers
    /// its card. A REVEAL WINDOW is several hundred points across and
    /// `layoutIconFace` deliberately caps the mark at its authored size, so
    /// everything around the mark is whatever else the card is holding — and
    /// `MapPinRevealSource.marker` dresses every stand-in with the pin's cover,
    /// an icon post's wire thumbnail included. Filmed as a photograph appearing
    /// from nowhere as the window closed.
    ///
    /// A TEXT face carries the same cover and is saved only by an opaque disc
    /// that happens to fill the window, which is why this asserts all three
    /// faces rather than the one that was filmed.
    @Test func onlyAMediaFaceDrawsTheCover() {
        let cover = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }

        for face in [PinCardView.Face.text, .icon] {
            let card = PinCardView(frame: CGRect(x: 0, y: 0, width: face.side, height: face.side))
            card.setFace(face)
            card.imageView.image = cover
            #expect(card.imageView.isHidden, "a \(face) face drew the post's cover under its own")
        }

        let media = PinCardView(frame: CGRect(x: 0, y: 0, width: 56, height: 56))
        media.setFace(.media)
        media.imageView.image = cover
        #expect(media.imageView.isHidden == false, "a media face IS its cover")
    }

    /// ⚠️ THE DISC'S CONTENT IS WHICHEVER OF THE TWO IS DRAWN.
    ///
    /// `PinTextFaceView` shows the author's picture when one has loaded and a
    /// fallback mark when none has, and the reveal's content channel used to
    /// fade only the mark. That is a rule that holds exactly in the case that
    /// happens to be showing.
    ///
    /// It broke twice over: a TEXT marker's reveal kept the author's photograph
    /// at full opacity while everything else left, and an ICON marker — which
    /// then BORROWED this disc as its container and asked for its content to be
    /// silent — closed onto that photograph. A post with no media at all,
    /// showing a picture, which is what made it read as impossible.
    ///
    /// The icon half of that is now settled at the root: a dressed icon shows
    /// no disc at all, so it can carry nothing. The TEXT half stands, and it is
    /// what this pins.
    @Test func theDiscFadesWhicheverOfItsTwoPicturesIsDrawn() {
        let card = PinCardView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        card.setFace(.text)
        card.setTextAvatar(UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { c in
            UIColor.red.setFill()
            c.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        })

        card.setContentOpacity(0)
        #expect(card.debugTextFaceGlyph.alpha == 0)
        #expect(card.debugTextFaceAvatar.alpha == 0,
                "the author's picture is the disc's content too")

        // …and the icon half, at the root: nothing to carry, because there is
        // no container to carry it.
        let dressed = PinCardView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        dressed.setFace(.icon)
        dressed.setTextAvatar(UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { c in
            UIColor.red.setFill()
            c.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        })
        dressed.setIcon((art(), 0))
        dressed.setContentOpacity(0)
        #expect(dressed.debugTextFace.isHidden, "a dressed icon closes onto nothing at all")
    }
}

