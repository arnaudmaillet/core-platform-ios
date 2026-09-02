import Testing
import UIKit
@testable import CoreNavigation

/// How a transition card carries the picture it is LEAVING — the shared rule
/// two cards read, so the marker's and the tile's cannot drift apart.
///
/// The defect it encodes was filmed twice and reported both times as the
/// departure content "truncating in the transition window": an aspect-fill
/// cover resized to the card recomputes its crop every frame, so a page closing
/// toward a 44pt marker keeps its height and loses its sides.
@MainActor
struct DepartureCoverLayoutTests {
    private func picture() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    private func cover() -> UIImageView {
        let view = UIImageView()
        view.image = picture()
        return view
    }

    /// ⚠️ THE PICTURE SHRINKS WHOLE — it is not re-cropped to the card.
    ///
    /// Both halves are asserted, because either alone is satisfiable by a bug:
    /// covering alone is what the re-crop already did, and preserving the
    /// aspect alone would letterbox the window with the card's ground showing
    /// through.
    @Test func aCoverShrinksWholeRatherThanBeingRecropped() {
        let page = CGSize(width: 402, height: 874)
        let marker = CGSize(width: 44, height: 44)
        let view = cover()

        var base = DepartureCoverLayout.apply(
            to: view, in: CGRect(origin: .zero, size: page), departureBase: nil
        )
        #expect(abs(view.frame.width - page.width) < 0.5, "precondition: it starts covering")

        base = DepartureCoverLayout.apply(
            to: view, in: CGRect(origin: .zero, size: marker), departureBase: base
        )

        let shrunk = view.frame.size
        #expect(shrunk.width >= marker.width - 0.5 && shrunk.height >= marker.height - 0.5,
                "the window showed its own ground: \(shrunk) does not cover \(marker)")
        #expect(abs(shrunk.width / shrunk.height - page.width / page.height) < 0.01,
                "the picture was re-cropped, not scaled: \(shrunk) is not \(page)'s shape")
        #expect(base == page, "the departure was not remembered")
    }

    /// The base is the LARGEST size seen, not the size at the hand-in. A card
    /// is born at `.zero` and may be handed a picture before it is ever sized;
    /// reading the maximum takes the departure off the animation itself.
    @Test func theBaseIsTheLargestSizeSeenNotTheFirst() {
        let view = cover()
        var base = DepartureCoverLayout.apply(to: view, in: .zero, departureBase: nil)
        #expect(base == nil, "an unsized card has no departure to report")

        base = DepartureCoverLayout.apply(
            to: view, in: CGRect(x: 0, y: 0, width: 402, height: 874), departureBase: base
        )
        base = DepartureCoverLayout.apply(
            to: view, in: CGRect(x: 0, y: 0, width: 120, height: 200), departureBase: base
        )
        #expect(base == CGSize(width: 402, height: 874),
                "a shrinking card overwrote the size it set off from")
    }

    /// And a card that only ever shrinks under a transform keeps the behaviour
    /// it always had: its bounds never grow, the scale stays 1, and the cover
    /// fills them exactly as an aspect-fill would.
    @Test func aCardThatNeverGrewFillsItsBounds() {
        let view = cover()
        let side = CGRect(x: 0, y: 0, width: 56, height: 56)
        let base = DepartureCoverLayout.apply(to: view, in: side, departureBase: nil)

        #expect(base == side.size)
        #expect(abs(view.frame.width - 56) < 0.5)
        #expect(abs(view.frame.height - 56) < 0.5)
    }

    /// With no picture there is nothing to pose, and the rule must not invent a
    /// departure for a card that is never going to carry one.
    @Test func aCoverWithNoPictureIsLeftAtItsBounds() {
        let empty = UIImageView()
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 300)
        let base = DepartureCoverLayout.apply(to: empty, in: bounds, departureBase: nil)

        #expect(base == nil)
        #expect(empty.frame == bounds)
        #expect(empty.transform == .identity)
    }
}
