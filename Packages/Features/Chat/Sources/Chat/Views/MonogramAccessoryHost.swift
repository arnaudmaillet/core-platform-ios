import DesignSystem
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
final class MonogramAccessoryHost: UIView {
    private let monogramView = MonogramAvatarView()

    init() {
        super.init(frame: CGRect(
            x: 0, y: 0,
            width: MonogramAvatarView.rowDiameter,
            height: MonogramAvatarView.rowDiameter
        ))
        monogramView.pin(to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: MonogramAvatarView.rowDiameter, height: MonogramAvatarView.rowDiameter)
    }

    func setMonogram(_ monogram: String) {
        monogramView.setMonogram(monogram)
    }

    /// This host expressed as the accessory it exists to be. Stated once here so
    /// every cell reserves the same width and keeps its separators inset past
    /// the disc identically.
    var leadingAccessory: UICellAccessory {
        .customView(configuration: .init(
            customView: self,
            placement: .leading(displayed: .always),
            reservedLayoutWidth: .actual,
            maintainsFixedSize: true
        ))
    }
}
