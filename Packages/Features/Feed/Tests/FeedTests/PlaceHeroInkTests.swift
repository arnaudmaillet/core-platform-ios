import CoreModels
import DesignSystem
import FeedInterface
import MediaCore
import Testing
import UIKit
@testable import Feed

/// The place's name on its banner: white over a black ink scrim — the
/// profile poster's rule, shared through `HeroInk` — measured on the rendered
/// pixels behind the type.
///
/// ⚠️ It was `.label` with a page-toned halo over a plate that was still
/// mostly picture where the name stood: faint black over a dark photograph in
/// light mode, faint white over a bright one in dark mode.
@MainActor
@Suite("Place hero ink")
struct PlaceHeroInkTests {
    /// The extremes a picture can be under white type: pure white is its
    /// worst case, hard 2px white/black stripes a busy one.
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

    /// AA for the name over every extreme, in both appearances — and for the
    /// first counter's value, page ink on the plate, which now starts at the
    /// name's foot rather than under the name.
    @Test(arguments: Picture.allCases, [UIUserInterfaceStyle.light, .dark])
    func theNameClearsAAOverAnyBanner(picture: Picture, style: UIUserInterfaceStyle) throws {
        let profile = place(picture, style: style)
        #expect(profile.debugHasBannerPicture)
        #expect(profile.debugHeroNameInk == HeroInk.primary)
        let measured = try #require(profile.debugHeroInkContrast())
        let name = try #require(measured.first { $0.0 == "Paris" })
        #expect(name.1.min >= 4.5, "name \(name.1)")
        let rank = try #require(measured.first { $0.0 == "#3" })
        #expect(rank.1.min >= 4.5, "rank value \(rank.1)")
    }

    /// The plate is clear under the name and climbs from its foot; the ink
    /// scrim peaks under the name and, on a light page, has given way by the
    /// counters — so nothing is grey where the plate lands flat, under the
    /// selector. On a dark page it holds to the foot, under a plate of the
    /// same tone.
    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func theScrimsShareTheBannerAtTheType(style: UIUserInterfaceStyle) throws {
        let profile = place(.grey, style: style)
        // ⚠️ IN A WINDOW, for this one: where the ink scrim ends is read off
        // the scrim's own traits, and a view tree with no window never hands
        // the override down that deep. Local, never stored on the suite.
        let window = UIWindow(frame: profile.view.frame)
        window.overrideUserInterfaceStyle = style
        window.addSubview(profile.view)
        defer { profile.view.removeFromSuperview() }
        profile.view.layoutIfNeeded()
        profile.viewDidLayoutSubviews()
        profile.view.layoutIfNeeded()
        let box = profile.debugBannerBoxFrame
        let plate = profile.debugPlateFrame
        let name = profile.debugNameFrame
        let metrics = profile.debugMetricsFrame
        func alpha(at y: CGFloat, locations: [CGFloat], alphas: [CGFloat]) -> CGFloat {
            guard let upper = locations.firstIndex(where: { $0 >= y }) else { return alphas.last ?? 0 }
            guard upper > 0 else { return alphas[0] }
            let span = locations[upper] - locations[upper - 1]
            guard span > 0 else { return alphas[upper] }
            let t = (y - locations[upper - 1]) / span
            return alphas[upper - 1] + (alphas[upper] - alphas[upper - 1]) * t
        }
        func plateAlpha(_ y: CGFloat) -> CGFloat {
            alpha(at: (y - plate.minY) / plate.height,
                  locations: profile.debugPlateLocations, alphas: profile.debugPlateAlphas)
        }
        func inkAlpha(_ y: CGFloat) -> CGFloat {
            alpha(at: (y - box.minY) / box.height,
                  locations: profile.debugInkScrimLocations, alphas: profile.debugInkScrimAlphas)
        }
        try #require(!profile.debugInkScrimLocations.isEmpty)
        #expect(plateAlpha(name.midY) < 0.001)
        #expect(plateAlpha(name.maxY) < 0.001)
        #expect(abs(inkAlpha(name.minY) - HeroInk.scrimPeak) < 0.001)
        #expect(abs(inkAlpha(name.maxY) - HeroInk.scrimPeak) < 0.001)
        #expect(plateAlpha(metrics.minY) >= 0.5)
        if style == .light {
            #expect(inkAlpha(metrics.midY) < 0.001)
        } else {
            #expect(abs(inkAlpha(box.maxY - 1) - HeroInk.scrimPeak) < 0.001)
        }
    }
}
