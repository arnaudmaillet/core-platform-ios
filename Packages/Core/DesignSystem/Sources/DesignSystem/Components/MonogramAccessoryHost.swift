import UIKit

/// A fixed-size, frame-based host for `MonogramAvatarView`, so an identity disc
/// can be a list cell's *leading accessory* rather than something laid out by
/// hand inside the content view.
///
/// UIKit **asserts** that a custom accessory view keeps
/// `translatesAutoresizingMaskIntoConstraints` enabled, and `MonogramAvatarView`
/// sizes itself with constraints on itself — so the two cannot be the same view.
/// The disc therefore travels inside this container, which reports its size the
/// frame-based way and uses Auto Layout internally: exactly the arrangement the
/// assertion allows.
///
/// Shared by every list cell in the inbox that carries a disc. The workaround is
/// subtle enough — and its failure mode (a debug-only assert, on a cell that
/// looks fine in release) obscure enough — that a second copy of it is a second
/// thing to get wrong.
public final class MonogramAccessoryHost: UIView {
    private let monogramView = MonogramAvatarView()
    /// Laid OVER the monogram rather than replacing it, so the initials stay
    /// behind as the permanent fallback: a row renders an identity from the
    /// first frame and the picture, if there is one, arrives on top of it.
    private let imageView = AvatarImageView()
    /// The glyph a row that is NOT a person wears in the same slot — see
    /// `setSymbol`.
    private lazy var symbolView: UIImageView = {
        let view = UIImageView()
        view.contentMode = .center
        view.tintColor = .secondaryLabel
        view.isHidden = true
        view.pin(to: monogramView)
        return view
    }()

    public init() {
        super.init(frame: CGRect(
            x: 0, y: 0,
            width: MonogramAvatarView.rowDiameter,
            height: MonogramAvatarView.rowDiameter
        ))
        // Centred rather than pinned: the host is the disc's size today, and
        // centring keeps a circle a circle if it ever is not.
        monogramView.constrain(in: self) { parent in
            monogramView.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            monogramView.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }
        // Over the DISC rather than over the host, so both follow it.
        imageView.pin(to: monogramView)
        imageView.isHidden = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var intrinsicContentSize: CGSize {
        CGSize(width: MonogramAvatarView.rowDiameter, height: MonogramAvatarView.rowDiameter)
    }

    public func setMonogram(_ monogram: String) {
        monogramView.setMonogram(monogram)
        symbolView.isHidden = true
    }

    /// A glyph on the same disc, for a row in a people list that is not a
    /// person — a remembered query, a hashtag.
    ///
    /// **The disc stays.** The point is the leading column: if a query row
    /// carried a small inline icon and a person row carried a 48pt disc, every
    /// line of text in the list would start at a different place and the two
    /// kinds of row would read as two different lists. One slot, one text
    /// margin, and what sits in the slot is what differs.
    public func setSymbol(_ systemName: String) {
        monogramView.setMonogram("")
        symbolView.image = UIImage(systemName: systemName)
        symbolView.isHidden = false
    }

    /// The picture, or `nil` to fall back to the initials.
    ///
    /// A `UIImage`, not a URL: fetching belongs to whoever owns the image
    /// pipeline, and DesignSystem depends on nothing — taking a URL here would
    /// mean taking `MediaCore` with it. The caller loads and hands over the
    /// result, which is also what lets a cell cancel its own load on reuse.
    public func setImage(_ image: UIImage?) {
        imageView.image = image
        imageView.isHidden = image == nil
    }

    /// Back to a bare disc — no picture, no glyph — so a recycled host does
    /// not carry the last row's dressing into the next one.
    public func reset() {
        setImage(nil)
        symbolView.isHidden = true
    }

    /// This host expressed as the accessory it exists to be. Stated once here so
    /// every cell reserves the same width and keeps its separators inset past
    /// the disc identically.
    public var leadingAccessory: UICellAccessory {
        .customView(configuration: .init(
            customView: self,
            placement: .leading(displayed: .always),
            reservedLayoutWidth: .actual,
            maintainsFixedSize: true
        ))
    }
}
