import DesignSystem
import Testing
import UIKit
@testable import MediaCore

/// The shared avatar (#943): initials first, the picture over them.
@MainActor
struct AvatarViewTests {
    private func makePipeline() -> ImagePipeline { ImagePipeline(fetcher: PlaceholderImageFetcher()) }

    private func solid() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    /// The initials are the rendered state: shown at once, never hidden by
    /// a load.
    @Test func theInitialsShowAtOnce() {
        let avatar = AvatarView(diameter: 40, size: .avatar)
        avatar.setMonogram("AL")
        avatar.setPicture(URL(string: "mock://face/cold"), pipeline: makePipeline())
        #expect(!avatar.monogram.isHidden)
        #expect(avatar.monogram.debugMonogramText == "AL")
        #expect(!avatar.monogram.isCovered)
        #expect(avatar.shownPicture == nil)
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

    /// A late picture lands and covers the initials.
    @Test func aLatePictureLandsOverTheInitials() async throws {
        let avatar = AvatarView(diameter: 40, size: .avatar)
        avatar.setPicture(try #require(URL(string: "mock://face/late")), pipeline: makePipeline())
        for _ in 0..<200 where avatar.debugIsLoading { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(avatar.picture.image != nil)
        #expect(avatar.ladder.rung == .content)
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
        #expect(!avatar.monogram.isCovered)
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
