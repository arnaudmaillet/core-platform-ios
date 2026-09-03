import Testing
import UIKit
@testable import PostGrid

/// ON SCREEN AND VISIBLE ARE NOT THE SAME RECTANGLE.
///
/// The chrome floats over the content, so the scrollable area is bigger than
/// the area a viewer can actually see. `adjustedContentInset` is the
/// difference, and an item inside it is present, hit-testable, and hidden.
///
/// These cover the cases that are awkward to produce by hand on a device, which
/// is most of the interesting ones: the clamp at either end of the content, an
/// item taller than the gap between the bars, and — the one a feature like this
/// gets wrong — an item that is already visible and must not move at all.
struct ScrollIntoViewTests {
    /// A 800pt viewport with a 100pt bar at the top and a 90pt one at the
    /// bottom, scrolled to `offsetY`. Visible band: offsetY+100 … offsetY+710.
    private func viewport(offsetY: CGFloat = 0, contentHeight: CGFloat = 5000)
        -> (bounds: CGRect, inset: UIEdgeInsets, size: CGSize) {
        (
            CGRect(x: 0, y: offsetY, width: 390, height: 800),
            UIEdgeInsets(top: 100, left: 0, bottom: 90, right: 0),
            CGSize(width: 390, height: contentHeight)
        )
    }

    private func offset(for rect: CGRect, offsetY: CGFloat = 0,
                        contentHeight: CGFloat = 5000, padding: CGFloat = 12) -> CGPoint? {
        let v = viewport(offsetY: offsetY, contentHeight: contentHeight)
        return ScrollIntoView.offset(toReveal: rect, bounds: v.bounds,
                                     contentInset: v.inset, contentSize: v.size,
                                     padding: padding)
    }

    /// The case that must stay free: a fully visible item does not move. If
    /// this returned an offset, every ordinary tap would jolt the list.
    @Test func anItemAlreadyInSightDoesNotMove() {
        #expect(offset(for: CGRect(x: 0, y: 300, width: 390, height: 200)) == nil)
    }

    /// Flush against the inset edges, inside the padding — still no move, or
    /// the list would nudge on taps that need nothing.
    @Test func anItemExactlyInsideThePaddingDoesNotMove() {
        #expect(offset(for: CGRect(x: 0, y: 112, width: 390, height: 100)) == nil)
        #expect(offset(for: CGRect(x: 0, y: 598, width: 390, height: 100)) == nil)
    }

    /// Under the TOP bar: scroll up until it clears, plus padding.
    @Test func anItemUnderTheHeaderComesDownBelowIt() throws {
        // Visible band starts at 100. This item spans 60…260, so its top is
        // buried 40pt under the bar.
        let result = try #require(offset(for: CGRect(x: 0, y: 60, width: 390, height: 200)))
        // rect.minY - inset.top - padding. Bound as CGFloat on purpose: `#expect`
        // captures each operand separately, so a bare literal expression here
        // infers as Int and the comparison fails cross-type with both sides
        // printing the same number.
        let expected: CGFloat = 60 - 100 - 12
        #expect(result.y == expected)
    }

    /// Under the BOTTOM bar: scroll down until its lower edge clears.
    @Test func anItemUnderTheFooterComesUpAboveIt() throws {
        // Visible band ends at 710. This item spans 650…850.
        let result = try #require(offset(for: CGRect(x: 0, y: 650, width: 390, height: 200)))
        // rect.maxY + inset.bottom + padding - height
        let expected: CGFloat = 850 + 90 + 12 - 800
        #expect(result.y == expected)
    }

    /// Taller than the gap between the bars: both edges cannot clear, so show
    /// the top. Aligning the bottom would open an item by revealing its last
    /// few points.
    @Test func anItemTallerThanTheGapAlignsToItsTop() throws {
        let tall = CGRect(x: 0, y: 400, width: 390, height: 900)
        let result = try #require(offset(for: tall))
        let expected: CGFloat = 400 - 100 - 12
        #expect(result.y == expected)
    }

