import DesignSystem
import Testing
import UIKit
@testable import MediaCore

/// THE APP'S ONE PERSON PILL (#1277): the post toolbar, the conversation, the
/// composer and the profile bar all draw it.
@MainActor
struct PersonPillTests {
    private static func laidOut(_ pill: PersonPill) -> PersonPill {
        pill.setName("Ada Lovelace", handle: "@ada")
        pill.frame.size = pill.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        pill.layoutIfNeeded()
        return pill
    }

    /// ⚠️ ON THE FACE'S CIRCLE AT ITS BOTTOM-TRAILING CORNER (the owner,
    /// 2026-10-28, #1793, replacing #1277's mid-height): the badge's centre
    /// sits on the face's rim, 45° below its trailing side; its size is
    /// unchanged and the name starts clear of it.
    @Test(arguments: [PersonPill.Badge.follow, .following, .friends, .pending])
    func theBadgeSitsOnTheFacesBottomTrailingCorner(_ badge: PersonPill.Badge) throws {
        let pill = PersonPill(carriesBadge: true)
        pill.setBadge(badge, animated: false)
        let geometry = Self.laidOut(pill).debugGeometry
        let drawn = try #require(geometry.badge)
        #expect(abs(drawn.width - 20) < 0.5 && abs(drawn.height - 20) < 0.5, "not the larger badge: \(drawn)")
        let face = geometry.face
        let radius = face.width / 2
        let corner = CGPoint(x: face.midX + radius * cos(.pi / 4), y: face.midY + radius * sin(.pi / 4))
        #expect(abs(drawn.midX - corner.x) < 0.5 && abs(drawn.midY - corner.y) < 0.5,
                "the centre \(CGPoint(x: drawn.midX, y: drawn.midY)) is not on the rim at 45° \(corner)")
        #expect(drawn.maxX <= geometry.name.minX, "the badge covers the name")
    }

    /// Mirrored under right-to-left: the bottom-LEADING corner of the face,
    /// as seen, since the anchors are trailing ones.
    @Test func theCornerMirrorsUnderRightToLeft() throws {
        let pill = PersonPill(carriesBadge: true)
        pill.semanticContentAttribute = .forceRightToLeft
        pill.subviews.forEach { $0.semanticContentAttribute = .forceRightToLeft }
        pill.setBadge(.follow, animated: false)
        let geometry = Self.laidOut(pill).debugGeometry
        let drawn = try #require(geometry.badge)
        #expect(drawn.midX < geometry.face.midX, "the badge did not mirror: \(drawn) face \(geometry.face)")
        #expect(drawn.midY > geometry.face.midY)
    }

    /// The badge is optional: the profile's pill has none, and its name sits
    /// at the row's plain gap from the face.
    @Test func aPillWithoutABadgeDrawsNone() {
        let pill = PersonPill(carriesBadge: false)
        pill.setBadge(.follow, animated: false)
        let geometry = Self.laidOut(pill).debugGeometry
        #expect(geometry.badge == nil)
        #expect(pill.badge == .none, "a badge-less pill took a relation")
        #expect(pill.drawnBadgeSymbol == nil)
        #expect(geometry.name.minX - geometry.face.maxX < 10, "the badge's room was kept on a pill without one")
    }

    /// A relation never moves the pill's width.
    @Test func noBadgeMovesTheWidth() {
        let pill = Self.laidOut(PersonPill(carriesBadge: true))
        var widths: [CGFloat] = []
        for badge in [PersonPill.Badge.none, .follow, .following, .friends, .pending] {
            pill.setBadge(badge, animated: false)
            widths.append(pill.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width)
        }
        #expect(widths.allSatisfy { abs($0 - widths[0]) < 0.5 }, "\(widths)")
    }

    /// The width budget caps the pill under its ceiling, and the cold floor
    /// holds only while no person is set.
    @Test func theBudgetCapsAndTheColdFloorHoldsUntilAPerson() {
        let pill = PersonPill(carriesBadge: true, ceiling: 220, coldWidth: 150)
        #expect(pill.isRedacted)
        #expect(pill.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width >= 150 - 0.5)
        #expect(pill.setWidthBudget(400) == false, "a budget past the ceiling changed the cap")
        #expect(pill.widthCap == 220, "the ceiling did not hold")
        #expect(pill.setWidthBudget(180))
        #expect(pill.setWidthBudget(180) == false, "an unchanged cap asked for a pass")
        pill.setName("A", handle: "")
        #expect(pill.isRedacted == false)
        #expect(pill.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width < 150,
                "a hydrated short name kept the cold floor")
    }

    /// Too narrow for a name, the pill is its face alone (#1924, the owner:
    /// "minimum width = avatar"): no labels, a circle the bar draws around
    /// the avatar — never the row crushing the face into an oval. Given room
    /// again, the name comes back.
    @Test func tooNarrowForANameThePillIsItsFace() {
        let pill = Self.laidOut(PersonPill(carriesBadge: true, ceiling: 220))
        pill.setWidthBudget(PersonPill.faceOnlyWidth)
        #expect(pill.showsFaceOnly)
        let face = pill.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
        #expect(abs(face - PersonPill.faceOnlyWidth) < 0.5, "the face-only pill is \(face) wide")
        #expect(pill.accessibilityLabel?.contains("Ada Lovelace") == true, "VoiceOver lost the name")

        pill.setWidthBudget(180)
        #expect(!pill.showsFaceOnly, "the name did not come back")
        #expect(pill.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width > PersonPill.faceOnlyWidth + 20)
    }

    /// A badge change is a symbol replace when animated, and nothing else.
    @Test func anAnimatedChangeIsOneReplace() {
        let pill = PersonPill(carriesBadge: true)
        pill.setBadge(.follow, animated: false)
        #expect(pill.badgeReplaceCount == 0)
        pill.setBadge(.following, animated: true)
        #expect(pill.badgeReplaceCount == 1)
        #expect(pill.drawnBadgeSymbol == "checkmark.circle.fill")
    }

    /// THE FACE'S RELATION RING (#1298, the owner 2026-10-16): grey — the
    /// badge's quiet disc — while the viewer follows, pink once they are
    /// friends, none otherwise; re-coloured in place, the width unmoved.
    @Test(arguments: [
        (PersonPill.Badge.following, PersonPillBadgeInks.quietDisc),
        (.friends, PersonPillBadgeInks.accent),
        (.follow, UIColor.clear), (.pending, .clear), (.none, .clear),
    ])
    func theRingSaysTheRelation(_ relation: PersonPill.Badge, _ ink: UIColor) {
        let pill = Self.laidOut(PersonPill(carriesBadge: true))
        let width = pill.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
        pill.setBadge(relation, animated: false)
        #expect(pill.ringRelation == relation)
        #expect(pill.drawnRingColor.cgColor == ink.cgColor || (ink == .clear && pill.drawnRingColor.cgColor.alpha == 0))
        #expect(abs(pill.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width - width) < 0.5,
                "the ring moved the pill's width")
    }

    /// ⚠️ THE RING GOES WITH THE BADGE (the owner, 2026-10-16): a pill with
    /// no badge (the profile's) never wears one, whatever it is told.
    @Test func aBadgeLessPillWearsNoRing() {
        let pill = PersonPill(carriesBadge: false)
        pill.setRing(.friends, animated: false)
        #expect(pill.ringRelation == .none)
        #expect(pill.drawnRingColor.cgColor.alpha == 0)
    }

    // MARK: - #1912: the ring behind the face, the initials' grey, the cutout

    /// The ring is a disc BEHIND the face, never a border meeting it: two
    /// anti-aliased edges on one circle left a hairline seam on screen.
    @Test func theRingIsADiscBehindTheFace() {
        let pill = Self.laidOut(PersonPill(carriesBadge: true))
        pill.setBadge(.following, animated: false)
        #expect(pill.ringIsBackingDisc, "the ring is a border, or in front of the face")
    }

    /// The final initials wear their own grey, apart from the badge's quiet
    /// disc and the following ring, in both appearances.
    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func theInitialsGreyIsNotTheQuietDisc(_ style: UIUserInterfaceStyle) {
        let traits = UITraitCollection(userInterfaceStyle: style)
        let plate = MonogramAvatarView.initialsPlateColor.resolvedColor(with: traits)
        let quiet = PersonPillBadgeInks.quietDisc.resolvedColor(with: traits)
        #expect(plate.cgColor != quiet.cgColor, "the initials' grey is the ring's in \(style.rawValue)")
    }

    /// A loading face keeps the media ground; only final initials change.
    @Test func onlyFinalInitialsWearTheirGrey() {
        let monogram = MonogramAvatarView(diameter: 36)
        let ground = monogram.drawnPlateColor.cgColor
        monogram.showsFinalInitials = true
        #expect(monogram.drawnPlateColor.cgColor != ground)
        monogram.showsFinalInitials = false
        #expect(monogram.drawnPlateColor.cgColor == ground)
    }

    /// The badge is cut out of the face it overlaps: its radius plus 1.5 pt.
    @Test func theBadgeIsCutOutOfTheFace() {
        let pill = Self.laidOut(PersonPill(carriesBadge: true))
        pill.setBadge(.follow, animated: false)
        pill.layoutIfNeeded()
        #expect(pill.drawnCutoutRadius == 10 + PersonPill.cutoutGap)
        pill.setBadge(.none, animated: false)
        pill.layoutIfNeeded()
        #expect(pill.drawnCutoutRadius == nil, "a cutout with no badge")
    }
}
