import CoreModels
import CoreNavigation
import EmoteKit
import FeedInterface
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// A close's landing hands the caption's emotes from the flight's card to the
/// resting cell without a frame of still glyphs (#922).
///
/// The cell is hidden for the whole flight (`setConcealed`), so its labels give
/// their players back. At the landing it is shown again in the transaction
/// that removes the card — and a hidden ANCESTOR coming back tells a label
/// nothing: it went on drawing the system's still emoji until the visibility
/// monitor's next tick, up to a quarter of a second. Filmed by the owner as
/// the emotes freezing on the last frame of the close.
///
/// Each test pins one landing seam: after the source is un-concealed THROUGH
/// it, a layout pass — the one the landing's own commit runs — has the label
/// placing its players again, with no tick in between. From the warm cache a
/// landing has, placing IS playing, in that same pass (`EmoteLabelTests
/// .aRecheckPlaysAShownAgainLabelInTheSameTurn`). Players are counted rather
/// than art: the art would need a real bake, and on a starved runner the
/// process-wide bake queue has kept a test waiting for over 100 s.
@MainActor
@Suite(.serialized)
struct HeroLandingEmotesTests {
    /// window → cell → label, the label holding one emote.
    @MainActor
    private final class Fixture {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let cell = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let label = EmoteLabel(frame: CGRect(x: 10, y: 10, width: 300, height: 40))

        init() {
            window.isHidden = false
            window.addSubview(cell)
            label.font = .systemFont(ofSize: 24)
            label.setEmoteText("Third coffee 🔥")
            cell.addSubview(label)
            label.layoutIfNeeded()
        }

        /// Players placed over the glyphs: showing art, or about to.
        var placedEmotes: Int {
            label.subviews.filter { $0 is AnimatedIconView }.count
        }

        func tearDown() {
            cell.isHidden = false
            window.isHidden = true
        }
    }

    /// The state the landing finds: the label played, then its cell was hidden
    /// under the flight and the players were taken back. Ends with the cell
    /// hidden.
    ///
    /// The monitor's tick during the flight is stood in for by the same walk,
    /// asked for directly: its timer is not something a test can wait on
    /// under a loaded runner (a full-suite run waited past any deadline).
    private func flown() throws -> Fixture {
        let fixture = Fixture()
        try #require(fixture.placedEmotes == 1, "precondition: the emote is placed before the flight")
        fixture.cell.isHidden = true
        EmoteLabel.recheckVisibility()
        try #require(fixture.placedEmotes == 0, "precondition: hidden under the flight, it gave its player back")
        // The flight's own frames lay the hidden label out: nothing is left
        // pending for the landing to pick up.
        fixture.label.layoutIfNeeded()

        // ⚠️ THE WITNESS: shown again by itself, the label does not know — a
        // layout pass changes nothing until something asks. This is the frozen
        // frame; without it the assertions below would prove nothing.
        fixture.cell.isHidden = false
        fixture.label.layoutIfNeeded()
        #expect(fixture.placedEmotes == 0, "witness: un-hiding alone re-asks nothing")
        fixture.cell.isHidden = true
        return fixture
    }

    private static let post = GalleryPost(
        id: PostID("emotes"), kind: .text, isRepost: false, thumbnailURL: nil,
        caption: "Third coffee 🔥", publishedAtMS: 1,
        authorID: ProfileID("yuki"), authorName: "Yuki", authorHandle: "yuki"
    )

    /// A TEXT card's close (the For You Following card filmed in #922): the
    /// reveal un-conceals the row through the installer's geometry.
    @Test func aRevealClosePlaysTheRowsEmotesInTheLandingFrame() throws {
        let fixture = try flown()
        defer { fixture.tearDown() }
        let origin = TextRevealOrigin(
            rowFrame: { _ in CGRect(x: 0, y: 0, width: 400, height: 200) },
            captionEnd: nil,
            depthView: { nil },
            makeDismissStandIn: { _ in nil },
            setConcealed: { [cell = fixture.cell] in cell.isHidden = $0 }
        )
        let geometry = TextRevealInstaller.geometry(feed: UIViewController(), origin: origin, pipeline: nil)

        geometry.setSourceConcealed(false)
        fixture.label.layoutIfNeeded()

        #expect(fixture.placedEmotes == 1, "the row drew its still glyph in the landing frame")
    }

    /// A MEDIA tile's close from a surface flown through `ExternalHeroZoomSource`
    /// (profile tiles, the rows' media cards, the sound sheet).
    @Test func aZoomClosePlaysTheTilesEmotesInTheLandingFrame() throws {
        let fixture = try flown()
        defer { fixture.tearDown() }
        let origin = SnapFeedHeroOrigin(
            post: Self.post,
            cover: nil,
            style: .listMedia,
            frame: { _ in CGRect(x: 0, y: 0, width: 400, height: 200) },
            isOnScreen: { true },
            setConcealed: { [cell = fixture.cell] in cell.isHidden = $0 }
        )
        let source = ExternalHeroZoomSource(origin: origin)

        source.setZoomSourceHidden(false)
        fixture.label.layoutIfNeeded()

        #expect(fixture.placedEmotes == 1, "the tile drew its still glyph in the landing frame")
    }
}
