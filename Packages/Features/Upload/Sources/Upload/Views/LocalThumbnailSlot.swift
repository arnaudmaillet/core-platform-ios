import DesignSystem
import UIKit

/// A LOCAL picture's place (#1772): a PhotoKit thumbnail decoding on the
/// device — the media slot's arrival for a picture that never touches the
/// network. The host's image view shows the media ground while the picture
/// decodes; one answered in the same turn is drawn at once, a later one
/// dissolves in; a picture that will not come leaves the ground. An answer
/// for another item (a recycled cell) lands nowhere.
///
/// The picker's grid, the chosen-media tray and the new post's strip draw
/// their thumbnails through it.
@MainActor
final class LocalThumbnailSlot {
    let view: UIImageView
    /// The item whose picture is awaited or shown.
    private(set) var id: String?
    private var begunAt: CFTimeInterval = 0

    /// A late picture's dissolve.
    static let arrivalDuration: TimeInterval = 0.2
    /// An answer within this of `begin` is the same turn's: drawn, no
    /// dissolve.
    static let sameTurn: CFTimeInterval = 0.05

    /// - Parameter ground: what the place shows while the picture decodes —
    ///   the media ground, or a host's own canvas (the new post's black
    ///   letterbox).
    init(view: UIImageView, ground: UIColor = Surface.mediaGround) {
        self.view = view
        view.backgroundColor = ground
    }

    /// A new item: its place empty on the ground. The same item again (a
    /// reconfigure) keeps what it shows.
    func begin(_ id: String) {
        guard id != self.id else { return }
        self.id = id
        view.image = nil
        begunAt = CACurrentMediaTime()
    }

    /// `image` decoded for `id`.
    func show(_ image: UIImage?, for id: String) {
        guard id == self.id, let image else { return }
        let late = CACurrentMediaTime() - begunAt > Self.sameTurn
        guard late, view.window != nil, !UIAccessibility.isReduceMotionEnabled else {
            view.image = image
            return
        }
        UIView.transition(
            with: view, duration: Self.arrivalDuration, options: [.transitionCrossDissolve, .allowUserInteraction]
        ) { self.view.image = image }
    }

    /// Back to no item (a recycled host).
    func reset() {
        id = nil
        view.image = nil
    }
}
