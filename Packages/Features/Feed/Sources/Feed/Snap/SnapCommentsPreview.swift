import DesignSystem
import UIKit

/// The post's media floating over the comments sheet once the sheet has
/// grown over it (#2087, the owner, 2026-11-03): in the media's own shape,
/// at the screen's top right under the sheet's bar, a clip playing on in it
/// (`SnapFeedCell.makeCommentsPreviewContent`).
///
/// It does not appear: the shrunk media flies into it from where it stood
/// above the sheet, and back (`SnapCommentsSheetSession`). It drags, and
/// snaps to the corner it is thrown towards — the last one is where the next
/// preview opens — or is stashed off a side, a tab of it left showing (iOS's
/// picture in picture's ways).
@MainActor
final class SnapCommentsPreview: UIView {
    /// The preview's longer side; the other follows the media's shape.
    static let longSide: CGFloat = 168
    static let cornerRadius: CGFloat = Spacing.md
    /// What of a stashed preview stays on the screen.
    static let stashedTab: CGFloat = Spacing.xl

    enum Corner: String {
        case topLeading, topTrailing, bottomLeading, bottomTrailing

        var isTop: Bool { self == .topLeading || self == .topTrailing }
        var isLeading: Bool { self == .topLeading || self == .bottomLeading }

        static func at(top: Bool, leading: Bool) -> Corner {
            switch (top, leading) {
            case (true, true): .topLeading
            case (true, false): .topTrailing
            case (false, true): .bottomLeading
            case (false, false): .bottomTrailing
            }
        }
    }

    /// The corner the last preview was left in (the owner, 2026-11-03: the
    /// next one opens there), the top right before any.
    static var lastCorner: Corner {
        get {
            UserDefaults.standard.string(forKey: lastCornerKey).flatMap(Corner.init(rawValue:)) ?? .topTrailing
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: lastCornerKey) }
    }
    private static let lastCornerKey = "feed.comments.preview.corner"

    let content: UIView
    private let clip = UIView()
    private let edge = UIView()
    /// Over a stashed preview: a veil, and a chevron pointing back in.
    private let stashVeil = UIView()
    private let stashChevron = UIImageView()

    /// A drag on the preview, its phases as the recogniser has them.
    var onPan: ((UIPanGestureRecognizer) -> Void)?
    /// A tap on the preview.
    var onTap: (() -> Void)?

    init(content: UIView) {
        self.content = content
        super.init(frame: .zero)
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
        stashVeil.isUserInteractionEnabled = false
        stashVeil.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        stashVeil.alpha = 0
        clip.addSubview(stashVeil)
        stashVeil.pin(to: clip)
        stashChevron.tintColor = .white
        stashChevron.contentMode = .center
        stashChevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .headline)
        stashChevron.translatesAutoresizingMaskIntoConstraints = false
        stashVeil.addSubview(stashChevron)
        stashChevronLeading = stashChevron.leadingAnchor.constraint(equalTo: stashVeil.leadingAnchor)
        stashChevronTrailing = stashChevron.trailingAnchor.constraint(equalTo: stashVeil.trailingAnchor)
        NSLayoutConstraint.activate([
            stashChevron.centerYAnchor.constraint(equalTo: stashVeil.centerYAnchor),
            stashChevron.widthAnchor.constraint(equalToConstant: Self.stashedTab),
        ])
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(panned(_:))))
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    private var stashChevronLeading: NSLayoutConstraint?
    private var stashChevronTrailing: NSLayoutConstraint?

    /// The veil and the chevron of a preview stashed off `side`'s edge
    /// (leading: true for the left), or none: nil.
    func showStash(leading: Bool?) {
        if let leading {
            stashChevron.image = UIImage(systemName: leading ? "chevron.right" : "chevron.left")
            // The chevron in the tab left on the screen.
            // The one let go first: both at once would fight the width.
            (leading ? stashChevronLeading : stashChevronTrailing)?.isActive = false
            (leading ? stashChevronTrailing : stashChevronLeading)?.isActive = true
        }
        stashVeil.alpha = leading == nil ? 0 : 1
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) { onPan?(pan) }
    @objc private func tapped() { onTap?() }

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
