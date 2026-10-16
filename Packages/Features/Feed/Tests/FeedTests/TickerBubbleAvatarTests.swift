import MediaCore
import Testing
import UIKit
@testable import Feed

/// The danmaku bubble's disc is THE app's avatar (#1308): the author's
/// initials as a permanent floor, the picture over them when it lands —
/// never the empty grey disc it used to be.
@MainActor
struct TickerBubbleAvatarTests {
    private func bubble() -> TickerBubbleView {
        let view = TickerBubbleView()
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 22)
        view.layoutIfNeeded()
        return view
    }

    /// No picture: the initials, and nothing covering them.
    @Test func anAuthorWithoutAPictureShowsTheirInitials() {
        let view = bubble()
        view.configure(text: "🔥🔥", avatarURL: nil, monogram: "AM", pipeline: nil)
        #expect(view.avatarView.monogram.debugMonogramText == "AM")
        #expect(view.avatarView.picture.image == nil)
        #expect(view.avatarView.monogram.isCovered == false)
    }

    /// A picture on its way: the initials hold the disc until it lands.
    @Test func theInitialsHoldTheDiscUntilThePictureLands() {
        let view = bubble()
        let pipeline = ImagePipeline(fetcher: PlaceholderImageFetcher())
        view.configure(
            text: "GG", avatarURL: URL(string: "mock://avatar/ticker-1308?w=64&h=64"),
            monogram: "TK", pipeline: pipeline
        )
        #expect(view.avatarView.monogram.debugMonogramText == "TK")
        if view.avatarView.picture.image == nil {
            #expect(view.avatarView.monogram.isCovered == false, "an empty disc while the picture loads")
        }
    }

    /// A recycled bubble belongs to its new author at once.
    @Test func aRecycledBubbleNeverShowsThePreviousAuthor() {
        let view = bubble()
        view.configure(text: "a", avatarURL: nil, monogram: "AM", pipeline: nil)
        view.prepareForReuse()
        view.configure(text: "b", avatarURL: nil, monogram: "KT", pipeline: nil)
        #expect(view.avatarView.monogram.debugMonogramText == "KT")
        #expect(view.avatarView.picture.image == nil)
    }
}
