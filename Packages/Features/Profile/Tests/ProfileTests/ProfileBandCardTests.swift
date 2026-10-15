import CoreModels
import DesignSystem
import MediaCore
import Testing
import UIKit
@testable import Profile

/// A profile's landscape banner is a CARD (the owner, 2026-10-15): held off
/// the screen's top and sides, its top held while the page climbs until the
/// avatar reaches the bar, a scroll notch with the avatar under the bar, and
/// a ramp in the picture's own dark tone.
@MainActor
struct ProfileBandCardTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private func header(width: CGFloat = 393) -> ProfileHeaderView {
        let header = ProfileHeaderView(imagePipeline: ImagePipeline(fetcher: SilentFetcher()))
        header.chromeTopInset = 103
        header.configure(with: ProfileDisplayModel(profile: UserProfile(
            id: ProfileID("prof-1"), handle: "kenji.dev", displayName: "Kenji Tanaka",
            bio: "Building small tools.", avatarURL: URL(string: "https://kenji.example/avatar.jpg"),
            websiteURL: nil, isVerified: false,
            followerCount: .exact(4), followingCount: .exact(4), reactionCount: .exact(1_000)
        )))
        header.configureAction(.following)
        header.setBannerFormat(.band)
        header.frame = CGRect(x: 0, y: 0, width: width, height: 1)
        header.frame.size.height = header.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height
        header.setNeedsLayout()
        header.layoutIfNeeded()
        return header
    }

    /// The same margin on the top and the sides.
    @Test func theCardIsHeldOffTheTopAndTheSides() {
        let header = header()
        let banner = header.debugBannerFrame
        #expect(banner.minY == 12)
        #expect(banner.minX == 12)
        #expect(abs(header.bounds.width - banner.maxX - 12) < 0.5)
    }

    /// As the page climbs, the card's top stays where it was on screen — its
    /// foot rides up — until the avatar's top reaches the bar; then it goes
    /// with the page.
    @Test func theCardHoldsItsTopUntilTheAvatarReachesTheBar() throws {
        let header = header()
        let hold = header.debugAvatarFrame.minY - header.chromeTopInset
        try #require(hold > 40)
        let foot = header.debugBannerFrame.maxY
        for travelled in [CGFloat(10), 30, hold - 5] {
            header.setTravelled(travelled)
            header.layoutIfNeeded()
            let banner = header.debugBannerFrame
            // In the header's space, which climbs by `travelled` on screen.
            #expect(abs(banner.minY - (12 + travelled)) < 0.5, "travelled \(travelled)")
            #expect(abs(banner.maxY - foot) < 0.5, "the foot moved at \(travelled)")
        }
        header.setTravelled(hold + 40)
        header.layoutIfNeeded()
        #expect(abs(header.debugBannerFrame.minY - (12 + hold)) < 0.5, "the card kept holding past the bar")
    }

    /// The notch: the avatar's top `bandAvatarDetentGap` under the bar.
    @Test func theNotchLeavesTheAvatarUnderTheBar() throws {
        let header = header()
        let notch = try #require(header.bandAvatarDetent)
        #expect(abs(header.debugAvatarFrame.minY - notch - header.chromeTopInset - 40) < 0.5)
    }

    /// A catching detent stops a release that crosses it, however hard; one
    /// that started past it is left to the others.
    @Test func aReleaseCrossingTheNotchStopsOnIt() {
        let detents: [CGFloat] = [0, 128, 411]
        #expect(ProfileScrollDetents.snapped(target: 326, detents: detents, from: 80, catching: [128]) == 128)
        #expect(ProfileScrollDetents.snapped(target: 20, detents: detents, from: 300, catching: [128]) == 128)
        #expect(ProfileScrollDetents.snapped(target: 326, detents: detents, from: 170, catching: [128]) == 411)
        #expect(ProfileScrollDetents.snapped(target: 326, detents: detents) == 411)
    }

    /// The ramp's tone: the picture's prominent dark shade, its hue kept,
    /// capped as dark as black under the type; a light picture gives its
    /// shade, darkened.
    @Test func theRampWearsThePicturesDarkTone() throws {
        func picture(_ colours: [(UIColor, CGFloat)]) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { context in
                var y: CGFloat = 0
                for (colour, share) in colours {
                    colour.setFill()
                    context.fill(CGRect(x: 0, y: y, width: 100, height: 100 * share))
                    y += 100 * share
                }
            }
        }
        let navy = UIColor(red: 0.05, green: 0.08, blue: 0.30, alpha: 1)
        let tone = try #require(ProfileBannerView.prominentDarkTone(of: picture([(.white, 0.4), (navy, 0.6)])))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        tone.getRed(&r, green: &g, blue: &b, alpha: &a)
        #expect(b > r && b > g, "the navy's hue is gone: \(tone)")
        #expect(ProfileBannerView.luminance(of: tone) <= ProfileBannerView.maxToneLuminance + 0.0005)

        let light = try #require(ProfileBannerView.prominentDarkTone(of: picture([(.white, 1)])))
        #expect(ProfileBannerView.luminance(of: light) <= ProfileBannerView.maxToneLuminance + 0.0005)
    }
}
