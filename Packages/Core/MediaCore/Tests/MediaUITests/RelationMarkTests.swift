import DesignSystem
import Testing
import UIKit
@testable import MediaCore
@testable import MediaUI

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

    /// THE BADGE'S STATES (#2419): none, loading, following, friends —
    /// the "+" and the clock are gone, and a relation that is "not followed"
    /// or "requested" draws nothing.
    @Test func theBadgeHasFourStates() {
        let states: [PersonPill.Badge] = [.none, .loading, .following, .friends]
        for state in states {
            switch state {
            case .none, .loading, .following, .friends: break
            }
        }
        #expect(PersonPill.Badge.following.symbolName == "checkmark.circle.fill")
        #expect(PersonPill.Badge.friends.symbolName == "person.2.fill")
        #expect(PersonPill.Badge.none.symbolName == nil)
        #expect(!PersonPill.Badge.none.cutsTheFace)
        #expect(PersonPill.Badge.loading.cutsTheFace)
    }

    /// NEVER A CONTROL (#2419): no state takes a touch, at any size, and the
    /// badge is no accessibility element of its own unless its host lets it
    /// speak, and then as words, never a button.
    @Test(arguments: [36, 96] as [CGFloat])
    func theBadgeNeverTakesATouch(_ face: CGFloat) {
        let badge = RelationBadgeView(metrics: RelationMarkMetrics(faceDiameter: face))
        #expect(!(badge as UIView is UIControl), "the badge is a control")
        for relation in [PersonPill.Badge.none, .loading, .following, .friends] {
            badge.show(relation, animated: false)
            #expect(!badge.isUserInteractionEnabled, "\(relation)")
            #expect(!badge.isAccessibilityElement, "\(relation)")
        }
        badge.speaksForItself = true
        for relation in [PersonPill.Badge.following, .friends] {
            badge.show(relation, animated: false)
            #expect(badge.isAccessibilityElement)
            #expect(badge.accessibilityLabel == relation.accessibilityLabel)
            #expect(!badge.accessibilityTraits.contains(.button), "\(relation) reads as a button")
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
        badge.show(.following, animated: false)
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

    /// AN OPEN GROWS THE DISC FROM NOTHING (#2419): a badge that arrives on
    /// screen opens the cutout with an animation, the mask on the face from
    /// its start; a layout pass leaves it to finish, and an open of a face
    /// already cut is at once.
    @Test func anAnimatedOpenGrowsTheDiscAndLayoutLeavesIt() {
        let face = CALayer()
        face.bounds = CGRect(x: 0, y: 0, width: 96, height: 96)
        let cutout = FaceCutout()
        cutout.reducesMotion = { false }
        let metrics = RelationMarkMetrics(faceDiameter: 96)
        let centre = CGPoint(x: 82, y: 82)
        cutout.open(face, centre: centre, metrics: metrics, animated: true)
        #expect(cutout.isCut(face))
        #expect(cutout.isOpening)
        #expect(cutout.mask.animation(forKey: "faceCutout.open") != nil, "the disc did not grow")
        cutout.cut(face, centre: centre, metrics: metrics)
        #expect(cutout.isOpening, "a layout pass cut the open short")
        #expect(cutout.mask.animation(forKey: "faceCutout.open") != nil)
        let cutAlready = FaceCutout()
        cutAlready.cut(face, centre: centre, metrics: metrics)
        cutAlready.open(face, centre: centre, metrics: metrics, animated: true)
        #expect(!cutAlready.isOpening, "a face already cut opened again")
    }

    /// INTERRUPTIBLE (#2419): a close reversed mid-way opens from where it
    /// is, and an open reversed closes; neither jumps to its end.
    @Test func aReversedChangeStartsFromWhereItIs() {
        let face = CALayer()
        face.bounds = CGRect(x: 0, y: 0, width: 96, height: 96)
        let cutout = FaceCutout()
        cutout.reducesMotion = { false }
        let metrics = RelationMarkMetrics(faceDiameter: 96)
        let centre = CGPoint(x: 82, y: 82)
        cutout.cut(face, centre: centre, metrics: metrics)
        cutout.close(face, animated: true)
        #expect(cutout.isClosing)
        cutout.open(face, centre: centre, metrics: metrics, animated: true)
        #expect(!cutout.isClosing)
        #expect(cutout.isOpening, "a reversed close jumped back whole")
        #expect(cutout.mask.animation(forKey: "faceCutout.close") == nil)
        #expect(cutout.mask.animation(forKey: "faceCutout.open") != nil)
        cutout.close(face, animated: true)
        #expect(!cutout.isOpening)
        #expect(cutout.isClosing, "a reversed open jumped shut")
        #expect(cutout.isCut(face), "the mask left before its shrink")
    }

    /// REDUCE MOTION (#2419): the cutout cross-fades (its veil), it never
    /// grows or shrinks; the badge's glyph cross-fades too, still counted
    /// as an animated change.
    @Test func underReduceMotionTheCutoutAndTheBadgeCrossFade() {
        let face = CALayer()
        face.bounds = CGRect(x: 0, y: 0, width: 96, height: 96)
        let cutout = FaceCutout()
        cutout.reducesMotion = { true }
        let metrics = RelationMarkMetrics(faceDiameter: 96)
        cutout.open(face, centre: CGPoint(x: 82, y: 82), metrics: metrics, animated: true)
        #expect(cutout.mask.animation(forKey: "faceCutout.open") == nil, "the disc grew under Reduce Motion")
        #expect(cutout.debugIsAnimating, "no cross-fade")
        #expect(cutout.debugVeilOpacity == 0)
        cutout.close(face, animated: true)
        #expect(cutout.mask.animation(forKey: "faceCutout.close") == nil, "the disc shrank under Reduce Motion")
        #expect(cutout.debugVeilOpacity == 1)
        #expect(cutout.isCut(face), "the mask left before the fade")

        let badge = RelationBadgeView(metrics: metrics)
        badge.reducesMotion = { true }
        badge.show(.following, animated: true)
        #expect(badge.replaceCount == 1)
        #expect(badge.drawn == .following)
    }

    /// The face's whole-or-cut answer for a mark (`wear`): a mark with no
    /// badge closes the cutout, one with a badge opens it.
    @Test func wearingAMarkOpensOrClosesTheCutout() {
        let face = CALayer()
        face.bounds = CGRect(x: 0, y: 0, width: 96, height: 96)
        let cutout = FaceCutout()
        let metrics = RelationMarkMetrics(faceDiameter: 96)
        let centre = CGPoint(x: 82, y: 82)
        cutout.wear(.following, on: face, centre: centre, metrics: metrics, animated: false)
        #expect(cutout.isCut(face))
        cutout.wear(.none, on: face, centre: centre, metrics: metrics, animated: false)
        #expect(!cutout.isCut(face))
        cutout.wear(.loading, on: face, centre: nil, metrics: metrics, animated: false)
        #expect(!cutout.isCut(face), "cut with no centre to cut round")
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
