import DesignSystem
import MediaCore
import Testing
import UIKit
@testable import HeroPage

/// THE PROFILE'S AVATAR WEARS THE RELATION (#2014): the author pill's ring
/// and badge, at the disc's size — the badge on its rim at 45°, the ring in
/// the grey rim's place while there is one.
@MainActor
struct HeroHeaderRelationMarkTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private func makeHeader(avatar: HeroHeaderAvatar = .person) -> HeroHeaderView {
        let header = HeroHeaderView(
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            counters: ["Followers", "Following", "Likes"], avatar: avatar
        )
        header.chromeTopInset = 103
        header.configure(with: HeroHeaderContent(
            title: "Ada Lovelace", subtitle: "@ada", counterValues: ["1", "2", "3"]
        ))
        layOut(header)
        return header
    }

    private func layOut(_ header: HeroHeaderView) {
        header.frame = CGRect(x: 0, y: 0, width: 393, height: 1)
        header.frame.size.height = header.systemLayoutSizeFitting(
            CGSize(width: 393, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height
        header.setNeedsLayout()
        header.layoutIfNeeded()
    }

    /// Each relation's symbol on the disc, and NO EDGE round it whatever the
    /// relation (#2082, the owner 2026-11-03): no ring, no grey rim — the
    /// badge alone.
    @Test(arguments: [PersonPill.Badge.follow, .following, .friends, .pending])
    func theAvatarWearsEachRelation(_ relation: PersonPill.Badge) throws {
        let header = makeHeader()
        header.setRelationMark(relation, animated: false)
        layOut(header)
        #expect(header.debugRelationSymbol == relation.symbolName)
        #expect(header.debugAvatarIsCutOut, "the disc keeps the badge's cutout")
        #expect(header.debugAvatarRingWidth == 0, "an edge round the disc for \(relation)")
    }

    /// The badge's centre on the disc's circle at 45°, at the 96 pt face's
    /// 28 pt side.
    @Test func theBadgeSitsOnTheDiscsRim() throws {
        let header = makeHeader()
        header.setRelationMark(.following, animated: false)
        layOut(header)
        let badge = try #require(header.debugRelationBadge)
        let frame = badge.convert(badge.bounds, to: header)
        let disc = header.debugAvatarFrame
        #expect(abs(frame.width - 28) < 0.5, "badge \(frame)")
        let radius = disc.width / 2
        let corner = CGPoint(x: disc.midX + radius * cos(.pi / 4), y: disc.midY + radius * sin(.pi / 4))
        #expect(hypot(frame.midX - corner.x, frame.midY - corner.y) < 1, "badge \(frame) disc \(disc)")
        // It reaches no further than the disc's own square: nothing beside
        // it can be crossed.
        #expect(frame.maxX <= disc.maxX + 0.5 && frame.maxY <= disc.maxY + 0.5)
    }

    /// None: no badge, no cutout, and no edge either.
    @Test func noRelationDrawsNothing() {
        let header = makeHeader()
        header.setRelationMark(.following, animated: false)
        header.setRelationMark(.none, animated: false)
        layOut(header)
        #expect(header.debugRelationSymbol == nil)
        #expect(!header.debugAvatarIsCutOut)
        #expect(header.debugAvatarRingWidth == 0)
    }

    /// ⚠️ NO LAYOUT MOVE: the relation arriving moves nothing in the header
    /// — the disc, the name, the counters.
    @Test func theRelationArrivingMovesNothing() {
        let header = makeHeader()
        let before = (header.debugAvatarFrame, header.debugNameHalfFrame, header.debugStatFrames, header.bounds.height)
        header.setRelationMark(.friends, animated: false)
        layOut(header)
        #expect(header.debugAvatarFrame == before.0)
        #expect(header.debugNameHalfFrame == before.1)
        #expect(header.debugStatFrames == before.2)
        #expect(header.bounds.height == before.3)
    }

    /// ⚠️ THE SKELETON WEARS THE SKELETON'S BADGE (#2098, reversing
    /// #2014): a bone with its cutout under the bones; the reveal brings the
    /// asked mark in the same place.
    @Test func theSkeletonWearsTheSkeletonsBadge() throws {
        let header = makeHeader()
        header.setRedacted(true)
        header.setRelationMark(.follow, animated: false)
        layOut(header)
        #expect(header.shownRelationMark == .loading)
        #expect(header.debugRelationSymbol == nil)
        #expect(header.debugRelationBadge?.showsBone == true)
        #expect(header.debugAvatarIsCutOut, "the skeleton's badge with no cutout")
        let place = try #require(header.debugRelationBadge).frame
        #expect(header.relationMark == .follow)
        header.setRedacted(false)
        layOut(header)
        #expect(header.debugRelationSymbol == "plus")
        #expect(header.debugRelationBadge?.showsBone == false)
        #expect(header.debugRelationBadge?.frame == place, "the badge moved at the reveal")
        #expect(header.debugAvatarIsCutOut)
    }

    /// A face that wears no badge for good — the viewer's own — wears none
    /// under the bones either.
    @Test func aFaceWithNoBadgeWearsNoneUnderTheBones() {
        let header = makeHeader()
        header.setRelationMark(.none, animated: false)
        header.setRedacted(true)
        layOut(header)
        #expect(header.shownRelationMark == .none)
        #expect(!header.debugAvatarIsCutOut)
        #expect(header.debugRelationBadge?.showsBone == false)
    }

    /// A state mark takes no tap: it falls through to the disc's own, and
    /// is read as its state, not as a button (#2050).
    @Test(arguments: [PersonPill.Badge.following, .friends, .pending])
    func aStateMarkTakesNoTap(_ relation: PersonPill.Badge) throws {
        let header = makeHeader()
        var taps = 0
        header.onRelationBadgeTapped = { taps += 1 }
        header.setRelationMark(relation, animated: false)
        let badge = try #require(header.debugRelationBadge)
        #expect(!badge.isUserInteractionEnabled)
        badge.sendActions(for: .primaryActionTriggered)
        #expect(taps == 0, "a state mark followed")
        #expect(!badge.accessibilityTraits.contains(.button))
        #expect(badge.accessibilityLabel != nil)
    }

    /// The "+" is the header's follow (#2050): a button, "Follow", that
    /// tells `onRelationBadgeTapped`.
    @Test func thePlusTellsTheFollow() throws {
        let header = makeHeader()
        var taps = 0
        header.onRelationBadgeTapped = { taps += 1 }
        header.setRelationMark(.follow, animated: false)
        let badge = try #require(header.debugRelationBadge)
        #expect(badge.isUserInteractionEnabled)
        badge.sendActions(for: .primaryActionTriggered)
        #expect(taps == 1)
        #expect(badge.isAccessibilityElement && badge.accessibilityTraits.contains(.button))
        #expect(badge.accessibilityLabel == "Follow")
    }

    /// A place's disc wears no relation.
    @Test func aCustomDiscWearsNone() {
        let header = makeHeader(avatar: .custom(UIView()))
        header.setRelationMark(.follow, animated: false)
        #expect(header.debugRelationBadge == nil)
        #expect(header.debugAvatarRingWidth == 0)
    }
}
