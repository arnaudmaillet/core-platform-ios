import UIKit

/// THE section title — every section of the app wears this one view, in the
/// flow or inside the pinned glass capsule (`SectionHeaderPillButton`).
///
/// ```
///   │←20→Following 3 ›                          (a link: the whole bar opens)
///   │←20→Recent                                 (a heading: nothing to tap)
///   │←20→Active stakes              ◆ 40 at stake   (a trailing accessory)
/// ```
///
/// **One object, identical everywhere (asked for, 2026-09-30).** Before it,
/// seven surfaces drew their titles seven ways: a red count pill on For You's
/// rows and its pushed lists, a bare chevron on the sound sheet, a list
/// header on the notifications drawer, `Unlocked · 3` in the shop's grouped
/// headers, a 17pt title in the wallet… and each started its title at its own
/// content edge — 8pt on the sound sheet, 16 on For You, the list's margin in
/// the inbox. This view owns the type, the colours, the gaps and the inset;
/// a host owns only where the bar goes and what it says.
///
/// - **The title**: title3, bold, `.label` — the size a heading needs to read
///   as the head of what follows rather than one more row of it.
/// - **The count** (optional): PLAIN TEXT right after the title, in the
///   secondary colour, the chevron's (`Following 3 ›`). The red pill it
///   replaces said "notification", which a section is not; grey says "how
///   many", and keeps the title the word the eye reads.
/// - **The chevron** (a link only): `›` in that same secondary colour, a
///   notch smaller than the title — the platform's "this pushes a screen".
/// - **The gaps** (`Metrics`): a word space after the title, and a tighter
///   one between the count and the chevron, so `3 ›` reads as one secondary
///   token — the relation the pill had with the chevron (2026-09-30: "the
///   count belongs to the chevron").
///
/// ⚠️ **THE INSET IS MEASURED FROM THE SURFACE, NOT FROM THE HOST** (the
/// fix for "titles stuck to the left"). A host lays the bar wherever its
/// layout puts headers — edge to edge in a table, inside a section's content
/// insets in a compositional layout, inside an inset-grouped list's margins —
/// and the title still stands `Metrics.surfaceInset` in from the edge of the
/// scrolling surface it belongs to (`surfaceInsets(of:)`). One number,
/// whatever the host's own geometry: which is the only way "identical
/// everywhere" survives seven different layouts.
///
/// ⚠️ **A TAP RECOGNISER, NOT A `UIControl`** (both halves were bugs,
/// 2026-09-29, when this was `SectionLinkHeaderView`):
/// - a plain `UIControl` never sends `.primaryActionTriggered` (only its
///   subclasses do) — #312's header answered nothing on device while its
///   tests, calling the host's closure, passed;
/// - the bar lives in scroll views, and a scroll view does not cancel a
///   touch a control is tracking — a scroll that began on a held header
///   belonged to the header. A tap recogniser fails as soon as the finger
///   travels, and the scroll keeps the touch.
/// And no press feedback: the product call is that a heading gives none.
///
/// The WHOLE bar is the target of a link, not the 20pt chevron: a row of
/// content under a heading reads "tap the heading to see all of it", and a
/// glyph is a target nobody should have to aim for.
@MainActor
public final class SectionTitleView: UIView {
    /// The two sizes a title comes in.
    public enum Style: Equatable, Sendable {
        /// In the flow: title3 bold. Every section title the viewer reads.
        case standard
        /// The pinned glass capsule's (`SectionHeaderPillButton`): subheadline
        /// semibold — chrome floating over rows, not a title introducing them.
        case compact
    }

    /// What a title says.
    public struct Content: Equatable, Sendable {
        public var title: String?
        /// The secondary text after the title; nil draws none.
        public var count: String?
        /// What VoiceOver says for the count ("3 new"); the count itself when
        /// nil.
        public var countAccessibilityValue: String?
        /// A way in: a chevron, the whole bar a button.
        public var isLink: Bool

        public init(
            title: String?, count: String? = nil, countAccessibilityValue: String? = nil, isLink: Bool = false
        ) {
            self.title = title
            let count = count.flatMap { $0.isEmpty ? nil : $0 }
            self.count = count
            self.countAccessibilityValue = count == nil ? nil : (countAccessibilityValue ?? count)
            self.isLink = isLink
        }

