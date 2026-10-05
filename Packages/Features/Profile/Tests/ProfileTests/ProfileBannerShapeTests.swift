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
        // A poster's stage settles from the block as laid out: fit again, as
        // the screen does when the header's revision moves.
        header.frame.size.height = header.systemLayoutSizeFitting(
            CGSize(width: 402, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height
        header.layoutIfNeeded()
        header.layoutIfNeeded()
        return header
    }

    private var screenHeight: CGFloat { UIScreen.main.bounds.height }

    @Test func aPosterRunsDownEightyPercentOfTheScreen() {
        let poster = header(picture: CGSize(width: 900, height: 1600))
        #expect(poster.bannerFormat == .poster)
        #expect(abs(poster.debugBannerFrame.maxY - (screenHeight * 0.8).rounded()) < 1,
                "poster foot \(poster.debugBannerFrame.maxY) of \(screenHeight)")
    }

    /// The content starts at 40% of the screen, over the picture — not at
    /// its foot: the identity block stands well inside the banner, and the
    /// banner runs on below the tray, under the first posts.
    @Test func aPostersContentStartsAtFortyPercentOverThePicture() {
        let poster = header(picture: CGSize(width: 900, height: 1600))
        #expect(abs(poster.debugAvatarFrame.minY - (screenHeight * 0.4).rounded()) < 1,
                "content at \(poster.debugAvatarFrame.minY) of \(screenHeight)")
        #expect(poster.debugTrayFrame.maxY < poster.debugBannerFrame.maxY, "the banner stops at the tray")
        // The header — what the pages are inset by — ends with the content,
        // not with the picture.
        #expect(poster.bounds.height < poster.debugBannerFrame.maxY)
    }

    /// Both stay put whatever the block holds: a longer bio pushes the tray
    /// down, not the content's start nor the picture's foot.
    @Test func aLongerBioMovesNeitherTheContentNorThePicture() {
        let short = header(picture: CGSize(width: 900, height: 1600), bio: "Hi.")
        let long = header(
            picture: CGSize(width: 900, height: 1600),
            bio: String(repeating: "Building small tools for small teams. ", count: 4)
        )
        #expect(abs(short.debugBannerFrame.maxY - long.debugBannerFrame.maxY) < 1)
        #expect(abs(short.posterClearance - long.posterClearance) < 0.5)
        #expect(long.debugTrayFrame.maxY > short.debugTrayFrame.maxY)
        // The poster fades out over its stage.
        #expect(abs(short.posterFadeOutTravel - (short.posterClearance - Spacing.md)) < 0.5)
    }

    @Test func aPosterKeepsItsBlurIntoThePage() {
        let poster = header(picture: CGSize(width: 900, height: 1600))
        #expect(poster.debugBannerShowsBlur)
        #expect(poster.debugBannerRampTone == Surface.page)
    }

    @Test func aBandDoesNotBlurAndFadesToBlack() {
        let band = header(picture: CGSize(width: 1600, height: 900))
        #expect(band.bannerFormat == .band)
        #expect(!band.debugBannerShowsBlur, "the band still blurs")
        #expect(band.debugBannerRampTone == .black, "the band's ramp follows the page")
        #expect(band.debugBannerBlurLevels.isEmpty, "blur levels are drawn")
        // Still a band's height: on the avatar's midline, not the poster's 80%.
        #expect(band.debugBannerFrame.maxY < screenHeight * 0.5)
    }
}
