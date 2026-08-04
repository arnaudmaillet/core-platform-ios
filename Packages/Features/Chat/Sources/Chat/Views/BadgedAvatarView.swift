import DesignSystem
import UIKit

/// A monogram disc with a notification badge pinned to its bottom-right corner.
///
/// The mark used to live at the row's trailing edge, beside the timestamp, a
/// column away from the face it was about. On the avatar it is attached to the
/// person: scanning a list, the eye lands on the discs, and anything overlapping
/// one is read as belonging to it without a second look.
///
/// Both inbox lists share it, and they mean slightly different things by it — a
/// conversation you have not read, a request you have not viewed — which is
/// exactly why it takes a STYLE rather than a Bool. See `Style`.
final class BadgedAvatarView: UIView {
    /// What the badge says.
    ///
    /// ⚠️ `.count` is implemented and currently unused. `chat.v1` carries no
    /// per-conversation unread count — `Conversation.isUnread` is a Bool, and
    /// there is no `unread_count` anywhere in the generated messages — so the
    /// All list can only honestly say THAT a conversation is unread, not how
    /// many messages are waiting in it (`dev/BACKEND_GAPS.md` §17). The case
    /// exists so that the day the field lands, the change is one call site and
    /// no layout work; using it before then would mean printing a number the
    /// app made up.
    enum Style: Equatable {
        case none
        /// Presence only. The honest answer when all that is known is "there
        /// is something here you have not seen".
        case dot
        /// A number. Zero draws nothing, the same rule `PagedTabBar` follows.
        case count(Int)

        var isVisible: Bool {
            switch self {
            case .none: false
            case .dot: true
            case .count(let value): value > 0
            }
        }
    }

    private enum Metrics {
        /// The dot's diameter, and the badge's minimum in both axes — a pill
        /// narrower than it is tall degenerates, the rule the tab capsule's own
        /// badge states.
        static let dotDiameter: CGFloat = 14
        /// The ring that separates the badge from the disc beneath it. Drawn in
        /// the list's own background colour, so the badge reads as sitting ON
        /// the avatar rather than being part of it.
        static let ringWidth: CGFloat = 2
        /// How far the badge's centre sits inside the disc's corner. The disc
        /// is a circle, so its bottom-right "corner" is at 45°: pulling in by
        /// this much puts the badge across the edge rather than floating off it.
        static let cornerInset: CGFloat = 4
        static let labelInset: CGFloat = 4
    }

    private let avatar = MonogramAvatarView()
    private let badge = UIView()
    private let label = UILabel()
    private var badgeWidth: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        avatar.pin(to: self)

        badge.backgroundColor = .tintColor
        badge.layer.borderWidth = Metrics.ringWidth
        badge.layer.cornerCurve = .continuous
        badge.isHidden = true
        // The ring is a dynamic colour resolved at draw time by the layer,
        // which does NOT re-resolve on a trait change by itself — layers hold
        // CGColors. `traitCollectionDidChange` is where it is refreshed.
        applyRingColour()

        label.font = UIFont.systemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize, weight: .semibold
        )
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        // The same trap `PagedTabBar.BadgeView` documents: a semantic colour
        // can resolve to the wrong end of the spectrum over a tinted fill, so
        // the count's colour is stated outright.
        label.textColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 0.06, alpha: 1)
                : UIColor(white: 1, alpha: 1)
        }
        label.isHidden = true
        label.pin(to: badge, insets: NSDirectionalEdgeInsets(
            top: 0, leading: Metrics.labelInset, bottom: 0, trailing: Metrics.labelInset
        ))

        badge.constrain(in: self) { parent in
            badge.heightAnchor.constraint(equalToConstant: Metrics.dotDiameter)
            badge.trailingAnchor.constraint(
                equalTo: parent.trailingAnchor, constant: -Metrics.cornerInset
            )
            badge.bottomAnchor.constraint(
                equalTo: parent.bottomAnchor, constant: -Metrics.cornerInset
            )
        }
        // Held, because a count re-states it: the pill widens for two digits
        // and returns to a circle for one.
        badgeWidth = badge.widthAnchor.constraint(equalToConstant: Metrics.dotDiameter)
        badgeWidth.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        badge.layer.cornerRadius = badge.bounds.height / 2
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previous) else { return }
        applyRingColour()
    }

    private func applyRingColour() {
        badge.layer.borderColor = UIColor.systemBackground.resolvedColor(with: traitCollection).cgColor
    }

    func setMonogram(_ monogram: String) {
        avatar.setMonogram(monogram)
    }

    func setBadge(_ style: Style) {
        badge.isHidden = !style.isVisible
        switch style {
        case .none, .dot:
            label.isHidden = true
            badgeWidth.constant = Metrics.dotDiameter
        case .count(let value):
            label.isHidden = false
            label.text = value > 99 ? "99+" : String(value)
            // Never narrower than it is tall: a single digit draws a circle.
            let text = (label.text ?? "") as NSString
            let measured = ceil(text.size(withAttributes: [.font: label.font as Any]).width)
            badgeWidth.constant = max(Metrics.dotDiameter, measured + Metrics.labelInset * 2)
        }
    }
}
