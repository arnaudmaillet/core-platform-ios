import CoreNavigation
import DesignSystem
import UIKit

/// The inbox's category header: a floating Liquid Glass capsule under the
/// navigation bar, with a lens that slides between segments.
///
/// **Anatomy.** A content-hugging capsule of `.systemUltraThinMaterial`, its
/// own soft shadow, and one `UIGlassEffect` lens marking the active segment.
/// The capsule floats — it does not span the width and it has no hairline —
/// so the lists scroll *beneath* it and are seen through the material. Both
/// materials are semantic, so light and dark come free.
///
/// **Why two materials here, when the house rule says one.** The rule
/// `GlassSegmentRow` documents is about putting a material inside a material
/// the *system* already supplies (a toolbar item's capsule). Here we own both
/// layers deliberately: a bar-like backdrop and a lens moving across it, which
/// is the Telegram/iOS-26 segmented idiom. Nothing else in the bar carries a
/// material — segments are text only.
///
/// **Tracking.** `setProgress` takes the pager's *fractional* page position
/// and interpolates the lens's frame between the two neighbouring segments
/// while crossfading each segment's regular/semibold label pair. Nothing
/// snaps: a tap animates the pager, which reports progress every frame, so
/// taps and swipes drive the header through exactly the same path. The label
/// pair exists so selection can change weight without re-measuring — segment
/// widths are pinned to their SEMIBOLD size up front, the reflow trap
/// `GlassSegmentRow` calls out.
///
/// The lens tracks progress LINEARLY and rigidly. A spring-driven elastic
/// variant (stretch on velocity, squash on settle) was built and rejected —
/// see [[messages-inbox-paged]]; if it is ever revisited, note that the lens
/// must still be driven by its `frame`, never a `CGAffineTransform`, which
/// scales the rendered corner radius and turns the capsule into an ellipse.
final class InboxCategoryBar: UIView {
    private enum Metrics {
        /// The floating capsule's own height.
        static let capsuleHeight: CGFloat = 42
        static let topMargin: CGFloat = 4
        static let bottomMargin: CGFloat = 8
        /// Breathing room between the capsule's edge and the first segment.
        static let capsulePadding: CGFloat = 5
        /// Inset of the lens inside the capsule.
        static let lensInset: CGFloat = 4
        static let interSegmentSpacing: CGFloat = 2
    }

    /// Total height the container reserves as safe area, margins included.
    static let height: CGFloat = Metrics.capsuleHeight + Metrics.topMargin + Metrics.bottomMargin

    /// A segment was tapped. Swipes report through the pager, not here.
    var onSelect: ((Int) -> Void)?

    private let categories: [MessagesCategory]
    /// Carries the shadow; the capsule itself clips to its corner radius,
    /// which would clip a shadow set on the same layer.
    private let shadowHost = UIView()
    private let capsule = UIVisualEffectView(effect: nil)
    private let lens = UIVisualEffectView(effect: nil)
    private let row = UIStackView()
    private var segments: [SegmentView] = []
    private var progress: CGFloat = 0

    init(categories: [MessagesCategory]) {
        self.categories = categories
        super.init(frame: .zero)

        shadowHost.layer.shadowColor = UIColor.black.cgColor
        shadowHost.layer.shadowOpacity = 0.12
        shadowHost.layer.shadowRadius = 10
        shadowHost.layer.shadowOffset = CGSize(width: 0, height: 3)
        shadowHost.constrain(in: self) { parent in
            shadowHost.topAnchor.constraint(equalTo: parent.topAnchor, constant: Metrics.topMargin)
            shadowHost.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -Metrics.bottomMargin)
            shadowHost.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            shadowHost.leadingAnchor.constraint(greaterThanOrEqualTo: parent.leadingAnchor, constant: Spacing.lg)
        }

        capsule.clipsToBounds = true
        capsule.pin(to: shadowHost)

        // The lens goes in before the row so it sits behind the labels; it is
        // frame-driven (not constrained) because it has to land on fractional
        // positions between two segments every frame.
        capsule.contentView.addSubview(lens)
        lens.clipsToBounds = true
        lens.isUserInteractionEnabled = false

