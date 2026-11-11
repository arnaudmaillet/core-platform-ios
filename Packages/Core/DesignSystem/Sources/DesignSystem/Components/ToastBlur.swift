import UIKit

/// A piece of a toast that can be drawn as a picture for its blur (#2285):
/// in its OWN ink, resolved for its traits, never through `layer.render`.
///
/// ⚠️ INSIDE THE TOAST'S GLASS, A RENDER OF THE CONTENT IS NOT WHAT SHOWS
/// (#2166): a layer mask isn't drawn there, and `layer.render` of a label
/// comes out in the glass's vibrant ink (white). So each piece draws itself:
/// the words (`ToastWords`), the disc and its glyph (`ToastBadge`), the
/// loader (`AppLoaderView`), the action and the close button.
@MainActor
protocol ToastPictured: UIView {
    /// The piece as it shows, on a transparent margin `pad` wide all round
    /// for the blur to spread into, at `scale`.
    func picture(scale: CGFloat, pad: CGFloat) -> CGImage?
}

/// The content change's blur, shared by every piece of a toast (#2285): a
/// picture stands exactly where the piece is, the piece hidden under it,
/// and blurs away (sharp to `peak`, fading) or in (from `peak` to sharp,
/// appearing) — the system's glass bubbles' change. Arriving, the piece
/// takes its place back as it clears (`handOver`).
@MainActor
enum ToastBlur {
    /// The blurred levels a stand steps through.
    static let levels = 4

    /// `view` as a picture in its own ink (`ToastPictured`); for anything
    /// else, a render of its layer.
    static func picture(of view: UIView, scale: CGFloat, pad: CGFloat) -> CGImage? {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        if let pictured = view as? any ToastPictured { return pictured.picture(scale: scale, pad: pad) }
        return AppButtonBlur.snapshot(of: view, rect: view.bounds, pad: pad, scale: scale)
    }

    /// A transparent picture of `size` on `pad` all round, at `scale`;
    /// `draw` is handed the rect the piece takes in it.
    static func draw(size: CGSize, pad: CGFloat, scale: CGFloat, _ draw: (CGRect) -> Void) -> CGImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let canvas = CGSize(width: size.width + pad * 2, height: size.height + pad * 2)
        return UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
            draw(CGRect(origin: CGPoint(x: pad, y: pad), size: size))
        }.cgImage
    }

    /// Stands `image` at `frame` in `host` and blurs it in or away over
    /// `duration` after `delay`: `appearing`, from `peak` (pixels) to sharp
    /// and from clear to opaque; else from sharp to `peak` and from
    /// `opacity` — what still showed of the piece — to clear. `done` runs
    /// once it has finished, the stand still in place.
    static func stand(
        _ image: CGImage, scale: CGFloat, frame: CGRect, in host: UIView, appearing: Bool,
        peak: CGFloat, delay: TimeInterval, duration: TimeInterval, opacity: Float = 1,
        done: @escaping @MainActor (UIImageView) -> Void
    ) -> UIImageView {
        var images = (0...levels).map { AppButtonBlur.blurred(image, radius: peak * CGFloat($0) / CGFloat(levels)) }
        if appearing { images.reverse() }
        let standIn = UIImageView(image: UIImage(cgImage: images[0], scale: scale, orientation: .up))
        standIn.frame = frame
        standIn.isUserInteractionEnabled = false
        host.addSubview(standIn)
        let begin = standIn.layer.convertTime(CACurrentMediaTime(), from: nil) + delay
        let contents = CAKeyframeAnimation(keyPath: "contents")
        contents.values = images.map(\.self)
        contents.beginTime = begin
        contents.duration = duration
        contents.fillMode = .both
        contents.isRemovedOnCompletion = false
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = appearing ? 0 : opacity
        fade.toValue = appearing ? 1 : 0
        fade.beginTime = begin
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: appearing ? .easeOut : .easeIn)
        fade.fillMode = .both
        fade.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak standIn] in
            guard let standIn else { return }
            done(standIn)
        }
        standIn.layer.add(contents, forKey: "blur.contents")
        standIn.layer.add(fade, forKey: "blur.opacity")
        CATransaction.commit()
        return standIn
    }

    /// The piece takes over from its picture in a breath — the glass's
    /// vibrant ink and the picture's are not quite one — and the picture
    /// goes.
    static func handOver(from stand: UIImageView, to piece: UIView) {
        UIView.animate(withDuration: 0.08, delay: 0, options: [.allowUserInteraction]) {
            piece.alpha = 1
            stand.alpha = 0
        } completion: { _ in
            stand.removeFromSuperview()
        }
    }

    /// A filled capsule (or disc) in `ground`, `content` drawn over it: the
    /// action's and the close button's picture.
    static func capsule(
        size: CGSize, ground: UIColor, pad: CGFloat, scale: CGFloat, _ content: (CGRect) -> Void
    ) -> CGImage? {
        draw(size: size, pad: pad, scale: scale) { rect in
            ground.setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: min(rect.width, rect.height) / 2).fill()
            content(rect)
        }
    }

    /// `image` drawn at its own size, centred on `centre`, in `ink`.
    static func drawGlyph(_ image: UIImage?, ink: UIColor, centredOn centre: CGPoint) {
        guard let image else { return }
        let tinted = image.withTintColor(ink, renderingMode: .alwaysOriginal)
        let size = tinted.size
        tinted.draw(in: CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2, width: size.width, height: size.height))
    }
}

