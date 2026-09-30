import CoreModels
import DesignSystem
import FeedInterface
import MediaCore
import Testing
import UIKit
@testable import Feed

/// The place's name and counters on its banner's picture, in the picture's
/// ink — white on a dark picture, black on a light one, read off the blurred
/// picture behind each — over the picture's progressively blurred foot (the
/// profile banner's run-out, shared through `HeroBannerFade`), measured on
/// the rendered pixels behind the type.
///
/// ⚠️ With no scrim (#327's went as a black veil, 30 September 2026), white
/// alone measured 2.34:1 over this page's light mock picture; the ink
/// choosing the picture's side is what restores AA over any picture.
@MainActor
@Suite("Place hero ink")
struct PlaceHeroInkTests {
    /// The extremes a picture can be under the type: pure white and black,
    /// hard 2px white/black stripes, and a mid grey near where the inks cross.
    enum Picture: String, CaseIterable, CustomTestStringConvertible {
        case white, black, stripes, grey

        var testDescription: String { rawValue }

        var image: UIImage {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let size = CGSize(width: 90, height: 160)
            return UIGraphicsImageRenderer(size: size, format: format).image { context in
                switch self {
                case .white: UIColor.white.setFill()
                case .grey: UIColor(white: 0.5, alpha: 1).setFill()
                case .black, .stripes: UIColor.black.setFill()
                }
                context.fill(CGRect(origin: .zero, size: size))
                if self == .stripes {
                    UIColor.white.setFill()
                    for x in stride(from: 0, to: size.width, by: 4) {
                        context.fill(CGRect(x: x, y: 0, width: 2, height: size.height))
                    }
                }
            }
        }
    }

    /// Keeps each test's hidden windows alive while it measures.
    private final class WindowHosts { var windows: [UIWindow] = [] }
    private let hosts = WindowHosts()

    private func place(_ picture: Picture, style: UIUserInterfaceStyle) -> PlaceProfileViewController {
        let profile = PlaceProfileViewController(
            postIDs: [],
            placeName: "Paris • City Cluster",
            rank: PlaceRankBadge(position: 3, label: "City Rank"),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            videoPlayback: nil,
            loadPosts: { [] },
            openPost: { _, _, _ in }
        )
        // ⚠️ IN A HIDDEN WINDOW OF THE STYLE: off a window the test host
        // reports the simulator's own appearance whatever the override says
        // (see `UIView.isInVisibleWindow`).
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.overrideUserInterfaceStyle = style
        profile.overrideUserInterfaceStyle = style
        window.addSubview(profile.view)
        hosts.windows.append(window)
        profile.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        profile.loadViewIfNeeded()
        profile.debugSetBannerImage(picture.image)
        profile.view.layoutIfNeeded()
        profile.viewDidLayoutSubviews()
        profile.view.layoutIfNeeded()
        return profile
    }

    /// AA for the name and for every counter's value and caption over any
    /// picture — hard stripes included — in both appearances: the page's
    /// tone half under the name (the shoulder) closes a sharp picture's
    /// spread where the blur, nil at the container's top, cannot.
    @Test(arguments: Picture.allCases, [UIUserInterfaceStyle.light, .dark])
    func theTypeClearsAAOverAnyBanner(picture: Picture, style: UIUserInterfaceStyle) throws {
        let profile = place(picture, style: style)
        #expect(profile.debugHasBannerPicture)
        let measured = try #require(profile.debugHeroInkContrast())
        #expect(measured.count == 5)
        for (label, contrast) in measured {
            #expect(contrast.min >= 4.5, "\(label) \(contrast) \(profile.debugHeroInkTones)")
        }
    }

    /// With half the page's tone under the type (the shoulder), every block
    /// wears the page's side of the inks whatever the picture — black on a
    /// light page, white on a dark one.
    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func thePageSidePicksTheInk(style: UIUserInterfaceStyle) {
        let pageSide: HeroInk.Tone = style == .dark ? .light : .dark
        for picture in [Picture.white, .black] {
            let profile = place(picture, style: style)
            #expect(profile.debugHeroInkTones.name == pageSide, "\(picture)")
            #expect(profile.debugHeroInkTones.rank == pageSide, "\(picture)")
            #expect(profile.debugHeroInkTones.likes == pageSide, "\(picture)")
            #expect(profile.debugHeroNameInk == pageSide.primary, "\(picture)")
        }
    }

    /// The blur is next to nothing under the name — the top of its
    /// container (user, 30 September 2026) — so a busy picture's stripes
    /// still show behind it: the worst pixel far from the typical one.
    @Test func theBlurIsNilUnderTheName() throws {
        let profile = place(.stripes, style: .light)
        let measured = try #require(profile.debugHeroInkContrast())
        let name = try #require(measured.first { $0.0 == "Paris" })
        #expect(name.1.median - name.1.min > 1, "name \(name.1)")
    }

    /// The blur and the page's tone climbing from just above the name — the
    /// identity's top — all the way down to the banner's foot, under the
    /// counters too: the whole identity on the picture, as on a profile's
    /// poster, half the page already behind it and whole at the foot.
    @Test func theFadeRunsTheIdentityOnThePicture() throws {
        let profile = place(.grey, style: .light)
        let fade = try #require(profile.debugBannerFade)
        let name = profile.debugNameFrame
        let metrics = profile.debugMetricsFrame
        let box = profile.debugBannerBoxFrame
        #expect(abs(fade.blurFull - box.maxY) < 0.5)
        #expect(abs(name.minY - fade.blurStart - HeroBannerFade.blurLead) < 0.5)
        #expect(abs(fade.rampEnd - box.maxY) < 0.5)
        // Shouldered: half the page's tone already under the name.
        #expect(abs((fade.rampShoulder ?? .nan) - fade.blurStart) < 0.5)
        #expect(HeroBannerFade.rampAlpha(at: name.minY, geometry: fade) >= HeroBannerFade.shoulderAlpha - 0.001)
        #expect(HeroBannerFade.rampAlpha(at: metrics.maxY, geometry: fade) < 0.9)
        let levels = profile.debugBannerBlurLevels
        try #require(levels.count == HeroBannerFade.blurSigmas.count)
        #expect(abs(levels[levels.count - 1].full - box.maxY) < 1)
    }
}