    /// The clamp at the start: an item at the very top cannot be pushed
    /// further down, and asking for it must not scroll into rubber band.
    @Test func theFirstItemCannotBeScrolledPastTheTop() {
        // Already at rest against the top inset, so nothing to do.
        #expect(offset(for: CGRect(x: 0, y: -100, width: 390, height: 150), offsetY: -100) == nil)
    }

    /// The clamp at the end: the last item's lower edge may be unreachable, and
    /// the answer is the furthest legal offset — never past it.
    @Test func theLastItemStopsAtTheEndOfTheContent() throws {
        // Content ends at 1000; the maximum resting offset is 1000+90-800 = 290.
        let result = try #require(offset(
            for: CGRect(x: 0, y: 900, width: 390, height: 100), offsetY: 0, contentHeight: 1000
        ))
        let expected: CGFloat = 290
        #expect(result.y == expected)
    }

    /// …and once parked there, tapping the same item asks for nothing more.
    @Test func anUnreachableEdgeSettlesRatherThanRepeating() {
        #expect(offset(for: CGRect(x: 0, y: 900, width: 390, height: 100),
                       offsetY: 290, contentHeight: 1000) == nil)
    }

    /// Degenerate geometry must not produce an offset: a view with no height
    /// has no visible band to reveal anything into.
    @Test func aCollapsedViewportAsksForNothing() {
        let result = ScrollIntoView.offset(
            toReveal: CGRect(x: 0, y: 0, width: 390, height: 100),
            bounds: CGRect(x: 0, y: 0, width: 390, height: 0),
            contentInset: .zero, contentSize: CGSize(width: 390, height: 500)
        )
        #expect(result == nil)
    }

    /// Insets larger than the viewport (a keyboard over a short sheet) leave no
    /// visible band at all — also nothing to do, rather than a wild offset.
    @Test func insetsThatSwallowTheViewportAskForNothing() {
        let result = ScrollIntoView.offset(
            toReveal: CGRect(x: 0, y: 10, width: 390, height: 100),
            bounds: CGRect(x: 0, y: 0, width: 390, height: 200),
            contentInset: UIEdgeInsets(top: 150, left: 0, bottom: 150, right: 0),
            contentSize: CGSize(width: 390, height: 900)
        )
        #expect(result == nil)
    }

    /// The horizontal offset is preserved, not zeroed — these grids do not
    /// scroll sideways, but zeroing it would be a silent jump if one ever did.
    @Test func theHorizontalOffsetIsLeftAlone() throws {
        let result = try #require(ScrollIntoView.offset(
            toReveal: CGRect(x: 0, y: 0, width: 390, height: 100),
            bounds: CGRect(x: 40, y: 300, width: 390, height: 800),
            contentInset: UIEdgeInsets(top: 100, left: 0, bottom: 90, right: 0),
            contentSize: CGSize(width: 390, height: 5000)
        ))
        let expected: CGFloat = 40
        #expect(result.x == expected)
    }
}

/// THE REVEAL HAPPENS WHERE NOBODY IS LOOKING.
///
/// Two earlier versions moved the grid at TAP time and both were wrong, for
/// the same reason arrived at twice. Animating and waiting for the scroll put
/// a delay in front of the one thing the tap asked for. Applying it
/// synchronously removed the delay but not the movement — and the grid stays
/// visible behind an expanding hero card, so the viewer watches the spot they
/// just touched jump.
///
/// So the flight leaves from the untouched frame, and the reveal is applied
/// once the post has covered the grid. These cover the mechanism it uses; the
/// timing is the pages' (`applyPendingReveal`).
@MainActor
struct ScrollIntoViewImmediateTests {
    private func scrollView(offsetY: CGFloat = 0) -> UIScrollView {
        let view = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        view.contentInsetAdjustmentBehavior = .never
        view.contentInset = UIEdgeInsets(top: 100, left: 0, bottom: 90, right: 0)
        view.contentSize = CGSize(width: 390, height: 5000)
        view.contentOffset = CGPoint(x: 0, y: offsetY)
        return view
    }

