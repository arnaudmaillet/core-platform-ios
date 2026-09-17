import MediaPlayback
import UIKit

/// The layer a page's overlays are drawn in: one view per overlay, over the
/// picture, in the order they are stored — the last on top.
///
/// ⚠️ **INERT OUTSIDE TEXT AND STICKERS.** Overlays are drawn on every page and
/// in every mode, but they take touches only while `isEditable` — which the
/// overlay mode sets on the page in front of the author while it is open. In
/// any other mode the layer passes every touch through, so the page's
/// play/pause tap and the canvas's paging behave exactly as they do without it.
///
/// ⚠️ **AND EVEN WHEN EDITABLE, ONLY THE OVERLAYS TAKE TOUCHES.** A tap on the
/// picture beside an overlay falls through to the canvas (`hitTest`), so the
/// clip still plays and pauses from anywhere that is not an overlay.
///
/// ⚠️ **IT STORES NOTHING.** It shows the overlays it is handed (`show`), moves
/// them under a finger, and says what was decided through `onEvent`. The
/// overlay mode writes the edit and hands the result back.
@MainActor
final class MediaOverlayLayerView: UIView {
    /// What happened on the layer that the mode has to store or act on.
    enum Event: Equatable {
        /// A gesture or a VoiceOver action left the overlay where it now is.
        case placed(FrameOverlay)
        case delete(id: String)
        case edit(id: String)
        case bringToFront(id: String)
    }

    /// A step VoiceOver can take on an overlay.
    enum Nudge {
        case bigger, smaller, turnLeft, turnRight
        case move(dx: CGFloat, dy: CGFloat)
    }

    var onEvent: ((Event) -> Void)?

    /// How the rasteriser is asked for pictures — replaced by tests.
    var rasterize: MediaOverlayItemView.Rasterize = {
        OverlayRasterizer.image(for: $0, outputWidth: $1, scale: $2)
    }

    /// The size of the picture the page shows, which is the finished picture's
    /// shape. Nil until a picture lands; overlays are hidden until then rather
    /// than drawn against the wrong rectangle and moved.
    var contentSize: CGSize? {
        didSet { if contentSize != oldValue { setNeedsLayout() } }
    }

    /// How the page lays its picture.
    var fit: ContentFit = .fill {
        didSet { if fit != oldValue { setNeedsLayout() } }
    }

    /// The part of the layer the chrome covers — the bars over a filled
    /// picture. A new overlay, a drag and the bin all stay out of it.
    var chromeInsets: UIEdgeInsets = .zero {
        didSet { if chromeInsets != oldValue { setNeedsLayout() } }
    }

    /// Whether the overlays take touches — true only in the overlay mode, on
    /// the page in front of the author.
    var isEditable = false {
        didSet {
            isUserInteractionEnabled = isEditable
            if !isEditable { select(nil) }
            for item in items { item.describe() }
        }
    }

    private(set) var items: [MediaOverlayItemView] = []
    private(set) var selectedID: String?
    let trash = MediaOverlayTrashView()
    private var trashIsInUse = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true
        isUserInteractionEnabled = false
        addSubview(trash)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Geometry

    /// Where the picture is drawn in this layer.
    var mediaRect: CGRect {
        guard let contentSize else { return bounds }
        return MediaOverlayGeometry.mediaRect(contentSize: contentSize, bounds: bounds, fit: fit)
    }

    /// The part of the layer the author can see.
    var clearRect: CGRect { bounds.inset(by: chromeInsets) }

    /// The part of the picture the author can see, in fractions of it.
    var visibleFractions: CGRect {
        MediaOverlayGeometry.visibleFractions(mediaRect: mediaRect, window: clearRect)
    }

    /// Where a new overlay goes: the middle of the picture, held inside the
    /// part of it that can be seen.
    var newCentre: CGPoint {
        MediaOverlayGeometry.clamped(CGPoint(x: 0.5, y: 0.5), into: visibleFractions)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rect = mediaRect
        let scale = window?.screen.scale ?? traitCollection.displayScale
        let ready = contentSize != nil && rect.width > 0
        for item in items {
            item.isHidden = !ready
            if ready { item.lay(in: rect, screenScale: max(scale, 1)) }
        }
        let clear = clearRect
        trash.center = CGPoint(
            x: clear.midX,
            y: clear.maxY - MediaOverlayTrashView.side / 2 - 12
        )
        bringSubviewToFront(trash)
    }

