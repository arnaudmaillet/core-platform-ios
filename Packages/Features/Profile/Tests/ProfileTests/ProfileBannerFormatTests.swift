import CoreModels
import DesignSystem
import MediaCore
import Testing
import UIKit
@testable import Profile

/// The banner's two shapes — a strip across the top, or a tall poster — the
/// rule that picks one (the picture, never a setting), and the identity row
/// both share: the name and the handle on the picture, the counters on the
/// page, the banner ending on the avatar's midline between them.
@MainActor
struct ProfileBannerFormatTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private func header(
        width: CGFloat = 393, format: ProfileBannerFormat, picture: Bool = true
    ) -> ProfileHeaderView {
        let header = ProfileHeaderView(imagePipeline: ImagePipeline(fetcher: SilentFetcher()))
        header.chromeTopInset = 103
        header.configure(with: ProfileDisplayModel(profile: UserProfile(
            id: ProfileID("prof-1"),
            handle: "kenji.dev",
            displayName: "Kenji Tanaka",
            bio: "Building small tools for small teams.",
            avatarURL: picture ? URL(string: "https://kenji.example/avatar.jpg") : nil,
            websiteURL: URL(string: "https://kenji.example"),
            isVerified: false,
            followerCount: .exact(4),
            followingCount: .exact(4),
            reactionCount: .exact(1_000)
        )))
        header.configureAction(.following)
        if picture { header.setBannerFormat(format) }
        header.frame = CGRect(x: 0, y: 0, width: width, height: 1)
        header.frame.size.height = header.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        header.setNeedsLayout()
        header.layoutIfNeeded()
        return header
    }

    /// Wider than tall is a band; portrait — and square, which a strip would
    /// crop the head or the feet off — a poster.
    @Test func thePictureDecidesTheShape() {
        #expect(ProfileBannerFormat.resolved(forImageSize: CGSize(width: 1600, height: 900)) == .band)
        #expect(ProfileBannerFormat.resolved(forImageSize: CGSize(width: 1200, height: 1000)) == .band)
        #expect(ProfileBannerFormat.resolved(forImageSize: CGSize(width: 900, height: 1600)) == .poster)
        #expect(ProfileBannerFormat.resolved(forImageSize: CGSize(width: 800, height: 800)) == .poster)
        #expect(ProfileBannerFormat.resolved(forImageSize: CGSize(width: 1000, height: 950)) == .poster)
        #expect(ProfileBannerFormat.resolved(forImageSize: .zero) == .poster)
    }

    /// Beside the avatar, two halves of its height: the name and the handle
    /// in the top one, the counters in the bottom one — under the name,
    /// leading-aligned with it.
    @Test(arguments: [ProfileBannerFormat.band, .poster, .none])
    func theIdentityRowSplitsTheAvatarsHeightInTwo(format: ProfileBannerFormat) {
        let header = header(format: format, picture: format != .none)
        let avatar = header.debugAvatarFrame
        let names = header.debugNameHalfFrame
        let stats = header.debugStatsHalfFrame
        #expect(abs(avatar.height - 96) < 0.5)
        #expect(abs(names.minY - avatar.minY) < 0.5)
        #expect(abs(names.height - avatar.height / 2) < 0.5)
        #expect(abs(stats.minY - avatar.midY) < 0.5)
        #expect(abs(stats.maxY - avatar.maxY) < 0.5)
        #expect(names.minX > avatar.maxX)
        #expect(abs(stats.minX - names.minX) < 0.5)
        // The name and the handle sit INSIDE their half, the counters inside
        // theirs.
        #expect(header.debugNameFrame.minY >= names.minY - 0.5)
        #expect(header.debugHandleFrame.maxY <= names.maxY + 0.5)
        #expect(header.debugStatsFrame.minY >= stats.minY - 0.5)
        #expect(header.debugStatsFrame.maxY <= stats.maxY + 0.5)
        // Leading-aligned under the name: the first counter starts where the
        // name does.
        #expect(abs(header.debugStatsFrame.minX - header.debugNameFrame.minX) < 0.5)
        // And the bio follows the whole row, under the disc.
        #expect(header.debugTrayFrame.minY > avatar.maxY)
    }

    /// A band ENDS on the avatar's midline: the page's short ramp is centred
    /// there, the banner's own edge half a ramp lower, where the page's tone
    /// is already whole.
    @Test func aBandEndsOnTheAvatarsMidline() throws {
        let header = header(format: .band)
        let banner = header.debugBannerFrame
        let avatar = header.debugAvatarFrame
        #expect(banner.minY == 0)
        #expect(abs(banner.maxY - (avatar.midY + HeroBannerFade.rampLength / 2)) < 0.5)
        let fade = try #require(header.debugBannerFade)
        #expect(abs((fade.rampStart + fade.rampEnd) / 2 - avatar.midY) < 0.5)
        #expect(abs(fade.rampEnd - banner.maxY) < 0.5)
        // Short: a seam, not a run-out.
        #expect(fade.rampEnd - fade.rampStart <= 16)
        // The ramp itself: clear, then the page, opaque at the edge.
        let alphas = header.debugBannerRampAlphas
        #expect(alphas.first == 0)
        #expect(alphas.last == 1)
    }

    /// The blur's container runs from a lead above the name — the poster's
    /// full lead, the band's shorter one (its picture is mostly behind the
    /// chrome) — to the banner's FOOT, where it is whole.
    @Test(arguments: [ProfileBannerFormat.band, .poster])
    func theBlurClimbsFromAboveTheNameToTheFoot(format: ProfileBannerFormat) throws {
        let header = header(format: format)
        let fade = try #require(header.debugBannerFade)
        let name = header.debugNameFrame
        #expect(abs(fade.blurFull - header.debugBannerFrame.maxY) < 0.5)
        let lead: CGFloat = format == .band ? 64 : HeroBannerFade.blurLead
        #expect(abs(name.minY - fade.blurStart - lead) < 0.5)
        // The blur starts above the page's ramp — the long transition is the
        // blur's, the short one the page's.
        #expect(fade.blurStart < fade.rampStart - 40)
        // On a poster the container starts inside the stage, under the
        // chrome — the subject at the stage's top is left sharp, and the
        // ease-in keeps the next stretch nearly so.
        if format == .poster {
            #expect(fade.blurStart > header.chromeTopInset + 40)
        }
    }

    /// A poster runs to the tray's FOOT — not cut at the midline (user, 30
    /// September 2026): the whole identity block stands on the picture, and
    /// the page arrives only behind the tray's buttons.
    @Test func aPosterRunsToTheTraysFoot() throws {
        let header = header(format: .poster)
        let banner = header.debugBannerFrame
        let tray = header.debugTrayFrame
        #expect(abs(banner.maxY - tray.maxY) < 0.5)
        let fade = try #require(header.debugBannerFade)
        #expect(abs(fade.rampEnd - banner.maxY) < 0.5)
        // Behind the buttons (the row carries 12pt of air above them).
        #expect(abs(fade.rampStart - (tray.minY + 12)) < 0.5)
        // The counters and the bio are above it, on the blurred picture.
        #expect(header.debugStatsFrame.maxY < fade.rampStart)
        let alphas = header.debugBannerRampAlphas
        #expect(alphas.first == 0)
        #expect(alphas.last == 1)
    }

    /// On a band the name and the handle stand on the picture — above the
    /// ramp's middle — and the counters on the page, below it.
    @Test func onABandTheNameStandsOnThePictureAndTheCountersOnThePage() throws {
        let header = header(format: .band)
        let fade = try #require(header.debugBannerFade)
        let edge = (fade.rampStart + fade.rampEnd) / 2
        #expect(header.debugHandleFrame.maxY <= edge + 0.5)
        #expect(header.debugStatsFrame.minY >= edge - 0.5)
        #expect(header.debugNameFrame.minY >= header.debugBannerFrame.minY)
    }

    /// On the way up the picture lags the content, and a poster is gone by
    /// the time the avatar's top reaches where a band would hold it.
    @Test func aPosterFadesOutAsTheAvatarReachesTheBandsLine() {
        let header = header(format: .poster)
        let avatarAtRest = header.debugAvatarFrame.minY
        let bandLine = header.chromeTopInset + 12
        let fadeOut = avatarAtRest - bandLine
        #expect(fadeOut > 0)

        header.setTravelled(0)
        #expect(header.debugBannerAlpha == 1)
        #expect(header.debugBannerPictureShift == 0)

        header.setTravelled(fadeOut / 2)
        #expect(abs(header.debugBannerAlpha - 0.5) < 0.01)
        #expect(abs(header.debugBannerPictureShift - fadeOut / 2 * ProfileBannerView.parallaxShare) < 0.5)

        header.setTravelled(fadeOut)
        #expect(header.debugBannerAlpha == 0)
        header.setTravelled(fadeOut * 2)
        #expect(header.debugBannerAlpha == 0)

        // A pull down neither fades nor shifts: the stretch is the banner's.
        header.setTravelled(-60)
        #expect(header.debugBannerAlpha == 1)
        #expect(header.debugBannerPictureShift == 0)
    }

    /// A band keeps its picture whole on the way up — it scrolls off like
    /// the rest of the header — and lags the content the same way.
    @Test func aBandOnlyLags() {
        let header = header(format: .band)
        header.setTravelled(100)
        #expect(header.debugBannerAlpha == 1)
        #expect(abs(header.debugBannerPictureShift - 100 * ProfileBannerView.parallaxShare) < 0.5)
    }

    /// A band is the shorter header, by exactly the poster's clearance: the
    /// band's column starts on the chrome, the poster's a clearance below it.
    @Test func aBandIsShorterThanAPoster() {
        let band = header(format: .band)
        let poster = header(format: .poster)
        #expect(band.bounds.height < poster.bounds.height)
        #expect(abs((poster.bounds.height - band.bounds.height) - (200 - 12)) < 1)
    }

    /// A profile with no picture has no banner at all: the identity block
    /// starts under the chrome, as a band's does, and nothing is drawn above
    /// it.
    @Test func noPictureMeansNoBanner() {
        let header = header(format: .poster, picture: false)
        #expect(header.bannerFormat == .none)
        #expect(header.debugBannerIsHidden)
        #expect(abs(header.debugAvatarFrame.minY - (header.chromeTopInset + 12)) < 0.5)
        // And it is as short as a band.
        #expect(abs(header.bounds.height - self.header(format: .band).bounds.height) < 0.5)
    }

    /// ⚠️ THE TRAY IS FLAT. Glass is for chrome over content; these buttons
    /// sit on the page, and glass there is a blur of nothing. One prominent
    /// filled capsule for Follow, grey capsules and bubbles for the rest.
    @Test func theTrayWearsNoGlass() {
        let header = header(format: .band)
        for button in header.debugTrayButtons {
            #expect(button.configuration?.background.visualEffect == nil)
        }
        header.configureAction(.follow)
        let follow = header.debugTrayButtons[0]
        let message = header.debugTrayButtons[1]
        #expect(follow.configuration?.title == "Follow")
        #expect(follow.configuration?.background.visualEffect == nil)
        // Follow is the one prominent capsule: it does not wear the quiet
        // grey the others do.
        #expect(follow.configuration?.background.backgroundColor != message.configuration?.background.backgroundColor)
    }
}
