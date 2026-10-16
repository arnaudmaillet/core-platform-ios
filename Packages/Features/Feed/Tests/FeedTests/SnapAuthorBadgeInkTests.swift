import DesignSystem
import MediaCore
import Testing
import UIKit
@testable import Feed

/// THE PERSON PILL'S BADGE IS A BLACK DISC WITH A WHITE GLYPH (#968), on every
/// relation and in light and dark mode alike. #930 drew a white disc with a
/// near-black glyph.
///
/// The images the badge draws are rendered under each appearance's traits, in
/// image views TINTED RED, and every opaque pixel is read: a semantic ink would
/// resolve differently per appearance, and an ink a tint (or the glass's
/// vibrancy) can reach would come out red.
@MainActor
struct SnapAuthorBadgeInkTests {
    typealias Badge = SnapAuthorIdentityView.FollowBadge

    private static func rgb(_ colour: UIColor) -> Pixel {
        var c = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0), a: CGFloat(0))
        colour.getRed(&c.r, green: &c.g, blue: &c.b, alpha: &c.a)
        return (c.r, c.g, c.b)
    }

    private static func near(_ pixel: Pixel, _ colour: UIColor) -> Bool {
        let c = rgb(colour)
        return abs(pixel.r - c.r) < 0.05 && abs(pixel.g - c.g) < 0.05 && abs(pixel.b - c.b) < 0.05
    }

    /// The owner's inks (#1197): the "+" a black disc with a white mark; a
    /// FOLLOWED check and a PENDING clock a grey disc with a pink mark; FRIENDS
    /// a pink disc with a white mark — fixed, the same in either appearance.
    @Test(arguments: [Badge.follow, .following, .friends, .pending],
          [UIUserInterfaceStyle.light, .dark])
    func eachBadgeWearsItsInks(_ badge: Badge, _ style: UIUserInterfaceStyle) throws {
        let pill = SnapAuthorIdentityView()
        pill.setFollowBadge(badge)
        #expect(pill.drawnBadgeSymbol == badge.symbolName)
        let images = pill.drawnBadgeImages
        // ONE image: the disc and the mark are one circled symbol (#1199).
        #expect(images.disc == nil, "a separate disc animates out of step with the mark")
        let glyph = try #require(images.glyph)
        #expect(glyph.renderingMode != .alwaysTemplate, "the glass can re-tint the badge")

        let (discInk, markInk): (UIColor, UIColor) = switch badge {
        case .follow: (.black, .white)
        case .following, .pending: (PersonPillBadgeInks.quietDisc, PersonPillBadgeInks.accent)
        case .friends: (PersonPillBadgeInks.accent, .white)
        case .none: (.clear, .clear)
        }
        let mode = style == .dark ? "dark" : "light"
        let badgePixels = try Self.opaquePixels(of: [glyph], style: style)
        #expect(badgePixels.count > 50, "the badge draws nothing")
        let disc = badgePixels.filter { Self.near($0, discInk) }.count
        let mark = badgePixels.filter { Self.near($0, markInk) }.count
        #expect(disc > mark, "the \(badge) badge does not read as its disc ink in \(mode) mode")
        #expect(mark > 10, "the \(badge) mark is not its ink in \(mode) mode")
    }

    /// The same badge, pixel for pixel, in light and dark mode.
    @Test(arguments: [Badge.follow, .following, .friends, .pending])
    func theBadgeIsTheSameInEitherAppearance(_ badge: Badge) throws {
        let pill = SnapAuthorIdentityView()
        pill.setFollowBadge(badge)
        let images = pill.drawnBadgeImages
        let layers = [try #require(images.glyph)]
        let light = try Self.opaquePixels(of: layers, style: .light)
        let dark = try Self.opaquePixels(of: layers, style: .dark)
        #expect(light.count == dark.count)
        #expect(zip(light, dark).allSatisfy { $0 == $1 }, "the \(badge) badge changes with the appearance")
    }

    /// No badge draws nothing — the same symbol in clear ink, so the badge's
    /// arrival is a symbol replace too.
    @Test func noBadgeDrawsNothing() throws {
        let pill = SnapAuthorIdentityView()
        pill.setFollowBadge(.none)
        let images = pill.drawnBadgeImages
        #expect(images.disc == nil)
        #expect(try Self.opaquePixels(of: [try #require(images.glyph)], style: .light).isEmpty)
    }

    /// A pending request wears the filled clock (#968), takes no tap of its
    /// own, and says so to VoiceOver.
    @Test func aPendingRequestWearsTheClock() {
        #expect(Badge.pending.symbolName == "clock.circle.fill")
        #expect(UIImage(systemName: "clock.circle.fill") != nil)
        #expect(Badge(.requested) == .pending)
        #expect(Badge.pending.accessibilityLabel == "Requested")
        let pill = SnapAuthorIdentityView()
        pill.setFollowBadge(.pending)
        #expect(pill.drawnBadgeSymbol == "clock.circle.fill")
        #expect(!pill.offersFollow, "a pending request is not a follow on offer")
    }

    // MARK: - Pixels

    private typealias Pixel = (r: CGFloat, g: CGFloat, b: CGFloat)

    /// Every pixel of `layers` drawn at least 90% opaque, un-premultiplied —
    /// each layer in an image view centred on the badge's square, as the
    /// badge draws them, tinted red, rendered under `style`'s traits, where a
    /// dynamic ink resolves.
    private static func opaquePixels(of layers: [UIImage], style: UIUserInterfaceStyle) throws -> [Pixel] {
        let traits = UITraitCollection(userInterfaceStyle: style)
        let format = UIGraphicsImageRendererFormat(for: traits)
        format.scale = 3
        format.opaque = false
        let side = 16.0
        let views = layers.map { layer in
            let view = UIImageView(image: layer)
            view.frame = CGRect(x: 0, y: 0, width: side, height: side)
            view.contentMode = .center
            view.tintColor = .systemRed
            view.overrideUserInterfaceStyle = style
            return view
        }
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            traits.performAsCurrent {
                for view in views { view.layer.render(in: context.cgContext) }
            }
        }
        let cg = try #require(rendered.cgImage)
        let width = cg.width, height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var pixels: [Pixel] = []
        for index in stride(from: 0, to: bytes.count, by: 4) where bytes[index + 3] >= 230 {
            let alpha = CGFloat(bytes[index + 3])
            pixels.append((CGFloat(bytes[index]) / alpha, CGFloat(bytes[index + 1]) / alpha,
                           CGFloat(bytes[index + 2]) / alpha))
        }
        return pixels
    }

    private static func isBlack(_ pixel: Pixel) -> Bool {
        max(pixel.r, pixel.g, pixel.b) < 0.05
    }

    private static func isWhite(_ pixel: Pixel) -> Bool {
        min(pixel.r, pixel.g, pixel.b) > 0.95
    }

    /// Grey, at most — antialiasing between the two inks, never a colour.
    private static func isAchromatic(_ pixel: Pixel) -> Bool {
        max(pixel.r, pixel.g, pixel.b) - min(pixel.r, pixel.g, pixel.b) < 0.04
    }
}
