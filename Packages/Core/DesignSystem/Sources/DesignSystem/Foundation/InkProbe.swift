import UIKit

/// ⚠️ WHERE A VIEW'S INK STARTS, NOT ITS FRAME (#2286, the owner
/// 2026-11-11: "far too much space under the bar").
///
/// The soft fade under a titled bar softens what is DRAWN. A row's frame
/// starts with blank padding (its avatar sits ~7 pt in), and a section
/// heading's text sits at the bottom of a mostly empty header: measuring the
/// frame pushed lists down by space the fade never touched. This reads the
/// topmost thing a view actually paints:
/// - a label's text, from its first line's cap height (the top of a capital,
///   of a digit; an accent may rise above it, the margin covers it);
/// - an image view's image, where its content mode puts it;
/// - a fill that shows against the screen's ground, a border, a layer's own
///   bitmap (an avatar's initials), a shape or a gradient layer.
///
/// A fill the same colour as the screen's ground draws nothing visible (a
/// plain list's white cell on a white list), and a separator is a hairline
/// the fade can cross: neither counts.
@MainActor
enum InkProbe {
    /// The topmost ink `view` and its subviews draw, in `space`'s
    /// coordinates; nil when nothing is drawn.
    static func inkTop(of view: UIView, in space: UIView, ground: UIColor?) -> CGFloat? {
        view.layoutIfNeeded()
        guard let top = inkTop(of: view, ground: ground, depth: 0) else { return nil }
        return view.convert(CGPoint(x: 0, y: top), to: space).y
    }

    /// The colour the screen's content sits on: the first opaque-ish
    /// background from `view` up its superviews.
    static func ground(of view: UIView) -> UIColor? {
        var current: UIView? = view
        while let candidate = current {
            if let colour = candidate.backgroundColor, alpha(of: colour, in: candidate) > 0.5 { return colour }
            current = candidate.superview
        }
        return nil
    }

    #if DEBUG
    /// `-top-fade-trace`: every view of `view` that counts as ink, topmost
    /// first, with why — to see what a row's measure stops on.
    static func debugInkReport(of view: UIView, in space: UIView, ground: UIColor?) -> String {
        var found: [(CGFloat, String)] = []
        func walk(_ v: UIView, depth: Int) {
            guard depth < 24, !v.isHidden, v.alpha > 0.01, v.bounds.width > 0, v.bounds.height > 0,
                  !isHairline(v) else { return }
            if let own = ownInkTop(of: v, ground: ground) {
                let y = v.convert(CGPoint(x: 0, y: own), to: space).y
                var why = "?"
                if v is UILabel { why = "text" } else if v is UIImageView { why = "image" }
                else if showsFill(v, ground: ground) { why = "fill \(v.backgroundColor.map { "\($0)" } ?? "")" }
                else if v.layer.contents != nil { why = "contents" } else if v.layer.borderWidth > 0 { why = "border" }
                found.append((y, "\(type(of: v)):\(why)"))
            }
            for sublayer in v.layer.sublayers ?? [] where !(sublayer.delegate is UIView) {
                if let top = layerInkTop(sublayer, depth: 0) {
                    found.append((v.layer.convert(CGPoint(x: 0, y: top), to: space.layer).y, "layer \(type(of: sublayer)) in \(type(of: v))"))
                }
            }
            v.subviews.forEach { walk($0, depth: depth + 1) }
        }
        walk(view, depth: 0)
        return found.sorted { $0.0 < $1.0 }.prefix(4).map { String(format: "%.1f %@", $0.0, $0.1) }.joined(separator: " | ")
    }
    #endif

    // MARK: - Walk

    /// The view's own topmost ink and its subviews', in its own coordinates.
    private static func inkTop(of view: UIView, ground: UIColor?, depth: Int) -> CGFloat? {
        guard depth < 24, !view.isHidden, view.alpha > 0.01, view.bounds.width > 0, view.bounds.height > 0,
              !isHairline(view) else { return nil }
        var tops: [CGFloat] = []
        if let own = ownInkTop(of: view, ground: ground) { tops.append(own) }
        for sublayer in view.layer.sublayers ?? [] where !(sublayer.delegate is UIView) {
            if let top = layerInkTop(sublayer, depth: 0) { tops.append(top) }
        }
        for subview in view.subviews {
            guard let top = inkTop(of: subview, ground: ground, depth: depth + 1) else { continue }
            // A subview's coordinates in its parent's.
            var parentTop: CGFloat = subview.convert(CGPoint(x: 0, y: top), to: view).y
            // What a clipping parent cuts off above its top isn't drawn.
            if view.clipsToBounds { parentTop = max(parentTop, view.bounds.minY) }
            tops.append(parentTop)
        }
        return tops.min()
    }

    /// What the view itself paints, before its subviews.
    private static func ownInkTop(of view: UIView, ground: UIColor?) -> CGFloat? {
        if let label = view as? UILabel {
            return textInkTop(of: label)
        }
        if let imageView = view as? UIImageView {
            guard let image = imageView.image else { return showsFill(view, ground: ground) ? view.bounds.minY : nil }
            return imageRect(of: image, in: imageView).minY
        }
        if showsFill(view, ground: ground) { return view.bounds.minY }
        let layer = view.layer
        if layer.borderWidth > 0, let border = layer.borderColor, border.alpha > 0.01 { return view.bounds.minY }
        // A view drawing its own bitmap (an avatar's initials, a `draw(_:)`).
        if layer.contents != nil { return view.bounds.minY }
        if let shape = layer as? CAShapeLayer, let path = shape.path, !path.isEmpty { return path.boundingBox.minY }
        if layer is CAGradientLayer { return view.bounds.minY }
        return nil
    }

