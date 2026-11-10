import DesignSystem
import Testing
import UIKit
@testable import MediaCore

/// A GROUP'S PICTURE (#2233): its photo, else its members' faces stacked and
/// cut apart — up to four, "+N" beyond — else its initials; one component,
/// the inbox row's and the thread pill's alike.
@MainActor
struct GroupAvatarTests {
    private static let photo = URL(string: "https://example.com/group.jpg")!

    private static func faces(_ count: Int) -> [GroupAvatarFace] {
        let names = ["Sofía Reyes", "Tom Okafor", "Ana Lima", "Lee Park", "Mia Chen", "Noah Berg"]
        return (0..<count).map { index in
            GroupAvatarFace(
                name: names[index % names.count],
                avatarURL: URL(string: "https://example.com/face\(index).jpg")
            )
        }
    }

    // MARK: - What it draws

    /// Photo > faces > initials.
    @Test func thePhotoComesFirstThenTheFacesThenTheInitials() {
        let withPhoto = GroupAvatarContent(name: "Weekend hike", photoURL: Self.photo, faces: Self.faces(3), memberCount: 4)
        #expect(withPhoto.drawing == .photo(Self.photo))

        let faced = GroupAvatarContent(name: "Sofía Reyes and Tom Okafor", faces: Self.faces(2), memberCount: 3)
        #expect(faced.drawing == .stack(Self.faces(2), more: 0))

        let bare = GroupAvatarContent(name: "Sofía Reyes and Tom Okafor", memberCount: 3)
        #expect(bare.drawing == .initials("ST"))
        // A name of its own keeps the app's rule.
        #expect(GroupAvatarContent(name: "Weekend hike", memberCount: 4).monogram == "WH")
        #expect(GroupAvatarContent(name: "Ava, Kenji and Lena", memberCount: 4).monogram == "AK")
    }

    /// The other members, the viewer excluded: a group of three shows two
    /// faces, of five four; past four other members, three and "+N" — every
    /// member not drawn, so a group of 40 reads "+37".
    @Test(arguments: [
        (2, 1, nil), (3, 2, nil), (4, 3, nil), (5, 4, nil), (6, 3, 3), (40, 3, 37),
    ] as [(Int, Int, Int?)])
    func theFacesAndThePlusForEachMemberCount(_ members: Int, _ faces: Int, _ more: Int?) {
        // The data plane hands at most four faces, whatever the group's size.
        let content = GroupAvatarContent(name: "Group", faces: Self.faces(min(members - 1, 6)), memberCount: members)
        guard case .stack(let drawn, let plus) = content.drawing else {
            Issue.record("not a stack: \(content.drawing)")
            return
        }
        #expect(drawn.count == faces)
        #expect((plus > 0 ? plus : nil) == more)

        let view = GroupAvatarView()
        view.frame = CGRect(x: 0, y: 0, width: 48, height: 48)
        view.setContent(content, pipeline: nil)
        #expect(view.drawnFaceCount == faces)
        #expect(view.drawnMore == more)
        #expect(view.stackFrames.count == faces + (more == nil ? 0 : 1))
        #expect(!view.drawsSingleDisc)
    }

    /// No more than four faces are ever kept, in the order handed in.
    @Test func atMostFourFacesAreKeptInTheirOrder() {
        let content = GroupAvatarContent(name: "Group", faces: Self.faces(6), memberCount: 7)
        #expect(content.faces == Array(Self.faces(6).prefix(4)))
        #expect(GroupAvatarLayout.maximumFaces == 4)
    }

    /// A member count not known: the faces count for it, never a "+N".
    @Test func anUnknownCountDrawsTheFacesAlone() {
        let content = GroupAvatarContent(name: "Group", faces: Self.faces(4))
        #expect(content.drawing == .stack(Self.faces(4), more: 0))
    }

    // MARK: - The layout

    /// Each count's set, as the issue places it (fractions of a side of
    /// 100), the first face at the back.
    @Test func eachCountIsPlacedByHand() {
        func discs(_ count: Int) -> [[CGFloat]] {
            GroupAvatarLayout.frames(count: count, side: 100, rightToLeft: false).map { [$0.midX, $0.midY, $0.width / 2] }
        }
        #expect(discs(1) == [[50, 50, 50]])
        #expect(discs(2) == [[36, 36, 30], [70, 68, 24]])
        #expect(discs(3) == [[38, 40, 28], [74, 30, 20], [62, 74, 20]])
        #expect(discs(4) == [[34, 36, 24], [70, 30, 20], [32, 72, 18], [67, 67, 22]])
        // Different sizes: one main face larger than the others.
        for count in 2...4 {
            let radii = discs(count).map { $0[2] }
            #expect(Set(radii).count > 1, "\(count) faces all one size")
        }
    }

