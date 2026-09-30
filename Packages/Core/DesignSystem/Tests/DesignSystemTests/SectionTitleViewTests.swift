import Testing
import UIKit
@testable import DesignSystem

/// `Following 3 ›`: the app's ONE section title (2026-09-30) — the count
/// plain secondary text, the chevron in the same colour, the title standing
/// the same inset from every surface's edge.
@MainActor
struct SectionTitleViewTests {
    /// A bar laid across a surface `width` wide, `hostX` in from its edge (a
    /// host that lays its headers inside its content insets).
    private func bar(
        _ content: SectionTitleView.Content, width: CGFloat = 393, hostX: CGFloat = 0
    ) -> (bar: SectionTitleView, surface: UIScrollView) {
        let surface = UIScrollView(frame: CGRect(x: 0, y: 0, width: width, height: 400))
        let bar = SectionTitleView(content: content)
        bar.frame = CGRect(x: hostX, y: 40, width: width - 2 * hostX, height: SectionTitleView.Metrics.height)
        surface.addSubview(bar)
        bar.layoutIfNeeded()
        return (bar, surface)
    }

    // MARK: - Content

    @Test func nothingNewDrawsNoCount() {
        let content = SectionTitleView.Content(title: "Friends", newCount: 0, isLink: true)
        #expect(content.count == nil)
        #expect(content.countAccessibilityValue == nil)
        let (bar, _) = bar(content)
        #expect(bar.debugCountText == nil)
        #expect(bar.debugFrames.count.isNull)
        #expect(bar.accessibilityValue == nil)
        #expect(SectionTitleView.Content(title: "Friends", newCount: -2).count == nil, "a negative count is no count")
    }

    /// The count is the whole number — plain text has no badge's width to
    /// protect, so no "99+" — and VoiceOver says what it counts.
    @Test func aNewCountIsTheNumberSpokenAsNew() {
        let content = SectionTitleView.Content(title: "Following", newCount: 3, isLink: true)
        #expect(content.count == "3")
        #expect(content.countAccessibilityValue == "3 new")
        #expect(SectionTitleView.Content(title: "New", newCount: 250).count == "250")
        // A count that is not "new" (the shop's, the map editor's) speaks as
        // written unless told otherwise.
        #expect(SectionTitleView.Content(title: "Active", count: "3 of 5").countAccessibilityValue == "3 of 5")
        #expect(SectionTitleView.Content(title: "Recent", count: "").count == nil)
    }

    /// "Following, 3 new, button": one element, the whole bar.
    @Test func aLinkReadsAsOneButton() {
        let (bar, _) = bar(.init(title: "Following", newCount: 3, isLink: true))
        #expect(bar.isAccessibilityElement)
        #expect(bar.accessibilityLabel == "Following")
        #expect(bar.accessibilityValue == "3 new")
        #expect(bar.accessibilityTraits.contains(.button))
    }

    // MARK: - The run

    /// The count and the chevron are SECONDARY, one colour; the title is
    /// the label's — and bold title3, the size a heading needs.
    @Test func theCountIsSecondaryLikeTheChevron() {
        let (bar, _) = bar(.init(title: "Following", newCount: 3, isLink: true))
        let colors = bar.debugColors
        #expect(colors.title == .label)
        #expect(colors.count == .secondaryLabel)
        #expect(colors.chevron == .secondaryLabel)
        #expect(colors.count == colors.chevron)
        let font = bar.debugTitleFont
        #expect(font?.pointSize == UIFont.preferredFont(forTextStyle: .title3).pointSize)
        #expect(font?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
    }

    /// `Following 3 ›`, left-aligned: a word space after the title, a tighter
    /// one before the chevron so `3 ›` reads as one token — and the run stops
    /// well short of the trailing edge.
    @Test func theCountAndChevronFollowTheTitle() {
        let (bar, _) = bar(.init(title: "Following", newCount: 3, isLink: true))
        let frames = bar.debugFrames
        #expect(abs(frames.count.minX - frames.title.maxX - SectionTitleView.Metrics.titleToCount) < 0.5)
        #expect(abs(frames.chevron.minX - frames.count.maxX - SectionTitleView.Metrics.countToChevron) < 0.5)
        #expect(SectionTitleView.Metrics.countToChevron < SectionTitleView.Metrics.titleToCount)
        #expect(frames.chevron.maxX < 200, "the run stops well short of the trailing edge")
        // One line: the parts share a centre.
        #expect(abs(frames.title.midY - frames.count.midY) < 0.5)
        #expect(abs(frames.title.midY - frames.chevron.midY) < 1)
    }

    /// A count going to zero ON SCREEN gives its place back: the chevron
    /// closes up on the title, with the plain word space.
    @Test func aCountGoingToZeroClosesTheGap() {
        let (bar, _) = bar(.init(title: "Following", newCount: 3, isLink: true))
        bar.content = .init(title: "Following", newCount: 0, isLink: true)
        bar.layoutIfNeeded()
        let frames = bar.debugFrames
        #expect(frames.count.isNull)
        #expect(abs(frames.chevron.minX - frames.title.maxX - SectionTitleView.Metrics.titleToChevron) < 0.5)
    }