    /// A layer that isn't a view's: a shape, a gradient, a bitmap, a fill.
    private static func layerInkTop(_ layer: CALayer, depth: Int) -> CGFloat? {
        guard depth < 8, !layer.isHidden, layer.opacity > 0.01, layer.bounds.height > 0 else { return nil }
        var tops: [CGFloat] = []
        let drawsItself: Bool = layer.contents != nil
            || (layer.backgroundColor?.alpha ?? 0) > 0.01
            || (layer.borderWidth > 0 && (layer.borderColor?.alpha ?? 0) > 0.01)
            || layer is CAGradientLayer
        if let shape = layer as? CAShapeLayer, let path = shape.path, !path.isEmpty {
            tops.append(layer.convert(CGPoint(x: 0, y: path.boundingBox.minY), to: layer.superlayer).y)
        } else if drawsItself {
            tops.append(layer.frame.minY)
        }
        for sublayer in layer.sublayers ?? [] where !(sublayer.delegate is UIView) {
            guard let top = layerInkTop(sublayer, depth: depth + 1) else { continue }
            tops.append(layer.convert(CGPoint(x: 0, y: top), to: layer.superlayer).y)
        }
        return tops.min()
    }

    // MARK: - Pieces

    /// A label's first line's cap top: UIKit centres the text block in the
    /// label's bounds, its first baseline an ascender below the block's top.
    static func textInkTop(of label: UILabel) -> CGFloat? {
        let hasText: Bool = (label.attributedText?.length ?? 0) > 0 || !(label.text ?? "").isEmpty
        guard hasText else { return nil }
        let block: CGRect = label.textRect(forBounds: label.bounds, limitedToNumberOfLines: label.numberOfLines)
        let blockTop: CGFloat = label.bounds.minY + max(0, (label.bounds.height - block.height) / 2)
        let font: UIFont = (label.attributedText?.length ?? 0) > 0
            ? (label.attributedText?.attribute(.font, at: 0, effectiveRange: nil) as? UIFont ?? label.font)
            : label.font
        return blockTop + max(0, font.ascender - font.capHeight)
    }

    /// Where an image view draws its image, by its content mode.
    private static func imageRect(of image: UIImage, in view: UIImageView) -> CGRect {
        let bounds = view.bounds
        let size = image.size
        guard size.width > 0, size.height > 0 else { return bounds }
        switch view.contentMode {
        case .scaleAspectFit:
            let scale = min(bounds.width / size.width, bounds.height / size.height)
            let height = size.height * scale
            return CGRect(x: bounds.minX, y: bounds.midY - height / 2, width: bounds.width, height: height)
        case .center, .left, .right:
            return CGRect(x: bounds.minX, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        case .bottom, .bottomLeft, .bottomRight:
            return CGRect(x: bounds.minX, y: bounds.maxY - size.height, width: size.width, height: size.height)
        default:
            // Fill, aspect fill, top: from the top.
            return bounds
        }
    }

    /// A background that shows against the screen's ground.
    private static func showsFill(_ view: UIView, ground: UIColor?) -> Bool {
        guard let fill = view.backgroundColor, alpha(of: fill, in: view) > 0.01 else { return false }
        guard let ground else { return true }
        return !same(fill, ground, in: view)
    }

    /// A separator: a hairline the fade may cross without anyone reading it
    /// as a softened line.
    private static func isHairline(_ view: UIView) -> Bool {
        view.bounds.height <= 1 || NSStringFromClass(type(of: view)).contains("Separator")
    }

    private static func alpha(of colour: UIColor, in view: UIView) -> CGFloat {
        var alpha: CGFloat = 0
        colour.resolvedColor(with: view.traitCollection).getRed(nil, green: nil, blue: nil, alpha: &alpha)
        return alpha
    }

    private static func same(_ lhs: UIColor, _ rhs: UIColor, in view: UIView) -> Bool {
        var a: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var b: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        lhs.resolvedColor(with: view.traitCollection).getRed(&a.0, green: &a.1, blue: &a.2, alpha: &a.3)
        rhs.resolvedColor(with: view.traitCollection).getRed(&b.0, green: &b.1, blue: &b.2, alpha: &b.3)
        return abs(a.0 - b.0) < 0.02 && abs(a.1 - b.1) < 0.02 && abs(a.2 - b.2) < 0.02 && abs(a.3 - b.3) < 0.05
    }
}

/// A zero-size, transparent subview of a titled scroll view whose only job
/// is to be laid out AFTER it (#2286): UIKit lays a view's subviews out once
/// its own `layoutSubviews` has run, so when this one's runs, the cells the
/// list made for its first layout are there and configured — still before
/// the frame is drawn. The clearance measures their ink then, instead of on
/// the next turn, which would show the list moving under the viewer's eyes.
@MainActor
final class TopFadeLayoutProbe: UIView {
    private let onLayout: () -> Void

    init(onLayout: @escaping () -> Void) {
        self.onLayout = onLayout
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        alpha = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout()
    }
}
