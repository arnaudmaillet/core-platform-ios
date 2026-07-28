import CoreNavigation
import DesignSystem
import UIKit

/// The inbox's category header: a floating Liquid Glass capsule under the
/// navigation bar, with a lens that slides between segments.
///
/// **Anatomy.** A content-hugging capsule of `UIGlassEffect`, its own soft
/// shadow, and a tinted overlay marking the active segment. The capsule floats
/// — it has no hairline, and it spans the width only if its segments demand it
/// — so the lists scroll *beneath* it and are seen through the glass.
///
/// **ONE material, not two.** The lens is a plain tinted `UIView`
/// (`label` at 18% — a darkening in light mode, a lightening in dark), NOT a
/// second `UIVisualEffectView`. That is the whole trick: an earlier build put a
/// glass lens inside a glass capsule and the lens lost its edge entirely — the
/// selected segment stopped reading as selected, which is the one thing this
/// control exists to say. A tint has nothing to refract, so it separates
/// cleanly from the glass behind it at any position. It also honours the house
/// rule `GlassSegmentRow` documents, which the old blur-plus-glass pairing had
/// to argue its way around.
///
/// `UIGlassContainerEffect` is NOT the backdrop to reach for: it is a
/// *grouping* effect for sibling glass elements that should merge, and used as
/// the capsule's own effect it renders no backdrop whatsoever — message
/// previews behind the bar collide with the segment titles at full contrast.
///
/// ⚠️ **Semantic colours do not survive inside the glass content view.** The
/// badge's `.systemBackground` text resolved to WHITE in dark mode, on a badge
/// whose fill had correctly resolved to white — an invisible count, on a
/// control whose whole job is to show counts. `BadgeView` therefore states its
/// text colour as an explicit dynamic colour. Anything added inside this
/// capsule needs checking in BOTH appearances, not reasoned about.
///
/// **Overflow.** The segments live in a scroll view. Below the capsule's width
/// ceiling it never scrolls and is inert in every sense; past it — a fourth
/// category, a three-digit badge, a large Dynamic Type size — the capsule stops
/// growing and the strip scrolls, with the active segment kept in view. The
/// margin was thin without it: three segments with two badges need 331pt of the
/// 343pt a 375pt screen offers at XL text.
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
    /// Scrolls the segments when they out-measure the capsule's ceiling. Below
    /// that width it never scrolls and is invisible in every sense — the
    /// capsule still hugs its content and still floats centred.
    private let scroller = UIScrollView()
    /// The scroll view's content: the lens and the row, in one coordinate
    /// space. The lens lives HERE rather than in the capsule so it travels with
    /// the segments for free — a lens pinned outside would need the content
    /// offset subtracted out of it on every frame of both gestures.
    private let content = UIView()
    /// The active-segment marker. A tinted overlay, NOT a second material —
    /// see the type comment on why glass-inside-glass cost the lens its edge.
    private let lens = UIView()
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
            // The ceiling. Below it the capsule hugs its content (the `equalTo`
            // below, one priority step down); at it the capsule stops growing
            // and the scroll view starts earning its keep.
            shadowHost.widthAnchor.constraint(
                lessThanOrEqualTo: parent.widthAnchor, constant: -Spacing.lg * 2
            )
        }

        capsule.clipsToBounds = true
        capsule.pin(to: shadowHost)

        scroller.showsHorizontalScrollIndicator = false
        scroller.showsVerticalScrollIndicator = false
        // Segments are buttons: without this the scroll view swallows the first
        // touch and a tap only registers after a perceptible delay.
        scroller.delaysContentTouches = false
        scroller.pin(to: capsule.contentView)

        content.constrain(in: scroller) { _ in
            content.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor)
            content.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor)
            content.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor)
            content.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor)
            // The scroll view has no intrinsic size, so the content's height is
            // tied to the frame — this axis must never scroll.
            content.heightAnchor.constraint(equalTo: scroller.frameLayoutGuide.heightAnchor)
        }

        // The lens goes in before the row so it sits behind the labels; it is
        // frame-driven (not constrained) because it has to land on fractional
        // positions between two segments every frame.
        content.addSubview(lens)
        lens.clipsToBounds = true
        lens.isUserInteractionEnabled = false
        lens.backgroundColor = Self.lensTint

        row.axis = .horizontal
        row.spacing = Metrics.interSegmentSpacing
        row.alignment = .fill
        buildSegments()
        row.constrain(in: content) { parent in
            row.topAnchor.constraint(equalTo: parent.topAnchor)
            row.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
            row.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: Metrics.capsulePadding)
            row.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -Metrics.capsulePadding)
        }

        // Hugging, one step below required: the capsule matches its content
        // until the ceiling above forbids it, and then this yields rather than
        // conflicting. This pair IS the "hug until you can't, then scroll"
        // behaviour — there is no code path for it, only these two constraints.
        let hug = shadowHost.widthAnchor.constraint(equalTo: content.widthAnchor)
        hug.priority = .required - 1
        hug.isActive = true

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
            capsule.effect = UIGlassEffect(style: .regular)
        }
    }

    /// The active segment's fill. Adaptive by construction: `label` is near
    /// black in light mode and near white in dark, so one constant reads as a
    /// darkening in one and a lightening in the other, over a backdrop that is
    /// itself taking its cue from the content behind it.
    ///
    /// 0.18 rather than 0.12, chosen by comparison over scrolled list rows —
    /// which is the hard case, because the glass backdrop passes more of the
    /// content through than the thin material did. At 0.12 the pill reads as
    /// soft shading; at 0.18 it is unambiguous and still subtle.
    /// `.quaternarySystemFill` was fainter than either and was discarded.
    private static let lensTint = UIColor.label.withAlphaComponent(0.18)

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

    private func buildSegments() {
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
        keepLensVisible()
    }

    /// Follows the lens with the scroll offset when the row is wider than the
    /// capsule — the "active tab scrolls itself into view" half of the pattern.
    ///
    /// `scrollRectToVisible` unanimated is exactly right here: it scrolls the
    /// MINIMUM distance needed and no-ops when the rect is already visible, so
    /// the bar sits still through the middle of a drag and only creeps at the
    /// ends. Animating instead would queue a 0.3s animation on every one of the
    /// ~18 frames a page change emits, and they would fight each other.
    ///
    /// Skipped while the viewer is scrolling the bar by hand — otherwise their
    /// own drag would be yanked back to the selection under their finger.
    private func keepLensVisible() {
        guard scroller.contentSize.width > scroller.bounds.width,
              !scroller.isDragging, !scroller.isDecelerating
        else { return }
        scroller.scrollRectToVisible(
            lens.frame.insetBy(dx: -Metrics.capsulePadding, dy: 0), animated: false
        )
    }

    /// Built by hand rather than with `insetBy`: insetting a rect past its own
    /// size yields `CGRect.null`, whose infinite origin turns the frame
    /// interpolation into NaN and takes CALayer down with it. Segments start
    /// at zero height, so that path is not hypothetical.
    ///
    /// Coordinates are the SCROLL CONTENT's, not the capsule's — `row.frame` is
    /// already expressed in `content`, and the lens is a sibling there, so the
    /// arithmetic is unchanged by the scroll view and no content offset has to
    /// be subtracted anywhere.
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
    /// Titles scale with Dynamic Type up to here, then stop — four segments
    /// have to stay side by side in one fixed-height capsule.
    static let maximumTitlePointSize: CGFloat = 19

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
            label.font = .preferredFont(forTextStyle: .subheadline, weight: weight, maximumPointSize: SegmentView.maximumTitlePointSize)
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
        let bold = UIFont.preferredFont(forTextStyle: .subheadline, weight: .semibold, maximumPointSize: Self.maximumTitlePointSize)
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
        label.font = .preferredFont(forTextStyle: .caption2, weight: .semibold, maximumPointSize: 15)
        label.adjustsFontForContentSizeCategory = true
        // `.systemBackground` does NOT survive inside a `UIGlassEffect` content
        // view — it resolved to white in dark mode, on a badge whose fill had
        // correctly resolved to white, erasing the count. An explicit dynamic
        // colour carries the same intent (the inverse of `.label`) in values
        // the effect can't reinterpret.
        label.textColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 0.06, alpha: 1)
                : UIColor(white: 1, alpha: 1)
        }
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
    /// Scales with Dynamic Type but stops growing past `maximumPointSize`.
    ///
    /// The capsule is fixed chrome holding up to four segments side by side —
    /// at accessibility sizes unbounded scaling makes the titles collide and
    /// clip off the edge. Capping is what the system itself does for tab bar
    /// item titles: the row stays legible and stays a row.
    static func preferredFont(
        forTextStyle style: TextStyle,
        weight: Weight,
        maximumPointSize: CGFloat
    ) -> UIFont {
        let metrics = UIFontMetrics(forTextStyle: style)
        let base = UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: style).pointSize, weight: weight)
        return metrics.scaledFont(for: base, maximumPointSize: maximumPointSize)
    }
}