extension ToastBadge: ToastPictured {
    /// The disc in its fill, its glyph in its ink.
    func picture(scale: CGFloat, pad: CGFloat) -> CGImage? {
        let fill = (backgroundColor ?? .clear).resolvedColor(with: traitCollection)
        let ink = (glyph.tintColor ?? .white).resolvedColor(with: traitCollection)
        let configured = glyph.image.map { image in
            glyph.preferredSymbolConfiguration.map { image.withConfiguration($0.withTraitCollection(traitCollection)) } ?? image
        }
        let glyphCentre = CGPoint(x: glyph.frame.midX, y: glyph.frame.midY)
        return ToastBlur.draw(size: bounds.size, pad: pad, scale: scale) { rect in
            fill.setFill()
            UIBezierPath(ovalIn: rect).fill()
            let centre = CGPoint(x: rect.minX + glyphCentre.x, y: rect.minY + glyphCentre.y)
            ToastBlur.drawGlyph(configured, ink: ink, centredOn: centre)
        }
    }
}

extension ToastActionButton: ToastPictured {
    /// Its grey capsule and its word in the primary ink.
    func picture(scale: CGFloat, pad: CGFloat) -> CGImage? {
        let ground = Self.ground.resolvedColor(with: traitCollection)
        let ink = Self.ink.resolvedColor(with: traitCollection)
        let title = (configuration?.title ?? titleLabel?.text) as NSString?
        let font = titleLabel?.font ?? .scaledSystemFont(ofSize: 15, weight: .semibold, relativeTo: .subheadline)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        return ToastBlur.capsule(size: bounds.size, ground: ground, pad: pad, scale: scale) { rect in
            guard let title else { return }
            let size = title.size(withAttributes: attributes)
            title.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
        }
    }
}

extension ToastCloseButton: ToastPictured {
    /// Its grey disc and its ✕ in the primary ink.
    func picture(scale: CGFloat, pad: CGFloat) -> CGImage? {
        let ground = ToastActionButton.ground.resolvedColor(with: traitCollection)
        let ink = ToastActionButton.ink.resolvedColor(with: traitCollection)
        let shown = imageView?.image ?? configuration?.image
        return ToastBlur.capsule(size: bounds.size, ground: ground, pad: pad, scale: scale) { rect in
            ToastBlur.drawGlyph(shown, ink: ink, centredOn: CGPoint(x: rect.midX, y: rect.midY))
        }
    }
}

extension AppLoaderView: ToastPictured {}
