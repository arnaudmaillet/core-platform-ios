import DesignSystem
import UIKit

/// A row that hosts one app button edge to edge — a sign-in method, a
/// step's Continue (#2020).
///
/// ⚠️ **THE ROW NEVER CLIPS ITS BUTTON.** An inset-grouped section rounds
/// and clips its rows, and it does so again whenever the table lays out —
/// the list's sheet coming back after a form's closes included. Clipped,
/// a method's card corner came back a capsule, and a pressed button's
/// swell (it grows past its bounds) stayed inside the row: only its words
/// grew (the owner, on his iPhone, 2026-11-07). The button draws its own
/// shape; the row is only where it stands.
///
/// ⚠️ **iOS 26+ ROUNDS THE ROW WITH `cornerConfiguration`, NOT
/// `layer.cornerRadius`,** and turns its clipping back on after the row's
/// own layout and the table's (read on the iPhone, iOS 27.2: the cell at
/// `.fixed(26)`, `clipsToBounds` true, its `layer.cornerRadius` 0). So the
/// row's layer never clips (`UnclippedLayer`), whoever asks; a corner
/// left on it only shapes its background, which is clear.
final class AuthButtonCell: UITableViewCell {
    override class var layerClass: AnyClass { UnclippedLayer.self }

    init(hosting button: UIView) {
        super.init(style: .default, reuseIdentifier: nil)
        backgroundConfiguration = .clear()
        selectionStyle = .none
        // Over its neighbours, so a swell is drawn over the next row.
        layer.zPosition = 1
        button.constrain(in: contentView) { parent in
            button.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            button.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            button.topAnchor.constraint(equalTo: parent.topAnchor)
            button.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        }
        unclip()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        unclip()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        unclip()
    }

    override var clipsToBounds: Bool {
        get { false }
        set { super.clipsToBounds = false }
    }

    /// Undoes whatever rounding and clipping the section put on the row.
    func unclip() {
        for view in [self, contentView] {
            view.clipsToBounds = false
            view.layer.cornerRadius = 0
            view.layer.mask = nil
            if view.cornerConfiguration != Self.square {
                view.cornerConfiguration = Self.square
            }
        }
    }

    private static var square: UICornerConfiguration { .corners(radius: .fixed(0)) }
}

/// A layer that never clips its sublayers — `AuthButtonCell`'s.
final class UnclippedLayer: CALayer {
    override var masksToBounds: Bool {
        get { false }
        set { super.masksToBounds = false }
    }
}
