import Testing
import UIKit
@testable import DesignSystem

/// A section's title opens it only from its RUN — the title, its count and
/// its chevron, with a little slop (the owner, 2026-10-15): the whole width
/// of the bar used to, so a tap well right of "Following 3 ›" pushed too.
@MainActor
struct SectionTitleHitTests {
    @Test func onlyTheRunOpensTheSection() {
        let title = SectionTitleView(content: .init(title: "Following", count: "3", countAccessibilityValue: nil, isLink: true))
        title.frame = CGRect(x: 0, y: 0, width: 400, height: SectionTitleView.Metrics.height)
        title.layoutIfNeeded()
        let run = title.debugRunHitFrame
        #expect(run.width > 0 && run.maxX < 250, "the run spans the bar: \(run)")
        #expect(run.height >= SectionTitleView.Metrics.minimumHitHeight - 0.5)
        #expect(title.point(inside: CGPoint(x: run.midX, y: run.midY), with: nil))
        #expect(!title.point(inside: CGPoint(x: 380, y: run.midY), with: nil), "the far end of the bar opens the section")
    }
}
