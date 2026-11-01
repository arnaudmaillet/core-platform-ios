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

    /// Each relation's symbol on the disc, the ring in the rim's place for
    /// following and friends, the grey rim kept otherwise.
    @Test(arguments: [PersonPill.Badge.follow, .following, .friends, .pending])
    func theAvatarWearsEachRelation(_ relation: PersonPill.Badge) throws {
        let header = makeHeader()
        header.setRelationMark(relation, animated: false)
        layOut(header)
        #expect(header.debugRelationSymbol == relation.symbolName)
        #expect(header.debugAvatarIsCutOut, "the disc keeps the badge's cutout")
        let ring = try #require(header.debugAvatarRingColor)
        let traits = header.traitCollection
        if RelationMark.hasRing(relation) {
            #expect(UIColor(cgColor: ring) == RelationMark.ringInk(for: relation).resolvedColor(with: traits))
            #expect(header.debugAvatarRingWidth == 4, "the ring's width at 96 pt")
        } else {
            #expect(UIColor(cgColor: ring) == Surface.avatarRim.resolvedColor(with: traits))
            #expect(header.debugAvatarRingWidth == 3, "the rim's width")
        }
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

    /// None: no badge, the grey rim, no cutout.
    @Test func noRelationKeepsTheRim() throws {
        let header = makeHeader()
        header.setRelationMark(.following, animated: false)
        header.setRelationMark(.none, animated: false)
        layOut(header)
        #expect(header.debugRelationSymbol == nil)
        #expect(!header.debugAvatarIsCutOut)
        #expect(header.debugAvatarRingWidth == 3)
        let ring = try #require(header.debugAvatarRingColor)
        #expect(UIColor(cgColor: ring) == Surface.avatarRim.resolvedColor(with: header.traitCollection))
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

    /// The skeleton wears no relation; the reveal brings the asked one.
    @Test func theSkeletonWearsNoRelation() {
        let header = makeHeader()
        header.setRedacted(true)
        header.setRelationMark(.follow, animated: false)
        #expect(header.debugRelationSymbol == nil)
        #expect(header.relationMark == .follow)
        header.setRedacted(false)
        #expect(header.debugRelationSymbol == "plus")
    }

    /// A state mark takes no tap: it falls through to the disc's own.
    @Test(arguments: [PersonPill.Badge.following, .friends])
    func aStateMarkTakesNoTap(_ relation: PersonPill.Badge) throws {
        let header = makeHeader()
        header.setRelationMark(relation, animated: false)
        let badge = try #require(header.debugRelationBadge)
        #expect(!badge.isUserInteractionEnabled)
        #expect(!badge.isAccessibilityElement)
    }

    /// A place's disc wears no relation.
    @Test func aCustomDiscWearsNone() {
        let header = makeHeader(avatar: .custom(UIView()))
        header.setRelationMark(.follow, animated: false)
        #expect(header.debugRelationBadge == nil)
        #expect(header.debugAvatarRingWidth == 3)
    }
}
