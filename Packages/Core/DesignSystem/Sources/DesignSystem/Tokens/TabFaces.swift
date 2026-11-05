import UIKit

/// A tab's two faces, made the way the glyph tabs' are (#1191, #2073): the
/// OUTLINE as its image, the FILL as its selected image, both bitmaps the app
/// draws as templates the bar inks, at the glyphs' size, in one box.
///
/// ⚠️ NEVER A PLAIN SYMBOL IMAGE ON A TAB. The bar draws a system symbol in its
/// own way and prefers its fill variant whatever the selection: a guest's
/// Settings gear (`gearshape`) showed filled when not selected, beside glyph
/// tabs that showed their outline (#2073). A bitmap is drawn as given.
@MainActor
public enum TabFaces {
    /// A system symbol pair, as the bar's two faces: drawn at
    /// `TabGlyph.symbolConfiguration`, so it stands the size of its
    /// neighbours, and into one box, so selecting it neither grows nor
    /// shrinks it. Nil when the system does not know a name.
    public static func system(outline: String, fill: String) -> (outline: UIImage, fill: UIImage)? {
        let config = TabGlyph.symbolConfiguration
        guard let line = UIImage(systemName: outline, withConfiguration: config),
              let solid = UIImage(systemName: fill, withConfiguration: config) else { return nil }
        let box = CGSize(width: max(line.size.width, solid.size.width), height: max(line.size.height, solid.size.height))
        let baseline = line.baselineOffsetFromBottom ?? 0
        return (template(line, inBox: box, baseline: baseline), template(solid, inBox: box, baseline: baseline))
    }

    /// `glyph` drawn into a `box`, its leading edge and bottom on the box's —
    /// the bottom-left corner — as a template on `baseline`.
    public static func template(_ glyph: UIImage, inBox box: CGSize, baseline: CGFloat) -> UIImage {
        let image = UIGraphicsImageRenderer(size: box).image { _ in
            glyph.draw(at: CGPoint(x: 0, y: box.height - glyph.size.height))
        }
        return image
            .withBaselineOffset(fromBottom: baseline)
            .withRenderingMode(.alwaysTemplate)
    }
}

public extension UITab {
    /// Puts on the tab's two faces: `outline` as its image, `fill` as its
    /// selected image. Nil `fill`: the image in both states (an avatar).
    ///
    /// ⚠️ `selectedImage` IS SET BY NAME. `UITab.selectedImage` (iOS 26.1)
    /// failed to compile on CI's Xcode 26 SDK even behind `#available`, so it
    /// is reached through KVC, guarded by `responds(to:)`; a system without it
    /// shows the outline in both states.
    @MainActor
    func setFaces(outline: UIImage?, fill: UIImage?) {
        image = outline
        guard responds(to: NSSelectorFromString("setSelectedImage:")) else { return }
        setValue(fill, forKey: "selectedImage")
    }

    /// The selected face, nil when unset or unsupported: tests, and the
    /// shell skipping a re-send of the faces a tab already wears (#2116).
    @MainActor
    var selectedFace: UIImage? {
        guard responds(to: NSSelectorFromString("selectedImage")) else { return nil }
        return value(forKey: "selectedImage") as? UIImage
    }
}