    /// The offset has landed by the time the call returns — synchronously, in
    /// the same turn as the tap, which is what lets the open follow at once.
    @Test func anObscuredItemIsRevealedSynchronously() {
        let view = scrollView()

        let moved = ScrollIntoView.revealImmediately(
            CGRect(x: 0, y: 40, width: 390, height: 200), in: view
        )

        #expect(moved)
        let expected: CGFloat = 40 - 100 - 12
        #expect(view.contentOffset.y == expected, "the reveal had not landed when the call returned")
    }

    /// A visible item is not touched, and says so — the caller can open
    /// without a second thought either way.
    @Test func aVisibleItemIsLeftExactlyWhereItIs() {
        let view = scrollView(offsetY: 200)

        let moved = ScrollIntoView.revealImmediately(
            CGRect(x: 0, y: 500, width: 390, height: 200), in: view
        )

        #expect(moved == false)
        #expect(view.contentOffset.y == 200)
    }

    /// No layout attributes is not a reason to move anything — and never a
    /// reason to fail, since the tap still has to open.
    @Test func anUnknownRectMovesNothing() {
        let view = scrollView(offsetY: 120)

        #expect(ScrollIntoView.revealImmediately(nil, in: view) == false)
        #expect(view.contentOffset.y == 120)
    }

    /// Never parks in rubber band: the reveal clamps to the last legal offset
    /// even when the item's far edge cannot be cleared.
    @Test func theRevealNeverLeavesTheScrollPastItsEnd() {
        let view = scrollView()
        view.contentSize = CGSize(width: 390, height: 1000)

        ScrollIntoView.revealImmediately(CGRect(x: 0, y: 900, width: 390, height: 100), in: view)

        let maximum: CGFloat = 1000 + 90 - 800
        #expect(view.contentOffset.y == maximum)
    }
}

/// THE MOSAIC ASKS THE SAME QUESTION, IN A DIFFERENT SHAPE.
///
/// Discover is a multi-column mosaic of mixed-height bricks, Following is a
/// column of full-width cards, and the profile gallery is a third arrangement
/// again. None of that reaches the geometry: a tile is revealed on the VERTICAL
/// axis against the same two insets, and its column is irrelevant because
/// nothing here scrolls sideways.
///
/// Worth stating as tests rather than assumed, because the mosaic is the case
/// where "the item's frame" is least like the viewport: a brick can be a third
/// of the width and a fraction of the height of a row card.
struct ScrollIntoViewMosaicTests {
    /// 100pt nav bar, 90pt tab bar, 800pt viewport — the For You chrome.
    private func offset(for rect: CGRect, offsetY: CGFloat = 0) -> CGPoint? {
        ScrollIntoView.offset(
            toReveal: rect,
            bounds: CGRect(x: 0, y: offsetY, width: 390, height: 800),
            contentInset: UIEdgeInsets(top: 100, left: 0, bottom: 90, right: 0),
            contentSize: CGSize(width: 390, height: 5000)
        )
    }

    /// A small brick in the trailing column, tucked under the tab bar. Its
    /// column plays no part: only its top and bottom edges matter.
    @Test func aNarrowBrickUnderTheTabBarIsRevealedByItsVerticalEdgesAlone() throws {
        let trailingColumn = CGRect(x: 262, y: 660, width: 128, height: 128)
        let leadingColumn = CGRect(x: 0, y: 660, width: 128, height: 128)

        let trailing = try #require(offset(for: trailingColumn))
        let leading = try #require(offset(for: leadingColumn))

        #expect(trailing.y == leading.y, "the column changed the answer")
        let expected: CGFloat = 660 + 128 + 90 + 12 - 800
        #expect(trailing.y == expected)
    }

