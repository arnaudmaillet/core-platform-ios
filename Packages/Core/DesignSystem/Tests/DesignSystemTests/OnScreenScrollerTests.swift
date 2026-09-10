import Testing
import UIKit
@testable import DesignSystem

/// Which scroller the chrome follows, in the shape every accessory host has:
/// a horizontal pager carrying vertical pages.
///
/// Every failure these cover is INVISIBLE from the outside — the band simply
/// never moves, which reads as "`setContentScrollView` doesn't work" rather
/// than "it was pointed at the wrong view".
@MainActor
struct OnScreenScrollerTests {

    /// A pager with `count` pages, page `active` centred, each page holding one
    /// vertical scroller — the real hierarchy, not a stand-in.
    private func pager(count: Int, active: Int, pageHeight: CGFloat = 2_000,
                       width: CGFloat = 390) -> (UIScrollView, [UIScrollView]) {
        let size = CGSize(width: width, height: 700)
        let pager = UIScrollView(frame: CGRect(origin: .zero, size: size))
        pager.contentSize = CGSize(width: size.width * CGFloat(count), height: size.height)
        var pages: [UIScrollView] = []
        for index in 0..<count {
            let page = UIScrollView(frame: CGRect(x: size.width * CGFloat(index), y: 0,
                                                  width: size.width, height: size.height))
            page.contentSize = CGSize(width: size.width, height: pageHeight)
            pager.addSubview(page)
            pages.append(page)
        }
        pager.contentOffset = CGPoint(x: size.width * CGFloat(active), y: 0)
        return (pager, pages)
    }

    // MARK: - vertical(in:) — what the pagers publish

    /// ⚠️ THE ONE THAT MATTERS AT LAUNCH. A page not yet laid out is zero-width,
    /// and a rule that screens on geometry answers `nil` for it — measured on
    /// the Messages inbox as `named=0` for a whole UITest run, on correct
    /// wiring. `vertical(in:)` asks no geometric question at all.
    @Test func aPageThatHasNeverBeenLaidOutStillAnswers() {
        let page = UIView(frame: .zero)
        let list = UIScrollView(frame: .zero)
        page.addSubview(list)
        #expect(OnScreenScroller.vertical(in: page) === list)
    }

    @Test func aNestedCarouselIsNotTheAnswer() {
        let page = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let carousel = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 120))
        carousel.contentSize = CGSize(width: 2_000, height: 120)
        let list = UIScrollView(frame: CGRect(x: 0, y: 120, width: 390, height: 580))
        list.contentSize = CGSize(width: 390, height: 4_000)
        page.addSubview(carousel)
        page.addSubview(list)
        #expect(OnScreenScroller.vertical(in: page) === list)
    }

    /// Handed a pager by mistake, it must not answer with the pager.
    @Test func theCarriageIsNeverMistakenForItsCargo() {
        let (bar, pages) = pager(count: 3, active: 0)
        #expect(OnScreenScroller.vertical(in: bar) === pages[0])
    }

    @Test func aPageWithNoScrollerAnswersNil() {
        let page = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        page.addSubview(UILabel())
        #expect(OnScreenScroller.vertical(in: page) == nil)
    }

    // MARK: - candidate(in:) — what the audit asks

    /// ⚠️ The one a "biggest scroll view" heuristic gets wrong. Page 1 is on
    /// screen and page 0 is TALLER, so area or content height picks the wrong
    /// one — and the wrong one never moves, so the band never moves.
    @Test func theCentredPageWinsOverABiggerOffscreenOne() {
        let size = CGSize(width: 390, height: 700)
        let bar = UIScrollView(frame: CGRect(origin: .zero, size: size))
        bar.contentSize = CGSize(width: size.width * 2, height: size.height)
        let tall = UIScrollView(frame: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        tall.contentSize = CGSize(width: size.width, height: 20_000)
        let short = UIScrollView(frame: CGRect(x: size.width, y: 0, width: size.width, height: size.height))
        short.contentSize = CGSize(width: size.width, height: 900)
        bar.addSubview(tall)
        bar.addSubview(short)
        bar.contentOffset = CGPoint(x: size.width, y: 0)
        #expect(OnScreenScroller.candidate(in: bar) === short)
    }

    @Test func everyPageIsFoundInTurnAsThePagerCommits() {
        let (bar, pages) = pager(count: 4, active: 0)
        for index in pages.indices {
            bar.contentOffset = CGPoint(x: bar.bounds.width * CGFloat(index), y: 0)
            #expect(OnScreenScroller.candidate(in: bar) === pages[index])
        }
    }

    @Test func invisibleScrollersAreSkipped() {
        let (bar, pages) = pager(count: 2, active: 0)
        pages[0].isHidden = true
        #expect(OnScreenScroller.candidate(in: bar) === pages[1])
        pages[0].isHidden = false
        pages[0].alpha = 0
        #expect(OnScreenScroller.candidate(in: bar) === pages[1])
    }

    @Test func aHostWithNoScrollerAnswersNil() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        host.addSubview(UILabel())
        #expect(OnScreenScroller.candidate(in: host) == nil)
    }
}
