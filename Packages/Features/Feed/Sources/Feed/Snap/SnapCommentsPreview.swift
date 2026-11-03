import DesignSystem
import UIKit

/// The post's media floating over the comments sheet once the sheet has
/// grown over it (#2087, the owner, 2026-11-03): in the media's own shape,
/// at the screen's top right under the sheet's bar, a clip playing on in it
/// (`SnapFeedCell.makeCommentsPreviewContent`).
///
/// It does not appear: the shrunk media flies into it from where it stood
/// above the sheet, and back (`SnapCommentsSheetSession`).
@MainActor
final class SnapCommentsPreview: UIView {
    /// The preview's longer side; the other follows the media's shape.
    static let longSide: CGFloat = 168
    static let cornerRadius: CGFloat = Spacing.md

    let content: UIView
    private let clip = UIView()
    private let edge = UIView()

    init(content: UIView) {
        self.content = content
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        // Over the sheet's rows: a shadow lifts it off them.
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.45
        layer.shadowRadius = Spacing.md
        layer.shadowOffset = CGSize(width: 0, height: Spacing.xs)
        clip.clipsToBounds = true
        clip.layer.cornerCurve = .continuous
        clip.layer.cornerRadius = Self.cornerRadius
        clip.backgroundColor = .black
        addSubview(clip)
        clip.pin(to: self)
        content.frame = clip.bounds
        content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        clip.addSubview(content)
        // The media's own edge, as the shrunk media wears it.
        edge.isUserInteractionEnabled = false
        edge.layer.cornerCurve = .continuous
        edge.layer.cornerRadius = Self.cornerRadius
        addSubview(edge)
        edge.pin(to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        drawEdge()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        drawEdge()
    }

    private func drawEdge() {
        let dark = traitCollection.modifyingTraits { $0.userInterfaceStyle = .dark }
        edge.layer.borderColor = UIColor.systemGray2.resolvedColor(with: dark).cgColor
        edge.layer.borderWidth = Surface.hairline(for: traitCollection)
    }

    /// The preview's size for a picture of `shape`: its longer side
    /// `longSide`, the media's own proportions.
    static func size(for shape: CGSize) -> CGSize {
        guard shape.width > 0, shape.height > 0 else { return CGSize(width: longSide, height: longSide) }
        let scale = longSide / max(shape.width, shape.height)
        return CGSize(width: (shape.width * scale).rounded(), height: (shape.height * scale).rounded())
    }

    /// The transform that lays the preview, at `frame`, over `target` — the
    /// same shape, so one scale, about its centre.
    static func transform(from frame: CGRect, onto target: CGRect) -> CGAffineTransform {
        guard frame.width > 0 else { return .identity }
        let scale = target.width / frame.width
        return CGAffineTransform(translationX: target.midX - frame.midX, y: target.midY - frame.midY)
            .scaledBy(x: scale, y: scale)
    }
}