        /// A count of what is NEW — zero (or less) draws none, since "nothing
        /// new" is said by the absence of a number, never by a "0".
        public init(title: String?, newCount: Int, isLink: Bool = false) {
            let shown = newCount > 0 ? newCount.formatted() : nil
            self.init(
                title: title, count: shown,
                countAccessibilityValue: shown == nil ? nil : "\(newCount) new",
                isLink: isLink
            )
        }
    }

    public enum Metrics {
        /// From the surface's leading edge (the screen's, or a sheet's) to the
        /// title's first letter: 20pt, EVERY surface.
        ///
        /// Why 20: it is where Apple's own shelf titles start on an iPhone
        /// (App Store, Music, Podcasts), and it stands every title just INSIDE
        /// its content: 4pt in from For You's 16pt cards — whose 26pt corners
        /// curve the card's visible edge away from its frame, so a title on
        /// the frame line read as hanging out past the card (the "stuck to
        /// the left" of 2026-09-30) — 12 in from the sound sheet's 8pt tiles,
        /// on the inbox rows' own margin. Never outside the content, never
        /// further in than the text a card holds (16 + 12 inner padding).
        public static let surfaceInset: CGFloat = 20
        /// The bar at the default text size — a title3 line with
        /// `Spacing.sectionTitle` above and below, and a tap target at the
        /// 44pt minimum (`barHeight(traits:)` at other sizes).
        public static let height: CGFloat = 44
        /// Title → count: a word space at title3.
        public static let titleToCount: CGFloat = 6
        /// Count → chevron: tighter, so `3 ›` reads as one secondary token.
        public static let countToChevron: CGFloat = Spacing.xs
        /// Title → chevron with no count between them: the same word space.
        public static let titleToChevron: CGFloat = 6
        /// The run → a trailing accessory, at the least.
        public static let accessoryGap: CGFloat = Spacing.sm
        /// The chevron's size against the title's: 15pt beside a 20pt title.
        static let chevronScale: CGFloat = 0.75
    }

    // MARK: - Vertical rhythm

    /// The traits every static metric defaults to: the default text size.
    nonisolated public static let defaultTraits = UITraitCollection(preferredContentSizeCategory: .large)

    /// The bar's height at `traits`' text size: the title's line with
    /// `Spacing.sectionTitle` above and under it, never under 44pt.
    nonisolated public static func barHeight(traits: UITraitCollection = defaultTraits) -> CGFloat {
        Spacing.sectionTitleBarHeight(lineHeight: titleFont(.standard, traits: traits).lineHeight)
    }

    /// The space a host leaves ABOVE the bar when it follows another section:
    /// `Spacing.section` from that section's foot to the title's line, the
    /// bar's own air (it centres the title) counted in.
    nonisolated public static func gapAbove(traits: UITraitCollection = defaultTraits) -> CGFloat {
        Spacing.sectionGap(
            aboveTitleBar: barHeight(traits: traits), lineHeight: titleFont(.standard, traits: traits).lineHeight
        )
    }

    /// The space a host leaves UNDER the bar before the section's content:
    /// what `Spacing.sectionTitle` asks beyond the air the bar already holds
    /// under its line — none, since the bar is sized to hold exactly that.
    nonisolated public static func gapBelow(traits: UITraitCollection = defaultTraits) -> CGFloat {
        let air = (barHeight(traits: traits) - titleFont(.standard, traits: traits).lineHeight) / 2
        return max(0, (Spacing.sectionTitle - air).rounded())
    }

    /// The title's font in `style` at `traits`' text size.
    nonisolated public static func titleFont(_ style: Style, traits: UITraitCollection) -> UIFont {
        switch style {
        case .standard: .preferredFont(forTextStyle: .title3, compatibleWith: traits).withWeight(.bold)
        case .compact: .preferredFont(forTextStyle: .subheadline, compatibleWith: traits).withWeight(.semibold)
        }
    }

    // MARK: - Surface

    /// How far in from ITS OWN edges a view must start and end its content for
    /// that content to stand `Metrics.surfaceInset` in from the edges of the
    /// surface it scrolls on — the nearest scroll view up its ancestry, else
    /// its window. A view not yet on a surface is assumed edge to edge.
    public static func surfaceInsets(of view: UIView) -> (leading: CGFloat, trailing: CGFloat) {
        guard let surface = surface(of: view) else {
            return (Metrics.surfaceInset, Metrics.surfaceInset)
        }
        let frame = view.convert(view.bounds, to: surface)
        // The surface's VISIBLE frame: a scroll view's bounds origin is its
        // offset.
        let visible = surface.bounds
        var leading = Metrics.surfaceInset - (frame.minX - visible.minX)
        var trailing = Metrics.surfaceInset - (visible.maxX - frame.maxX)
        if view.effectiveUserInterfaceLayoutDirection == .rightToLeft { swap(&leading, &trailing) }
        return (max(0, leading.rounded()), max(0, trailing.rounded()))
    }

