import DesignSystem
import Testing
import UIKit
@testable import MediaCore

/// THE RELATION MARK AT ANY FACE SIZE (#2014): the author pill's ring and
/// badge, worn by the profile header's avatar too.
@MainActor
struct RelationMarkTests {
    /// At the pill's 36 pt face the mark is today's: a 2 pt ring, a 20 pt
    /// badge, a 17 pt glyph, a 11.5 pt cutout.
    @Test func thePillsFaceKeepsTodaysMark() {
        let metrics = RelationMarkMetrics(faceDiameter: AvatarImageView.bubbleDiameter)
        #expect(metrics.ringWidth == 2)
        #expect(metrics.badgeDiameter == 20)
        #expect(metrics.glyphPointSize == 17)
        #expect(metrics.cutoutRadius == 11.5)
        #expect(metrics.overhang == 10)
        #expect(abs(metrics.cornerOffset - (10 - 18 * (1 - cos(.pi / 4)))) < 0.0001)
        #expect(PersonPillRing.width == 2)
        #expect(PersonPill.markMetrics == metrics)
    }

    /// ⚠️ NOT A RATIO: at 96 pt the same ratio would give a 53 pt badge.
    @Test func theHeadersFaceWearsAFourPointRingAndATwentyEightPointBadge() {
        let metrics = RelationMarkMetrics(faceDiameter: 96)
        #expect(metrics.ringWidth == 4)
        #expect(metrics.badgeDiameter == 28)
        #expect(metrics.glyphPointSize == 25)
    }

    /// Capped at the header's Dynamic-Type ceiling, in half points.
    @Test(arguments: [110, 130, 200] as [CGFloat])
    func theMarkStopsGrowingAtTheHeadersCap(_ face: CGFloat) {
        let metrics = RelationMarkMetrics(faceDiameter: face)
        #expect(metrics.ringWidth == 4.5)
        #expect(metrics.badgeDiameter == 30)
    }

    /// Between the two faces it grows, in half points, never shrinking.
    @Test func theMarkGrowsInHalfPointsBetweenThePillAndTheHeader() {
        var previous = RelationMarkMetrics(faceDiameter: 36)
        for face in stride(from: 37, through: 110, by: 1) as StrideThrough<CGFloat> {
            let metrics = RelationMarkMetrics(faceDiameter: face)
            #expect(metrics.ringWidth >= previous.ringWidth && metrics.badgeDiameter >= previous.badgeDiameter)
            #expect((metrics.ringWidth * 2).rounded() == metrics.ringWidth * 2)
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

    /// The ring's ink per relation: the quiet grey while following, the
    /// accent for friends, none otherwise.
    @Test func theRingsInkPerRelation() {
        let traits = UITraitCollection(userInterfaceStyle: .light)
        func ink(_ relation: PersonPill.Badge) -> UIColor { RelationMark.ringInk(for: relation).resolvedColor(with: traits) }
        #expect(ink(.following) == PersonPillBadgeInks.quietDisc.resolvedColor(with: traits))
        #expect(ink(.friends) == PersonPillBadgeInks.accent.resolvedColor(with: traits))
        for relation in [PersonPill.Badge.none, .follow, .pending] {
            #expect(ink(relation).cgColor.alpha == 0)
            #expect(!RelationMark.hasRing(relation))
        }
        #expect(RelationMark.hasRing(.following) && RelationMark.hasRing(.friends))
    }

    /// Only the "+" takes a tap, at any size; the badge is never an
    /// accessibility element of its own.
    @Test(arguments: [36, 96] as [CGFloat])
    func onlyThePlusTakesATap(_ face: CGFloat) {
        let badge = RelationBadgeView(metrics: RelationMarkMetrics(faceDiameter: face))
        for relation in [PersonPill.Badge.none, .follow, .following, .friends, .pending] {
            badge.show(relation, animated: false)
            #expect(badge.isUserInteractionEnabled == (relation == .follow), "\(relation)")
            #expect(!badge.isAccessibilityElement, "\(relation)")
        }
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