    /// Right-to-left mirrors every set; the heights stay.
    @Test(arguments: [1, 2, 3, 4])
    func rightToLeftMirrorsTheLayout(_ count: Int) {
        for side in [36, 48, 96] as [CGFloat] {
            let leading = GroupAvatarLayout.frames(count: count, side: side, rightToLeft: false)
            let mirrored = GroupAvatarLayout.frames(count: count, side: side, rightToLeft: true)
            for (left, right) in zip(leading, mirrored) {
                #expect(abs((side - left.midX) - right.midX) <= 0.5, "\(count) at \(side)")
                #expect(left.minY == right.minY && left.size == right.size)
            }
        }
    }

    /// The view mirrors too, under a right-to-left layout.
    @Test func theViewMirrorsUnderRightToLeft() {
        let content = GroupAvatarContent(name: "Group", faces: Self.faces(2), memberCount: 3)
        let leading = GroupAvatarView()
        leading.frame = CGRect(x: 0, y: 0, width: 48, height: 48)
        leading.setContent(content, pipeline: nil)
        let trailing = GroupAvatarView()
        trailing.semanticContentAttribute = .forceRightToLeft
        trailing.frame = leading.frame
        trailing.setContent(content, pipeline: nil)
        let back = leading.stackFrames[0]
        let mirroredBack = trailing.stackFrames[0]
        #expect(back.midX < 24 && mirroredBack.midX > 24)
    }

    /// Every face stays inside the disc.
    @Test(arguments: [1, 2, 3, 4])
    func everyFaceStaysInsideTheDisc(_ count: Int) {
        let disc = CGRect(x: 0, y: 0, width: 48, height: 48)
        for frame in GroupAvatarLayout.frames(count: count, side: 48, rightToLeft: false) {
            #expect(disc.contains(frame), "\(frame)")
        }
    }

    // MARK: - The cut

    /// ⚠️ THE GAP IS IN POINTS, THE SAME AT EVERY SIZE: on the line between
    /// two faces, the face behind is cut `gap` past the front face's rim —
    /// at the pill's 36 pt, the row's 48 and the info screen's 96 alike.
    @Test(arguments: [36, 48, 96] as [CGFloat])
    func theGapIsTheSameWidthInPointsAtEverySize(_ side: CGFloat) {
        let frames = GroupAvatarLayout.frames(count: 2, side: side, rightToLeft: false)
        let back = frames[0]
        let front = frames[1]
        let mask = GroupAvatarLayout.maskPath(index: 0, frames: frames)
        // From the front face's centre toward the back face's.
        let dx = back.midX - front.midX
        let dy = back.midY - front.midY
        let length = hypot(dx, dy)
        func point(atDistance distance: CGFloat) -> CGPoint {
            // In the back face's own space, where its mask is drawn.
            CGPoint(
                x: front.midX + dx / length * distance - back.minX,
                y: front.midY + dy / length * distance - back.minY
            )
        }
        let rim = front.width / 2
        let gap = GroupAvatarLayout.gap
        #expect(!mask.contains(point(atDistance: rim - 0.5)), "the front face's own disc is cut")
        #expect(!mask.contains(point(atDistance: rim + gap - 0.25)), "the gap is narrower than \(gap) pt")
        #expect(mask.contains(point(atDistance: rim + gap + 0.25)), "the gap is wider than \(gap) pt")
    }

    /// The face in front is never cut: only faces behind lose a disc.
    @Test func theFrontFaceIsWhole() {
        let frames = GroupAvatarLayout.frames(count: 4, side: 48, rightToLeft: false)
        let front = frames[3]
        let mask = GroupAvatarLayout.maskPath(index: 3, frames: frames)
        #expect(mask.boundingBoxOfPath.size == front.size)
        #expect(mask.contains(CGPoint(x: front.width / 2, y: front.height / 2)))
    }

