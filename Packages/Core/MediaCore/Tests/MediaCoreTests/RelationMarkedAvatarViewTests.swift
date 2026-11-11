import DesignSystem
import Testing
import UIKit
@testable import MediaCore

/// THE ONE MARKED FACE, AT ANY DIAMETER (#2300): the inbox row's 48 pt, a
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

    /// The inbox's face is still 48 pt by default — Chat unchanged.
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

    /// Only the "+" takes a touch — past the face's own bounds too; a host
    /// that holds the face's taps keeps them everywhere else.
    @Test func onlyThePlusTakesATouch() {
        let face = laidOut(RelationMarkedAvatarView(diameter: 40))
        face.takesOnlyBadgeTouches = true
        face.setMark(.follow, animated: false)
        face.superview?.layoutIfNeeded()
        let badgeCentre = CGPoint(x: face.badge.frame.midX, y: face.badge.frame.midY)
        #expect(face.hitTest(badgeCentre, with: nil) === face.badge)
        #expect(face.hitTest(CGPoint(x: 10, y: 10), with: nil) == nil)
        face.setMark(.following, animated: false)
        #expect(face.hitTest(badgeCentre, with: nil) == nil)
        face.takesOnlyBadgeTouches = false
        #expect(face.hitTest(CGPoint(x: 10, y: 10), with: nil) != nil)
    }

    /// The "+"'s tap is told; a state mark's never.
    @Test func thePlusTellsItsTap() {
        let face = RelationMarkedAvatarView(diameter: 40)
        var taps = 0
        face.onFollowTapped = { taps += 1 }
        face.setMark(.follow, animated: false)
        face.badge.sendActions(for: .primaryActionTriggered)
        face.setMark(.following, animated: false)
        face.badge.sendActions(for: .primaryActionTriggered)
        #expect(taps == 1)
    }
}
