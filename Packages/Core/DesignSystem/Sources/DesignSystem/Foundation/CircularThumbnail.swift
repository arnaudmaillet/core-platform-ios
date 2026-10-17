import UIKit

public extension UIImage {
    /// The picture as a `side`-point circle — a tab icon, a menu row's avatar —
    /// rendered `.alwaysOriginal` so a bar or a menu does not tint the photo.
    ///
    /// ⚠️ ASPECT FILL, NEVER `draw(in:)` THE SQUARE (#1339). Drawn straight
    /// into the square, any picture that is not square is squeezed to fit: the
    /// Profile tab's avatar went oval-faced the day avatars started coming from
    /// portrait and landscape photos (#1320). The picture is scaled to cover
    /// the circle and centred; what overflows is cropped.
    func circularThumbnail(side: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        return renderer.image { _ in
            let bounds = CGRect(x: 0, y: 0, width: side, height: side)
            UIBezierPath(ovalIn: bounds).addClip()
            draw(in: Self.aspectFillRect(for: size, in: bounds))
        }.withRenderingMode(.alwaysOriginal)
    }

    /// Where a picture of `size` lands to cover `bounds` without distortion,
    /// centred — overflowing on the longer side.
    static func aspectFillRect(for size: CGSize, in bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = max(bounds.width / size.width, bounds.height / size.height)
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: bounds.midX - drawn.width / 2, y: bounds.midY - drawn.height / 2,
            width: drawn.width, height: drawn.height
        )
    }
}