        row.axis = .horizontal
        row.spacing = Metrics.interSegmentSpacing
        row.alignment = .fill
        segments = categories.enumerated().map { index, category in
            let segment = SegmentView(title: category.title)
            segment.addAction(
                UIAction { [weak self] _ in self?.onSelect?(index) },
                // NOT `.primaryActionTriggered`: only UIButton synthesizes
                // that. A bare UIControl sends touch events, so a segment
                // registered for the primary action never fires at all.
                for: .touchUpInside
            )
            row.addArrangedSubview(segment)
            return segment
        }
        row.constrain(in: capsule.contentView) { parent in
            row.topAnchor.constraint(equalTo: parent.topAnchor)
            row.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
            row.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: Metrics.capsulePadding)
            row.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -Metrics.capsulePadding)
        }

        // The whole capsule reads as one tab bar to VoiceOver; each segment is
        // a button reporting its own selected state.
        accessibilityContainerType = .semanticGroup
        row.accessibilityTraits = .tabBar

        applyProgress()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.height)
    }

    /// Materialized in-window, never in init: creating a real effect off
    /// screen stalls the render server on headless CI simulators (the same
    /// rule `ChatInputBar` and `SnapGlassCardView` follow).
    private func materializeEffects() {
        guard window != nil else { return }
        if capsule.effect == nil {
            capsule.effect = UIBlurEffect(style: .systemUltraThinMaterial)
        }
        if lens.effect == nil {
            let glass = UIGlassEffect()
            glass.isInteractive = true
            lens.effect = glass
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        capsule.layer.cornerRadius = capsule.bounds.height / 2
        capsule.layer.cornerCurve = .continuous
        shadowHost.layer.shadowPath = UIBezierPath(
            roundedRect: shadowHost.bounds,
            cornerRadius: shadowHost.bounds.height / 2
        ).cgPath
        applyProgress()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        materializeEffects()
    }

    // MARK: - Driven state

    /// The pager's fractional page position. Called every frame of a drag and
    /// every frame of a tap-driven scroll animation.
    func setProgress(_ progress: CGFloat) {
        guard progress != self.progress else { return }
        self.progress = progress
        applyProgress()
    }

    func setBadge(_ count: Int, for category: MessagesCategory) {
        guard let index = categories.firstIndex(of: category) else { return }
        segments[index].setBadge(count)
        // A badge changes the segment's pinned width, so the lens has to
        // re-derive its geometry from the new frames.
        setNeedsLayout()
        layoutIfNeeded()
        applyProgress()
    }

    // MARK: - Interpolation

    private func applyProgress() {
        guard !segments.isEmpty, row.bounds.width > 0, row.bounds.height > 0 else { return }
        let clamped = min(max(progress, 0), CGFloat(segments.count - 1))
        let lower = Int(clamped.rounded(.down))
        let upper = min(lower + 1, segments.count - 1)
        let t = clamped - CGFloat(lower)

        // Weight/tint crossfade: each segment is fully "selected" at its own
        // index and fully plain a page away, so a half-way drag shows both
        // neighbours at half strength — the same readout as the lens's frame.
        for (index, segment) in segments.enumerated() {
            segment.setSelectionStrength(max(0, 1 - abs(clamped - CGFloat(index))))
        }

        let from = lensFrame(for: lower)
        let to = lensFrame(for: upper)
        lens.frame = CGRect(
            x: from.minX + (to.minX - from.minX) * t,
            y: from.minY,
            width: from.width + (to.width - from.width) * t,
            height: from.height
        )
        lens.layer.cornerRadius = lens.bounds.height / 2
        lens.layer.cornerCurve = .continuous
    }

    /// Built by hand rather than with `insetBy`: insetting a rect past its own
    /// size yields `CGRect.null`, whose infinite origin turns the frame
    /// interpolation into NaN and takes CALayer down with it. Segments start
    /// at zero height, so that path is not hypothetical.
    private func lensFrame(for index: Int) -> CGRect {
        let segment = segments[index].frame
        return CGRect(
            x: row.frame.minX + segment.minX,
            y: row.frame.minY + segment.minY + Metrics.lensInset,
            width: segment.width,
            height: max(0, segment.height - Metrics.lensInset * 2)
        )
    }

}

// MARK: - Segment

/// One category segment: a stacked pair of labels (regular and semibold) that
/// crossfade, plus an optional count badge. Its width is pinned to the
/// SEMIBOLD measurement so selection can never reflow the row.
private final class SegmentView: UIControl {
    private let plainLabel = UILabel()
    private let boldLabel = UILabel()
    private let badge = BadgeView()
    private let content = UIStackView()
    private let title: String
    private var pinnedWidth: NSLayoutConstraint!