    /// The surface a view's title is inset from: the nearest scroll view up
    /// its ancestry, else its window.
    static func surface(of view: UIView) -> UIView? {
        var ancestor = view.superview
        while let current = ancestor {
            if current is UIScrollView { return current }
            ancestor = current.superview
        }
        return view.window
    }

    // MARK: - State

    public var content: Content {
        didSet {
            guard content != oldValue else { return }
            applyContent()
        }
    }

    public var style: Style {
        didSet {
            guard style != oldValue else { return }
            applyFonts()
        }
    }

    /// The bar was tapped. Only ever called on a link.
    public var onTap: (() -> Void)?

    /// A view at the bar's trailing end — the explore screen's "Clear all",
    /// the wallet's totals. The title's run gives way to it, never the
    /// reverse.
    public var trailingAccessory: UIView? {
        didSet {
            guard trailingAccessory !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let trailingAccessory { addSubview(trailingAccessory) }
            applyInteraction()
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    /// Inside a host that is itself the control and the accessibility element
    /// — the pinned capsule — the title is drawing only: no inset of its own,
    /// no touches, nothing for VoiceOver.
    let isEmbedded: Bool

    private let titleLabel = UILabel()
    private let countLabel = UILabel()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
    private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
    /// The title run as ONE element beside an interactive accessory, which a
    /// single-element bar would swallow.
    private lazy var runElement = RunAccessibilityElement(accessibilityContainer: self)

    public init(content: Content = Content(title: nil), style: Style = .standard) {
        self.content = content
        self.style = style
        self.isEmbedded = false
        super.init(frame: .zero)
        commonInit()
    }

    init(embeddedStyle style: Style) {
        self.content = Content(title: nil)
        self.style = style
        self.isEmbedded = true
        super.init(frame: .zero)
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func commonInit() {
        titleLabel.textColor = .label
        titleLabel.lineBreakMode = .byTruncatingTail
        countLabel.textColor = .secondaryLabel
        chevron.tintColor = .secondaryLabel
        chevron.contentMode = .center
        for view in [titleLabel, countLabel, chevron] as [UIView] { addSubview(view) }
        addGestureRecognizer(tap)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: SectionTitleView, _) in
            view.applyFonts()
        }
        applyFonts()
        applyContent()
    }

    // MARK: - Applying

    private func applyFonts() {
        let font = Self.titleFont(style, traits: traitCollection)
        titleLabel.font = font
        countLabel.font = font
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            font: .systemFont(ofSize: (font.pointSize * Metrics.chevronScale).rounded(), weight: .semibold)
        )
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func applyContent() {
        titleLabel.text = content.title
        countLabel.text = content.count
        countLabel.isHidden = content.count == nil
        chevron.isHidden = !content.isLink
        applyInteraction()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func applyInteraction() {
        tap.isEnabled = content.isLink && !isEmbedded
        // A heading and nothing more leaves its touches to the list under it;
        // an accessory that takes touches (a button) needs them passed down.
        isUserInteractionEnabled = !isEmbedded
            && (content.isLink || trailingAccessory?.isUserInteractionEnabled == true)

        let label = content.title
        let value = content.countAccessibilityValue
        let traits: UIAccessibilityTraits = content.isLink ? .button : .header
        if isEmbedded {
            isAccessibilityElement = false
            accessibilityElements = nil
        } else if let trailingAccessory {
            // The run and the accessory, each its own element.
            isAccessibilityElement = false
            runElement.accessibilityLabel = label
            runElement.accessibilityValue = value
            runElement.accessibilityTraits = traits
            runElement.onActivate = content.isLink ? { [weak self] in self?.onTap?() } : nil
            accessibilityElements = [runElement, trailingAccessory]
        } else {
            accessibilityElements = nil
            isAccessibilityElement = true
            accessibilityLabel = label
            accessibilityValue = value
            accessibilityTraits = traits
        }
    }

    @objc private func tapped() {
        onTap?()
    }

    override public func accessibilityActivate() -> Bool {
        guard content.isLink, !isEmbedded, let onTap else { return false }
        onTap()
        return true
    }

    // MARK: - Layout

    /// The run's parts at their natural sizes.
    private var measured: (title: CGSize, count: CGSize, chevron: CGSize) {
        let unbounded = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        func fit(_ label: UILabel) -> CGSize {
            guard !label.isHidden, label.text?.isEmpty == false else { return .zero }
            let size = label.sizeThatFits(unbounded)
            return CGSize(width: ceil(size.width), height: ceil(size.height))
        }
        return (fit(titleLabel), fit(countLabel), chevron.isHidden ? .zero : chevron.intrinsicContentSize)
    }

    /// Everything after the title: the count and the chevron with their gaps.
    private func tailWidth(count: CGSize, chevron: CGSize) -> CGFloat {
        var width: CGFloat = 0
        if count.width > 0 { width += Metrics.titleToCount + count.width }
        if chevron.width > 0 {
            width += (count.width > 0 ? Metrics.countToChevron : Metrics.titleToChevron) + chevron.width
        }
        return width
    }

    override public var intrinsicContentSize: CGSize {
        let parts = measured
        let insets = isEmbedded ? 0 : 2 * Metrics.surfaceInset
        var width = insets + parts.title.width + tailWidth(count: parts.count, chevron: parts.chevron)
        if let trailingAccessory, !trailingAccessory.isHidden {
            width += Metrics.accessoryGap + trailingAccessory.intrinsicContentSize.width
        }
        let height = switch style {
        case .standard: Self.barHeight(traits: traitCollection)
        case .compact: ceil(Self.titleFont(.compact, traits: traitCollection).lineHeight)
        }
        return CGSize(width: ceil(width), height: height)
    }

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        // The surface is known now: re-measure the inset against it.
        setNeedsLayout()
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        let insets = isEmbedded ? (leading: CGFloat(0), trailing: CGFloat(0)) : Self.surfaceInsets(of: self)
        let parts = measured
        let midY = bounds.midY
        var end = bounds.width - insets.trailing
        if let trailingAccessory, !trailingAccessory.isHidden {
            let fitted = trailingAccessory.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            let size = CGSize(width: ceil(fitted.width), height: ceil(fitted.height))
            trailingAccessory.frame = CGRect(
                x: end - size.width, y: pixelRound(midY - size.height / 2), width: size.width, height: size.height
            )
            end = trailingAccessory.frame.minX - Metrics.accessoryGap
        }
        let tail = tailWidth(count: parts.count, chevron: parts.chevron)
        // The title gives way first: a long one truncates, the count and the
        // chevron never do.
        let titleWidth = max(0, min(parts.title.width, end - insets.leading - tail))
        var runFrames: [CGRect] = []
        func place(_ view: UIView, x: CGFloat, size: CGSize) -> CGFloat {
            let frame = CGRect(x: x, y: pixelRound(midY - size.height / 2), width: size.width, height: size.height)
            view.frame = frame
            runFrames.append(frame)
            return frame.maxX
        }
        var x = place(titleLabel, x: insets.leading, size: CGSize(width: titleWidth, height: parts.title.height))
        if parts.count.width > 0 {
            x = place(countLabel, x: x + Metrics.titleToCount, size: parts.count)
        }
        if parts.chevron.width > 0 {
            let gap = parts.count.width > 0 ? Metrics.countToChevron : Metrics.titleToChevron
            _ = place(chevron, x: x + gap, size: parts.chevron)
        }
        if effectiveUserInterfaceLayoutDirection == .rightToLeft {
            for view in [titleLabel, countLabel, chevron, trailingAccessory].compactMap({ $0 }) {
                view.frame.origin.x = bounds.width - view.frame.maxX
            }
        }
        // The run's width, the bar's height: what a finger on the run hits.
        let run = runFrames.reduce(CGRect.null) { $0.union($1) }
        runElement.accessibilityFrameInContainerSpace = run.isNull
            ? .zero
            : CGRect(x: run.minX, y: 0, width: run.width, height: bounds.height)
        #if DEBUG
        auditIfAsked()
        #endif
    }

    private func pixelRound(_ value: CGFloat) -> CGFloat {
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
        return (value * scale).rounded() / scale
    }

    #if DEBUG
    /// `-section-title-audit`: every title on screen prints where it stands —
    /// its first letter's distance from its surface's leading edge and from
    /// the window's, and the gaps of its run — once per change. The number
    /// that proves every surface identical, read off the running app rather
    /// than off a screenshot's pixels.
    private static let isAuditing = ProcessInfo.processInfo.arguments.contains("-section-title-audit")
    private var lastAudit: String?

    private func auditIfAsked() {
        guard Self.isAuditing, let window, !isHidden, let title = titleLabel.text, !title.isEmpty else { return }
        let inWindow = titleLabel.convert(titleLabel.bounds, to: window).minX
        let surfaceX = Self.surface(of: self).map { surface in
            titleLabel.convert(titleLabel.bounds, to: surface).minX - surface.bounds.minX
        } ?? inWindow
        func gap(_ from: UIView, _ to: UIView) -> String {
            from.isHidden || to.isHidden ? "-" : String(format: "%.1f", to.frame.minX - from.frame.maxX)
        }
        let countGap = gap(titleLabel, countLabel)
        let chevronGap = countLabel.isHidden ? gap(titleLabel, chevron) : gap(countLabel, chevron)
        let line = String(
            format: "[section-title] '%@' count=%@ link=%@ style=%@ surfaceX=%.1f windowX=%.1f "
                + "title→count=%@ →chevron=%@ font=%.1f",
            title, content.count ?? "-", content.isLink ? "y" : "n",
            style == .standard ? "standard" : "compact", surfaceX, inWindow, countGap, chevronGap,
            titleLabel.font.pointSize
        )
        guard line != lastAudit else { return }
        lastAudit = line
        print(line)
    }

    /// What the count reads, nil while none shows — what a test pins.
    public var debugCountText: String? { countLabel.isHidden ? nil : countLabel.text }
    /// What the title reads.
    public var debugTitleText: String? { titleLabel.text }
    /// Whether the chevron is drawn.
    public var debugShowsChevron: Bool { !chevron.isHidden }
    /// The title, the count and the chevron in the bar's space — `.null` for a
    /// part not drawn.
    public var debugFrames: (title: CGRect, count: CGRect, chevron: CGRect) {
        func frame(_ view: UIView) -> CGRect { view.isHidden ? .null : view.frame }
        return (frame(titleLabel), frame(countLabel), frame(chevron))
    }
    /// The colours the parts are drawn in: title, count, chevron.
    public var debugColors: (title: UIColor?, count: UIColor?, chevron: UIColor?) {
        (titleLabel.textColor, countLabel.textColor, chevron.tintColor)
    }
    /// The title's font.
    public var debugTitleFont: UIFont? { titleLabel.font }
    /// Fires the bar's own recogniser action — the path a finger takes.
    public func debugTap() {
        guard tap.isEnabled, gestureRecognizers?.contains(tap) == true else { return }
        tapped()
    }
    #endif
}

/// The title run as an accessibility element of its own, when the bar also
/// holds an interactive accessory.
private final class RunAccessibilityElement: UIAccessibilityElement {
    var onActivate: (() -> Void)?

