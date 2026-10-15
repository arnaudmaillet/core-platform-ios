import CoreModels
import DesignSystem
import MediaCore
import Testing
import UIKit
@testable import Profile

/// The two banner shapes as redesigned on 5 October 2026:
/// - a POSTER (a cover, the vertical shape) runs down 80% of the screen, and
///   its content — the identity block, then the posts — starts at 40%, over
///   the picture's lower part: the two dissociated;
/// - a BAND (the horizontal shape) does not blur, and its opacity ramp lands
///   on black, fixed, rather than on the page's tone.
@MainActor
struct ProfileBannerShapeTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private static let pictureURL = URL(string: "https://kenji.example/avatar.jpg")!
    private final class WindowHosts { var windows: [UIWindow] = [] }
    private let hosts = WindowHosts()

    private func header(picture size: CGSize, bio: String = "Building small tools for small teams.") -> ProfileHeaderView {
        let pipeline = ImagePipeline(fetcher: SilentFetcher())
        let picture = UIGraphicsImageRenderer(size: size).image { context in
            UIColor(white: 0.5, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        // Cached: the shape is read off the picture before the first layout.
        pipeline.store(picture, for: Self.pictureURL)
        let header = ProfileHeaderView(imagePipeline: pipeline)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 2000))
        window.addSubview(header)
        hosts.windows.append(window)
        header.chromeTopInset = 116
        header.configure(with: ProfileDisplayModel(profile: UserProfile(
            id: ProfileID("prof-1"), handle: "kenji.dev", displayName: "Kenji Tanaka", bio: bio,
            avatarURL: Self.pictureURL, websiteURL: URL(string: "https://kenji.example"), isVerified: false,
            followerCount: .exact(4), followingCount: .exact(4), reactionCount: .exact(1_000)
        )))
        header.configureAction(.following)
        header.frame = CGRect(x: 0, y: 0, width: 402, height: 1)
        header.frame.size.height = header.systemLayoutSizeFitting(
            CGSize(width: 402, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height
        header.layoutIfNeeded()
        // Fit again, as the screen does when the header's revision moves.
        header.frame.size.height = header.systemLayoutSizeFitting(
            CGSize(width: 402, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height
        header.layoutIfNeeded()
        header.layoutIfNeeded()
        return header
    }

    private var screenHeight: CGFloat { UIScreen.main.bounds.height }

    /// ⚠️ A PORTRAIT PICTURE IS A BAND TOO (the owner, 2026-10-15: no
    /// poster any more): cropped to the card, which ends near 35% of the
    /// screen, its foot unmoved by a longer bio.
    @Test func aPortraitPictureIsABand() {
        let short = header(picture: CGSize(width: 900, height: 1600), bio: "Hi.")
        let long = header(
            picture: CGSize(width: 900, height: 1600),
            bio: String(repeating: "Building small tools for small teams. ", count: 4)
        )
        #expect(short.bannerFormat == .band)
        #expect(short.debugBannerFrame.maxY < screenHeight * 0.5)
        #expect(abs(short.debugBannerFrame.maxY - long.debugBannerFrame.maxY) < 1)
        #expect(long.debugTrayFrame.maxY > short.debugTrayFrame.maxY)
    }

    /// A band's ramp lands on the picture's own dark tone (the owner,
    /// 2026-10-15), capped as dark as black under the type.
    @Test func aBandDoesNotBlurAndFadesToItsDarkTone() {
        let band = header(picture: CGSize(width: 1600, height: 900))
        #expect(band.bannerFormat == .band)
        #expect(!band.debugBannerShowsBlur, "the band still blurs")
        #expect(band.debugBannerShowsRamp, "a band lost its fade")
        #expect(ProfileBannerView.luminance(of: band.debugBannerRampTone) <= ProfileBannerView.maxToneLuminance + 0.0005,
                "the band's ramp is lighter than its cap")
        #expect(band.debugBannerBlurLevels.isEmpty, "blur levels are drawn")
        // A card's height: above the counters, near 35% of the screen.
        #expect(band.debugBannerFrame.maxY < screenHeight * 0.5)
    }
}
