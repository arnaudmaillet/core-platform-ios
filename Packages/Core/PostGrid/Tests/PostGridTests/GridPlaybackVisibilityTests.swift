import Testing
import UIKit
@testable import PostGrid

/// The autoplay gate's geometry, with the place page's measured numbers.
struct GridPlaybackVisibilityTests {
    // MARK: visibleFraction

    @Test func wholeMediaInsideIsOne() {
        let viewport = CGRect(x: 0, y: 0, width: 400, height: 800)
        let media = CGRect(x: 10, y: 10, width: 100, height: 200)
        #expect(GridPlaybackVisibility.visibleFraction(of: media, in: viewport) == 1)
    }

    @Test func mediaOutsideIsZero() {
        let viewport = CGRect(x: 0, y: 0, width: 400, height: 800)
        let media = CGRect(x: 0, y: 900, width: 100, height: 200)
        #expect(GridPlaybackVisibility.visibleFraction(of: media, in: viewport) == 0)
    }

    @Test func touchingEdgeIsZero() {
        // Adjacent rects intersect in a zero-height strip, which is not "seen".
        let viewport = CGRect(x: 0, y: 0, width: 400, height: 800)
        let media = CGRect(x: 0, y: 800, width: 100, height: 200)
        #expect(GridPlaybackVisibility.visibleFraction(of: media, in: viewport) == 0)
    }

    @Test func degenerateMediaIsZero() {
        let viewport = CGRect(x: 0, y: 0, width: 400, height: 800)
        #expect(GridPlaybackVisibility.visibleFraction(of: .zero, in: viewport) == 0)
        #expect(GridPlaybackVisibility.visibleFraction(
            of: CGRect(x: 0, y: 0, width: 100, height: 0), in: viewport) == 0)
    }

    @Test func partialOverlapIsTheAreaShare() {
        let viewport = CGRect(x: 0, y: 0, width: 400, height: 800)
        // A quarter of the height and half the width inside.
        let media = CGRect(x: 350, y: 750, width: 100, height: 200)
        let fraction = GridPlaybackVisibility.visibleFraction(of: media, in: viewport)
        #expect(abs(fraction - 0.125) < 0.0001)
    }

    @Test func thresholdIsInclusiveAtHalf() {
        let viewport = CGRect(x: 0, y: 0, width: 400, height: 800)
        let half = CGRect(x: 0, y: 700, width: 100, height: 200)
        let justUnder = CGRect(x: 0, y: 701, width: 100, height: 200)
        #expect(GridPlaybackVisibility.autoplays(half, in: viewport))
        #expect(!GridPlaybackVisibility.autoplays(justUnder, in: viewport))
    }

    // MARK: viewport

    @Test func noHostOcclusionKeepsTheContentInset() {
        // For You: both insets are floating bars, so the inset IS the cover.
        let bounds = CGRect(x: 0, y: -100, width: 402, height: 874)
        let inset = UIEdgeInsets(top: 100, left: 0, bottom: 83, right: 0)
        let viewport = GridPlaybackVisibility.viewport(
            bounds: bounds, contentInset: inset, hostOcclusion: nil)
        #expect(viewport == bounds.inset(by: inset))
    }

    @Test func hostOcclusionReplacesTheContentInset() {
        let bounds = CGRect(x: 0, y: -628, width: 402, height: 874)
        let inset = UIEdgeInsets(top: 628, left: 0, bottom: 300, right: 0)
        let cover = UIEdgeInsets(top: 106, left: 0, bottom: 83, right: 0)
        let viewport = GridPlaybackVisibility.viewport(
            bounds: bounds, contentInset: inset, hostOcclusion: cover)
        #expect(viewport == bounds.inset(by: cover))
    }

    /// ⚠️ THE BUG, in the numbers `-grid-playback-log` measured on the place
    /// page (iPhone 18 Pro, Lyon, right after the grab's landing):
    /// `bounds=-479…395 inset=t479/b369`, the landing tile's media at 0…246.
    ///
    /// Neither inset is chrome. The top is the header's reserved range (content
    /// starts there, nothing hides behind it); the bottom is inflated by
    /// `applyBottomInset` so the page can always travel the header's distance.
    /// Removed as if they covered the page, they left a 26pt band — 0.11 of
    /// the landing tile, exactly the `frac=0.11` in the report — and the tile
    /// the dismissal had just landed on was stopped.
    ///
    /// The host's cover (the docked band at the top, the tab bar and its
    /// accessory at the foot) measured 176 / 139 in the same run, and against
    /// it the whole tile is visible, which is what the viewer sees.
    @Test func placePageLandingTileAtRestPlaysAgainstTheCoverNotTheInset() {
        let bounds = CGRect(x: 0, y: -479, width: 402, height: 874)
        let layoutInset = UIEdgeInsets(top: 479, left: 0, bottom: 369, right: 0)
        let cover = UIEdgeInsets(top: 176, left: 0, bottom: 139, right: 0)
        let landingTile = CGRect(x: 8, y: 0, width: 190, height: 246)

        let insetViewport = GridPlaybackVisibility.viewport(
            bounds: bounds, contentInset: layoutInset, hostOcclusion: nil)
        #expect(insetViewport.minY == 0)
        #expect(insetViewport.maxY == 26)
        let insetFraction = GridPlaybackVisibility.visibleFraction(of: landingTile, in: insetViewport)
        #expect(abs(insetFraction - 26.0 / 246.0) < 0.0001)
        #expect(!GridPlaybackVisibility.autoplays(landingTile, in: insetViewport))

        let coverViewport = GridPlaybackVisibility.viewport(
            bounds: bounds, contentInset: layoutInset, hostOcclusion: cover)
        #expect(coverViewport.minY == -303)
        #expect(coverViewport.maxY == 256)
        #expect(GridPlaybackVisibility.visibleFraction(of: landingTile, in: coverViewport) == 1)
        #expect(GridPlaybackVisibility.autoplays(landingTile, in: coverViewport))

        // And the cover still rejects what really IS behind the bar: the
        // second row's tile (254…389 in the same run) stays out.
        let underTheBar = CGRect(x: 8, y: 254, width: 190, height: 135)
        #expect(!GridPlaybackVisibility.autoplays(underTheBar, in: coverViewport))
    }

    /// Scrolled so the header has docked, a tile passing under the docked band
    /// is judged against that band — the cover is not only a rest-state fix.
    @Test func placePageDockedHeaderStillCoversTheTop() {
        // Travelled 700pt: the bounds' top is content y 221.
        let bounds = CGRect(x: 0, y: 221, width: 402, height: 874)
        let cover = UIEdgeInsets(top: 176, left: 0, bottom: 139, right: 0)
        let viewport = GridPlaybackVisibility.viewport(
            bounds: bounds, contentInset: UIEdgeInsets(top: 479, left: 0, bottom: 369, right: 0),
            hostOcclusion: cover)
        // Viewport starts at content y 397. Media 0...268 is wholly under the
        // docked band; 272...540 has 143pt of 268 below it (0.53).
        let tile = CGRect(x: 0, y: 0, width: 200, height: 268)
        #expect(!GridPlaybackVisibility.autoplays(tile, in: viewport))
        let next = CGRect(x: 0, y: 272, width: 200, height: 268)
        #expect(GridPlaybackVisibility.autoplays(next, in: viewport))
    }
}