    /// Bricks of different heights in the same mosaic row settle differently,
    /// and each by its own lower edge — a tall brick has further to travel.
    @Test func aTallerBrickInTheSameRowTravelsFurther() throws {
        let short = try #require(offset(for: CGRect(x: 0, y: 660, width: 128, height: 128)))
        let tall = try #require(offset(for: CGRect(x: 0, y: 660, width: 128, height: 260)))

        #expect(tall.y > short.y)
    }

    /// A brick under the NAV BAR at the top of the mosaic comes down clear of
    /// it — the header case, which the tab bar tests do not cover.
    @Test func aBrickUnderTheNavigationBarComesClearOfIt() throws {
        // Scrolled to 500, so the visible band is 600…1210. This brick spans
        // 560…688: its top is 40pt under the bar.
        let result = try #require(offset(for: CGRect(x: 131, y: 560, width: 128, height: 128),
                                         offsetY: 500))
        let expected: CGFloat = 560 - 100 - 12
        #expect(result.y == expected)
    }

    /// And a brick sitting comfortably between the bars is left alone, whatever
    /// column it is in — the tap must not jolt the mosaic.
    @Test func aBrickInTheClearIsNeverMoved() {
        for x in [CGFloat(0), 131, 262] {
            #expect(offset(for: CGRect(x: x, y: 300, width: 128, height: 128)) == nil)
        }
    }
}

/// OCCLUSION IS NOT THE CONTENT INSET, ON EVERY SURFACE.
///
/// A profile reserves ~556pt of TOP inset for a header that scrolls away with
/// the content, and inflates the bottom so a short page can still travel.
/// Neither number is chrome covering anything. Handing them over as the visible
/// band put it in the wrong place entirely, so a tile tucked under the header
/// was aligned against the wrong edge — the reported bug: open a post under the
/// header, dismiss it, and the grid pushes it down toward the footer.
///
/// These use the profile's real geometry, because the arithmetic only goes
/// wrong when the two insets disagree. Scrolled to mid-content, so both
/// directions are actually reachable — at the very top of the content a tile
/// cannot be brought down any further, and `nil` is the honest answer there.
struct ScrollIntoViewOcclusionTests {
    private let bounds = CGRect(x: 0, y: 400, width: 440, height: 956)
    /// Layout, not chrome: header space plus scroll padding.
    private let contentInset = UIEdgeInsets(top: 556, left: 0, bottom: 290, right: 0)
    /// What actually covers content.
    private let occlusion = UIEdgeInsets(top: 100, left: 0, bottom: 90, right: 0)
    private let contentSize = CGSize(width: 440, height: 4000)
    private let padding = ScrollIntoView.defaultPadding

    private func offset(for rect: CGRect, occluding: UIEdgeInsets?) -> CGPoint? {
        ScrollIntoView.offset(
            toReveal: rect, bounds: bounds, contentInset: contentInset,
            occlusion: occluding, contentSize: contentSize
        )
    }

    /// The regression, stated as the outcome that matters: the tile ends up
    /// exactly one padding below the real top chrome.
    @Test func aTileUnderTheHeaderLandsJustBelowIt() throws {
        // Visible band with real chrome: 500 … 1266. This tile straddles the
        // top edge at 460 … 640.
        let tucked = CGRect(x: 0, y: 460, width: 440, height: 180)

        let result = try #require(offset(for: tucked, occluding: occlusion))

        // In the new scroll position, the tile's top sits at the band's top
        // plus the padding — below the header, which is the whole ask.
        #expect(tucked.minY - result.y == occlusion.top + padding)
    }

