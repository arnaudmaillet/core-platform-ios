import Testing
import UIKit
@testable import Maps

/// `PinCardView`'s two opacity channels, and the fact that they are two.
///
/// `setContentOpacity` fades the marker's CONTENT — cover, glyph and the ring
/// that draws the marker's edge — for the reveal, and the ring is in there on
/// purpose: it reads as a border at 44pt and as an outline drawn around the
/// whole screen at full size, so it has to be gone well before the window is.
/// `setBlend` is the hero flight's picture channel, and it must not inherit any
/// of that clock. What is pinned here is that the two touch disjoint
/// properties, that the blend never moves the ring, and that a card with no
/// departure picture is byte-for-byte the card that existed before the blend
/// did.
@MainActor
struct PinCardBlendTests {
    private static let side: CGFloat = 56

    private func makeCard(_ face: PinCardView.Face = .media) -> PinCardView {
        let card = PinCardView(frame: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
        card.setFace(face)
        return card
    }

    /// A real (tiny) bitmap rather than `UIImage()`: the blend keys off whether
    /// an image is present, and an empty one would satisfy that test while
    /// being nothing a viewer could see.
    private func picture() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    /// ⚠️ `UIView.alpha` rides `CALayer.opacity`, which is a `Float`, so a
    /// fractional CGFloat does not necessarily come back bit-identical — the
    /// `==`-on-CGFloat trap that has already turned a suite red on CI while it
    /// was green locally. Every alpha here is compared inside a tolerance far
    /// finer than a frame could show.
    private func isAlpha(_ view: UIView, _ expected: CGFloat) -> Bool {
        abs(view.alpha - expected) < 0.0001
    }

    // MARK: - Layer order

    /// The order is part of the card's contract. The departure cover sits ABOVE
    /// the arrival cover (the blend fades whichever operand is on top) and
    /// BELOW the live surface (on a dismissal that surface is the departing
    /// page's own moving picture and the cover is only its poster; burying it
    /// under a still would fly a frozen frame for the whole flight). The two
    /// middle layers are private, so they are addressed by their position
    /// between the ones that are not — which pins the order as a side effect.
    @Test func theCardStacksItsFiveLayersInTheContractedOrder() {
        let card = makeCard()
        #expect(card.subviews.count == 5)
        #expect(card.subviews.first === card.imageView)
        #expect(card.subviews.last === card.ringView)
    }

    private func departureCover(of card: PinCardView) -> UIView { card.subviews[1] }
    private func liveSurface(of card: PinCardView) -> UIView { card.subviews[2] }
    private func textFace(of card: PinCardView) -> UIView { card.subviews[3] }

    // MARK: - The un-blended card

    /// No departure picture, no blend. This is how the row of the product rule
    /// that must NOT blend gets there: a dismissal onto the same media post is
    /// one picture at both ends, so there is nothing to blend against and a
    /// blend could only soften it. It hands in nil and keeps today's animation.
    @Test func aCardWithNoDeparturePictureIsUntouchedByTheBlend() {
        let card = makeCard()
        for t in [CGFloat(0), 0.5, 1] {
            card.setBlend(t)
            #expect(isAlpha(card.imageView, 1))
            #expect(isAlpha(departureCover(of: card), 1))
            #expect(isAlpha(textFace(of: card), 1))
            #expect(isAlpha(liveSurface(of: card), 1))
            #expect(isAlpha(card.ringView, 1))
        }
        #expect(departureCover(of: card).isHidden)
    }

    /// Handing the picture back as nil puts the card back where it started. A
    /// flight card is built fresh per transition, but a marker view is
    /// recycled, and a stuck operand would haunt the next post to land in it.
    @Test func clearingTheDeparturePictureRestoresTheRestingCard() {
        let card = makeCard()
        card.setDeparturePicture(picture())
        card.setBlend(0.5)
        #expect(isAlpha(departureCover(of: card), 0.5))

        card.setDeparturePicture(nil)
        #expect(departureCover(of: card).isHidden)
        #expect(isAlpha(departureCover(of: card), 1))
        #expect(isAlpha(liveSurface(of: card), 1))
        #expect(isAlpha(textFace(of: card), 1))
    }

    // MARK: - The blend's endpoints

    /// Media → media: the departure stack is on top of the marker's own cover,
    /// so it is the half that fades. The arrival cover is never touched, which
    /// is what keeps the landing handshake pixel-identical — the fix ADDS a
    /// second operand, it does not replace the marker's picture.
    @Test func aMediaArrivalFadesTheDepartureStackOffTheMarkersCover() {
        let card = makeCard(.media)
        card.setDeparturePicture(picture())

        card.setBlend(0)
        #expect(isAlpha(departureCover(of: card), 1))
        #expect(isAlpha(liveSurface(of: card), 1))
        #expect(isAlpha(card.imageView, 1))

        card.setBlend(1)
        #expect(isAlpha(departureCover(of: card), 0))
        #expect(isAlpha(liveSurface(of: card), 0))
        #expect(isAlpha(card.imageView, 1))
    }

    /// Media → icon: the arrival operand is the text face AS A WHOLE — the disc
    /// and the glyph, one opaque unit — fading IN over an opaque departure
    /// picture.
    ///
    /// ⚠️ This is the row where the fade law bites. Blending the glyph alone
    /// over a see-through ground is two half-finished drawings, which is what
    /// the caption ghost died of four times over; two opaque photographs are
    /// not, which is the only reason any of this is allowed.
    @Test func aTextArrivalFadesTheWholeDiscInOverTheDeparturePicture() {
        let card = makeCard(.text)
        card.setDeparturePicture(picture())

        card.setBlend(0)
        #expect(isAlpha(textFace(of: card), 0))
        #expect(isAlpha(departureCover(of: card), 1))

        card.setBlend(1)
        #expect(isAlpha(textFace(of: card), 1))
        #expect(isAlpha(departureCover(of: card), 1))
    }

    /// ⚠️ THE INVARIANT THE LAW ACTUALLY DEMANDS: exactly one operand's alpha
    /// moves and the one underneath stays fully opaque, so every intermediate
    /// frame is an opaque sum of two pictures rather than two transparent ones.
    @Test func theOperandUnderneathIsNeverPartlyDrawn() {
        for face in [PinCardView.Face.media, .text] {
            let card = makeCard(face)
            card.setDeparturePicture(picture())
            for step in 0...10 {
                card.setBlend(CGFloat(step) / 10)
                switch face {
                case .media: #expect(isAlpha(card.imageView, 1))
                case .text: #expect(isAlpha(departureCover(of: card), 1))
                }
            }
        }
    }

    @Test func theBlendClampsToTheUnitInterval() {
        let card = makeCard(.media)
        card.setDeparturePicture(picture())
        card.setBlend(-0.5)
        #expect(isAlpha(departureCover(of: card), 1))
        card.setBlend(1.5)
        #expect(isAlpha(departureCover(of: card), 0))
    }

    // MARK: - Channel independence

    /// The ring belongs to `setContentOpacity` and to nothing else. It is in
    /// that channel because it has to be gone well before the window is, and a
    /// blend riding the same property would drag the pictures onto that clock.
    @Test func theContentChannelMovesTheRingAndTheBlendNeverDoes() {
        let card = makeCard(.media)
        card.setDeparturePicture(picture())

        card.setContentOpacity(0.5)
        #expect(isAlpha(card.ringView, 0.5))

        for step in 0...4 {
            card.setBlend(CGFloat(step) / 4)
            #expect(isAlpha(card.ringView, 0.5), "the blend dragged the ring onto its clock")
        }
    }

    /// And the reverse: a blend already set is not disturbed by the reveal's
    /// channel. The two write disjoint properties, so whichever runs second
    /// leaves the other's exactly where it was.
    @Test func theTwoChannelsDoNotOverwriteEachOther() {
        let card = makeCard(.media)
        card.setDeparturePicture(picture())
        card.setBlend(0.25)
        card.setContentOpacity(0.5)

        #expect(isAlpha(departureCover(of: card), 0.75))
        #expect(isAlpha(card.ringView, 0.5))
        #expect(isAlpha(card.imageView, 0.5))

        card.setBlend(0.75)
        #expect(isAlpha(departureCover(of: card), 0.25))
        #expect(isAlpha(card.ringView, 0.5))
        #expect(isAlpha(card.imageView, 0.5))
    }

    // MARK: - The face still decides everything else

    /// The ARRIVAL face alone owns `side`, `cornerRadius` and the background
    /// even while a blend is loaded; only the drawn content is a pair. Which
    /// operand fades follows FROM the face rather than being a second thing to
    /// configure, so re-facing a card re-aims the blend at the same fraction.
    @Test func theArrivalFaceStillDecidesTheGeometryAndAimsTheBlend() {
        let card = makeCard(.media)
        card.setDeparturePicture(picture())
        card.setBlend(0.25)
        #expect(isAlpha(departureCover(of: card), 0.75))

        card.setFace(.text)
        #expect(card.layer.cornerRadius == PinCardView.Face.text.cornerRadius)
        #expect(card.zoomRestingCornerRadius == PinCardView.Face.text.cornerRadius)
        // Re-aimed at the same fraction: the disc is now the operand on top.
        #expect(isAlpha(textFace(of: card), 0.25))
        #expect(isAlpha(departureCover(of: card), 1))
    }

    /// A resting marker — which is never handed a departure picture — must come
    /// out of `setFace` exactly as it always did, including through the
    /// recycling an annotation view puts it through.
    @Test func setFaceLeavesARestingMarkerAlone() {
        let card = makeCard(.media)
        card.setFace(.text)
        #expect(isAlpha(textFace(of: card), 1))
        #expect(textFace(of: card).isHidden == false)
        #expect(card.backgroundColor == .clear)

        card.setFace(.media)
        #expect(textFace(of: card).isHidden)
        #expect(card.backgroundColor == .black)
        #expect(isAlpha(card.imageView, 1))
        #expect(isAlpha(card.ringView, 1))
    }
}
