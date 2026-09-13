import UIKit

/// The pill that stands where a post's sound will be chosen: a disc with a plus,
/// and a word.
///
/// Shared by two screens. In the text-post composer it holds the footer's
/// leading slot and rides up into the top bar while the keyboard covers its
/// home; in the media editor it sits at the foot beside the editing categories.
/// It was Feed's private `TextPostSoundPill` until the editor needed the same
/// control — and features cannot import one another, so the only way to have ONE
/// of it is here.
///
/// ⚠️ **NO ACTION, ON EITHER SCREEN.** This repository holds no audio seam of any
/// kind: no track model, no picker, no mock, nothing behind `CoreNetworking`. The
/// pill is drawn because it is part of the page, and a tap on it does nothing.
/// Hosts wire nothing to it, and say so where they build it.
///
/// ⚠️ **ITS TEXT DOES NOT GROW WITH DYNAMIC TYPE** — pinned at the default size.
/// In a top bar it shares a run with titles that do not grow either, and a pill
/// that did would outgrow the bar at large sizes and fold the whole run into
/// `•••`.
public final class SoundPillView: UIControl {
    private static let height: CGFloat = 36
    /// The attribution pill's cap, which this pill stands in for.
    private static let maxWidth: CGFloat = 240

    /// The word is the host's, because the two screens do not name the same
    /// thing: a text post takes a sound, a media post takes a song. One control,
    /// two vocabularies — which is cheaper than two controls, and honest.
    ///
    /// ⚠️ **ONE LINE, CENTRED ON THE DISC.** It carried a second line — "and a
    /// cover", `caption2` in `secondaryLabel` — until 2026-09-12. With the
    /// subtitle gone the title centres against the disc rather than sitting
    /// above a caption, which is what the vertical stack existed to arrange.
    /// The measured reason that stack was pinned at `.large` survives it: at
    /// accessibility XL the second line used to spill out of a bubble whose
    /// height is stated, and the height is still stated.
    /// `neverTruncates` states a MINIMUM width from the pill's own content, so
    /// nothing can squeeze the word out of it.
    ///
    /// ⚠️ **OPT-IN, BECAUSE THE DEFAULT IS DELIBERATE.** Left alone the words
    /// give way first — the attribution's rule — which is right in the text
    /// composer's narrow top bar, where the pill shares a run with Cancel and
    /// Drafts and something has to yield. It is wrong in the media editor's
    /// toolbar, where the pill sits beside a `PagedTabBar` that STATES an
    /// intrinsic width: lowering that bar's compression resistance lets it
    /// shrink but obliges nobody to respect the pill, so the pill — having no
    /// minimum of its own, only a 240pt cap — was the one that gave, and "Add a
    /// song" came out as "Add a…". Resistance was the wrong lever; a floor is
    /// the right one.
    public init(title: String = "Add a sound", neverTruncates: Bool = false) {
        super.init(frame: .zero)
        let traits = UITraitCollection(preferredContentSizeCategory: .large)
        let disc = UIView()
        disc.backgroundColor = .tertiarySystemFill
        disc.layer.cornerRadius = AvatarImageView.barDiameter / 2
        disc.isUserInteractionEnabled = false
        disc.widthAnchor.constraint(equalToConstant: AvatarImageView.barDiameter).isActive = true
        disc.heightAnchor.constraint(equalToConstant: AvatarImageView.barDiameter).isActive = true
        let plus = UIImageView(image: UIImage(
            systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)
        ))
        plus.tintColor = .label
        plus.translatesAutoresizingMaskIntoConstraints = false
        disc.addSubview(plus)
        NSLayoutConstraint.activate([
            plus.centerXAnchor.constraint(equalTo: disc.centerXAnchor),
            plus.centerYAnchor.constraint(equalTo: disc.centerYAnchor)
        ])

        let label = UILabel()
        label.text = title
        // ⚠️ **THE WEIGHT IS APPLIED HERE, NOT THROUGH A `withWeight` HELPER.**
        // Four modules carry one of those and every copy is `private` to the file
        // that needed it — DesignSystem's sits in `SectionHeaderPillButton.swift`
        // and is invisible from this file, which is what this component failed to
        // compile on. A shared component should not lean on an ambient helper
        // anyway. This is the descriptor edit those helpers perform: a weight at
        // the font's own size, keeping whatever Dynamic Type already scaled it to.
        let base = UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traits)
        label.font = UIFont(
            descriptor: base.fontDescriptor.addingAttributes([
                .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.semibold]
            ]),
            size: base.pointSize
        )
        label.textColor = .label
        // The words give way first — the attribution's rule — so the cap
        // truncates them rather than squeezing the disc.
        label.setContentCompressionResistancePriority(
            neverTruncates ? .required : UILayoutPriority(749), for: .horizontal
        )

        let row = UIStackView(arrangedSubviews: [disc, label])
        row.axis = .horizontal
        row.spacing = Spacing.sm
        row.alignment = .center
        row.isUserInteractionEnabled = false
        let breathing = (Self.height - AvatarImageView.barDiameter) / 2
        row.constrain(in: self) { parent in
            row.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: breathing)
            row.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -Spacing.sm)
            row.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }
        // 999, never required: a bar pins its item wrapper with autoresizing
        // constraints, and anything required loses to that with a console break.
        let height = heightAnchor.constraint(equalToConstant: Self.height)
        height.priority = UILayoutPriority(999)
        height.isActive = true
        widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxWidth).isActive = true
        if neverTruncates {
            // The floor: the disc, the gap, the word at its own size, and the
            // two insets. Stated as a `>=` so the cap above still governs a very
            // long word, and at `.defaultHigh` so it can never conflict with the
            // bar's own required layout — a required floor beside a required cap
            // is an unsatisfiable pair the console would report every frame.
            let content = AvatarImageView.barDiameter + Spacing.sm
                + ceil(label.intrinsicContentSize.width)
                + (Self.height - AvatarImageView.barDiameter) / 2 + Spacing.sm
            let floor = widthAnchor.constraint(greaterThanOrEqualToConstant: min(content, Self.maxWidth))
            floor.priority = .defaultHigh
            floor.isActive = true
        }

        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