    /// The same tile with occlusion defaulted to the content inset — what
    /// shipped — lands somewhere else entirely.
    @Test func theContentInsetAloneMisplacesIt() throws {
        let tucked = CGRect(x: 0, y: 460, width: 440, height: 180)

        let wrong = try #require(offset(for: tucked, occluding: nil))
        let right = try #require(offset(for: tucked, occluding: occlusion))

        #expect(wrong.y != right.y)
        #expect(tucked.minY - wrong.y != occlusion.top + padding,
                "the content inset happened to land it correctly, so this proves nothing")
    }

    /// The bottom direction still works: a tile behind the footer comes up to
    /// exactly one padding above it.
    @Test func aTileUnderTheFooterLandsJustAboveIt() throws {
        // Band ends at 1266; this tile spans 1200 … 1380.
        let low = CGRect(x: 0, y: 1200, width: 440, height: 180)

        let result = try #require(offset(for: low, occluding: occlusion))

        // Its bottom sits one padding above the bottom chrome.
        let bandBottomInNewOffset = result.y + bounds.height - occlusion.bottom
        #expect(low.maxY == bandBottomInNewOffset - padding)
    }

    /// A tile comfortably inside the real band is left alone, even though the
    /// content insets would call it hidden.
    @Test func aTileInsideTheRealBandIsNotMoved() {
        let middle = CGRect(x: 0, y: 700, width: 440, height: 180)
        #expect(offset(for: middle, occluding: occlusion) == nil)
    }

    /// The clamp still follows the scrollable RANGE, which is the content
    /// inset's job and not the occlusion's.
    @Test func theClampStillFollowsTheScrollableRange() {
        let firstRow = CGRect(x: 0, y: -556, width: 440, height: 180)
        if let result = offset(for: firstRow, occluding: occlusion) {
            #expect(result.y >= -contentInset.top, "scrolled past the top of the content")
        }
    }
}

/// CENTRING IS A DIFFERENT QUESTION FROM REVEALING, and the difference is the
/// difference between a tap and a landing.
///
/// Revealing moves as little as it can, which is right when the viewer is
/// reaching for something. A window closing onto a row is the other case: the
/// post they were just reading arrived pinned to the bottom edge of the list,
/// as far from where they were looking as it could be while still being on
/// screen. Filmed on the place page's first vertical dismiss.
struct ScrollIntoViewCentringTests {
    /// The same 800pt viewport as the suite above: a 100pt bar at the top, a
    /// 90pt one at the bottom. Band: offsetY+100 … offsetY+710, so the band's
    /// own middle sits 305pt below the top bar.
    private func offset(for rect: CGRect, offsetY: CGFloat = 0,
                        contentHeight: CGFloat = 5000) -> CGPoint? {
        ScrollIntoView.offset(
            toCentre: rect,
            bounds: CGRect(x: 0, y: offsetY, width: 390, height: 800),
            contentInset: UIEdgeInsets(top: 100, left: 0, bottom: 90, right: 0),
            contentSize: CGSize(width: 390, height: contentHeight)
        )
    }

    /// ⚠️ MID-BAND, NOT MID-SCREEN. The chrome is not symmetrical — 100pt above
    /// and 90pt below — so the two differ by several points, and a row centred
    /// on the viewport would sit slightly under the top bar's shadow.
    @Test func aRowLandsInTheMiddleOfTheVISIBLEBand() throws {
        // A 200pt row whose middle should end up 100 + 305 = 405pt down the
        // viewport, so the content must scroll to 2000 - 405 = 1595.
        let point = try #require(offset(for: CGRect(x: 0, y: 1900, width: 390, height: 200)))
        #expect(abs(point.y - 1595) < 0.5)
    }

    /// The row that is ALREADY centred must not move: this runs on every close,
    /// and a list that nudged itself under a landing window would read as the
    /// content shifting out from under the card.
    @Test func aRowAlreadyCentredDoesNotMove() {
        // midY 405 = the band's own middle at offset 0.
        #expect(offset(for: CGRect(x: 0, y: 305, width: 390, height: 200)) == nil)
    }

