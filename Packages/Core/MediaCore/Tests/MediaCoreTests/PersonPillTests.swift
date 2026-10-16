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

    /// ⚠️ LARGER, AND CENTRED ON THE FACE'S EDGE (the owner, 2026-10-16): the
    /// badge's centre sits on the far end of the face's disc, at its
    /// mid-height, and the name starts clear of it.
    @Test(arguments: [PersonPill.Badge.follow, .following, .friends, .pending])
    func theBadgeIsCentredOnTheFacesEdge(_ badge: PersonPill.Badge) throws {
        let pill = PersonPill(carriesBadge: true)
        pill.setBadge(badge, animated: false)
        let geometry = Self.laidOut(pill).debugGeometry
        let drawn = try #require(geometry.badge)
        #expect(abs(drawn.width - 20) < 0.5 && abs(drawn.height - 20) < 0.5, "not the larger badge: \(drawn)")
        #expect(abs(drawn.midX - geometry.face.maxX) < 0.5, "the centre is not on the disc's edge")
        #expect(abs(drawn.midY - geometry.face.midY) < 0.5, "not level with the face")
        #expect(drawn.maxX <= geometry.name.minX, "the badge covers the name")
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
}