    /// The view cuts through masks, never a ring of a background colour:
    /// what is behind shows through the gap.
    @Test func theViewCutsWithMasksNotRings() {
        let view = GroupAvatarView()
        view.frame = CGRect(x: 0, y: 0, width: 48, height: 48)
        view.setContent(GroupAvatarContent(name: "Group", faces: Self.faces(2), memberCount: 3), pipeline: nil)
        #expect(!view.drawsRings)
        let frames = view.stackFrames
        // Just outside the front face, toward the back one: inside the back
        // face's disc, yet cut out of it.
        let front = frames[1]
        let back = frames[0]
        let dx = back.midX - front.midX
        let dy = back.midY - front.midY
        let length = hypot(dx, dy)
        let reach = front.width / 2 + GroupAvatarLayout.gap / 2
        let inGap = CGPoint(x: front.midX + dx / length * reach, y: front.midY + dy / length * reach)
        #expect(!view.stackShows(at: inGap, index: 0))
        #expect(view.stackShows(at: CGPoint(x: back.minX + 4, y: back.midY), index: 0))
    }

    // MARK: - The view

    /// The photo and the initials are one disc, the whole side.
    @Test func thePhotoAndTheInitialsAreOneDisc() {
        let view = GroupAvatarView()
        view.frame = CGRect(x: 0, y: 0, width: 48, height: 48)
        view.setContent(GroupAvatarContent(name: "Weekend hike", photoURL: Self.photo, faces: Self.faces(2)), pipeline: nil)
        #expect(view.drawsSingleDisc && view.drawnFaceCount == 0)
        view.setContent(GroupAvatarContent(name: "Weekend hike"), pipeline: nil)
        #expect(view.drawsSingleDisc && view.drawnFaceCount == 0 && view.drawnMore == nil)
        view.setContent(nil, pipeline: nil)
        #expect(!view.drawsSingleDisc && view.drawnFaceCount == 0)
    }

    /// A member added moves the faces already drawn without making them
    /// again: the same views, their pictures kept (no flash).
    @Test func aMemberAddedKeepsTheFacesAlreadyDrawn() {
        let view = GroupAvatarView()
        view.frame = CGRect(x: 0, y: 0, width: 48, height: 48)
        view.setContent(GroupAvatarContent(name: "Group", faces: Self.faces(2), memberCount: 3), pipeline: nil)
        let before = view.subviews.filter { !$0.isHidden }
        view.setContent(GroupAvatarContent(name: "Group", faces: Self.faces(3), memberCount: 4), pipeline: nil)
        let after = view.subviews.filter { !$0.isHidden }
        #expect(after.count == 3)
        #expect(before.allSatisfy { after.contains($0) })
    }

    /// One element, "Group: Sofía, Tom and 2 others"; the faces are not
    /// elements of their own.
    @Test func voiceOverReadsOneElementForTheGroup() {
        let view = GroupAvatarView()
        view.setContent(GroupAvatarContent(name: "Group", faces: Self.faces(4), memberCount: 5), pipeline: nil)
        #expect(view.isAccessibilityElement)
        #expect(view.accessibilityLabel == "Group: Sofía, Tom and 2 others")
        #expect(GroupAvatarContent(name: "G", faces: Self.faces(2), memberCount: 3).spokenLabel == "Group: Sofía and Tom")
        #expect(GroupAvatarContent(name: "G", faces: Self.faces(3), memberCount: 40).spokenLabel
            == "Group: Sofía, Tom and 37 others")
        #expect(GroupAvatarContent(name: "Weekend hike", photoURL: Self.photo).spokenLabel == "Group: Weekend hike")
    }

    // MARK: - The pill

    /// The pill shows a group's picture in the face's place, the person's
    /// avatar hidden under it — and gives the face back for a person.
    @Test func thePillDrawsTheGroupInTheFacesPlace() {
        let pill = PersonPill(carriesBadge: true)
        let content = GroupAvatarContent(name: "Sofía Reyes and Tom Okafor", faces: Self.faces(2), memberCount: 3)
        pill.setGroupAvatar(content, pipeline: nil)
        pill.layoutIfNeeded()
        #expect(pill.groupAvatarContent == content)
        #expect(pill.avatar.isHidden)
        #expect(pill.debugGroupAvatar?.drawnFaceCount == 2)
        #expect(pill.debugGroupAvatar?.isAccessibilityElement == false, "the pill is the element")
        #expect(!pill.drawsAnythingRoundTheFace)
        pill.setGroupAvatar(nil, pipeline: nil)
        #expect(pill.groupAvatarContent == nil)
        #expect(!pill.avatar.isHidden)
    }
}
