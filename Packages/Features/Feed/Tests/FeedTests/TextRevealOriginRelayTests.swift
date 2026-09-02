import CoreNavigation
import CoreModels
import FeedInterface
import Foundation
import PostGrid
import Testing
import UIKit
@testable import Feed

/// What survives being handed from the screen that opens a post to the code
/// that pushes it.
///
/// A pushed post's host owns the tab bar, so it wraps the origin's two chrome
/// callbacks around its own dock work. That wrapping used to REBUILD the
/// struct, and the rebuild quietly dropped `captionTop`, `authorBand`,
/// `makeDismissStandIn` and `setConcealed` — every field carries a default, so
/// the omission compiled and simply produced an older, worse transition on the
/// one surface that goes through it.
///
/// These pin the relay itself rather than any one field, so a field added to
/// `TextRevealOrigin` tomorrow is covered the day it exists.
@MainActor
struct TextRevealOriginRelayTests {
    private final class Box: @unchecked Sendable {
        var concealed: [Bool] = []
        var chrome: [String] = []
    }

    private func origin(_ box: Box) -> TextRevealOrigin {
        TextRevealOrigin(
            rowFrame: { _ in CGRect(x: 1, y: 2, width: 3, height: 4) },
            captionEnd: 76,
            depthView: { UIView() },
            captionTop: 52,
            authorBand: PostAuthorBandView.Model(
                post: GalleryPost(
                    id: PostID("p1"), kind: .text, isRepost: false, thumbnailURL: nil,
                    caption: "note", publishedAtMS: 0,
                    authorID: ProfileID("prof-1"), authorName: "Ada", authorHandle: "ada"
                )
            ),
            makeDismissStandIn: { _ in UIView() },
            pageFit: .contained,
            setConcealed: { box.concealed.append($0) },
            presentationDidEnd: { _ in box.chrome.append("inner-present") },
            willStageDismissal: { _ in box.chrome.append("stage") },
            dismissalDidEnd: { _ in box.chrome.append("inner-dismiss") }
        )
    }

    /// The four that were lost, and the one added since. Each is a visible
    /// piece of the transition: the caption offset places the window, the band
    /// is what the destination borrows, the stand-in is what the close flies
    /// home, concealment is what stops the row being a second copy of the post
    /// beside its own window — and `pageCoversWindow` decides whether the whole
    /// post travels or only a window onto it.
    @Test func theFlightFieldsSurviveTheRelay() {
        let box = Box()
        let relayed = origin(box).replacingChrome(
            presentationDidEnd: { _ in }, dismissalDidEnd: { _ in }
        )

        // A field `replacingChrome` forgets defaults SILENTLY, and this one
        // decides whether the whole post travels or only a window onto it —
        // `.clipped` is the default, so an omission is invisible in review.
        #expect(relayed.pageFit == .contained)
        #expect(relayed.captionTop == 52)
        #expect(relayed.authorBand?.handle == "ada")
        #expect(relayed.makeDismissStandIn(nil) != nil)
        relayed.setConcealed(true)
        #expect(box.concealed == [true])
    }

    @Test func theGeometryAndItsStagingSurviveToo() {
        let box = Box()
        let relayed = origin(box).replacingChrome(
            presentationDidEnd: { _ in }, dismissalDidEnd: { _ in }
        )

        #expect(relayed.rowFrame(UIView()) == CGRect(x: 1, y: 2, width: 3, height: 4))
        #expect(relayed.captionEnd == 76)
        #expect(relayed.depthView() != nil)
        relayed.willStageDismissal(nil)
        #expect(box.chrome == ["stage"])
    }

    /// The two the relay is FOR are the two it replaces — and the caller
    /// composes with the originals itself, because the orders differ.
    @Test func onlyTheChromeCallbacksAreReplaced() {
        let box = Box()
        let relayed = origin(box).replacingChrome(
            presentationDidEnd: { _ in box.chrome.append("outer-present") },
            dismissalDidEnd: { _ in box.chrome.append("outer-dismiss") }
        )

        relayed.presentationDidEnd(true)
        relayed.dismissalDidEnd(true)

        #expect(box.chrome == ["outer-present", "outer-dismiss"])
    }
}
