import UIKit

extension UIImage {
    /// The diameter a menu header's face is drawn at. Menu rows size their
    /// image from the image itself, so this is what keeps the header one
    /// comfortable row taller than a verb rather than a banner.
    static let mapMenuHeaderAvatarDiameter: CGFloat = 28

    /// A circle-cropped copy for a menu row.
    ///
    /// Aspect-FILL, like every other avatar in the app: a portrait squeezed
    /// to fit would be the only distorted face on screen. The short side is
    /// what meets the circle, and the overflow on the long side is trimmed
    /// evenly so the subject stays centred.
    func mapMenuHeaderAvatar(diameter: CGFloat = UIImage.mapMenuHeaderAvatarDiameter) -> UIImage {
        let target = CGSize(width: diameter, height: diameter)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: target)).addClip()
            let scale = max(diameter / size.width, diameter / size.height)
            let scaled = CGSize(width: size.width * scale, height: size.height * scale)
            draw(in: CGRect(
                x: (diameter - scaled.width) / 2,
                y: (diameter - scaled.height) / 2,
                width: scaled.width,
                height: scaled.height
            ))
        }
    }
}