    init(title: String) {
        self.title = title
        super.init(frame: .zero)

        for (label, weight) in [(plainLabel, UIFont.Weight.regular), (boldLabel, .semibold)] {
            label.text = title
            label.font = .preferredFont(forTextStyle: .subheadline, weight: weight)
            label.adjustsFontForContentSizeCategory = true
            label.textAlignment = .center
            label.isUserInteractionEnabled = false
        }
        plainLabel.textColor = .secondaryLabel
        boldLabel.textColor = .label
        boldLabel.alpha = 0

        // The SEMIBOLD label defines the geometry (it is the wider of the
        // pair); the regular one is centred on top of it and only ever
        // crossfades, so neither weight can move the other's layout.
        content.addArrangedSubview(boldLabel)
        content.addArrangedSubview(badge)
        content.axis = .horizontal
        content.alignment = .center
        content.spacing = Spacing.xs
        content.isUserInteractionEnabled = false
        content.constrain(in: self) { parent in
            content.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            content.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }
        plainLabel.constrain(in: self) { _ in
            plainLabel.centerXAnchor.constraint(equalTo: boldLabel.centerXAnchor)
            plainLabel.centerYAnchor.constraint(equalTo: boldLabel.centerYAnchor)
        }

        badge.isHidden = true
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityTraits = .button

        pinnedWidth = widthAnchor.constraint(equalToConstant: 0)
        pinnedWidth.isActive = true
        updatePinnedWidth()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentSizeCategoryChanged),
            name: UIContentSizeCategory.didChangeNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Pressed feedback lives on the CONTENT, never on the lens — the lens
    /// belongs to the selection, not to the touch.
    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            UIView.animate(withDuration: 0.12, delay: 0, options: [.beginFromCurrentState]) {
                self.content.alpha = self.isHighlighted ? 0.55 : 1
                self.plainLabel.alpha = self.isHighlighted ? 0.55 * (1 - self.strength) : (1 - self.strength)
            }
        }
    }

    private var strength: CGFloat = 0

    /// 1 = fully selected, 0 = fully unselected, fractions mid-drag.
    func setSelectionStrength(_ strength: CGFloat) {
        self.strength = strength
        boldLabel.alpha = strength
        plainLabel.alpha = 1 - strength
        badge.setSelectionStrength(strength)
        let selected = strength > 0.5
        if selected != accessibilityTraits.contains(.selected) {
            accessibilityTraits = selected ? [.button, .selected] : [.button]
        }
    }

    func setBadge(_ count: Int) {
        badge.setCount(count)
        badge.isHidden = count == 0
        updatePinnedWidth()
    }

    @objc private func contentSizeCategoryChanged() {
        updatePinnedWidth()
    }

    /// Width = the semibold title plus the badge (when shown) plus breathing
    /// room, so the lens has somewhere to sit and the row never reflows.
    private func updatePinnedWidth() {
        let bold = UIFont.preferredFont(forTextStyle: .subheadline, weight: .semibold)
        var width = ceil((title as NSString).size(withAttributes: [.font: bold]).width) + Spacing.lg
        if !badge.isHidden {
            width += badge.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width + Spacing.xs
        }
        pinnedWidth.constant = width
    }
}

// MARK: - Badge

/// The pending count beside a segment title: a filled capsule that follows the
/// segment's own selection strength, so it brightens with its label.
private final class BadgeView: UIView {
    private let label = UILabel()

    init() {
        super.init(frame: .zero)
        label.font = .preferredFont(forTextStyle: .caption2, weight: .semibold)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .systemBackground
        label.textAlignment = .center
        label.pin(to: self, insets: NSDirectionalEdgeInsets(top: 2, leading: 5, bottom: 2, trailing: 5))
        backgroundColor = .secondaryLabel
        layer.cornerCurve = .continuous
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }

    func setCount(_ count: Int) {
        // Past 99 the capsule would out-measure its own segment title.
        label.text = count > 99 ? "99+" : String(count)
        invalidateIntrinsicContentSize()
    }

    func setSelectionStrength(_ strength: CGFloat) {
        backgroundColor = strength > 0.5 ? .label : .secondaryLabel
    }
}

private extension UIFont {
    static func preferredFont(forTextStyle style: TextStyle, weight: Weight) -> UIFont {
        let metrics = UIFontMetrics(forTextStyle: style)
        let base = UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: style).pointSize, weight: weight)
        return metrics.scaledFont(for: base)
    }
}
