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

    /// A band ENDS on the avatar's midline — a few points under it, in the
    /// air above the counters — and the page's tone is whole there.
    @Test func aBandEndsOnTheAvatarsMidline() throws {
        let header = header(format: .band)
        let banner = header.debugBannerFrame
        let avatar = header.debugAvatarFrame
        #expect(banner.minY == 0)
        #expect(banner.maxY > avatar.midY)
        #expect(banner.maxY <= avatar.midY + 8)
        let fade = try #require(header.debugBannerFade)
        #expect(abs(fade.rampEnd - banner.maxY) < 0.5)
        // The ramp itself: clear, then the page, opaque at the edge.
        let alphas = header.debugBannerRampAlphas
        #expect(alphas.first == 0)
        #expect(alphas.last == 1)
    }

    /// The blur's container — and the page's fade — run from JUST ABOVE THE
    /// AVATAR (user, 30 September 2026) to the banner's FOOT, where both are
    /// whole; the stage above it is the picture, untouched.
    @Test(arguments: [ProfileBannerFormat.band, .poster])
    func theRunOutClimbsFromAboveTheAvatarToTheFoot(format: ProfileBannerFormat) throws {
        let header = header(format: format)
        let fade = try #require(header.debugBannerFade)
        let avatar = header.debugAvatarFrame
        let foot = header.debugBannerFrame.maxY
        #expect(abs(fade.blurFull - foot) < 0.5)
        #expect(abs(fade.rampEnd - foot) < 0.5)
        #expect(abs(avatar.minY - fade.blurStart - HeroBannerFade.blurLead) < 0.5)
        // Shouldered on both: the ramp's tone eased in just above the
        // container, already half there at its top — on a band (black, and
        // no blur since 5 October 2026) it is all that closes the picture's
        // spread under the name.
        #expect(abs((fade.rampShoulder ?? .nan) - fade.blurStart) < 0.5)
        #expect(abs(fade.rampStart - (fade.blurStart - HeroBannerFade.shoulderRise)) < 0.5)
        #expect(header.debugBannerShowsBlur == (format == .poster))
        // The blur is next to nothing under the name: sigma under 3.5pt.
        let spans = HeroBannerFade.levelSpans(fade)
        try #require(spans.count > 2)
        #expect(spans[1].full > header.debugNameFrame.midY)
    }

    /// A poster runs to the tray's FOOT — not cut at the midline (user, 30
    /// September 2026): the whole identity block stands on the picture. It
    /// wears the blur alone (#688): no page tone fades in under its type.
    @Test func aPosterRunsPastTheTraysFoot() throws {
        let header = header(format: .poster)
        let banner = header.debugBannerFrame
        let tray = header.debugTrayFrame
        // Since 5 October 2026 the picture runs to 80% of the screen and the
        // block starts at 40%, over it: the tray stands on the picture too.
        #expect(banner.maxY > tray.maxY)
        let fade = try #require(header.debugBannerFade)
        #expect(abs(fade.blurFull - banner.maxY) < 0.5)
        #expect(header.debugBannerShowsBlur)
        #expect(!header.debugBannerShowsRamp, "a poster draws the opaque fade")
    }

    /// Only a poster lost its fade (#688): a band keeps its black one, and
    /// a header with no picture is as it was.
    @Test(arguments: [ProfileBannerFormat.band, .poster, .none])
    func onlyAPosterDropsTheFade(format: ProfileBannerFormat) {
        let header = header(format: format, picture: format != .none)
        #expect(header.debugBannerShowsRamp == (format != .poster))
        // `.none` hides the whole banner; its layers are as they always were.
        if format != .none {
            #expect(header.debugBannerShowsBlur == (format == .poster))
        }
        if format == .band {
            #expect(header.debugBannerRampTone == ProfileBannerView.bandRampTone)
        }
    }

    /// On a band the name and the handle stand on the picture — darkened by
    /// the black ramp's shoulder behind them — and the counters on the page,
    /// nearly whole behind them.
    @Test func onABandTheNameStandsOnThePictureAndTheCountersOnThePage() throws {
        let header = header(format: .band)
        let fade = try #require(header.debugBannerFade)
        #expect(HeroBannerFade.rampAlpha(at: header.debugNameFrame.minY, geometry: fade)
                >= HeroBannerFade.shoulderAlpha - 0.001)
        #expect(HeroBannerFade.rampAlpha(at: header.debugStatsFrame.minY, geometry: fade) > 0.7)
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
    /// band's column starts on the chrome, the poster's a clearance below it
    /// — the stage that puts a poster's foot at 80% of the screen.
    @Test func aBandIsShorterThanAPoster() {
        let band = header(format: .band)
        let poster = header(format: .poster)
        #expect(band.bounds.height < poster.bounds.height)
        #expect(abs((poster.bounds.height - band.bounds.height) - (poster.posterClearance - 12)) < 1)
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

    /// ⚠️ THE TRAY IS FLAT AND OPAQUE. Glass is for chrome over content;
    /// these buttons sit on the page, and glass there is a blur of nothing.
    /// One prominent filled capsule for Follow, grey capsules and bubbles for
    /// the rest — an opaque grey (user, 30 September 2026: the translucent
    /// one let a poster's picture through), the tone the translucent one
    /// made on the page.
    @Test func theTrayWearsNoGlassAndLetsNothingThrough() {
        let header = header(format: .poster)
        for button in header.debugTrayButtons {
            #expect(button.configuration?.background.visualEffect == nil)
        }
        header.configureAction(.follow)
        let follow = header.debugTrayButtons[0]
        let message = header.debugTrayButtons[1]
        #expect(follow.configuration?.title == "Follow")
        #expect(follow.configuration?.background.visualEffect == nil)
        // Follow is the one prominent capsule, in the tint: it does not wear
        // the quiet grey the others do.
        #expect(follow.configuration?.baseBackgroundColor == nil)
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            for button in header.debugTrayButtons where button !== follow {
                let fill = button.configuration?.baseBackgroundColor?.resolvedColor(with: traits)
                #expect(fill?.cgColor.alpha == 1, "\(button.configuration?.title ?? "bubble") \(style.rawValue)")
            }
            // The grey the page showed through the platform's translucent
            // fill: darker than a light page, lighter than a dark one.
            var fill = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0), a: CGFloat(0))
            var page = fill
            message.configuration?.baseBackgroundColor?.resolvedColor(with: traits)
                .getRed(&fill.r, green: &fill.g, blue: &fill.b, alpha: &fill.a)
            Surface.page.resolvedColor(with: traits).getRed(&page.r, green: &page.g, blue: &page.b, alpha: &page.a)
            #expect(style == .light ? fill.g < page.g : fill.g > page.g)
        }
    }

    /// The opaque grey IS the tone the platform's translucent gray button
    /// made on the page — measured, not assumed: a `.gray()` capsule drawn
    /// over the page, read back beside the title.
    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func theOpaqueGreyIsTheGrayButtonOnThePage(style: UIUserInterfaceStyle) throws {
        let page = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 44))
        page.overrideUserInterfaceStyle = style
        page.backgroundColor = Surface.page
        var configuration = UIButton.Configuration.gray()
        configuration.cornerStyle = .capsule
        configuration.title = "x"
        let button = UIButton(configuration: configuration)
        button.frame = page.bounds
        page.addSubview(button)
        // In a (never shown) window of the style being measured: off one,
        // the button's background resolves in the light style whatever the
        // view's override says.
        let window = UIWindow(frame: page.bounds)
        window.overrideUserInterfaceStyle = style
        window.addSubview(page)
        button.updateConfiguration()
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: page.bounds, format: format).image { context in
            page.layer.render(in: context.cgContext)
        }
        page.removeFromSuperview()
        let cgImage = try #require(image.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        // (40, 22): inside the capsule, clear of its rounding and of the title.
        context.draw(cgImage, in: CGRect(x: -40, y: -(CGFloat(cgImage.height) - 1 - 22), width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
        var fill = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0), a: CGFloat(0))
        ProfileHeaderView.trayFill.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            .getRed(&fill.r, green: &fill.g, blue: &fill.b, alpha: &fill.a)
        let expected = [fill.r, fill.g, fill.b].map { Int(($0 * 255).rounded()) }
        let drawn = pixel.prefix(3).map(Int.init)
        for (a, b) in zip(expected, drawn) {
            #expect(abs(a - b) <= 3, "style \(style.rawValue): trayFill \(expected) vs .gray() on the page \(drawn)")
        }
    }
}
