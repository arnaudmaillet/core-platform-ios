import Testing
import UIKit
@testable import DesignSystem

/// The Profile tab's avatar wears the glyphs' unread dot, cut into it (#2034).
@MainActor
struct TabAvatarBadgeTests {
    /// A solid round avatar, as `circularThumbnail` draws one.
    private func avatar() -> UIImage {
        let side = TabAvatarBadge.avatarSide
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            UIColor.systemTeal.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

    /// The dot is measured from a glyph's badge layer: a small disc at the
    /// glyph's top.
    @Test func theDotIsMeasuredFromTheGlyphs() throws {
        let dot = try #require(TabAvatarBadge.measureDot(of: .messages))
        #expect(dot.diameter > 3 && dot.diameter < 14, "diameter \(dot.diameter)")
        #expect(dot.centreOffsetY < 0, "the glyphs' dot sits above their centre: \(dot.centreOffsetY)")
        #expect(TabAvatarBadge.glyphDot == dot)
        // Every glyph's dot is the same size, the avatar's included.
        for glyph in TabGlyph.allCases {
            let other = try #require(TabAvatarBadge.measureDot(of: glyph))
            #expect(abs(other.diameter - dot.diameter) < 1, "\(glyph): \(other.diameter) against \(dot.diameter)")
        }
    }

    /// ⚠️ ONE BOX FOR BOTH STATES: the avatar never moves or resizes as the
    /// dot comes and goes.
    @Test func bothStatesShareOneBox() {
        let plain = TabAvatarBadge.image(avatar: avatar(), badged: false)
        let badged = TabAvatarBadge.image(avatar: avatar(), badged: true)
        #expect(plain.size == badged.size)
        let centre = CGPoint(x: plain.size.width / 2, y: plain.size.height / 2)
        #expect(TabAvatarBadge.alpha(of: plain, at: centre) == 1)
        #expect(TabAvatarBadge.alpha(of: badged, at: centre) == 1, "the avatar moved")
        #expect(plain.renderingMode == .alwaysOriginal && badged.renderingMode == .alwaysOriginal)
    }

    /// ⚠️ A TRUE CUTOUT: clear between the dot and the avatar, the dot opaque.
    @Test func theDotSitsInATransparentCutout() {
        let dot = TabAvatarBadge.glyphDot
        let image = TabAvatarBadge.image(avatar: avatar(), badged: true)
        let centre = TabAvatarBadge.dotCentre(for: dot)
        #expect(TabAvatarBadge.alpha(of: image, at: centre) == 1, "no dot")
        // Towards the avatar's centre, in the gap ring: inside the avatar, so
        // opaque without the cutout.
        let middle = CGPoint(x: image.size.width / 2, y: image.size.height / 2)
        let length = hypot(middle.x - centre.x, middle.y - centre.y)
        let reach = dot.diameter / 2 + TabAvatarBadge.cutoutGap * 0.6
        let ring = CGPoint(x: centre.x + (middle.x - centre.x) / length * reach,
                           y: centre.y + (middle.y - centre.y) / length * reach)
        let plain = TabAvatarBadge.image(avatar: avatar(), badged: false)
        #expect(TabAvatarBadge.alpha(of: plain, at: ring) == 1, "the probe is not on the avatar")
        #expect(TabAvatarBadge.alpha(of: image, at: ring) == 0, "the gap is not clear")
    }

    /// ⚠️ AT THE GLYPHS' DOT HEIGHT, on the avatar's rim.
    @Test func theDotIsAtTheGlyphsHeightOnTheRim() {
        let dot = TabAvatarBadge.glyphDot
        let side = TabAvatarBadge.boxSide(for: dot)
        let centre = TabAvatarBadge.dotCentre(for: dot)
        let radius = TabAvatarBadge.avatarSide / 2
        if abs(dot.centreOffsetY) <= radius {
            #expect(abs(centre.y - (side / 2 + dot.centreOffsetY)) < 0.001, "not at the glyphs' height")
        }
        #expect(abs(hypot(centre.x - side / 2, centre.y - side / 2) - radius) < 0.001, "off the rim")
        #expect(centre.x > side / 2, "on the leading side")
        // The dot and its gap fit in the box.
        #expect(centre.x + dot.diameter / 2 + TabAvatarBadge.cutoutGap <= side + 0.001)
        #expect(centre.y - dot.diameter / 2 - TabAvatarBadge.cutoutGap >= -0.001)
    }
}
