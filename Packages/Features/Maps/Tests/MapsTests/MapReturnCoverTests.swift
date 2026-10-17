import CoreModels
import Testing
import UIKit

@testable import Maps

/// The product rule for what a flight home dissolves, row by row.
///
/// Worth pinning as a pure decision rather than only on screen, because the two
/// rows fail in opposite, equally quiet ways. Answering `none` where a blend was
/// due is a cut nobody reads as a bug — the card simply wears a photograph the
/// viewer has not seen for three swipes, and only from the first frame. Blending
/// where `none` was due is a picture dissolved into ITSELF, which looks like a
/// slightly soft landing on the row that has always worked.
@MainActor
struct MapReturnCoverTests {
    private let red = UIImage.solid(.red)
    private let blue = UIImage.solid(.blue)

    private func post(_ n: Int) -> PostID { PostID(rawValue: "post-\(n)") }

    @Test("the same post at both ends does not blend at all")
    func samePostIsInert() {
        let cover = MapReturnCover.resolve(
            departure: post(1), arrival: post(1), picture: { _ in self.red }
        )
        #expect(cover == .none)
    }

    /// ⚠️ THE SAME CAROUSEL LEFT ON A LATER PAGE STILL BLENDS (#1326): the
    /// marker's picture is the collection's head, and flying it swapped the
    /// page on screen for page 1 at the grab (filmed by the owner).
    @Test("the same carousel left on page 2 leaves on that page")
    func sameCarouselOnALaterPageBlendsFromThatPage() {
        let cover = MapReturnCover.resolve(
            departure: post(1), arrival: post(1), mediaPage: 1, picture: { _ in self.blue }
        )
        #expect(cover == .picture(blue))
        #expect(MapReturnCover.resolve(
            departure: post(1), arrival: post(1), mediaPage: 0, picture: { _ in self.blue }
        ) == .none, "page 1 is the marker's own picture")
    }

    @Test("two different media posts blend their two pictures")
    func differentMediaPostsCrossFade() {
        let cover = MapReturnCover.resolve(
            departure: post(2),
            arrival: post(1),
            // Asked about the DEPARTURE, never the arrival: the marker's own
            // picture is already on the card, and handing it back as the second
            // operand would dissolve it into itself.
            picture: { id in id == self.post(2) ? self.blue : self.red }
        )
        #expect(cover == .picture(blue))
    }

    @Test("a picture that is not in memory degrades to today's flight, not to a blank")
    func unresolvablePictureFallsBackToNone() {
        let cover = MapReturnCover.resolve(
            departure: post(2), arrival: post(1), picture: { _ in nil }
        )
        #expect(cover == .none)
    }

    @Test("nothing settled means the card is the only post there has been")
    func nilDepartureIsInert() {
        let cover = MapReturnCover.resolve(
            departure: nil, arrival: post(1), picture: { _ in self.red }
        )
        #expect(cover == .none)
    }

    @Test("a marker standing for nothing still blends what the viewer is leaving")
    func nilArrivalStillResolves() {
        let cover = MapReturnCover.resolve(
            departure: post(2), arrival: nil, picture: { _ in self.blue }
        )
        #expect(cover == .picture(blue))
    }

    @Test("only a resolved cover hands the card an operand")
    func inertCoverHandsNoImage() {
        #expect(MapReturnCover.none.image() == nil)
        #expect(MapReturnCover.picture(red).image() === red)
    }
}

private extension UIImage {
    static func solid(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
    }
}
