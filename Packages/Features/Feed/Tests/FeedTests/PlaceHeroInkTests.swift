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
    /// hard 2px white/black stripes, a mid grey, and a light grey that only
    /// the dim turns to the white ink's side (#1372).
    enum Picture: String, CaseIterable, CustomTestStringConvertible {
        case white, black, stripes, grey, lightGrey

        var testDescription: String { rawValue }

        var image: UIImage {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let size = CGSize(width: 90, height: 160)
            return UIGraphicsImageRenderer(size: size, format: format).image { context in
                switch self {
                case .white: UIColor.white.setFill()
                case .grey: UIColor(white: 0.5, alpha: 1).setFill()
                case .lightGrey: UIColor(white: 0.55, alpha: 1).setFill()
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

    private func place(
        _ picture: Picture, style: UIUserInterfaceStyle, identity: PlaceIdentity? = nil
    ) -> PlaceProfileViewController {
        let profile = PlaceProfileViewController(
            postIDs: [],
            placeName: "Paris • City Cluster",
            rank: PlaceRankBadge(position: 3, label: "City Rank"),
            identity: identity,
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

    /// AA for the name and for every counter's value and caption over an
    /// even picture, in both appearances: the dimmed picture's own side of
    /// the inks (#1372).
    ///
    /// ⚠️ NOT OVER HARD STRIPES ANY MORE. The page's tone half under the name
    /// (the shoulder) closed a sharp picture's spread; the owner took that
    /// white wash away (2026-10-18), and with the blur nil under the name a
    /// 2px black/white stripe is both inks' worst ground. The mock banners
    /// are measured on the simulator (`-place-ink-audit`).
    ///
    /// ⚠️ NOT OVER A PURE WHITE ONE EITHER (the owner, 2026-10-22). The type
    /// is always light, and #1597's black veil carried it over white; the
    /// owner removed the veil ("garder seulement notre dégradé blur"),
    /// accepting that white type over a white picture's dimmed foot reads
    /// below AA.
    @Test(arguments: [Picture.black, .grey, .lightGrey], [UIUserInterfaceStyle.light, .dark])
    func theTypeClearsAAOverAnyBanner(picture: Picture, style: UIUserInterfaceStyle) throws {
        let profile = place(picture, style: style)
        #expect(profile.debugHasBannerPicture)
        let measured = try #require(profile.debugHeroInkContrast())
        #expect(measured.count == 3)
        for (label, contrast) in measured {
            #expect(contrast.min >= 4.5, "\(label) \(contrast) \(profile.debugHeroInkTones)")
        }
    }

    /// A pull-down stretches the banner up from the viewport's top while
    /// the name rides its foot — and only zooms the picture: no blur
    /// composed, no bake, no ground read again for the ink, the fade where
    /// it was, the picture still covering the stretched box to its top.
    @Test func aPullDownOnlyZoomsTheBanner() throws {
        let profile = place(.stripes, style: .light)
        let composed = profile.debugBlurComposeCount
        let baked = profile.debugBlurBakeCount
        let reads = profile.debugInkReadCount
        let fade = try #require(profile.debugBannerFade)
        try #require(composed > 0 && baked > 0 && reads > 0)
        for pull in stride(from: CGFloat(4), through: 160, by: 4) {
            profile.debugScrollActivePage(to: -pull)
            profile.view.layoutIfNeeded()
            let box = profile.debugBannerBoxFrame
            #expect(abs(box.minY) < 0.5, "pull \(pull): the box holds the viewport's top \(box)")
            #expect(profile.debugBlurComposeCount == composed, "pull \(pull)")
            #expect(profile.debugBlurBakeCount == baked, "pull \(pull)")
            #expect(profile.debugInkReadCount == reads, "pull \(pull)")
            let moved = try #require(profile.debugBannerFade)
            // The fade rides the header down with the content, unchanged.
            #expect(abs(moved.blurStart - fade.blurStart - pull) < 0.5, "pull \(pull)")
            #expect(abs(moved.blurFull - box.maxY) < 0.5, "pull \(pull)")
            let cover = profile.debugBannerPictureCover
            #expect(cover.minY <= box.minY + 0.5 && cover.maxY >= box.maxY - 0.5, "pull \(pull): \(cover)")
        }
        profile.debugScrollActivePage(to: 0)
        profile.view.layoutIfNeeded()
        #expect(profile.debugBlurComposeCount == composed)
        #expect(profile.debugInkReadCount == reads)
    }

    /// ⚠️ ALWAYS LIGHT (#1597, the owner 2026-10-22): white type over any
    /// picture, whatever the appearance, and no veil under it (the owner,
    /// 2026-10-22, removed #1597's black band): the banner's dim and blur.
    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func theTypeIsAlwaysLight(style: UIUserInterfaceStyle) {
        for picture in [Picture.white, .black] {
            let profile = place(picture, style: style)
            #expect(profile.debugHeroInkTones.name == .light, "\(picture)")
            #expect(profile.debugHeroInkTones.likes == .light, "\(picture)")
            #expect(profile.debugHeroNameInk == HeroInk.Tone.light.primary, "\(picture)")
        }
    }

    /// ⚠️ THE POPULAR TITLE IS LIGHT ON THE BANNER (#1617, the owner's option
    /// A): at rest it stands on the picture, above where the page's tone
    /// arrives, in the identity's ink. No veil under it (the owner,
    /// 2026-10-22): the banner's dim and blur alone.
    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func thePopularTitleIsLightOnTheBanner(style: UIUserInterfaceStyle) {
        for picture in [Picture.white, .black] {
            let profile = place(picture, style: style)
            #expect(profile.debugListTitleInk == .light, "\(picture): the Popular title kept the page's ink")
        }
    }

    /// The rule: light only on a picture that is there, above where the
    /// page's tone has started to show; the page's ink otherwise.
    @Test func thePopularTitleTakesThePagesInkOnceThePageIsUnderIt() {
        let fade = HeroBannerFade.Geometry(blurStart: 300, blurFull: 700, rampStart: 580, rampEnd: 700)
        let ink = PlaceProfileViewController.listTitleInk
        #expect(ink(true, 1, 500, fade) == .light)
        #expect(ink(true, 1, 610, fade) == .light, "a quarter into the ramp is still the picture")
        #expect(ink(true, 1, 620, fade) == nil, "on the page's tone")
        #expect(ink(true, 0.3, 500, fade) == nil, "the banner faded out as the header docked")
        #expect(ink(false, 1, 500, fade) == nil, "no banner (#1599)")
        #expect(ink(true, 1, 500, nil) == nil, "no fade yet")
    }

    /// The ink is read through the dim: a light grey that takes black ink
    /// on its own is darkened to the white ink's side (#1372).
    @Test func theInkSeesTheDim() {
        let profile = place(.lightGrey, style: .light)
        #expect(profile.debugBannerDim > 0)
        #expect(profile.debugHeroInkTones.name == .light)
    }

    /// The dim covers the whole picture, the stretched part under a
    /// pull-down included.
    @Test func theDimCoversTheStretchedBanner() {
        let profile = place(.grey, style: .light)
        for pull: CGFloat in [0, 80] {
            profile.debugScrollActivePage(to: -pull)
            profile.view.layoutIfNeeded()
            let box = profile.debugBannerBoxFrame
            let dim = profile.debugBannerDimFrame
            #expect(dim.minY <= box.minY + 0.5 && dim.maxY >= box.maxY - 0.5, "pull \(pull): \(dim) over \(box)")
        }
        profile.debugScrollActivePage(to: 0)
    }

    /// The blur is next to nothing under the name — the top of its
    /// container (user, 30 September 2026) — so a busy picture's stripes
    /// still show behind it: the worst pixel far from the typical one.
    @Test func theBlurIsNilUnderTheName() throws {
        let profile = place(.stripes, style: .light)
        let measured = try #require(profile.debugHeroInkContrast())
        let name = try #require(measured.first { $0.0.hasPrefix("Paris") }, "\(measured.map(\.0))")
        #expect(name.1.median - name.1.min > 1, "name \(name.1)")
    }

    /// The blur climbing from just above the identity row — its flag's top,
    /// as a profile's avatar's — all the way down to the banner's foot, and
    /// the page's tone only over the blur's last 30 % (#1372): none under
    /// the name, whole at the foot.
    @Test func theFadeRunsTheIdentityOnThePicture() throws {
        let profile = place(.grey, style: .light)
        let fade = try #require(profile.debugBannerFade)
        let name = profile.debugIdentityFrame
        let metrics = profile.debugMetricsFrame
        let box = profile.debugBannerBoxFrame
        #expect(abs(fade.blurFull - box.maxY) < 0.5)
        #expect(abs(name.minY - fade.blurStart - HeroBannerFade.blurLead) < 0.5)
        #expect(abs(fade.rampEnd - box.maxY) < 0.5)
        // No shoulder, no wash: the page arrives over the last 30 % only.
        #expect(fade.rampShoulder == nil)
        #expect(abs(fade.rampStart - (fade.blurStart + 0.7 * (fade.blurFull - fade.blurStart))) < 0.5)
        #expect(HeroBannerFade.rampAlpha(at: name.minY, geometry: fade) == 0)
        #expect(HeroBannerFade.rampAlpha(at: profile.debugNameFrame.maxY, geometry: fade) == 0, "none under the flag and the name")
        #expect(HeroBannerFade.rampAlpha(at: metrics.maxY, geometry: fade) < 0.9)
        let levels = profile.debugBannerBlurLevels
        try #require(levels.count == HeroBannerFade.blurSigmas.count)
        #expect(abs(levels[levels.count - 1].full - box.maxY) < 1)
    }
}
