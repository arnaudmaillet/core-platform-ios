import UIKit

/// A section's title that is also the way INTO the section: `Title (3) ›`.
///
/// ```
///   Friends (3) ›
///   ───────────────────────────────────────────────
///   ◯ ◯ ◯ ◯ ◯ …            (the section's own row)
/// ```
///
/// The title leads, and right after it comes the count of what is new in the
/// section — a `NotificationCountBadge`, the count the tab badges have always
/// worn and the pushed list's "New" header repeats — then a chevron, the
/// platform's sign that a screen will be PUSHED.
///
/// ⚠️ BESIDE THE TITLE, NOT AT THE EDGE (product call, 2026-09-30). #312 put
/// the badge and chevron at the trailing edge, where they read as a control of
/// their own a screen-width away from the word they qualify; after the title
/// they read as one phrase, "Friends, 3 new, more". The row stops where the
/// chevron does and the rest of the bar is empty — but still the bar's: the
/// whole width is the control, not just the chevron: a row of content under a
/// heading reads "tap the heading to see all of it", and a 20pt glyph is a
/// target nobody should have to aim for.
///
/// Zero draws no pill (`.count` has always meant that), so a section with
/// nothing new reads as a plain heading with a way in.
///
/// A header that is NOT a way in (`isLink: false`) is the same title in the
/// same place with nothing trailing and nothing to tap — For You's "For you"
/// over its list, which reads as the page's third section and pushes nothing.
///
/// ⚠️ **A TAP RECOGNISER, NOT A `UIControl` — BOTH HALVES OF THAT WERE BUGS
/// (2026-09-29).**
/// - A plain `UIControl` never sends `.primaryActionTriggered`; only its
///   subclasses (`UIButton`, …) do. The header #312 shipped as a control
///   answered `addAction(_:for: .primaryActionTriggered)` with nothing: the
///   chevron "did nothing" on device, and the tests passed because they called
///   the host's closure directly.
/// - The bar lives inside a scroll view (For You's list). A scroll view does
///   not cancel a touch a `UIControl` is tracking (`touchesShouldCancel(in:)`
///   is false for controls), so a scroll that began on a held header belonged
///   to the header. A tap recogniser fails as soon as the finger travels, and
///   the scroll keeps the touch.
///
/// And NO press feedback: the product call is that a heading gives none under
/// a finger. It used to fire at the start of every scroll that happened to
/// begin on it.
///
/// Built for For You's rows (Friends, Following) and kept free of either: any
/// section that is a preview of a screen can wear it.
@MainActor
public final class SectionLinkHeaderView: UIView {
    /// The bar's height: a title3 line with room to breathe, and a tap target
    /// past the 44pt minimum.
    public static let height: CGFloat = 44

    private let titleLabel = UILabel()
    private let countBadge = NotificationCountBadge()
    private let chevron = UIImageView(
        image: UIImage(
            systemName: "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        )
    )

    public var title: String? {
        get { titleLabel.text }
        set {
            titleLabel.text = newValue
            updateAccessibility()
        }
    }

    /// What the pill says. Zero hides it.
    public var count: Int { countBadge.count }

    /// Whether the bar is a way in: a chevron, a button to VoiceOver, a tap.
    public let isLink: Bool

    /// The bar was tapped. Never called on a header that is not a link.
    public var onTap: (() -> Void)?

    public init(title: String? = nil, isLink: Bool = true) {
        self.isLink = isLink
        super.init(frame: .zero)
        titleLabel.text = title
        titleLabel.font = UIFontMetrics(forTextStyle: .title3).scaledFont(
            // 20pt is title3 at the default size; the metrics scale it, once.
            for: .systemFont(ofSize: 20, weight: .bold)
        )
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        chevron.tintColor = .secondaryLabel
        chevron.contentMode = .center
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        // ⚠️ EVERYTHING HUGS, and the row is held at the leading edge with its
        // trailing end FREE (`≤`): the slack is the bar's, after the chevron.
        // Left to the defaults a stack stretches something across the width —
        // the pill, once, or the title, which put the badge back at the edge.
        // The title is the first to give when a long one meets a narrow bar.
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        countBadge.setContentHuggingPriority(.required, for: .horizontal)
        countBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
        // ONE FLAT ROW, `[title][pill][›]`: a hidden pill leaves the row with
        // its spacing, so the chevron closes up on the title when the count
        // goes to zero (`SectionLinkHeaderTests.aCountGoingToZeroClosesTheGap`).
        // At the trailing edge a kept gap was invisible; after the title it is
        // not.
        let row = UIStackView(arrangedSubviews: [titleLabel, countBadge, chevron])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Spacing.sm
        // Touches belong to the bar: the stacks are layout only.
        row.isUserInteractionEnabled = false
        row.constrain(in: self) { parent in
            row.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            row.trailingAnchor.constraint(lessThanOrEqualTo: parent.trailingAnchor)
            row.topAnchor.constraint(equalTo: parent.topAnchor)
            row.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        }
        heightAnchor.constraint(greaterThanOrEqualToConstant: Self.height).isActive = true

        chevron.isHidden = !isLink
        isAccessibilityElement = true
        accessibilityTraits = isLink ? .button : .header
        if isLink {
            addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        } else {
            // A heading and nothing more: its touches are the list's.
            isUserInteractionEnabled = false
        }
        updateAccessibility()
    }

    @objc private func tapped() {
        onTap?()
    }

    override public func accessibilityActivate() -> Bool {
        guard isLink, let onTap else { return false }
        onTap()
        return true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The pill's number — "99+" past 99 (`NotificationCountBadge`).
    public func setCount(_ count: Int) {
        countBadge.setCount(count)
        // The run after the title changes length with the pill.
        setNeedsLayout()
        updateAccessibility()
    }

    private func updateAccessibility() {
        accessibilityLabel = titleLabel.text
        accessibilityValue = count > 0 ? "\(count) new" : nil
    }

    #if DEBUG
    /// What the pill reads, nil while hidden — what a test pins.
    public var debugCountText: String? { countBadge.text }
    /// Whether the chevron is drawn.
    public var debugShowsChevron: Bool { !chevron.isHidden }
    /// Where the title, the pill and the chevron are, in the bar's space —
    /// the arrangement a test pins (a hidden pill reads `.null`).
    public var debugFrames: (title: CGRect, badge: CGRect, chevron: CGRect) {
        func frame(_ view: UIView) -> CGRect {
            view.isHidden ? .null : view.convert(view.bounds, to: self)
        }
        return (frame(titleLabel), frame(countBadge), frame(chevron))
    }
    /// Fires the bar's own recogniser action — the path a finger takes, which
    /// is the one #312's tests skipped by calling the host's closure.
    public func debugTap() {
        guard gestureRecognizers?.contains(where: { $0 is UITapGestureRecognizer }) == true else { return }
        tapped()
    }
    #endif
}
