import DesignSystem
import Testing
import UIKit
@testable import MediaCore
@testable import MediaUI

/// THE ONE MARKED FACE, AT ANY DIAMETER (#2300): the inbox row's 56 pt, a
/// list card's 40 pt author band, a text page's caption row (its side
/// follows Dynamic Type) — the badge's side always from
/// `RelationMarkMetrics`, never assumed.
@MainActor
struct RelationMarkedAvatarViewTests {
    /// The hosts, kept for the suite's life: a released host leaves the face
    /// with no superview, and a later layout pass never reaches it.
    private static var hosts: [UIView] = []

    private func laidOut(_ face: RelationMarkedAvatarView) -> RelationMarkedAvatarView {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        Self.hosts.append(host)
        face.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(face)
        NSLayoutConstraint.activate([
            face.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 20),
            face.topAnchor.constraint(equalTo: host.topAnchor, constant: 20),
        ])
        host.layoutIfNeeded()
        return face
    }

    /// The badge's side for each face: the metrics' answer.
    @Test(arguments: [40, 48, 38] as [CGFloat])
    func theBadgesSideComesFromTheMetrics(_ diameter: CGFloat) {
        let face = laidOut(RelationMarkedAvatarView(diameter: diameter))
        face.setMark(.following, animated: false)
        face.superview?.layoutIfNeeded()
        let metrics = RelationMarkMetrics(faceDiameter: diameter)
        #expect(face.metrics == metrics)
        #expect(face.bounds.width == diameter)
        // Within a 3x pixel: the badge's frame lands on the pixel grid.
        #expect(abs(face.badge.bounds.width - metrics.badgeDiameter) < 0.34)
        // On the rim at 45°, bottom-trailing.
        #expect(abs(face.badge.frame.maxX - (diameter + metrics.cornerOffset)) < 0.34)
        #expect(abs(face.badge.frame.maxY - (diameter + metrics.cornerOffset)) < 0.34)
        #expect(face.faceIsCutOut)
    }

    /// The inbox's face is the people row's, 56 pt since #2420.
    @Test func theDefaultFaceIsTheInboxRows() {
        let face = RelationMarkedAvatarView()
        #expect(face.metrics == RelationMarkMetrics(faceDiameter: MonogramAvatarView.rowDiameter))
    }

    /// A face that follows Dynamic Type restates the badge with it.
    @Test func aNewDiameterRestatesTheBadge() {
        let face = laidOut(RelationMarkedAvatarView(diameter: 36))
        face.setMark(.friends, animated: false)
        face.setDiameter(60)
        face.superview?.layoutIfNeeded()
        #expect(face.bounds.width == 60, "the face kept its old size: \(face.frame)")
        let metrics = RelationMarkMetrics(faceDiameter: 60)
        #expect(face.metrics == metrics)
        #expect(face.badge.metrics == metrics)
        // Within a 3x pixel: the badge's frame lands on the pixel grid.
        #expect(abs(face.badge.bounds.width - metrics.badgeDiameter) < 0.34)
        #expect(abs(face.badge.frame.maxX - (60 + metrics.cornerOffset)) < 0.34)
    }

    /// NEVER A CONTROL (#2419): no mark takes a touch; a tap on the face is
    /// the face's (its host's).
    @Test func theBadgeNeverTakesATouch() {
        let face = laidOut(RelationMarkedAvatarView(diameter: 40))
        for mark in [PersonPill.Badge.none, .loading, .following, .friends] {
            face.setMark(mark, animated: false)
            face.superview?.layoutIfNeeded()
            let inside = CGPoint(x: face.badge.frame.minX + 2, y: face.badge.frame.minY + 2)
            #expect(face.hitTest(inside, with: nil) !== face.badge, "\(mark) took the touch")
            #expect(!face.badge.isUserInteractionEnabled)
        }
    }

    /// EVERY CHANGE SEEN ON SCREEN IS ANIMATED (#2419): no badge → a badge
    /// opens the cutout as the badge grows in, a badge → no badge closes it
    /// as it shrinks out, and the skeleton → no badge closes it as the bone
    /// fades.
    @Test func aChangeOnScreenAnimatesTheCutoutAndTheBadge() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        window.isHidden = false
        defer { window.isHidden = true }
        let face = RelationMarkedAvatarView(diameter: 56)
        face.debugFaceCutout.reducesMotion = { false }
        face.badge.reducesMotion = { false }
        face.frame = CGRect(x: 20, y: 20, width: 56, height: 56)
        window.addSubview(face)
        face.layoutIfNeeded()

        face.setMark(.following, animated: true)
        #expect(face.badge.replaceCount == 1, "the badge did not grow in")
        #expect(face.debugFaceCutout.isOpening, "the cutout did not open")
        face.setMark(.none, animated: true)
        #expect(face.badge.replaceCount == 2, "the badge did not shrink out")
        #expect(face.debugFaceCutout.isClosing, "the cutout did not close")
        #expect(face.faceIsCutOut, "the cutout left before its shrink")

        face.setMark(.loading, animated: false)
        face.setMark(.none, animated: true)
        #expect(face.debugFaceCutout.isClosing, "the skeleton's cutout was cut, not closed")
    }

    /// A FACE FILLED AFRESH DRAWS ITS STATE AT ONCE (#2419): a reused cell's
    /// known relation is no animation, on screen or not.
    @Test func aFaceFilledAfreshDrawsItsStateAtOnce() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        window.isHidden = false
        defer { window.isHidden = true }
        let face = RelationMarkedAvatarView(diameter: 56)
        face.frame = CGRect(x: 20, y: 20, width: 56, height: 56)
        window.addSubview(face)
        face.layoutIfNeeded()
        face.setMark(.loading, animated: false)
        face.setMark(.friends, animated: false)
        face.setMark(.none, animated: false)
        face.setMark(.following, animated: false)
        #expect(face.badge.replaceCount == 0)
        #expect(!face.debugFaceCutout.debugIsAnimating)
        #expect(face.faceIsCutOut)
    }
}
