import CoreModels
import DesignSystem
import MediaCore
import Testing
import UIKit
@testable import Profile

/// The name and the handle over a poster's picture: white over an ink scrim,
/// legible over ANY picture — measured on the rendered pixels behind the type,
/// not on the scrim's numbers.
///
/// ⚠️ The pictures are the extremes on purpose. White type's worst case is a
/// pure white picture and a white stripe right behind a glyph; a pure black
/// one pins that the scrim never drags the dark page's type down with it. A
/// real photograph sits between them.
@MainActor
@Suite("Profile identity ink")
struct ProfileIdentityInkTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    enum Picture: String, CaseIterable, CustomTestStringConvertible {
        case white, black, stripes, grey

        var testDescription: String { rawValue }

        /// Portrait unless asked otherwise, so the header resolves a poster.
        func image(size: CGSize = CGSize(width: 90, height: 160)) -> UIImage {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return UIGraphicsImageRenderer(size: size, format: format).image { context in
                switch self {
                case .white: UIColor.white.setFill()
                case .black: UIColor.black.setFill()
                case .grey: UIColor(white: 0.5, alpha: 1).setFill()
                case .stripes: UIColor.black.setFill()
                }
                context.fill(CGRect(origin: .zero, size: size))
                if self == .stripes {
                    // A busy picture: hard white/black edges every 2px.
                    UIColor.white.setFill()
                    for x in stride(from: 0, to: size.width, by: 4) {
                        context.fill(CGRect(x: x, y: 0, width: 2, height: size.height))
                    }
                }
            }
        }
    }

    private static let pictureURL = URL(string: "https://kenji.example/avatar.jpg")!

    private func header(
        picture: UIImage?, style: UIUserInterfaceStyle = .light, width: CGFloat = 402
    ) -> ProfileHeaderView {
        let pipeline = ImagePipeline(fetcher: SilentFetcher())
        // Cached, so the picture lands synchronously in `configure` and the
        // shape is read off it before the first layout.
        if let picture { pipeline.store(picture, for: Self.pictureURL) }
        let header = ProfileHeaderView(imagePipeline: pipeline)
        header.overrideUserInterfaceStyle = style
        header.chromeTopInset = 116
        header.configure(with: ProfileDisplayModel(profile: UserProfile(
            id: ProfileID("prof-1"),
            handle: "kenji.dev",
            displayName: "Kenji Tanaka",
            bio: "Building small tools for small teams.",
            avatarURL: picture == nil ? nil : Self.pictureURL,
            websiteURL: URL(string: "https://kenji.example"),
            isVerified: false,
            followerCount: .exact(4),
            followingCount: .exact(4),
            reactionCount: .exact(1_000)
        )))
        header.configureAction(.following)
        header.frame = CGRect(x: 0, y: 0, width: width, height: 1)
        header.frame.size.height = header.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        header.setNeedsLayout()
        header.layoutIfNeeded()
        // The banner places its scrim from the frames the header hands it in
        // this pass; one more lays the layers out against them.
        header.layoutIfNeeded()
        return header
    }

    /// WCAG AA for the handle's 15pt text — the stricter of the two lines —
    /// over every extreme a picture can be, in both appearances.
    @Test(arguments: Picture.allCases, [UIUserInterfaceStyle.light, .dark])
    func theTypeClearsAAOverAnyPoster(picture: Picture, style: UIUserInterfaceStyle) throws {
        let header = header(picture: picture.image(), style: style)
        #expect(header.bannerFormat == .poster)
        #expect(header.debugBannerHasPicture)
        let contrast = try #require(header.debugIdentityContrast())
        #expect(contrast.handle.min >= 4.5, "handle \(contrast.handle)")
        #expect(contrast.name.min >= 4.5, "name \(contrast.name)")
    }

    /// The instrument can see a failure: halfway through the poster's fade on
    /// the way up, the ink is half-way to the page's over a half-faded
    /// picture — a transient mid-grey on mid-grey, gone within a flick. If
    /// this ever reads AA, the measurement has stopped measuring.
    @Test func theInstrumentSeesAFailure() throws {
        let header = header(picture: Picture.white.image(), style: .light)
        header.setTravelled(header.posterFadeOutTravel / 2)
        let contrast = try #require(header.debugIdentityContrast())
        #expect(contrast.handle.min < 4.5, "handle \(contrast.handle)")
    }

    /// Only a poster puts type on the picture. A band's name sits on the page
    /// under the strip, and a header with no picture is all page: both keep
    /// exactly the dynamic colours they always had, and no scrim is drawn.
    @Test func aBandAndNoPictureKeepThePagesInk() {
        let band = header(picture: Picture.white.image(size: CGSize(width: 160, height: 90)))
        #expect(band.bannerFormat == .band)
        let bare = header(picture: nil)
        #expect(bare.bannerFormat == .none)
        for header in [band, bare] {
            #expect(header.debugNameInk == ProfileHeaderView.pageNameInk)
            #expect(header.debugHandleInk == ProfileHeaderView.pageHandleInk)
            #expect(header.debugNameShadowOpacity == 0)
            #expect(!header.debugShowsInkScrim)
        }
        let poster = header(picture: Picture.white.image())
        #expect(poster.debugNameInk == HeroInk.primary)
        #expect(poster.debugHandleInk == HeroInk.secondary)
        #expect(poster.debugNameShadowOpacity > 0)
        #expect(poster.debugShowsInkScrim)
    }

    /// The poster fades as it scrolls up, scrim and all; white type left over
    /// a light page would vanish, so the ink follows the banner back to the
    /// page's.
    @Test func theInkFollowsThePosterAway() throws {
        let header = header(picture: Picture.white.image(), style: .light)
        header.setTravelled(header.posterFadeOutTravel / 2)
        var red: CGFloat = 0
        header.debugNameInk.resolvedColor(with: header.traitCollection)
            .getRed(&red, green: nil, blue: nil, alpha: nil)
        // Halfway between white and the light page's black label.
        #expect(abs(red - 0.5) < 0.02)
        header.setTravelled(header.posterFadeOutTravel)
        #expect(header.debugNameInk == ProfileHeaderView.pageNameInk)
        #expect(header.debugNameShadowOpacity == 0)
        header.setTravelled(0)
        #expect(header.debugNameInk == HeroInk.primary)
    }

    /// The scrim is at its peak under the whole of the type. Below it, under a
    /// dark page it holds to the foot — the run-out is the same tone — and
    /// under a light one it has given way by the counters, so they, the bio
    /// and the tray are not greyed.
    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func theScrimPeaksUnderTheTypeAndEndsByThePage(style: UIUserInterfaceStyle) throws {
        let header = header(picture: Picture.grey.image(), style: style)
        // ⚠️ IN A WINDOW, for this one: where the scrim ends is read off the
        // SCRIM's own traits, and a view tree with no window never hands an
        // override down to a subview that deep — the dark case read a light
        // page. Local, never stored on the suite (a suite-held window dies at
        // release). Hidden: nothing here needs to be on screen.
        let window = UIWindow(frame: header.frame)
        window.overrideUserInterfaceStyle = style
        window.addSubview(header)
        defer { header.removeFromSuperview() }
        header.setNeedsLayout()
        header.layoutIfNeeded()
        header.layoutIfNeeded()
        let banner = header.debugBannerFrame
        let locations = header.debugInkScrimLocations
        let alphas = header.debugInkScrimAlphas
        try #require(locations.count == alphas.count && !locations.isEmpty)
        func alpha(at y: CGFloat) -> CGFloat {
            let f = y / banner.height
            guard let upper = locations.firstIndex(where: { $0 >= f }) else { return alphas.last! }
            guard upper > 0 else { return alphas[0] }
            let lower = upper - 1
            let span = locations[upper] - locations[lower]
            guard span > 0 else { return alphas[upper] }
            let t = (f - locations[lower]) / span
            return alphas[lower] + (alphas[upper] - alphas[lower]) * t
        }
        let peak = HeroInk.scrimPeak
        #expect(alphas.first == 0)
        #expect(abs(alpha(at: header.debugNameFrame.minY) - peak) < 0.001)
        #expect(abs(alpha(at: header.debugHandleFrame.maxY) - peak) < 0.001)
        // The upper half of the picture's stage is untouched: the climb
        // begins a lead above the name, low in the stage.
        #expect(alpha(at: header.chromeTopInset + HeroBannerMetrics.posterStage / 2) == 0)
        #expect(alpha(at: header.debugNameFrame.minY - HeroInk.scrimPad - HeroInk.scrimLead) < 0.001)
        let counters = header.debugStatsFrame
        if style == .dark {
            #expect(alphas.last == peak)
        } else {
            #expect(alpha(at: counters.minY) < 0.001)
            #expect(alphas.last == 0)
        }
    }
}
