import CoreGraphics
import PostGrid
import Testing
@testable import Profile

/// Where a profile's scroll rests while the header is on screen.
struct ProfileScrollDetentsTests {
    /// A band has its top, the avatar's notch under the bar, and the first
    /// post; a header with no picture its top and the first post. (No
    /// poster any more, the owner 2026-10-15.)
    @Test func aBandHasItsNotchAndABareHeaderTwoDetents() {
        #expect(ProfileScrollDetents.detents(for: .band, firstPost: 600, bandAvatar: 188) == [0, 188, 600])
        #expect(ProfileScrollDetents.detents(for: .none, firstPost: 600, bandAvatar: 188) == [0, 600])
    }

    /// A notch past the first post would be a stop the header cannot reach;
    /// it is dropped rather than ordered wrongly.
    @Test func aNotchPastTheFirstPostIsDropped() {
        #expect(ProfileScrollDetents.detents(for: .band, firstPost: 600, bandAvatar: 700) == [0, 600])
    }

    /// The nearest detent to where the scroll would have stopped.
    @Test func aReleaseRestsOnTheNearestDetent() {
        let detents: [CGFloat] = [0, 188, 600]
        #expect(ScrollDetents.snapped(target: 40, detents: detents) == 0)
        #expect(ScrollDetents.snapped(target: 150, detents: detents) == 188)
        #expect(ScrollDetents.snapped(target: 300, detents: detents) == 188)
        #expect(ScrollDetents.snapped(target: 500, detents: detents) == 600)
        #expect(ScrollDetents.snapped(target: 600, detents: detents) == 600)
    }

    /// A release heading a little past the first post is drawn back onto
    /// it; one that clears it by more is the list's own. Above the top is a
    /// pull.
    @Test func theListBeyondTheHeaderIsFree() {
        let detents: [CGFloat] = [0, 188, 600]
        #expect(ScrollDetents.snapped(target: 601, detents: detents) == 600)
        #expect(ScrollDetents.snapped(target: 600 + ScrollDetents.beyondSlack, detents: detents) == 600)
        #expect(ScrollDetents.snapped(target: 600 + ScrollDetents.beyondSlack + 1, detents: detents) == nil)
        #expect(ScrollDetents.snapped(target: 2000, detents: detents) == nil)
        #expect(ScrollDetents.snapped(target: -30, detents: detents) == nil)
        #expect(ScrollDetents.snapped(target: 100, detents: []) == nil)
    }
}
