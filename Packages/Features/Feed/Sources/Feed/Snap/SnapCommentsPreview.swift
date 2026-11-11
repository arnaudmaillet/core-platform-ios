import DesignSystem
import UIKit

/// The post's media floating over the comments sheet once the sheet has
/// grown over it (#2087, the owner, 2026-11-03): in the media's own shape,
/// at the screen's top right under the sheet's bar, a clip playing on in it
/// (`SnapFeedCell.makeCommentsPreviewContent`).
///
/// It pops in at its corner as the shrunk media scales out above the rising
/// sheet — one picture at a time — and back (`SnapCommentsSheetSession`).
/// It drags, and
/// snaps to the corner it is thrown towards — the last one is where the next
/// preview opens — or is stashed off a side, a tab of it left showing (iOS's
/// picture in picture's ways).
@MainActor
final class SnapCommentsPreview: UIView {
    /// The preview's longer side, as a share of the screen's width; the other
    /// follows the media's shape. iOS's own picture in picture's (the owner,
    /// 2026-11-04: "the same size as Apple's"), measured on an iPhone 17 Pro
    /// Max: a 16:9 clip at 208 × 117 pt on a 440 pt wide screen.
    static let longSideShare: CGFloat = 208.0 / 440.0
    /// Its corners, iOS's picture in picture's too (~20 pt, the same capture).
    static let cornerRadius: CGFloat = 20
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

    /// The clip's stopped mark, in the middle, while it is paused.
    private let pausedMark = UIImageView()
    /// Puts the media back in place (the owner, 2026-11-03), at the bottom right (the owner, 2026-11-04).
    private let expandButton = UIButton(type: .system)

    /// A drag on the preview, its phases as the recogniser has them.
    var onPan: ((UIPanGestureRecognizer) -> Void)?
    /// A tap on the preview: the clip played or paused (the owner,
    /// 2026-11-03), a stashed preview brought out.
    var onTap: (() -> Void)?
    /// The expand button: the media back in place.
    var onExpand: (() -> Void)?

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
        pausedMark.image = AppSymbol.play.image()
        pausedMark.tintColor = .white
        pausedMark.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title2)
        pausedMark.layer.shadowColor = UIColor.black.cgColor
        pausedMark.layer.shadowOpacity = 0.5
        pausedMark.layer.shadowRadius = Spacing.xs
        pausedMark.layer.shadowOffset = .zero
        pausedMark.alpha = 0
        pausedMark.translatesAutoresizingMaskIntoConstraints = false
        clip.insertSubview(pausedMark, belowSubview: stashVeil)
        var expand = UIButton.Configuration.plain()
        expand.image = UIImage(systemName: "arrow.up.left.and.arrow.down.right")
        expand.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .caption1, scale: .medium)
        expand.baseForegroundColor = .white
        expand.background.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        expand.background.cornerRadius = Self.expandSide / 2
        expand.contentInsets = .zero
        expandButton.configuration = expand
        expandButton.accessibilityLabel = "Show the post"
        expandButton.addTarget(self, action: #selector(expandTapped), for: .touchUpInside)
        expandButton.translatesAutoresizingMaskIntoConstraints = false
        clip.insertSubview(expandButton, belowSubview: stashVeil)
        NSLayoutConstraint.activate([
            pausedMark.centerXAnchor.constraint(equalTo: clip.centerXAnchor),
            pausedMark.centerYAnchor.constraint(equalTo: clip.centerYAnchor),
            expandButton.bottomAnchor.constraint(equalTo: clip.bottomAnchor, constant: -(Spacing.xs + 2)),
            expandButton.trailingAnchor.constraint(equalTo: clip.trailingAnchor, constant: -(Spacing.xs + 2)),
            expandButton.widthAnchor.constraint(equalToConstant: Self.expandSide),
            expandButton.heightAnchor.constraint(equalToConstant: Self.expandSide),
        ])
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(panned(_:))))
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        isAccessibilityElement = false
        accessibilityElements = [expandButton]
    }

    /// The expand button's side; its touch reaches a little wider.
    private static let expandSide: CGFloat = 28

    /// A touch near the expand button is the button's: it is small, and the
    /// preview round it drags.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if !expandButton.isHidden, expandButton.alpha > 0,
           expandButton.convert(expandButton.bounds, to: self).insetBy(dx: -Spacing.sm, dy: -Spacing.sm).contains(point) {
            return expandButton
        }
        return super.hitTest(point, with: event)
    }

    /// The clip's stopped mark shown, or taken down.
    func showPaused(_ paused: Bool) {
        UIView.animate(withDuration: 0.2) { self.pausedMark.alpha = paused ? 1 : 0 }
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
        // Stashed, the tab only brings it out.
        expandButton.alpha = leading == nil ? 1 : 0
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) { onPan?(pan) }
    @objc private func tapped() { onTap?() }
    @objc private func expandTapped() { onExpand?() }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    #if DEBUG
    /// The paused clip's mark (the owner's play, #2276).
    var debugPausedMarkImage: UIImage? { pausedMark.image }
    #endif

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        drawEdge()
    }

    /// The shadow's outline, given: without one, Core Animation renders the
    /// preview offscreen every frame to find it (measured on a device,
    /// 2026-11-03).
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: Self.cornerRadius).cgPath
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

    /// The preview's size for a picture of `shape` on a screen `screenWidth`
    /// wide: its longer side `longSideShare` of it, the media's own
    /// proportions.
    static func size(for shape: CGSize, screenWidth: CGFloat) -> CGSize {
        let longSide = (screenWidth * longSideShare).rounded()
        guard shape.width > 0, shape.height > 0 else { return CGSize(width: longSide, height: longSide) }
        let scale = longSide / max(shape.width, shape.height)
        return CGSize(width: (shape.width * scale).rounded(), height: (shape.height * scale).rounded())
    }
}
