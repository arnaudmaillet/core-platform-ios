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

    private func header(width: CGFloat = 393, format: ProfileBannerFormat) -> ProfileHeaderView {
        let header = ProfileHeaderView(imagePipeline: ImagePipeline(fetcher: SilentFetcher()))
        header.chromeTopInset = 103
        header.configure(with: ProfileDisplayModel(profile: UserProfile(
            id: ProfileID("prof-1"),
            handle: "kenji.dev",
            displayName: "Kenji Tanaka",
            bio: "Building small tools for small teams.",
            avatarURL: nil,
            websiteURL: URL(string: "https://kenji.example"),
            isVerified: false,
            followerCount: .exact(4),
            followingCount: .exact(4),
            reactionCount: .exact(1_000),
            viewCount: .exact(12)
        )))
        header.configureAction(.following)
        header.setBannerFormat(format)
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

    /// A band ends on the avatar's midline: the disc straddles the strip's
    /// edge, its ring cutting the picture.
    @Test func aBandEndsOnTheAvatarsMidline() {
        let header = header(format: .band)
        let banner = header.debugBannerFrame
        let avatar = header.debugAvatarFrame
        #expect(abs(banner.maxY - avatar.midY) < 0.5)
        #expect(banner.minY == 0)
        // And the picture carries no run-out: a clean edge.
        #expect(!header.debugBannerShowsFade)
    }

    /// A poster runs to the foot of the tray, and the identity sits on it.
    @Test func aPosterRunsToTheTray() {
        let header = header(format: .poster)
        let banner = header.debugBannerFrame
        let tray = header.debugTrayFrame
        #expect(abs(banner.maxY - tray.maxY) < 0.5)
        #expect(header.debugBannerShowsFade)
    }

    /// The poster's picture is left alone above the avatar and the fade is
    /// opaque by the counters — the name row alone sits on the run-out.
    @Test func aPostersFadeStartsAboveTheAvatarAndIsOpaqueByTheCounters() {
        let header = header(format: .poster)
        let banner = header.debugBannerFrame
        let avatar = header.debugAvatarFrame
        let stops = header.debugBannerFadeLocations
        #expect(stops.count == 4)
        let start = stops[0] * banner.height
        let opaque = stops[2] * banner.height
        #expect(abs(start - (avatar.minY - 40)) < 1)
        #expect(opaque > avatar.maxY)
        #expect(opaque < header.debugTrayFrame.minY)
        // Most of the picture is clear: the run-out begins past two fifths.
        #expect(stops[0] > 0.4)
    }

    /// A band is the shorter header, by the difference in clearance plus the
    /// half-avatar the disc climbs back up the strip.
    @Test func aBandIsShorterThanAPoster() {
        let band = header(format: .band)
        let poster = header(format: .poster)
        #expect(band.bounds.height < poster.bounds.height)
        #expect(abs((poster.bounds.height - band.bounds.height) - (60 + 48)) < 1)
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
    }
}
