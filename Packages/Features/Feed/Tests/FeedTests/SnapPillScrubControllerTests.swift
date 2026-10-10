import CoreGraphics
import CoreModels
import Foundation
import Testing
@testable import Feed

/// THE AUTHOR PILL'S STEPS UNDER THE SCROLL.
///
/// `SnapPillScrubController` turns each scroll frame into what the pill does:
/// how blurred it is, and the page it changes to at the midpoint — sharp when
/// the two pages draw the same pill, nothing at all while a presentation owns
/// the bars, and the "do these pages differ" question asked once per pair.
struct SnapPillScrubControllerTests {
    private static let page: CGFloat = 800

    /// A frame at `position` pages, on a feed of `count` posts.
    private static func step(
        _ controller: inout SnapPillScrubController, at position: CGFloat, count: Int = 5,
        canScrub: Bool = true, differs: (Int) -> Bool? = { _ in true }
    ) -> SnapPillScrubController.Step? {
        controller.update(
            offset: position * page, pageHeight: page, itemCount: count,
            canScrub: canScrub, pillDiffers: differs
        )
    }

    private static func settled(at index: Int) -> SnapPillScrubController {
        var controller = SnapPillScrubController()
        controller.settle(at: index)
        return controller
    }

    // MARK: - Guards

    @Test func noStepWithoutAPageHeight() {
        var controller = Self.settled(at: 0)
        let step = controller.update(
            offset: 400, pageHeight: 0, itemCount: 5, canScrub: true, pillDiffers: { _ in true }
        )
        #expect(step == nil)
    }

    @Test func noStepWhileAPresentationOwnsTheBars() {
        var controller = Self.settled(at: 0)
        #expect(Self.step(&controller, at: 0.6, canScrub: false) == nil)
        #expect(controller.shownIndex == 0, "a refused frame swaps nothing")
    }

    // MARK: - Blur and swap

    @Test func theBlurFollowsTheScrollBetweenTwoPagesThatDiffer() throws {
        var controller = Self.settled(at: 0)
        let rising = try #require(Self.step(&controller, at: 0.4))
        #expect(rising.blur == BarPillScrub.blur(coverage: 0.4))
        #expect(rising.blur > 0 && rising.blur < 1)
        #expect(rising.position == 0.4)
        #expect(rising.swapTo == nil)
        #expect(Self.step(&controller, at: 0.5)?.blur == 1)
    }

    @Test func twoPagesThatDrawTheSamePillLeaveItSharp() throws {
        var controller = Self.settled(at: 0)
        let step = try #require(Self.step(&controller, at: 0.5, differs: { _ in false }))
        #expect(step.blur == 0)
    }

    @Test func anUnknownPairReadsAsTheSameAndIsAskedAgain() throws {
        var controller = Self.settled(at: 0)
        var asked = 0
        #expect(Self.step(&controller, at: 0.45, differs: { _ in asked += 1; return nil })?.blur == 0)
        let known = try #require(Self.step(&controller, at: 0.45, differs: { _ in asked += 1; return true }))
        #expect(known.blur > 0)
        #expect(asked == 2, "an unknown answer is not cached")
    }

    @Test func thePillSwapsOnceThePageIsPastTheMidpoint() {
        var controller = Self.settled(at: 0)
        #expect(Self.step(&controller, at: 0.51)?.swapTo == nil, "inside the hysteresis band")
        #expect(Self.step(&controller, at: 0.53)?.swapTo == 1)
        #expect(Self.step(&controller, at: 0.6)?.swapTo == nil, "one swap per change of hands")
        #expect(controller.shownIndex == 1)
        #expect(Self.step(&controller, at: 0.45)?.swapTo == 0, "a drag back swaps back")
    }

    @Test func nothingSwapsBeforeAPageHasSettled() {
        var controller = SnapPillScrubController()
        #expect(Self.step(&controller, at: 0.8)?.swapTo == nil)
    }

    @Test func overscrollPastTheEndIsSharp() {
        var controller = Self.settled(at: 4)
        #expect(Self.step(&controller, at: 4.3, count: 5)?.blur == 0)
    }

    // MARK: - The pair cache

    @Test func eachPairIsAskedOnce() {
        var controller = Self.settled(at: 0)
        var asked: [Int] = []
        let differs: (Int) -> Bool? = { asked.append($0); return true }
        for position in [0.35, 0.4, 0.45, 0.5] as [CGFloat] {
            _ = Self.step(&controller, at: position, differs: differs)
        }
        #expect(asked == [0])
        _ = Self.step(&controller, at: 1.4, differs: differs)
        #expect(asked == [0, 1], "a new pair is asked")
    }

    @Test func forgettingThePairAsksAgain() {
        var controller = Self.settled(at: 0)
        var asked = 0
        let differs: (Int) -> Bool? = { _ in asked += 1; return true }
        _ = Self.step(&controller, at: 0.4, differs: differs)
        controller.forgetPair()
        _ = Self.step(&controller, at: 0.4, differs: differs)
        #expect(asked == 2)
    }

    @Test func aSettleForgetsThePair() {
        var controller = Self.settled(at: 0)
        var asked = 0
        let differs: (Int) -> Bool? = { _ in asked += 1; return true }
        _ = Self.step(&controller, at: 0.4, differs: differs)
        controller.settle(at: 0)
        _ = Self.step(&controller, at: 0.4, differs: differs)
        #expect(asked == 2)
        #expect(controller.shownIndex == 0)
    }

    // MARK: - What the author pill draws

    private static func model(
        author: String = "a", name: String = "Ava", meta: String = "2h", avatar: String? = nil
    ) -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID("p"), authorID: ProfileID(author), authorName: name, metaText: meta,
            avatarURL: avatar.flatMap(URL.init(string:)), caption: nil, mediaURL: nil,
            mediaKind: .image, thumbnailURL: nil, audioText: nil
        )
    }

    @Test func thePillDiffersByFaceNameAgeOrBadge() {
        let base = Self.model()
        let none: (ProfileID?) -> SnapAuthorIdentityView.FollowBadge = { _ in .none }
        #expect(!SnapPillScrubController.authorPillDiffers(base, Self.model(), badge: none))
        #expect(SnapPillScrubController.authorPillDiffers(base, Self.model(author: "b"), badge: none))
        #expect(SnapPillScrubController.authorPillDiffers(base, Self.model(name: "Bo"), badge: none))
        #expect(SnapPillScrubController.authorPillDiffers(base, Self.model(meta: "3h"), badge: none))
        #expect(SnapPillScrubController.authorPillDiffers(
            base, Self.model(avatar: "mock://face/1"), badge: none))
    }

    /// The badge is asked for both authors: an answer that changed between
    /// the two is a difference the blur has to carry (#627).
    @Test func aDifferentBadgeIsADifference() {
        var answers: [SnapAuthorIdentityView.FollowBadge] = [.follow, .following]
        let badge: (ProfileID?) -> SnapAuthorIdentityView.FollowBadge = { _ in answers.removeFirst() }
        #expect(SnapPillScrubController.authorPillDiffers(Self.model(), Self.model(), badge: badge))
        #expect(answers.isEmpty)
    }
}
