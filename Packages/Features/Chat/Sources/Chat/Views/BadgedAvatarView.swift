import DesignSystem
import MediaCore
import UIKit

/// A monogram disc with a notification badge pinned to its bottom-right corner:
/// the message requests list's avatar (an unviewed request).
///
/// The conversation rows wore it too until #2049 (the owner, 2026-11-02): their
/// count moved under the time, and their face wears the relation mark
/// (`RelationMarkedAvatarView`). It takes a STYLE rather than a Bool. See
/// `Style`.
final class BadgedAvatarView: UIView {
    /// What the badge says.
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

    /// The app's avatar (#943): the picture drawn OVER the initials rather
    /// than instead of them, so there is no empty disc at any point — before
    /// the fetch, during it, and after one that failed, the initials show.
    private let avatar = AvatarView(size: .avatar)
    /// The pill, ringed: it sits on the face (`UnreadCountPill`).
    private let badge = UnreadCountPill(ringed: true)

    init() {
        super.init(frame: .zero)
        avatar.pin(to: self)
        badge.constrain(in: self) { parent in
            badge.trailingAnchor.constraint(
                equalTo: parent.trailingAnchor, constant: Metrics.overhang
            )
            badge.bottomAnchor.constraint(
                equalTo: parent.bottomAnchor, constant: Metrics.overhang
            )
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The pill's laid-out size, so a test can assert the shape rather than
    /// measure it in a screenshot.
    var badgeSize: CGSize { badge.bounds.size }

    func setMonogram(_ monogram: String) {
        avatar.setMonogram(monogram)
    }

    /// Shows the picture at `url` over the initials, or clears back to them
    /// (nil). The avatar decides the motion: at once when the pipeline has it
    /// (a scroll through cached rows doesn't shimmer), dissolved in when it
    /// lands late.
    func setPicture(_ url: URL?, pipeline: ImagePipeline?) {
        avatar.setPicture(url, pipeline: pipeline)
    }

    /// A picture still being looked up: the skeleton until `setPicture`.
    func awaitPicture() {
        avatar.awaitPicture()
    }

    /// The picture on show, nil while the initials are — for tests.
    var shownPicture: UIImage? { avatar.shownPicture }

    func setBadge(_ style: Style) {
        switch style {
        case .none: badge.hide()
        case .dot: badge.show(count: nil)
        case .count(let value): badge.show(count: value)
        }
    }
}