    override func accessibilityActivate() -> Bool {
        guard let onActivate else { return false }
        onActivate()
        return true
    }
}

/// `SectionTitleView` as a collection view's section header — for lists whose
/// headers scroll with their rows (the sound sheet, the notifications drawer,
/// the shop, the wallet, the map's filter editor). The pinned-capsule lists
/// host it through `SectionHeaderCapsuleView` instead.
///
/// Lay it edge to edge or inside a section's insets: the title finds its
/// inset from the surface either way (`SectionTitleView.surfaceInsets`).
public final class SectionTitleSupplementaryView: UICollectionReusableView {
    public let titleView = SectionTitleView()

    /// The bar was tapped — a link only. Re-assigned on every configure: the
    /// view is reused across sections.
    public var onTap: (() -> Void)? {
        get { titleView.onTap }
        set { titleView.onTap = newValue }
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        titleView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleView)
        NSLayoutConstraint.activate([
            titleView.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleView.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleView.topAnchor.constraint(equalTo: topAnchor),
            titleView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func prepareForReuse() {
        super.prepareForReuse()
        onTap = nil
    }

    public func configure(_ content: SectionTitleView.Content) {
        titleView.content = content
    }
}

extension UIFont {
    /// A weight at this font's own size, keeping whatever Dynamic Type has
    /// already scaled it to — a descriptor edit, so the size is never restated.
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight]
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
