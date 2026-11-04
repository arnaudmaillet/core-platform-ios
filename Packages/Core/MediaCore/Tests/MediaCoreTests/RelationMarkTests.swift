import DesignSystem
import Testing
import UIKit
@testable import MediaCore

/// THE RELATION MARK AT ANY FACE SIZE (#2014): the author pill's badge,
/// worn by the profile header's avatar too — the badge alone, no ring
/// (#2082).
@MainActor
struct RelationMarkTests {
    /// At the pill's 36 pt face the mark is today's: a 20 pt badge, a 17 pt
    /// glyph, a 11.5 pt cutout.
    @Test func thePillsFaceKeepsTodaysMark() {
        let metrics = RelationMarkMetrics(faceDiameter: AvatarImageView.bubbleDiameter)
        #expect(metrics.badgeDiameter == 20)
        #expect(metrics.glyphPointSize == 17)
        #expect(metrics.cutoutRadius == 11.5)
        #expect(metrics.overhang == 10)
        #expect(abs(metrics.cornerOffset - (10 - 18 * (1 - cos(.pi / 4)))) < 0.0001)
        #expect(PersonPill.markMetrics == metrics)
    }

    /// ⚠️ NOT A RATIO: at 96 pt the same ratio would give a 53 pt badge.
    @Test func theHeadersFaceWearsATwentyEightPointBadge() {
        let metrics = RelationMarkMetrics(faceDiameter: 96)
        #expect(metrics.badgeDiameter == 28)
        #expect(metrics.glyphPointSize == 25)
    }

    /// Capped at the header's Dynamic-Type ceiling, in half points.
    @Test(arguments: [110, 130, 200] as [CGFloat])
    func theMarkStopsGrowingAtTheHeadersCap(_ face: CGFloat) {
        let metrics = RelationMarkMetrics(faceDiameter: face)
        #expect(metrics.badgeDiameter == 30)
    }

    /// Between the two faces it grows, in half points, never shrinking.
    @Test func theMarkGrowsInHalfPointsBetweenThePillAndTheHeader() {
        var previous = RelationMarkMetrics(faceDiameter: 36)
        for face in stride(from: 37, through: 110, by: 1) as StrideThrough<CGFloat> {
            let metrics = RelationMarkMetrics(faceDiameter: face)
            #expect(metrics.badgeDiameter >= previous.badgeDiameter)
            #expect((metrics.badgeDiameter * 2).rounded() == metrics.badgeDiameter * 2)
            previous = metrics
        }
    }

    /// The badge's centre sits on the face's circle, 45° below its trailing
    /// side, mirrored under right-to-left.
    @Test(arguments: [36, 96, 110] as [CGFloat])
    func theBadgesCentreIsOnTheRimAtFortyFiveDegrees(_ side: CGFloat) {
        let metrics = RelationMarkMetrics(faceDiameter: side)
        let radius = side / 2
        for rightToLeft in [false, true] {
            let centre = metrics.badgeCentre(inFaceOfSide: side, rightToLeft: rightToLeft)
            let distance = hypot(centre.x - radius, centre.y - radius)
            #expect(abs(distance - radius) < 0.001, "off the rim: \(centre)")
            #expect(centre.y > radius)
            #expect(rightToLeft ? centre.x < radius : centre.x > radius)
        }
    }

    /// Only the "+" takes a tap, at any size; the badge is never an
    /// accessibility element of its own.
    @Test(arguments: [36, 96] as [CGFloat])
    func onlyThePlusTakesATap(_ face: CGFloat) {
        let badge = RelationBadgeView(metrics: RelationMarkMetrics(faceDiameter: face))
        for relation in [PersonPill.Badge.none, .loading, .follow, .following, .friends, .pending] {
            badge.show(relation, animated: false)
            #expect(badge.isUserInteractionEnabled == (relation == .follow), "\(relation)")
            #expect(!badge.isAccessibilityElement, "\(relation)")
        }
    }

    /// The skeleton's badge (#2098): the kit's bone, the badge's whole side,
    /// no symbol, no tap, never spoken — not even where the badge speaks for
    /// itself (the profile header).
    @Test func theSkeletonsBadgeIsABone() {
        let badge = RelationBadgeView(metrics: RelationMarkMetrics(faceDiameter: 96))
        badge.speaksForItself = true
        #expect(!badge.showsBone)
        badge.show(.loading, animated: false)
        #expect(badge.showsBone)
        #expect(!badge.isUserInteractionEnabled)
        #expect(!badge.isAccessibilityElement)
        #expect(RelationBadgeView.discInk(for: .loading) == .clear)
        badge.show(.follow, animated: false)
        #expect(!badge.showsBone, "the bone outlived the mark")
        #expect(badge.isAccessibilityElement)
        badge.show(.loading, animated: false)
        badge.show(.none, animated: false)
        #expect(!badge.showsBone)
    }

    /// A cutout closed with an animation stays on the face until its shrink
    /// ends — the bone fades with it; a second animated close changes
    /// nothing, a new cut cancels it, and a plain close is at once.
    @Test func anAnimatedCloseShrinksTheDiscThenGivesTheFaceBack() {
        let face = CALayer()
        face.bounds = CGRect(x: 0, y: 0, width: 96, height: 96)
        let cutout = FaceCutout()
        let metrics = RelationMarkMetrics(faceDiameter: 96)
        cutout.cut(face, centre: CGPoint(x: 82, y: 82), metrics: metrics)
        #expect(cutout.isCut(face))
        cutout.close(face, animated: true)
        #expect(cutout.isClosing)
        #expect(cutout.isCut(face), "the mask left before its shrink")
        #expect(cutout.mask.animation(forKey: "faceCutout.close") != nil)
        cutout.close(face, animated: true)
        #expect(cutout.isCut(face), "a second close cut the first short")
        cutout.cut(face, centre: CGPoint(x: 82, y: 82), metrics: metrics)
        #expect(!cutout.isClosing)
        #expect(cutout.mask.animation(forKey: "faceCutout.close") == nil)
        cutout.close(face, animated: true)
        cutout.close(face, animated: false)
        #expect(!cutout.isCut(face), "a plain close waited for the shrink")
        #expect(!cutout.isClosing)
    }

    /// Resized for a Dynamic-Type face, the badge takes its new side and
    /// keeps its symbol.
    @Test func aResizedBadgeTakesItsNewSide() {
        let badge = RelationBadgeView(metrics: RelationMarkMetrics(faceDiameter: 96))
        badge.show(.following, animated: false)
        badge.setMetrics(RelationMarkMetrics(faceDiameter: 110))
        let size = badge.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        #expect(size == CGSize(width: 30, height: 30))
        #expect(badge.drawn == .following)
    }
}
