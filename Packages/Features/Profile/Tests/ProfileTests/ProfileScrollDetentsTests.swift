import CoreGraphics
import Testing
@testable import Profile

/// Where a profile's scroll rests while the header is on screen.
struct ProfileScrollDetentsTests {
    /// A poster has three detents, a band two — the band's top already IS the
    /// poster's second.
    @Test func aPosterHasThreeDetentsAndABandTwo() {
        #expect(ProfileScrollDetents.detents(for: .poster, posterFadeOut: 188, firstPost: 600) == [0, 188, 600])
        #expect(ProfileScrollDetents.detents(for: .band, posterFadeOut: 188, firstPost: 600) == [0, 600])
        #expect(ProfileScrollDetents.detents(for: .none, posterFadeOut: 188, firstPost: 600) == [0, 600])
    }

    /// A middle detent past the first post would be a stop the header cannot
    /// reach; it is dropped rather than ordered wrongly.
    @Test func aMiddleDetentPastTheFirstPostIsDropped() {
        #expect(ProfileScrollDetents.detents(for: .poster, posterFadeOut: 700, firstPost: 600) == [0, 600])
    }

    /// The nearest detent to where the scroll would have stopped.
    @Test func aReleaseRestsOnTheNearestDetent() {
        let detents: [CGFloat] = [0, 188, 600]
        #expect(ProfileScrollDetents.snapped(target: 40, detents: detents) == 0)
        #expect(ProfileScrollDetents.snapped(target: 150, detents: detents) == 188)
        #expect(ProfileScrollDetents.snapped(target: 300, detents: detents) == 188)
        #expect(ProfileScrollDetents.snapped(target: 500, detents: detents) == 600)
        #expect(ProfileScrollDetents.snapped(target: 600, detents: detents) == 600)
    }

    /// A release heading a little past the first post is drawn back onto
    /// it; one that clears it by more is the list's own. Above the top is a
    /// pull.
    @Test func theListBeyondTheHeaderIsFree() {
        let detents: [CGFloat] = [0, 188, 600]
        #expect(ProfileScrollDetents.snapped(target: 601, detents: detents) == 600)
        #expect(ProfileScrollDetents.snapped(target: 600 + ProfileScrollDetents.beyondSlack, detents: detents) == 600)
        #expect(ProfileScrollDetents.snapped(target: 600 + ProfileScrollDetents.beyondSlack + 1, detents: detents) == nil)
        #expect(ProfileScrollDetents.snapped(target: 2000, detents: detents) == nil)
        #expect(ProfileScrollDetents.snapped(target: -30, detents: detents) == nil)
        #expect(ProfileScrollDetents.snapped(target: 100, detents: []) == nil)
    }
}