    /// A long title gives way; the count and the chevron never do.
    @Test func aLongTitleTruncatesBeforeTheCount() {
        let long = String(repeating: "Following ", count: 8)
        let (bar, _) = bar(.init(title: long, newCount: 12, isLink: true), width: 320)
        let frames = bar.debugFrames
        #expect(frames.chevron.maxX <= 320 - SectionTitleView.Metrics.surfaceInset + 0.5)
        #expect(bar.debugCountText == "12")
        #expect(frames.count.width > 0)
    }

    // MARK: - The inset

    /// ⚠️ THE INSET IS THE SURFACE'S: 20pt from the surface's edge whether
    /// the host lays the bar edge to edge (a table, For You's rows) or inside
    /// a section's content insets (16 on For You's lists, 8 on the sound
    /// sheet) — the "identical everywhere" of 2026-09-30.
    @Test func theTitleStandsTheSameInsetFromEverySurface() {
        for hostX: CGFloat in [0, 8, 16, 20] {
            let (bar, surface) = bar(.init(title: "Recent"), hostX: hostX)
            let x = bar.convert(bar.debugFrames.title, to: surface).minX
            #expect(abs(x - SectionTitleView.Metrics.surfaceInset) < 0.5, "host at \(hostX): title at \(x)")
        }
    }

    /// 20pt: Apple's own shelf titles' inset, just inside every surface's
    /// content (For You's 16pt cards, the sound sheet's 8pt tiles).
    @Test func theInsetIsTheShelfTitlesOne() {
        #expect(SectionTitleView.Metrics.surfaceInset == 20)
    }

    /// A trailing accessory (the wallet's totals, "Clear all") ends on the
    /// same inset from the far edge, and the run gives way to it.
    @Test func anAccessoryEndsOnTheFarInset() {
        let (bar, surface) = bar(.init(title: "Active stakes"), hostX: 16)
        let detail = UILabel()
        detail.text = "40 at stake"
        bar.trailingAccessory = detail
        bar.layoutIfNeeded()
        let right = detail.convert(detail.bounds, to: surface).maxX
        #expect(abs(right - (393 - SectionTitleView.Metrics.surfaceInset)) < 0.5, "accessory ends at \(right)")
        #expect(detail.frame.minX > bar.debugFrames.title.maxX)
        // Two elements now: the run and the accessory.
        #expect(!bar.isAccessibilityElement)
        #expect(bar.accessibilityElements?.count == 2)
        // A label takes no touch: the heading still leaves the list its touches.
        #expect(!bar.isUserInteractionEnabled)
    }

    // MARK: - Touch

    /// The whole bar is the target, a button to VoiceOver — and a TAP
    /// recogniser answers it (#312's `UIControl` never sent its action).
    @Test func theWholeBarIsATapTarget() {
        let (bar, _) = bar(.init(title: "Friends", isLink: true))
        #expect(bar.hitTest(CGPoint(x: 360, y: 22), with: nil) === bar, "the empty end still opens")
        #expect(bar.gestureRecognizers?.contains { $0 is UITapGestureRecognizer } == true)
        #expect(bar.debugShowsChevron)
        var taps = 0
        bar.onTap = { taps += 1 }
        bar.debugTap()
        #expect(taps == 1)
        #expect(bar.accessibilityActivate())
        #expect(taps == 2)
    }

    /// A heading that is not a way in: no chevron, nothing to tap, its
    /// touches left to the list under it.
    @Test func aHeadingThatIsNotALinkTakesNoTouch() {
        let (bar, _) = bar(.init(title: "For you"))
        #expect(!bar.debugShowsChevron)
        #expect(bar.accessibilityTraits.contains(.header))
        #expect(!bar.accessibilityTraits.contains(.button))
        #expect(bar.hitTest(CGPoint(x: 180, y: 22), with: nil) == nil)
        var taps = 0
        bar.onTap = { taps += 1 }
        bar.debugTap()
        #expect(!bar.accessibilityActivate())
        #expect(taps == 0)
    }

    // MARK: - Hosting

    /// The collection-view host self-sizes to the bar, and hands the title
    /// its tap.
    @Test func theSupplementaryHostIsTheBar() {
        let host = SectionTitleSupplementaryView(frame: CGRect(x: 0, y: 0, width: 393, height: 10))
        host.configure(.init(title: "Popular", isLink: true))
        let fitted = host.systemLayoutSizeFitting(
            CGSize(width: 393, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        )
        #expect(fitted.height == SectionTitleView.Metrics.height)
        var taps = 0
        host.onTap = { taps += 1 }
        host.titleView.debugTap()
        #expect(taps == 1)
        host.prepareForReuse()
        host.titleView.debugTap()
        #expect(taps == 1, "a recycled header keeps no old section's tap")
    }
}