    /// ⚠️ **THE LAYER ITSELF IS NEVER THE TARGET.** Only an overlay is; a
    /// touch anywhere else belongs to the canvas beneath.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self || hit === trash ? nil : hit
    }

    // MARK: - What is shown

    /// Shows `overlays`, bottom first, reusing the view each overlay already
    /// has.
    func show(_ overlays: [FrameOverlay]) {
        var byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var next: [MediaOverlayItemView] = []
        for overlay in overlays {
            if let item = byID.removeValue(forKey: overlay.id) {
                item.update(overlay)
                next.append(item)
            } else {
                let item = MediaOverlayItemView(overlay: overlay, rasterize: rasterize)
                item.handler = self
                item.describe()
                next.append(item)
            }
        }
        for gone in byID.values { gone.removeFromSuperview() }
        items = next
        for item in items { addSubview(item) }
        bringSubviewToFront(trash)
        if let selectedID, !items.contains(where: { $0.id == selectedID }) { select(nil) }
        setNeedsLayout()
        layoutIfNeeded()
    }

    /// Marks one overlay as the one being worked on, or none.
    func select(_ id: String?) {
        selectedID = id
        for item in items { item.setSelected(item.id == id) }
    }

    func item(for id: String) -> MediaOverlayItemView? {
        items.first { $0.id == id }
    }

    // MARK: - What the items report

    func item(_ item: MediaOverlayItemView, panned phase: MediaOverlayItemView.Phase, by delta: CGPoint, at location: CGPoint) {
        switch phase {
        case .began:
            select(item.id)
            trashIsInUse = true
            trash.setShowing(true)
            fallthrough
        case .changed:
            let moved = MediaOverlayGeometry.moved(
                item.overlay.placement, by: delta, in: mediaRect, visible: visibleFractions
            )
            item.setPlacement(moved, redraw: false)
            trash.setArmed(trash.covers(location))
        case .ended:
            let drop = trash.covers(location)
            trashIsInUse = false
            trash.setShowing(false)
            if drop {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onEvent?(.delete(id: item.id))
            } else {
                item.setPlacement(item.overlay.placement, redraw: true)
                onEvent?(.placed(item.overlay))
            }
        }
    }

    func item(_ item: MediaOverlayItemView, pinched phase: MediaOverlayItemView.Phase, by factor: Double) {
        let scaled = MediaOverlayGeometry.scaled(item.overlay.placement, by: factor)
        item.setPlacement(scaled, redraw: phase == .ended)
        if phase == .began { select(item.id) }
        if phase == .ended { onEvent?(.placed(item.overlay)) }
    }

    func item(_ item: MediaOverlayItemView, rotated phase: MediaOverlayItemView.Phase, by radians: Double) {
        let turned = MediaOverlayGeometry.rotated(item.overlay.placement, by: radians)
        item.setPlacement(turned, redraw: false)
        if phase == .began { select(item.id) }
        if phase == .ended { onEvent?(.placed(item.overlay)) }
    }

    func itemTapped(_ item: MediaOverlayItemView) {
        select(item.id)
    }

    func itemWantsEditing(_ item: MediaOverlayItemView) {
        guard case .text = item.overlay.content else { return itemTapped(item) }
        select(item.id)
        onEvent?(.edit(id: item.id))
    }

    func itemWantsDeleting(_ item: MediaOverlayItemView) {
        onEvent?(.delete(id: item.id))
    }

    func itemWantsFront(_ item: MediaOverlayItemView) {
        onEvent?(.bringToFront(id: item.id))
    }

    /// A VoiceOver step: 25% bigger or smaller, 15° either way, or 5% of the
    /// picture in one direction — then stored like a gesture's end.
    func item(_ item: MediaOverlayItemView, nudged nudge: Nudge) {
        var placement = item.overlay.placement
        switch nudge {
        case .bigger: placement = MediaOverlayGeometry.scaled(placement, by: 1.25)
        case .smaller: placement = MediaOverlayGeometry.scaled(placement, by: 1 / 1.25)
        case .turnLeft: placement = MediaOverlayGeometry.rotated(placement, by: -.pi / 12)
        case .turnRight: placement = MediaOverlayGeometry.rotated(placement, by: .pi / 12)
        case .move(let dx, let dy):
            placement.centre = MediaOverlayGeometry.clamped(
                CGPoint(x: placement.centre.x + dx, y: placement.centre.y + dy), into: visibleFractions
            )
        }
        item.setPlacement(placement, redraw: true)
        onEvent?(.placed(item.overlay))
    }

    /// Internal for tests: whether the bin is showing for a drag.
    var debugTrashIsInUse: Bool { trashIsInUse }
}