    /// ⚠️ A ROW THAT IS MERELY VISIBLE STILL MOVES, which is the whole point
    /// and the one thing the reveal rule would not do. The defect was a row
    /// sitting legally on screen near the bottom edge, and revealing left it
    /// exactly where it was.
    @Test func aRowLowOnScreenIsBroughtToTheMiddle() throws {
        // Low in the band but clear of the bottom bar's padding, so the reveal
        // rule has nothing to say about it.
        let low = CGRect(x: 0, y: 600, width: 390, height: 60)
        #expect(ScrollIntoView.offset(
            toReveal: low,
            bounds: CGRect(x: 0, y: 0, width: 390, height: 800),
            contentInset: UIEdgeInsets(top: 100, left: 0, bottom: 90, right: 0),
            contentSize: CGSize(width: 390, height: 5000)
        ) == nil, "precondition: the reveal rule is content to leave it there")
        let point = try #require(offset(for: low))
        #expect(abs(point.y - 225) < 0.5)
    }

    /// Clamped at both ends, so a post near the start or the end of the list
    /// settles as close to the middle as the content allows rather than
    /// rubber-banding to reach it.
    @Test func theEndsOfTheListClampRatherThanOvershoot() throws {
        // ⚠️ Compared inside a tolerance, never with `==`: a CGPoint's y is a
        // Double and these are sums of insets, which is the comparison this
        // repo has already had go red on CI while it was green locally.
        let first = try #require(offset(for: CGRect(x: 0, y: 0, width: 390, height: 200)))
        #expect(abs(first.y + 100) < 0.5, "the top of the content, inset included")
        let last = try #require(
            offset(for: CGRect(x: 0, y: 4800, width: 390, height: 200), contentHeight: 5000)
        )
        #expect(abs(last.y - (5000 + 90 - 800)) < 0.5)
    }

    /// A row taller than the band cannot be centred meaningfully — both edges
    /// cannot clear — so it takes the reveal rule's own answer: show its TOP,
    /// because opening an item by showing its last few points is worse.
    @Test func aRowTallerThanTheBandFallsBackToTheRevealRule() {
        let tall = CGRect(x: 0, y: 1000, width: 390, height: 900)
        let centred = offset(for: tall)
        let revealed = ScrollIntoView.offset(
            toReveal: tall,
            bounds: CGRect(x: 0, y: 0, width: 390, height: 800),
            contentInset: UIEdgeInsets(top: 100, left: 0, bottom: 90, right: 0),
            contentSize: CGSize(width: 390, height: 5000)
        )
        #expect(centred == revealed)
    }
}

/// THE THREE FILMED CASES ON THE PLACE PAGE, as arithmetic.
///
/// ⚠️ A HOSTED PAGE'S TOP INSET IS NOT ITS COVER. The place page insets its
/// lists by the header's whole height (627.8) because that is the range the
/// content scrolls THROUGH — nothing is behind the banner. Handed to
/// `ScrollIntoView` as a cover it leaves a 163.2pt band, every Activity card
/// (310-549pt) reads as taller than it, and the reveal parks whatever was
/// tapped at screen y 639.8 — below the fold on an 874pt screen.
///
/// The destination is the defect, NOT the clamp: the last test here pins the
/// law, so a future "fix" that only adjusts clamping fails.
///
/// Real numbers, iPhone 17 Pro: 402x874, safe top 59, selector slot 60, tab bar
/// covering 83 while the safe area reports 34.
@MainActor struct PlaceProfileRevealArithmetic {
    private let bounds = CGRect(x: 0, y: 0, width: 402, height: 874)
    /// Reserved range, not chrome.
    private let contentInset = UIEdgeInsets(top: 627.8, left: 0, bottom: 34, right: 0)
    /// What the reveal was handed: the inset, with only the foot repaired.
    private let headerCover = UIEdgeInsets(top: 627.8, left: 0, bottom: 83, right: 0)
    /// What actually covers the list: the docked band, and the real bar.
    private let landingCover = UIEdgeInsets(top: 119, left: 0, bottom: 83, right: 0)
    /// The half fix — the right top, the bar measured after it had gone.
    private let halfCover = UIEdgeInsets(top: 119, left: 0, bottom: 34, right: 0)
    private let contentSize = CGSize(width: 402, height: 1370)
    private let card = CGRect(x: 0, y: 0, width: 370, height: 450)

