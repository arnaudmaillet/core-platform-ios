import CoreModels
import MediaCore
import Testing
import UIKit
@testable import Profile

/// The banner's two shapes — a strip across the top, or a poster the identity
/// sits on — and the rule that picks one: the picture, never a setting.
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
            reactionCount: .exact(1_000),
            viewCount: .exact(12)
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

    /// A band ends a quarter of the way down the avatar: the disc straddles
    /// the strip's edge high, its ring cutting the picture, and the name
    /// below sits clear of it with air above.
    @Test func aBandEndsInTheAvatarsFirstQuarter() {
        let header = header(format: .band)
        let banner = header.debugBannerFrame
        let avatar = header.debugAvatarFrame
        #expect(abs(banner.maxY - (avatar.minY + avatar.height / 4)) < 0.5)
        #expect(banner.minY == 0)
        // The disc's top sits a small gap under the chrome's bottom edge: air,
        // not a strip of picture.
        #expect(abs(avatar.minY - (header.chromeTopInset + 12)) < 0.5)
        #expect(abs(banner.height - (header.chromeTopInset + 12 + avatar.height / 4)) < 0.5)
        // The edge is softened, lightly and only near the edge — not run out.
        let stops = header.debugBannerFadeLocations
        let alphas = header.debugBannerFadeAlphas
        #expect(stops.count == 2)
        #expect(stops[0] * banner.height >= banner.height - ProfileBannerView.bandFadeDepth - 0.5)
        #expect(alphas.last == ProfileBannerView.bandFadeAlpha)
    }

    /// A poster runs to the foot of the tray, and the identity sits on it.
    @Test func aPosterRunsToTheTray() {
        let header = header(format: .poster)
        let banner = header.debugBannerFrame
        let tray = header.debugTrayFrame
        #expect(abs(banner.maxY - tray.maxY) < 0.5)
        // The picture shows through under the whole block — and the very
        // foot is opaque, so the banner meets the page without a seam.
        let alphas = header.debugBannerFadeAlphas
        let stops = header.debugBannerFadeLocations
        let climb = ProfileBannerView.posterClimbSamples
        #expect(alphas.count == climb + 3)
        #expect(alphas[climb + 1] < 1)
        #expect(alphas[climb + 1] > alphas[climb])
        #expect(alphas[climb + 2] == 1)
        #expect(stops[climb + 2] == 1)
        #expect((1 - stops[climb + 1]) * banner.height <= ProfileBannerView.posterFootDepth + 0.5)
    }

    /// The climb to the counters is eased in: gentle at the top, steeper at
    /// the bottom, and between a line and a square — halfway along it, the
    /// tone is about a third of what it will be at the counters.
    @Test func aPostersClimbIsGentleFirstAndSteepLast() {
        let header = header(format: .poster)
        let alphas = header.debugBannerFadeAlphas
        let stops = header.debugBannerFadeLocations
        let climb = ProfileBannerView.posterClimbSamples
        #expect(alphas[0] == 0)
        #expect(abs(alphas[climb] - ProfileBannerView.posterFadeAtCounters) < 0.001)
        // Each step of the climb is steeper than the one before it.
        var previousRise: CGFloat = 0
        for sample in 1...climb {
            let rise = alphas[sample] - alphas[sample - 1]
            #expect(rise > previousRise)
            previousRise = rise
        }
        // The stops are evenly spaced along the climb — the curve is in the
        // opacities, not in where they land.
        let spans = (1...climb).map { stops[$0] - stops[$0 - 1] }
        for span in spans { #expect(abs(span - spans[0]) < 0.001) }
        let halfway = ProfileBannerView.posterFadeAtCounters * pow(0.5, ProfileBannerView.posterClimbExponent)
        #expect(abs(alphas[climb / 2] - halfway) < 0.001)
        #expect(halfway > ProfileBannerView.posterFadeAtCounters / 4)
        #expect(halfway < ProfileBannerView.posterFadeAtCounters / 2)
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

    /// The poster's picture is left alone down past the avatar and the name:
    /// the run-out begins just above the counters and is strong by the bio.
    @Test func aPostersFadeStartsAboveTheCountersAndIsStrongByTheBio() {
        let header = header(format: .poster)
        let banner = header.debugBannerFrame
        let avatar = header.debugAvatarFrame
        let stats = header.debugStatsFrame
        let stops = header.debugBannerFadeLocations
        #expect(stops.count == ProfileBannerView.posterClimbSamples + 3)
        let start = stops[0] * banner.height
        let strong = stops[ProfileBannerView.posterClimbSamples] * banner.height
        #expect(abs(start - (stats.minY - 40)) < 1)
        // The lead reaches into the avatar's lower edge, where the curve is
        // still at nothing; the disc's upper half and the name are clear.
        #expect(start > avatar.midY)
        #expect(abs(strong - (stats.maxY + 12)) < 1)
        #expect(strong < header.debugTrayFrame.minY)
        // Most of the picture is clear: the run-out begins past half.
        #expect(stops[0] > 0.5)
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

    /// On a band the name sits BELOW the strip's edge, on the page — not on
    /// the picture.
    @Test func onABandTheNameSitsOnThePage() throws {
        let header = header(format: .band)
        func labels(_ view: UIView) -> [UILabel] {
            if let label = view as? UILabel { return [label] }
            return view.subviews.flatMap(labels)
        }
        let name = try #require(labels(header).first { $0.text == "Kenji Tanaka" })
        let frame = name.convert(name.bounds, to: header)
        #expect(frame.minY >= header.debugBannerFrame.maxY - 0.5)
        // Just below it — a small gap, not the foot of the disc.
        #expect(abs(frame.minY - header.debugBannerFrame.maxY - 8) < 1)
    }
}
