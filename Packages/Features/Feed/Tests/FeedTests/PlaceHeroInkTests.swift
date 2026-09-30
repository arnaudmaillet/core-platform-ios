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
        profile.overrideUserInterfaceStyle = style
        profile.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        profile.loadViewIfNeeded()
        profile.debugSetBannerImage(picture.image)
        profile.view.layoutIfNeeded()
        profile.viewDidLayoutSubviews()
        profile.view.layoutIfNeeded()
        return profile
    }

    /// AA for the name and for every counter's value and caption over any
    /// picture, in both appearances.
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

    /// The picture picks the ink, the same in both appearances.
    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func thePicturePicksTheInk(style: UIUserInterfaceStyle) {
        let light = place(.white, style: style)
        #expect(light.debugHeroInkTones.name == .dark)
        #expect(light.debugHeroInkTones.rank == .dark)
        #expect(light.debugHeroInkTones.likes == .dark)
        #expect(light.debugHeroNameInk == HeroInk.Tone.dark.primary)
        let dark = place(.black, style: style)
        #expect(dark.debugHeroInkTones.name == .light)
        #expect(dark.debugHeroInkTones.rank == .light)
        #expect(dark.debugHeroInkTones.likes == .light)
        #expect(dark.debugHeroNameInk == HeroInk.Tone.light.primary)
    }

    /// The blur's job: under the name, a busy picture is one tone — no stripe
    /// is left for a glyph to stand on.
    @Test func theBlurCalmsABusyPictureUnderTheName() throws {
        let profile = place(.stripes, style: .light)
        let measured = try #require(profile.debugHeroInkContrast())
        let name = try #require(measured.first { $0.0 == "Paris" })
        #expect(name.1.median - name.1.min < 0.3, "name \(name.1)")
    }

    /// The blur climbing from a lead above the name all the way down to the
    /// banner's foot, under the counters too — the whole identity on the
    /// picture, as on a profile's poster — and the page arriving over the
    /// banner's last few points.
    @Test func theFadeRunsTheIdentityOnThePicture() throws {
        let profile = place(.grey, style: .light)
        let fade = try #require(profile.debugBannerFade)
        let name = profile.debugNameFrame
        let metrics = profile.debugMetricsFrame
        let box = profile.debugBannerBoxFrame
        #expect(abs(fade.blurFull - box.maxY) < 0.5)
        #expect(abs(name.minY - fade.blurStart - HeroBannerFade.blurLead) < 0.5)
        #expect(abs(fade.rampEnd - box.maxY) < 0.5)
        #expect(abs(fade.rampEnd - fade.rampStart - HeroBannerFade.rampLength) < 0.5)
        #expect(metrics.maxY < fade.rampStart)
        let levels = profile.debugBannerBlurLevels
        try #require(levels.count == HeroBannerFade.blurSigmas.count)
        #expect(abs(levels[levels.count - 1].full - box.maxY) < 1)
    }
}
