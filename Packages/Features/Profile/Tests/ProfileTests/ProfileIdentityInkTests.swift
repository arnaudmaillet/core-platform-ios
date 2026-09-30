import CoreModels
import DesignSystem
import MediaCore
import Testing
import UIKit
@testable import Profile

/// The type over a banner's picture — the name and the handle, and on a
/// poster the counters and the bio — in the picture's ink (white on a dark
/// picture, black on a light one, read off the blurred picture behind each
/// block), over the picture's progressively blurred foot (`HeroBannerFade`):
/// measured on the rendered pixels behind the type, not on the numbers.
///
/// ⚠️ The pictures are the extremes on purpose — white, black, hard 2px
/// stripes and a mid grey (luminance 0.21, near where the two inks cross) —
/// and every line clears AA over each, in both appearances, with no scrim.
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
        // The banner places its fade from the frames the header hands it in
        // this pass; one more lays the blur and the ramp out against them.
        header.layoutIfNeeded()
        return header
    }

    /// WCAG AA for every line on the picture — the handle's 15pt the
    /// stricter — over any picture, on a poster and on a band, in both
    /// appearances.
    @Test(arguments: Picture.allCases, [UIUserInterfaceStyle.light, .dark])
    func theTypeClearsAAOverAnyPicture(picture: Picture, style: UIUserInterfaceStyle) throws {
        for band in [false, true] {
            let size = band ? CGSize(width: 160, height: 90) : CGSize(width: 90, height: 160)
            let header = header(picture: picture.image(size: size), style: style)
            #expect(header.bannerFormat == (band ? .band : .poster))
            #expect(header.debugBannerHasPicture)
            let contrast = try #require(header.debugIdentityContrast())
            let shape = band ? "band" : "poster"
            #expect(contrast.handle.min >= 4.5, "\(shape) handle \(contrast.handle) \(header.debugInkTones)")
            #expect(contrast.name.min >= 4.5, "\(shape) name \(contrast.name)")
            // On a poster the counters and the bio stand on the picture too.
            // (On a band they are page ink on the page, whose secondary
            // caption is the system's own 3.3:1 in light mode — not this
            // suite's.)
            if !band {
                let body = try #require(header.debugBodyContrast())
                for (label, measured) in body {
                    #expect(measured.min >= 4.5, "poster \(label) \(measured) \(header.debugInkTones)")
                }
            }
        }
    }

    /// The picture picks the ink: black over a light picture, white over a
    /// dark one — per block, the same in both appearances.
    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func thePicturePicksTheInk(style: UIUserInterfaceStyle) {
        let light = header(picture: Picture.white.image(), style: style)
        #expect(light.debugInkTones.name == .dark)
        #expect(light.debugInkTones.counters == .dark)
        #expect(light.debugInkTones.body == .dark)
        #expect(light.debugNameInk == HeroInk.Tone.dark.primary)
        let dark = header(picture: Picture.black.image(), style: style)
        #expect(dark.debugInkTones.name == .light)
        #expect(dark.debugNameInk == HeroInk.Tone.light.primary)
    }

    /// The blur's job: under the type, a busy picture is ONE tone. Over hard
    /// 2px stripes the worst pixel behind the name sits right by the typical
    /// one — the stripes that made the worst pixel a white stripe are gone.
    @Test func theBlurCalmsABusyPictureUnderTheType() throws {
        let header = header(picture: Picture.stripes.image(), style: .light)
        let contrast = try #require(header.debugIdentityContrast())
        #expect(contrast.name.min >= 4.5, "name \(contrast.name)")
        // Not one flat tone any more: the blur keeps climbing under the name
        // (to the banner's foot), so the name's top rows keep a trace.
        #expect(contrast.name.median - contrast.name.min < 0.5, "name \(contrast.name)")
        #expect(contrast.handle.median - contrast.handle.min < 0.3, "handle \(contrast.handle)")
    }

    /// The instrument can see a failure: halfway through the poster's fade on
    /// the way up, the ink is half-way to the page's over a half-faded
    /// picture — a transient mid-grey on mid-grey, gone within a flick. If
    /// this ever reads AA, the measurement has stopped measuring.
    @Test func theInstrumentSeesAFailure() throws {
        // White ink over a black picture, fading towards the light page's
        // black label over the light page: grey on grey half-way.
        let header = header(picture: Picture.black.image(), style: .light)
        header.setTravelled(header.posterFadeOutTravel / 2)
        let contrast = try #require(header.debugIdentityContrast())
        #expect(contrast.handle.min < 4.5, "handle \(contrast.handle)")
    }

    /// The name stands on the picture on a band too now (it used to sit on
    /// the page below the strip), so both shapes wear the picture's ink; only
    /// a header with no picture keeps the page's.
    @Test func everyBannerWearsThePicturesInkAndNoPictureThePages() {
        let band = header(picture: Picture.white.image(size: CGSize(width: 160, height: 90)))
        #expect(band.bannerFormat == .band)
        let poster = header(picture: Picture.white.image())
        #expect(poster.bannerFormat == .poster)
        for header in [band, poster] {
            #expect(header.debugNameInk == HeroInk.Tone.dark.primary)
            #expect(header.debugHandleInk == HeroInk.Tone.dark.secondary)
            #expect(header.debugNameShadowOpacity > 0)
        }
        let bare = header(picture: nil)
        #expect(bare.bannerFormat == .none)
        #expect(bare.debugNameInk == ProfileHeaderView.pageNameInk)
        #expect(bare.debugHandleInk == ProfileHeaderView.pageHandleInk)
        #expect(bare.debugNameShadowOpacity == 0)
    }

    /// The poster fades as it scrolls up; white type left over a light page
    /// would vanish, so the ink follows the banner back to the page's.
    @Test func theInkFollowsThePosterAway() throws {
        // A dark picture's white ink, going back to the light page's black.
        let header = header(picture: Picture.black.image(), style: .light)
        header.setTravelled(header.posterFadeOutTravel / 2)
        var red: CGFloat = 0
        header.debugNameInk.resolvedColor(with: header.traitCollection)
            .getRed(&red, green: nil, blue: nil, alpha: nil)
        // Halfway between white and the light page's black label.
        #expect(abs(red - 0.5) < 0.02, "red \(red)")
        header.setTravelled(header.posterFadeOutTravel)
        #expect(header.debugNameInk == ProfileHeaderView.pageNameInk)
        #expect(header.debugNameShadowOpacity == 0)
        header.setTravelled(0)
        #expect(header.debugNameInk == HeroInk.Tone.light.primary)
    }

    /// The blur's levels are all showing once the picture is in, each fading
    /// in below the one before, the strongest whole by the name's top; the
    /// page's ramp is clear under the name and whole at the banner's foot.
    @Test(arguments: [false, true])
    func theBlurClimbsToTheNameAndThePageArrivesBelowIt(band: Bool) throws {
        let size = band ? CGSize(width: 160, height: 90) : CGSize(width: 90, height: 160)
        let header = header(picture: Picture.grey.image(size: size))
        let levels = header.debugBannerBlurLevels
        try #require(levels.count == HeroBannerFade.blurSigmas.count)
        let name = header.debugNameFrame
        let fade = try #require(header.debugBannerFade)
        #expect(abs(levels[0].start - fade.blurStart) < 1)
        for (lower, upper) in zip(levels, levels.dropFirst()) {
            #expect(upper.start >= lower.start)
            #expect(upper.full > lower.full)
            // Neighbours hand over: the next starts where this one is whole.
            #expect(abs(upper.start - lower.full) < 1)
        }
        // Whole only at the banner's foot: the blur keeps climbing under
        // the type.
        #expect(abs(levels[levels.count - 1].full - header.debugBannerFrame.maxY) < 1)
        #expect(levels[levels.count - 1].start > name.minY)

        let banner = header.debugBannerFrame
        let locations = header.debugBannerRampLocations
        let alphas = header.debugBannerRampAlphas
        try #require(locations.count == alphas.count && !locations.isEmpty)
        func alpha(at y: CGFloat) -> CGFloat {
            let f = (y - banner.minY) / banner.height
            guard let upper = locations.firstIndex(where: { $0 >= f }) else { return alphas.last! }
            guard upper > 0 else { return alphas[0] }
            let span = locations[upper] - locations[upper - 1]
            guard span > 0 else { return alphas[upper] }
            let t = (f - locations[upper - 1]) / span
            return alphas[upper - 1] + (alphas[upper] - alphas[upper - 1]) * t
        }
        #expect(alpha(at: name.maxY) == 0)
        #expect(alpha(at: header.debugHandleFrame.midY) < 0.001)
        #expect(alpha(at: banner.maxY) > 0.99)
    }

    /// The bake is a few milliseconds, once per picture — not per frame.
    @Test func theBlurIsBakedOnce() throws {
        let header = header(picture: Picture.grey.image())
        let first = header.debugBlurBakeMilliseconds
        #expect(first > 0)
        #expect(header.debugBlurBakeBytes > 0)
        print("HERO-BLUR test bake \(first)ms, \(header.debugBlurBakeBytes / 1024) KB")
        // A scroll moves the picture, the masks stay put, nothing re-bakes.
        header.setTravelled(40)
        header.setNeedsLayout()
        header.layoutIfNeeded()
        #expect(header.debugBlurBakeMilliseconds == first)
    }
}
