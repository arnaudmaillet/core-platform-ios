import DesignSystem
import UIKit

/// One tile of the library grid: the thumbnail, the number it was chosen in,
/// and — for a video — how long it runs.
final class MediaPickerGridCell: UICollectionViewCell {
    private enum Metrics {
        static let badgeSize: CGFloat = 24
        static let badgeInset: CGFloat = 6
        /// The same radius the tray's thumbnails wear, so a tile and the
        /// thumbnail it becomes when chosen are visibly the same object.
        static let corner: CGFloat = 10
        /// How far the thumbnail shrinks once it is chosen. The tile keeps its
        /// place in the grid and the gap that opens around it is the whole
        /// signal — the same move Photos makes, and the reason a chosen tile is
        /// never DIMMED here: dimming reads as "unavailable" on a surface where
        /// the unavailable tiles are the ones past the cap.
        static let chosenScale: CGFloat = 0.94
        static let durationInset: CGFloat = 6
        /// The ring a chosen tile wears. Thick enough to read over a busy
        /// photograph at a third of the screen's width.
        static let chosenBorder: CGFloat = 3
    }

    /// The item this cell currently stands for.
    ///
    /// ⚠️ A THUMBNAIL ARRIVES LATE AND A CELL IS REUSED EARLY. The screen checks
    /// this before it hands an image over, so a photo fetched for a tile that
    /// has since scrolled away never lands on whatever took its place.
    private(set) var representedID: String?

    private let thumbnail = UIImageView()
    private let badge = SelectionBadgeView()
    private let duration = UILabel()
    private let durationScrim = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)

        thumbnail.contentMode = .scaleAspectFill
        thumbnail.clipsToBounds = true
        thumbnail.backgroundColor = .secondarySystemBackground
        thumbnail.layer.cornerRadius = Metrics.corner
        thumbnail.layer.cornerCurve = .continuous
        thumbnail.pin(to: contentView)

        // A video's duration sits over the photo's own colours, so it carries a
        // shadow rather than a plate: a plate on every video tile turns a grid
        // of pictures into a grid of labels.
        durationScrim.isUserInteractionEnabled = false
        durationScrim.backgroundColor = .clear
        duration.font = .preferredFont(forTextStyle: .caption2)
        duration.adjustsFontForContentSizeCategory = true
        duration.textColor = .white
        duration.layer.shadowColor = UIColor.black.cgColor
        duration.layer.shadowOpacity = 0.6
        duration.layer.shadowRadius = 2
        duration.layer.shadowOffset = .zero
        duration.constrain(in: contentView) { parent in
            duration.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -Metrics.durationInset)
            duration.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -Metrics.durationInset)
        }

        badge.constrain(in: contentView) { parent in
            badge.topAnchor.constraint(equalTo: parent.topAnchor, constant: Metrics.badgeInset)
            badge.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -Metrics.badgeInset)
            badge.widthAnchor.constraint(equalToConstant: Metrics.badgeSize)
            badge.heightAnchor.constraint(equalToConstant: Metrics.badgeSize)
        }

        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedID = nil
        thumbnail.image = nil
        thumbnail.transform = .identity
        thumbnail.layer.borderWidth = 0
        contentView.alpha = 1
    }

    /// `isSelectable` is false only for an unchosen tile once the cap is
    /// reached: the tap is still answered, with a word about the limit, but the
    /// tile says beforehand that it is not on offer.
    func configure(item: MediaLibraryItem, order: Int?, isSelectable: Bool, animated: Bool = false) {
        representedID = item.id

        if case .video(let seconds) = item.kind {
            duration.text = Self.durationText(seconds)
            duration.isHidden = false
        } else {
            duration.text = nil
            duration.isHidden = true
        }

        let chosen = order != nil
        badge.setOrder(order, animated: animated)
        // ⚠️ A `CGColor` does not follow a trait change the way a `UIColor`
        // does, so it is re-stated on every configure rather than set once.
        thumbnail.layer.borderWidth = chosen ? Metrics.chosenBorder : 0
        thumbnail.layer.borderColor = tintColor.cgColor
        contentView.alpha = chosen || isSelectable ? 1 : 0.4
        let transform = chosen
            ? CGAffineTransform(scaleX: Metrics.chosenScale, y: Metrics.chosenScale)
            : .identity
        let apply = { self.thumbnail.transform = transform }
        if animated {
            UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState], animations: apply)
        } else {
            apply()
        }

        accessibilityLabel = item.isVideo ? "Video" : "Photo"
        accessibilityValue = order.map { "Selected, number \($0)" }
    }

    /// Hands over an image that was fetched for `id`, and ignores one whose tile
    /// has moved on.
    func showThumbnail(_ image: UIImage?, for id: String) {
        guard representedID == id else { return }
        thumbnail.image = image
    }

    /// "0:07", "1:04", "12:30" — a stamp, not a sentence, so it is built here
    /// rather than through a `DateComponentsFormatter` whose shortest style is
    /// still "12 min".
    private static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The ring a tile wears, and the number it wears once it is chosen.
private final class SelectionBadgeView: UIView {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        // The shape is `cornerConfiguration` rather than a layer radius, for the
        // reason `GlassCapsule` states: it is a property UIKit animates with the
        // view, and this badge is scaled and re-drawn under one.
        cornerConfiguration = .capsule()
        layer.borderWidth = 1.5
        // The ring has to read over a white sky and a black jacket alike, so it
        // is white with a shadow rather than a semantic colour.
        layer.borderColor = UIColor.white.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 2
        layer.shadowOffset = .zero

        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white
        label.textAlignment = .center
        label.pin(to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// ⚠️ THE BOUNCE FIRES ON A CHANGE OF STATE, NOT ON EVERY CONFIGURE. A
    /// reconfigure runs for renumbering and for the cap crossing too, and a
    /// badge that sprang every time those happened would have the whole grid
    /// twitching at each tap.
    func setOrder(_ order: Int?, animated: Bool = false) {
        let wasChosen = label.text != nil
        label.text = order.map(String.init)
        backgroundColor = order == nil ? UIColor.black.withAlphaComponent(0.15) : tintColor
        guard animated, wasChosen != (order != nil) else { return }
        bounce()
    }

    /// Grows from small and settles — the ring answers the finger rather than
    /// simply appearing where it was already.
    ///
    /// ⚠️ DAMPING CARRIES THE "SMOOTH", DURATION CARRIES THE "SLOW", and they
    /// are not the same dial. The first cut sprang at 0.5 damping over 0.42s:
    /// fast AND springy, which reads as a twitch on a badge this small. Higher
    /// damping takes the wobble out; the longer duration is what makes the
    /// settle legible.
    private func bounce() {
        transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
        UIView.animate(
            withDuration: 0.7,
            delay: 0,
            usingSpringWithDamping: 0.72,
            initialSpringVelocity: 0.25,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.transform = .identity
        }
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        guard label.text != nil else { return }
        backgroundColor = tintColor
    }
}