    private func offset(_ rect: CGRect, at offsetY: CGFloat, cover: UIEdgeInsets) -> CGPoint? {
        ScrollIntoView.offset(
            toReveal: rect,
            bounds: CGRect(x: 0, y: offsetY, width: bounds.width, height: bounds.height),
            contentInset: contentInset, occlusion: cover, contentSize: contentSize
        )
    }

    /// v1 — the card was cut off at the FOOT, and nothing moved.
    ///
    /// And the half fix is not enough: with the bar measured after it had been
    /// taken down (34, not 83) the card's foot lands at 828, behind a bar that
    /// starts at 791. Both the cover AND the cached bar height are load-bearing.
    @Test func aCardCutOffAtTheFootComesUpJustClearOfTheBar() throws {
        #expect(offset(card, at: -627.8, cover: headerCover) == nil)

        let fixed = try #require(offset(card, at: -627.8, cover: landingCover))
        // Bottom-aligned: 450 + 83 + 12 - 874.
        #expect(abs(fixed.y - -329) < 0.01)
        // On screen at 329…779, twelve points clear of a bar starting at 791.
        #expect(card.maxY - fixed.y == 779)

        let half = try #require(offset(card, at: -627.8, cover: halfCover))
        #expect(card.maxY - half.y == 828, "a bar measured after it left is 37pt of card")
    }

    /// v2 — the card was WHOLE on screen, and the list jumped to the top.
    @Test func aCardAlreadyWholeOnScreenIsLeftWhereItIs() {
        // Travel 400: the card sits at screen 227.8 … 677.8, clear at both ends.
        #expect(offset(card, at: -227.8, cover: headerCover) == CGPoint(x: 0, y: -627.8))
        #expect(offset(card, at: -227.8, cover: landingCover) == nil)
        // And at the boundary — head exactly one padding below the band.
        #expect(offset(card, at: -131, cover: landingCover) == nil)
    }

    /// v3 — the card was cut off at the HEAD, and the list jumped to the top.
    @Test func aCardCutOffAtTheHeadComesDownJustBelowTheChrome() throws {
        // Travel 600: the card sits at screen 27.8 … 477.8, its head 91.2pt
        // behind the docked band.
        #expect(offset(card, at: -27.8, cover: headerCover) == CGPoint(x: 0, y: -627.8))

        let fixed = try #require(offset(card, at: -27.8, cover: landingCover))
        // Top-aligned: 0 - 119 - 12.
        #expect(abs(fixed.y - -131) < 0.01)
        // On screen at 131…581: head one padding below the chrome, foot well
        // clear of the bar. A 103.2pt move — "slightly", as asked.
        #expect(card.minY - fixed.y == 131)
    }

    /// ⚠️ THE LAW, NOT THE CLAMP. Under the wrong cover every card is parked
    /// with its head at screen 639.8 wherever it started; "it jumped to the
    /// top" is only that law's value for a row near the content's own top.
    /// Pinned so a fix aimed at the clamp cannot pass.
    @Test func theWrongCoverParksEveryCardBelowTheFold() throws {
        for top in [CGFloat(460), 920] {
            let rect = CGRect(x: 0, y: top, width: 370, height: 450)
            let result = try #require(offset(rect, at: -627.8, cover: headerCover))
            #expect(abs((rect.minY - result.y) - 639.8) < 0.01)
        }
    }
}
