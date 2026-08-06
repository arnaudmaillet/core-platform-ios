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
        /// The pill's height, and the diameter a bare dot draws at.
        ///
        /// 20pt against a 48pt disc. It was 14, which is the right size for a
        /// DOT and too small for a number: at 14 the digits had 1.5pt of air
        /// above and below them and the pill read as a smudge with something in
        /// it. The badge is a thing to be READ now, so it is sized to be read.
        static let height: CGFloat = 20
        /// Clearance between the digits and the pill's end caps.
        ///
        /// Generous on purpose: this is what turns a two-digit count into a
        /// capsule rather than a circle with the number wedged into it. A
        /// single digit never reaches it — the height floor wins, so one digit
        /// is a circle — and it only ever describes how a count GROWS. 7 put a
        /// one-digit pill at 22 against a 20pt height, which is neither a
        /// circle nor obviously a capsule; 6 lets the floor bind.
        static let labelInset: CGFloat = 6
        /// The ring that separates the badge from the disc beneath it. Drawn in
        /// the list's own background colour, so the badge reads as sitting ON
        /// the avatar rather than being part of it.
        ///
        /// 2.5pt: at 2 the ring disappeared into the disc's own edge at the one
        /// place they cross, which is exactly where it has work to do.
        static let ringWidth: CGFloat = 2.5
        /// How far the badge hangs OUTSIDE the disc's bounding box.
        ///
        /// Positive, so the pill breaks the avatar's bounds rather than sitting
        /// within them: a badge tucked inside reads as part of the picture,
        /// where one that overhangs reads as attached to it — which is what it
        /// is. The disc is a circle inscribed in a square box, so its
        /// bottom-right corner region is already empty; 3pt past that puts the
        /// pill's own edge clear of the circle's.
        ///
        /// ⚠️ Nothing between here and the cell may clip. `MonogramAccessoryHost`
        /// exists because a leading ACCESSORY is sized by the table and would
        /// crop this; these two lists lay their avatar out in a stack inside the
        /// content view, which does not clip by default.
        static let overhang: CGFloat = 3
    }

    private let avatar = MonogramAvatarView()
    /// The picture, drawn OVER the monogram rather than instead of it.
    ///
    /// The monogram stays underneath for the whole lifetime of the row, so
    /// there is no empty disc at any point: before the fetch, during it, and
    /// after one that failed, the initials are what shows. A swap would need a
    /// third state for "loading" and would flash on cell reuse.
    private let picture = AvatarImageView()
    private let badge = UIView()
    private let label = UILabel()
    private var badgeWidth: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        avatar.pin(to: self)
        picture.pin(to: avatar)

        badge.backgroundColor = .tintColor
        badge.layer.borderWidth = Metrics.ringWidth
        badge.layer.cornerCurve = .continuous
        badge.isHidden = true
        // The ring is a dynamic colour resolved at draw time by the layer,
        // which does NOT re-resolve on a trait change by itself — layers hold
        // CGColors. `traitCollectionDidChange` is where it is refreshed.
        applyRingColour()

        // `.caption1` rather than `.caption2`: the pill grew, and a number in
        // it should look deliberate rather than lost.
        label.font = UIFont.systemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .semibold
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
            badge.heightAnchor.constraint(equalToConstant: Metrics.height)
            badge.trailingAnchor.constraint(
                equalTo: parent.trailingAnchor, constant: Metrics.overhang
            )
            badge.bottomAnchor.constraint(
                equalTo: parent.bottomAnchor, constant: Metrics.overhang
            )
        }
        // Held, because a count re-states it: the pill widens for two digits
        // and returns to a circle for one.
        badgeWidth = badge.widthAnchor.constraint(equalToConstant: Metrics.height)
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

    /// The pill's laid-out size, so a test can assert the shape rather than
    /// measure it in a screenshot.
    var badgeSize: CGSize { badge.bounds.size }

    func setMonogram(_ monogram: String) {
        avatar.setMonogram(monogram)
    }

    /// Reveals a fetched picture over the initials, or clears back to them.
    ///
    /// Cross-dissolved when it arrives late (the common case — the row was on
    /// screen before the profile service answered) and set outright when it is
    /// already in hand, so a scroll through cached rows doesn't shimmer.
    func setPicture(_ image: UIImage?, animated: Bool) {
        guard animated, image != nil else {
            picture.image = image
            return
        }
        UIView.transition(
            with: picture, duration: 0.25,
            options: [.transitionCrossDissolve, .allowUserInteraction]
        ) { self.picture.image = image }
    }

    func setBadge(_ style: Style) {
        badge.isHidden = !style.isVisible
        switch style {
        case .none, .dot:
            label.isHidden = true
            badgeWidth.constant = Metrics.height
        case .count(let value):
            label.isHidden = false
            label.text = value > 99 ? "99+" : String(value)
            // Never narrower than it is tall — below that a capsule's own
            // corner radius exceeds half its width and the shape degenerates,
            // the same floor the tab capsule's lens and badge both state. So a
            // single digit is a circle, and every digit after it widens the
            // pill by exactly what that digit measures.
            let text = (label.text ?? "") as NSString
            let measured = ceil(text.size(withAttributes: [.font: label.font as Any]).width)
            badgeWidth.constant = max(Metrics.height, measured + Metrics.labelInset * 2)
        }
    }
}
