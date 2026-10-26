import DesignSystem
import Testing
import UIKit
@testable import MediaCore

/// The shared avatar (#943, #1750): a picture's skeleton, then the picture;
/// the initials only without a picture, or when it fails.
@MainActor
struct AvatarViewTests {
    private func makePipeline() -> ImagePipeline { ImagePipeline(fetcher: PlaceholderImageFetcher()) }

    /// A clock a test steps by hand.
    @MainActor
    final class ManualClock {
        var now: TimeInterval = 0
        private var pending: [(at: TimeInterval, work: @MainActor () -> Void)] = []
        var clock: LoadingLadder.Clock {
            LoadingLadder.Clock(now: { [weak self] in self?.now ?? 0 }, after: { [weak self] delay, work in
                guard let self else { return }
                pending.append((now + delay, work))
            })
        }
        func advance(_ seconds: TimeInterval) {
            now += seconds
            while let index = pending.indices.filter({ pending[$0].at <= now }).min(by: { pending[$0].at < pending[$1].at }) {
                pending.remove(at: index).work()
            }
        }
    }

    private func solid() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    /// ⚠️ #1505 option A: a face that exists is never stood in for by the
    /// initials. Cold, nothing for `skeletonDelay`, then the skeleton — the
    /// initials stay hidden throughout.
    @Test func aColdPictureShowsTheSkeletonNeverTheInitials() {
        let time = ManualClock()
        let avatar = AvatarView(diameter: 40, size: .avatar, clock: time.clock)
        avatar.setMonogram("AL")
        avatar.setPicture(URL(string: "mock://face/cold"), pipeline: makePipeline())
        #expect(avatar.monogram.isHidden, "the initials stood in for a face")
        #expect(avatar.skeleton.isHidden, "a bone for a load that may land at once")
        time.advance(0.15)
        #expect(!avatar.skeleton.isHidden)
        #expect(avatar.ladder.rung == .skeleton)
        #expect(avatar.monogram.isHidden)
        #expect(avatar.shownPicture == nil)
    }

    /// A picture that fails: the initials, and the bone goes.
    @Test func aFailedPictureShowsTheInitials() throws {
        let time = ManualClock()
        let avatar = AvatarView(diameter: 40, size: .avatar, clock: time.clock)
        avatar.setMonogram("AL")
        // No pipeline: the load fails at once.
        avatar.setPicture(try #require(URL(string: "mock://face/broken")), pipeline: nil)
        #expect(!avatar.monogram.isHidden)
        #expect(avatar.monogram.debugMonogramText == "AL")
        time.advance(1)
        #expect(avatar.skeleton.isHidden)
        #expect(avatar.isSettled)
    }

    /// A warm picture lands in the configure pass and covers the initials.
    @Test func aWarmPictureCoversTheInitialsAtOnce() throws {
        let pipeline = makePipeline()
        let url = try #require(URL(string: "mock://face/warm"))
        pipeline.store(solid(), for: url, size: .avatar)
        let avatar = AvatarView(diameter: 40, size: .avatar)
        avatar.setPicture(url, pipeline: pipeline)
        #expect(avatar.shownPicture != nil)
        #expect(avatar.monogram.isCovered)
        #expect(avatar.ladder.transitions.last?.1 == LoadingLadder.Transition.none)
        #expect(avatar.isSettled)
    }

    /// A late picture lands (after the skeleton's minimum, if it showed).
    @Test func aLatePictureLands() async throws {
        let avatar = AvatarView(diameter: 40, size: .avatar)
        avatar.setPicture(try #require(URL(string: "mock://face/late")), pipeline: makePipeline())
        for _ in 0..<200 where avatar.ladder.rung != .content { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(avatar.picture.image != nil)
        #expect(avatar.ladder.rung == .content)
        #expect(avatar.monogram.isHidden || avatar.monogram.isCovered)
    }

    /// ⚠️ A recycled avatar never shows the previous person: a new person cuts
    /// back to the initials, and a late picture for the old one lands nowhere.
    @Test func aRecycledAvatarNeverShowsThePreviousPerson() async throws {
        let pipeline = makePipeline()
        let warm = try #require(URL(string: "mock://face/ada"))
        pipeline.store(solid(), for: warm, size: .avatar)
        let avatar = AvatarView(diameter: 40, size: .avatar)
        avatar.setPicture(warm, pipeline: pipeline)
        #expect(avatar.monogram.isCovered)
        avatar.setPicture(try #require(URL(string: "mock://face/grace")), pipeline: pipeline)
        #expect(avatar.shownPicture == nil, "the previous face stayed")
        #expect(avatar.picture.isHidden, "the previous face stayed")
        avatar.reset()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(avatar.picture.image == nil, "a late face landed on a reset avatar")
    }

    /// No picture: the initials stay, and the avatar is settled.
    @Test func noPictureKeepsTheInitialsAndSettles() {
        let avatar = AvatarView(diameter: 40, size: .avatar)
        avatar.setPicture(nil, pipeline: makePipeline())
        #expect(!avatar.monogram.isHidden && !avatar.monogram.isCovered)
        #expect(avatar.isSettled)
    }

    /// The outline is one: the initials and the picture share it.
    @Test func theShapeIsShared() {
        let avatar = AvatarView(diameter: 40, size: .avatar)
        avatar.shape = .superellipse(exponent: 4)
        #expect(avatar.monogram.shape == .superellipse(exponent: 4))
        #expect(avatar.skeleton.shape == .superellipse(exponent: 4))
        #expect(avatar.picture.shape == .superellipse(exponent: 4))
    }

    /// A smaller decode at hand stands in while the sharp one decodes: the
    /// face shows at once (never the initials), the avatar counts as settled
    /// for a push, and the sharp face replaces it when it lands (the profile
    /// header, #943).
    @Test func aSmallerDecodeStandsInForTheSharpFace() async throws {
        let pipeline = makePipeline()
        let url = try #require(URL(string: "mock://face/header"))
        pipeline.store(solid(), for: url, size: .avatar)
        let avatar = AvatarView(diameter: 96, size: .px512)
        avatar.standInSize = .avatar
        var settledAfterLoad = 0
        avatar.onSettledAfterLoad = { settledAfterLoad += 1 }
        avatar.setPicture(url, pipeline: pipeline)
        #expect(avatar.ladder.rung == .preview)
        #expect(avatar.shownPicture != nil, "the stand-in face shows at once")
        #expect(avatar.monogram.isCovered)
        #expect(avatar.isSettled, "a push does not wait for the sharper face")
        for _ in 0..<200 where avatar.debugIsLoading { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(avatar.ladder.rung == .content)
        #expect(settledAfterLoad == 1)
    }

    /// The frame (#943): from the profile's id, over the face, in its shape,
    /// changing no size; an unknown id draws none.
    @Test func theFrameRidesOverTheFace() {
        let avatar = AvatarView(diameter: 40, size: .avatar)
        let size = avatar.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        #expect(avatar.frameView.isHidden)
        avatar.frameID = "frame.aurora"
        #expect(avatar.frameID == "frame.aurora")
        #expect(!avatar.frameView.isHidden)
        #expect(avatar.frameView.superview === avatar.picture.superview)
        #expect(avatar.frameView.superview?.subviews.last === avatar.frameView, "drawn over the picture")
        #expect(avatar.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize) == size)
        avatar.shape = .roundedTile
        #expect(avatar.frameView.shape == .roundedTile)
        avatar.frameID = "frame.mystery"
        #expect(avatar.frameID == nil)
        #expect(avatar.frameView.isHidden)
    }
}
