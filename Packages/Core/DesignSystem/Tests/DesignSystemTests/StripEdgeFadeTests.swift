import Testing
import UIKit
@testable import DesignSystem

/// The selector's edge fade (#2475): the strip fades out on the side where
/// pages are cut off, and nowhere when the whole row is in view — on the
/// strips that ask for it only.
@MainActor
struct StripEdgeFadeTests {
    /// The cut sides follow the scroll: nothing when the row fits, the
    /// trailing side at the start, both in the middle, the leading at the end.
    @Test func theCutSidesFollowTheScroll() {
        let fits = StripEdgeFade.cutSides(offset: 0, width: 300, contentWidth: 280)
        #expect(!fits.leading && !fits.trailing)
        let start = StripEdgeFade.cutSides(offset: 0, width: 200, contentWidth: 500)
        #expect(!start.leading && start.trailing)
        let middle = StripEdgeFade.cutSides(offset: 150, width: 200, contentWidth: 500)
        #expect(middle.leading && middle.trailing)
        let end = StripEdgeFade.cutSides(offset: 300, width: 200, contentWidth: 500)
        #expect(end.leading && !end.trailing)
    }

    /// Seven pages in 140pt: the strip that asked fades its trailing side at
    /// rest and its leading side scrolled to the end; one that did not is
    /// never masked.
    @Test func aStripThatAskedFadesTheSideItCutsAndNoOtherIsMasked() {
        let titles = ["Posts", "Channels", "Reposts", "Tagged", "Saved", "History", "Liked"]
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 200))
        window.isHidden = false
        defer { window.isHidden = true }
        func strip(fades: Bool) -> PagedTabBar {
            let bar = PagedTabBar(titles: titles, style: .navigationTitle)
            bar.widthCeiling = 140
            bar.fadesCutEdges = fades
            bar.frame = CGRect(x: 0, y: 0, width: 140, height: 44)
            window.addSubview(bar)
            bar.layoutIfNeeded()
            bar.debugApplyEdgeFade()
            return bar
        }
        let fading = strip(fades: true)
        #expect(fading.debugOverflow > 0, "the strip does not overflow: nothing to fade")
        #expect(fading.debugFadedEdges.trailing && !fading.debugFadedEdges.leading)
        fading.debugSetStripOffset(fading.debugOverflow)
        fading.debugApplyEdgeFade()
        #expect(fading.debugFadedEdges.leading && !fading.debugFadedEdges.trailing)
        fading.fadesCutEdges = false
        #expect(!fading.debugFadedEdges.leading && !fading.debugFadedEdges.trailing, "the fade outlived the opt-out")

        let plain = strip(fades: false)
        #expect(!plain.debugFadedEdges.leading && !plain.debugFadedEdges.trailing)
    }

    /// Seven pages in the room a bar leaves (#2361's rule, #2475): the strip
    /// scrolls, and whichever page is selected, its pill is in view.
    @Test func theSelectedPageStaysInViewInANarrowBar() {
        let titles = ["Posts", "Channels", "Reposts", "Tagged", "Saved", "History", "Liked"]
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 200))
        window.isHidden = false
        defer { window.isHidden = true }
        let bar = PagedTabBar(titles: titles, style: .navigationTitle)
        let selector = BarSelectorItem(strip: bar, id: "test.selector")
        selector.fit(BarSelectorBudget(barWidth: 375, leadingWidths: [44], trailingWidths: [44]))
        bar.fadesCutEdges = true
        bar.frame = CGRect(origin: .zero, size: bar.intrinsicContentSize)
        window.addSubview(bar)
        bar.layoutIfNeeded()
        #expect(bar.debugOverflow > 0, "seven pages fit: nothing to keep in view")
        for index in [6, 0, 4, 2, 6] {
            bar.select(index)
            bar.setProgress(CGFloat(index))
            bar.layoutIfNeeded()
            let pill = bar.debugPillInViewport
            #expect(pill.minX >= -0.5 && pill.maxX <= bar.debugViewportWidth + 0.5,
                    "page \(index)'s pill \(pill) is out of the \(bar.debugViewportWidth)pt viewport")
        }
    }
}
