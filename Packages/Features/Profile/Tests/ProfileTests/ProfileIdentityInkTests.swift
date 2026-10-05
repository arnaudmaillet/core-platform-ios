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

    /// Keeps each test's hidden windows alive while it measures.
    private final class WindowHosts { var windows: [UIWindow] = [] }
    private let hosts = WindowHosts()

    private func header(
        picture: UIImage?, style: UIUserInterfaceStyle = .light, width: CGFloat = 402
    ) -> ProfileHeaderView {
        let pipeline = ImagePipeline(fetcher: SilentFetcher())
        // Cached, so the picture lands synchronously in `configure` and the
        // shape is read off it before the first layout.
        if let picture { pipeline.store(picture, for: Self.pictureURL) }
        let header = ProfileHeaderView(imagePipeline: pipeline)
        // ⚠️ IN A HIDDEN WINDOW OF THE STYLE, not an override on a loose
        // view: off a window the test host reports the simulator's own
        // appearance whatever the override says, so a ".dark" case drew
        // and read the light page (see `UIView.isInVisibleWindow`). Hidden,
        // the header still does its work in place — the bake, the ink.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 2000))
        window.overrideUserInterfaceStyle = style
        window.addSubview(header)
        hosts.windows.append(window)
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
    ///
    /// ⚠️ TWO KNOWN ISSUES, BOTH ON A BAND, whose name half stands on the
    /// picture with the blur nil (it starts just above the avatar) and only
    /// a thin page tone (a band's ramp starts at the handle): over hard 2px
    /// stripes no single ink holds (name 1.02, handle 1.12 worst; median
    /// 5.2–5.4 — the handle was 4.49 until the band's blur climbed the
    /// ladder of levels, gentle enough now to leave the stripes under it;
    /// a photograph's band measures ≥ 7:1, `-profile-ink-audit` on prof-0),
    /// and on the crossover grey in the dark the page arriving under the
    /// handle's foot takes it to 4.49. A poster clears everywhere: half
    /// the page's tone under its type (the shoulder) closes the spread.
    @Test(arguments: Picture.allCases, [UIUserInterfaceStyle.light, .dark])
    func theTypeClearsAAOverAnyPicture(picture: Picture, style: UIUserInterfaceStyle) throws {
        for band in [false, true] {
            let size = band ? CGSize(width: 160, height: 90) : CGSize(width: 90, height: 160)
            let header = header(picture: picture.image(size: size), style: style)
            #expect(header.bannerFormat == (band ? .band : .poster))
            #expect(header.debugBannerHasPicture)
            let contrast = try #require(header.debugIdentityContrast())
            let shape = band ? "band" : "poster"
            let identity = {
                #expect(contrast.handle.min >= 4.5, "\(shape) handle \(contrast.handle) \(header.debugInkTones)")
                #expect(contrast.name.min >= 4.5, "\(shape) name \(contrast.name)")
            }
            // No exception any more: a band's black ramp (5 October 2026) is
            // shouldered, half there under the name, and closes even hard
            // stripes and the crossover grey that its blur used to leave.
            identity()
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

    /// A BAND's ramp is black (5 October 2026), half there under the name:
    /// white ink over a light picture as over a dark one, in both
    /// appearances. On a POSTER half the PAGE's tone is under the name (the
    /// shoulder): a picture of the page's own side stays there, and one of
    /// the other side is pulled to the middle, where the ink is the one that
    /// holds best there.
    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func thePicturePicksTheInk(style: UIUserInterfaceStyle) {
        let bandSize = CGSize(width: 160, height: 90)
        let light = header(picture: Picture.white.image(size: bandSize), style: style)
        #expect(light.bannerFormat == .band)
        #expect(light.debugInkTones.name == .light)
        #expect(light.debugNameInk == HeroInk.Tone.light.primary)
        let dark = header(picture: Picture.black.image(size: bandSize), style: style)
        #expect(dark.debugInkTones.name == .light)
        #expect(dark.debugNameInk == HeroInk.Tone.light.primary)
        // A poster whose picture is the page's own side keeps the page's ink.
        let ownSide = header(picture: (style == .dark ? Picture.black : .white).image(), style: style)
        #expect(ownSide.bannerFormat == .poster)
        #expect(ownSide.debugInkTones.name == (style == .dark ? .light : .dark))
    }

    /// The blur's shape, read off a busy picture: next to nothing under the
    /// name — the stripes still show behind it, worst pixel far from the
    /// typical one — and calm by a poster's bio, half way down, where the
    /// stripes are gone and the bio clears AA.
    @Test func theBlurIsNilUnderTheNameAndCalmsTheBio() throws {
        let header = header(picture: Picture.stripes.image(), style: .light)
        let contrast = try #require(header.debugIdentityContrast())
        #expect(contrast.name.median - contrast.name.min > 1, "name \(contrast.name)")
        let body = try #require(header.debugBodyContrast())
        let bio = try #require(body.first { $0.0 == "bio" })
        #expect(bio.1.min >= 4.5, "bio \(bio.1)")
    }

    /// The instrument can see a failure: the WRONG ink on a name. If this
    /// ever reads AA, the measurement has stopped measuring.
    ///
    /// ⚠️ FORCED, because nothing fails on its own any more: a poster's
    /// shoulder and a band's black one (5 October 2026) put half a tone under
    /// every name, and the ink picked over it holds over any picture.
    @Test func theInstrumentSeesAFailure() throws {
        let header = header(picture: Picture.stripes.image(size: CGSize(width: 160, height: 90)))
        #expect(header.bannerFormat == .band)
        header.debugForceNameInk(.black)
        let contrast = try #require(header.debugIdentityContrast())
        #expect(contrast.name.min < 4.5, "name \(contrast.name)")
    }

    /// The name stands on the picture on a band too now (it used to sit on
    /// the page below the strip), so both shapes wear the picture's ink; only
    /// a header with no picture keeps the page's.
    @Test func everyBannerWearsThePicturesInkAndNoPictureThePages() {
        let band = header(picture: Picture.white.image(size: CGSize(width: 160, height: 90)))
        #expect(band.bannerFormat == .band)
        let poster = header(picture: Picture.white.image())
        #expect(poster.bannerFormat == .poster)
        // A band's black ramp takes white type; a poster over a white
        // picture on a light page, black.
        for (header, tone) in [(band, HeroInk.Tone.light), (poster, .dark)] {
            #expect(header.debugNameInk == tone.primary)
            #expect(header.debugHandleInk == tone.secondary)
            #expect(header.debugNameShadowOpacity > 0)
        }
        let bare = header(picture: nil)
        #expect(bare.bannerFormat == .none)
        #expect(bare.debugNameInk == ProfileHeaderView.pageNameInk)
        #expect(bare.debugHandleInk == ProfileHeaderView.pageHandleInk)
        #expect(bare.debugNameShadowOpacity == 0)
    }

    /// The poster fades as it scrolls up and its type goes back to the
    /// page's ink. With half the page under the name (the shoulder), a
    /// poster wears the page's side of the inks whatever its picture — so
    /// the way back is seamless: the ink is the page's colour all the way.
    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func theInkFollowsThePosterAway(style: UIUserInterfaceStyle) throws {
        for picture in [Picture.white, .black] {
            let header = header(picture: picture.image(), style: style)
            #expect(header.debugInkTones.name == (style == .dark ? .light : .dark), "\(picture)")
            let page = ProfileHeaderView.pageNameInk.resolvedColor(with: header.traitCollection)
            for travel in [0, 0.5, 1] as [CGFloat] {
                header.setTravelled(header.posterFadeOutTravel * travel)
                var red: CGFloat = 0
                var pageRed: CGFloat = 0
                header.debugNameInk.resolvedColor(with: header.traitCollection)
                    .getRed(&red, green: nil, blue: nil, alpha: nil)
                page.getRed(&pageRed, green: nil, blue: nil, alpha: nil)
                #expect(abs(red - pageRed) < 0.02, "\(picture) travel \(travel)")
            }
            #expect(header.debugNameInk == ProfileHeaderView.pageNameInk)
            #expect(header.debugNameShadowOpacity == 0)
        }
    }

    /// A pull-down at the top of a profile — the banner pinned to the
    /// viewport's top while the header travels down with the content —
    /// stretches the banner, and every frame of it is a zoom: no blur
    /// composed, no bake, no ground read for the ink, the fade where it was,
    /// and the picture still covering the stretched banner to its top. The
    /// pull used to re-read the ground under the type every two points (on
    /// a device, the gesture at half the scroll's frame rate).
    @Test(arguments: [false, true])
    func aPullDownOnlyZoomsTheBanner(band: Bool) throws {
        let size = band ? CGSize(width: 160, height: 90) : CGSize(width: 90, height: 160)
        let header = header(picture: Picture.stripes.image(size: size))
        #expect(header.bannerFormat == (band ? .band : .poster))
        let viewport = try #require(header.superview)
        header.anchorBanner(toViewportTop: viewport.topAnchor)
        viewport.layoutIfNeeded()
        let composed = header.debugBlurComposeCount
        let baked = header.debugBlurBakeCount
        let reads = header.debugInkReadCount
        let fade = try #require(header.debugBannerFade)
        let tones = header.debugInkTones
        // A band shows no blur (5 October 2026): nothing composed, but the
        // levels are still baked — the ink is read off them.
        try #require((band ? composed == 0 : composed > 0) && baked > 0 && reads > 0)
        for pull in stride(from: CGFloat(3), through: 180, by: 3) {
            header.frame.origin.y = pull
            header.setTravelled(-pull)
            viewport.layoutIfNeeded()
            let banner = header.debugBannerFrame
            #expect(abs(banner.minY + pull) < 0.5, "pull \(pull): the banner stretches \(banner)")
            #expect(header.debugBlurComposeCount == composed, "pull \(pull)")
            #expect(header.debugBlurBakeCount == baked, "pull \(pull)")
            #expect(header.debugInkReadCount == reads, "pull \(pull)")
            #expect(header.debugBannerFade == fade, "pull \(pull)")
            let cover = header.debugBannerPictureCover
            #expect(cover.minY <= banner.minY + 0.5, "pull \(pull): \(cover) in \(banner)")
            #expect(cover.maxY >= banner.maxY - 0.5, "pull \(pull): \(cover) in \(banner)")
            // The page's tone stays on the resting banner.
            #expect(abs(header.debugBannerRampFrame.minY) < 0.5, "pull \(pull)")
        }
        #expect(header.debugInkTones == tones)
        header.frame.origin.y = 0
        header.setTravelled(0)
        viewport.layoutIfNeeded()
        #expect(header.debugBannerFrame.minY == 0)
        #expect(header.debugBlurComposeCount == composed)
        #expect(header.debugInkReadCount == reads)
    }

    /// On a poster the blur's levels are all showing once the picture is in,
    /// each fading in below the one before, the strongest whole only at the
    /// foot — a band shows none (5 October 2026). The ramp is shouldered on
    /// both, half there under the name and whole at the banner's foot.
    @Test(arguments: [false, true])
    func theBlurAndThePageClimbToTheFoot(band: Bool) throws {
        let size = band ? CGSize(width: 160, height: 90) : CGSize(width: 90, height: 160)
        let header = header(picture: Picture.grey.image(size: size))
        let levels = header.debugBannerBlurLevels
        if band {
            #expect(levels.isEmpty, "a band blurs")
        } else {
            try #require(levels.count == HeroBannerFade.blurSigmas.count)
        }
        let name = header.debugNameFrame
        let fade = try #require(header.debugBannerFade)
        if !band {
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
        }

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
        // The page's tone climbs the same container on its own ease-in:
        // clear above it, thin under the name, whole at the foot — drawn as
        // the curve the ground is read with.
        #expect(alpha(at: fade.rampStart - 4) == 0)
        // The shoulder under the name, on both shapes: with no blur, a
        // band's black ramp is what closes the picture's spread under its type.
        #expect(alpha(at: name.minY) >= HeroBannerFade.shoulderAlpha - 0.05)
        let handle = header.debugHandleFrame.midY
        #expect(abs(alpha(at: handle) - HeroBannerFade.rampAlpha(at: handle, geometry: fade)) < 0.02)
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
