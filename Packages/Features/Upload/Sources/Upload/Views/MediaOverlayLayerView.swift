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
/// ⚠️ **IT STORES NOTHING PAST A GESTURE.** It shows the overlays it is handed
/// (`show`), moves them under a finger, and says what was decided through
/// `onEvent`. The overlay mode writes the edit and hands the result back. The
/// one thing it does keep is the RAW placement of the overlay currently under
/// the fingers, which exists only between a touch down and the last finger
/// lifting — see `advance` and `MediaOverlayGeometry.snapped`.
///
/// ⚠️ **AN OVERLAY SNAPS TO THE PICTURE'S MIDDLES AND TO THE RIGHT ANGLES.**
/// The rule is arithmetic and lives in `MediaOverlayGeometry`; what lives here
/// is the feedback — two solid guide lines while a centre is caught, the item's
/// own outline going solid while its turn is square, and one tick of the
/// selection engine for each mark that lights.
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
            // ⚠️ **A LAYER GOING INERT MID-DRAG TAKES ITS GUIDES WITH IT.** The
            // recognisers are cancelled by `isUserInteractionEnabled` and never
            // report their end, so nothing else would clear the raw placement
            // or the lines — the next mode would open over two white strokes.
            if !isEditable {
                select(nil)
                live = nil
                lastMarks = []
                showMarks([])
            }
            for item in items { item.describe() }
        }
    }

    private(set) var items: [MediaOverlayItemView] = []
    private(set) var selectedID: String?
    let trash = MediaOverlayTrashView()
    private var trashIsInUse = false

    /// The overlay under the fingers: its id, the placement the fingers have
    /// actually made — before any snap — and how many of its recognisers are
    /// running at once.
    ///
    /// ⚠️ **THE RAW PLACEMENT IS THE ONE THE GESTURE ADVANCES; THE SNAPPED ONE
    /// IS ONLY EVER DRAWN AND STORED.** See `MediaOverlayGeometry.snapped`: an
    /// overlay whose own snapped value is fed back in can never be moved out of
    /// a detent again. `hands` exists because pan, pinch and rotation are
    /// allowed to run together and each has its own began and ended — the raw
    /// placement belongs to the whole two-fingered gesture, not to one
    /// recogniser.
    private var live: (id: String, raw: OverlayPlacement, hands: Int)?

    /// What was lit at the last sample, so a tick is owed once per snap rather
    /// than once per frame.
    private var lastMarks: MediaOverlayGeometry.OverlaySnapMarks = []

    /// ⚠️ STORED, NOT MADE PER CLICK — `StraightenDialView` records why: a
    /// generator built inside the handler "arrives cold and clicks late".
    /// `prepare()` runs when the fingers land.
    private let click = UISelectionFeedbackGenerator()
    private var ticks = 0

    /// The picture's middle lines, drawn only while an overlay is resting on
    /// them.
    ///
    /// ⚠️ **SOLID, WHERE THE SELECTION OUTLINE IS DASHED.** The overlay stack
    /// had exactly one piece of feedback before these — the dashed rectangle
    /// that means "this is the one you are working on" — and a second dashed
    /// line would have read as more of the same. A guide is a ruler: it is
    /// drawn as one continuous stroke, and the dash stays the selection's.
    private let acrossGuide = MediaOverlayLayerView.makeGuide()
    private let downGuide = MediaOverlayLayerView.makeGuide()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true
        isUserInteractionEnabled = false
        // ⚠️ **AT THE BOTTOM, SO EVERY OVERLAY STANDS OVER ITS GUIDES.** A
        // sublayer added with `addSublayer` lands above whatever is there and
        // below whatever is added next; the items are added later and would sit
        // above it anyway, but the bin is added here and must not be crossed by
        // a line.
        layer.insertSublayer(acrossGuide, at: 0)
        layer.insertSublayer(downGuide, at: 0)
        addSubview(trash)
    }

    private static func makeGuide() -> CAShapeLayer {
        let guide = CAShapeLayer()
        guide.fillColor = nil
        guide.strokeColor = UIColor.white.withAlphaComponent(0.9).cgColor
        guide.lineWidth = 1
        guide.isHidden = true
        return guide
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
            if phase == .began { handsOn(item) }
            advance(item) { MediaOverlayGeometry.moved($0, by: delta, in: mediaRect, visible: visibleFractions) }
            trash.setArmed(trash.covers(location))
        case .ended:
            let drop = trash.covers(location)
            trashIsInUse = false
            trash.setShowing(false)
            let settled = handsOff(item)
            // ⚠️ **THE BIN DOES NOT WAIT FOR THE OTHER FINGERS.** A drop is the
            // pan's own verdict and the overlay is gone either way; only the
            // placement is held back until the gesture is over.
            if drop {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onEvent?(.delete(id: item.id))
            } else {
                item.setPlacement(item.overlay.placement, redraw: true)
                if settled { onEvent?(.placed(item.overlay)) }
            }
        }
    }

    func item(_ item: MediaOverlayItemView, pinched phase: MediaOverlayItemView.Phase, by factor: Double) {
        if phase == .began {
            select(item.id)
            handsOn(item)
        }
        advance(item) { MediaOverlayGeometry.scaled($0, by: factor) }
        if phase == .ended {
            let settled = handsOff(item)
            item.setPlacement(item.overlay.placement, redraw: true)
            if settled { onEvent?(.placed(item.overlay)) }
        }
    }

    func item(_ item: MediaOverlayItemView, rotated phase: MediaOverlayItemView.Phase, by radians: Double) {
        if phase == .began {
            select(item.id)
            handsOn(item)
        }
        advance(item) { MediaOverlayGeometry.rotated($0, by: radians) }
        if phase == .ended, handsOff(item) {
            onEvent?(.placed(item.overlay))
        }
    }

    // MARK: - Snapping

    /// A recogniser on `item` began. The raw placement is taken from where the
    /// overlay stands the first time a hand lands, and kept until the last one
    /// lifts.
    private func handsOn(_ item: MediaOverlayItemView) {
        if let live, live.id == item.id {
            self.live = (live.id, live.raw, live.hands + 1)
            return
        }
        live = (item.id, item.overlay.placement, 1)
        // ⚠️ **WHAT IS ALREADY LIT OWES NOTHING.** Starting this at `[]` makes
        // the first sample of every gesture on an overlay that is already
        // centred — which is where every overlay is born — a tick for having
        // been touched. The hand is told about snaps it FALLS INTO, and an
        // overlay resting on the middle has not just fallen into anything.
        lastMarks = MediaOverlayGeometry
            .snapped(item.overlay.placement, in: mediaRect, visible: visibleFractions).marks
        click.prepare()
    }

    /// A recogniser ended. Answers whether it was the LAST of them — the only
    /// moment the placement is worth storing.
    ///
    /// ⚠️ **ONE GESTURE, ONE STORED PLACEMENT, BECAUSE ONE GESTURE IS ONE STEP
    /// IN THE AUTHOR'S HISTORY.** Pan, pinch and rotation run together and each
    /// ends on its own clock; storing from every `.ended` filed a single
    /// two-fingered move as two or three entries, and the back arrow then
    /// walked the author through the middle of their own gesture. The raw
    /// placement goes at the same moment, for the same reason.
    ///
    /// ⚠️ **AN END WITH NO BEGINNING STILL STORES.** Nothing tracked that
    /// gesture, so its end is all this layer knows about it; answering false
    /// would swallow the placement entirely.
    private func handsOff(_ item: MediaOverlayItemView) -> Bool {
        guard let live, live.id == item.id else { return true }
        let hands = live.hands - 1
        guard hands <= 0 else {
            self.live = (live.id, live.raw, hands)
            return false
        }
        self.live = nil
        lastMarks = []
        showMarks([])
        return true
    }

    /// Advances the raw placement by `step`, draws what the snaps make of it,
    /// lights the guides, and ticks the engine once for a sample that caught a
    /// mark it had not caught before.
    ///
    /// ⚠️ **THE ITEM IS SET FROM THE SNAPPED VALUE AND THE RAW ONE IS KEPT
    /// ASIDE.** Reading `item.overlay.placement` back as the input — which is
    /// what this did before there were snaps — would make every detent a trap:
    /// see `MediaOverlayGeometry.snapped`.
    private func advance(
        _ item: MediaOverlayItemView, by step: (OverlayPlacement) -> OverlayPlacement
    ) {
        guard let live, live.id == item.id else {
            item.setPlacement(step(item.overlay.placement), redraw: false)
            return
        }
        let raw = step(live.raw)
        self.live = (live.id, raw, live.hands)
        let snap = MediaOverlayGeometry.snapped(raw, in: mediaRect, visible: visibleFractions)
        item.setPlacement(snap.placement, redraw: false)
        if MediaOverlayGeometry.ticks(from: lastMarks, to: snap.marks) { tick() }
        lastMarks = snap.marks
        showMarks(snap.marks)
    }

    /// ⚠️ **THE COUNTER IS IN HERE WITH THE ENGINE, AND NOWHERE ELSE.** A test
    /// counting ticks at the call sites instead would pass while this routine
    /// clicked twice, or clicked not at all.
    private func tick() {
        click.selectionChanged()
        ticks += 1
    }

    /// Draws the guides `marks` asks for, and tells the item whether its turn
    /// is square.
    ///
    /// ⚠️ **THE TURN'S MARK IS THE ITEM'S OWN OUTLINE, NOT A THIRD LINE.** A
    /// line drawn through an overlay at 0° and a centring guide through the
    /// middle of the picture are the same stroke in the same place whenever the
    /// overlay is both square and centred — one mark for two different facts.
    /// The outline going solid belongs unmistakably to the thing that is square.
    private func showMarks(_ marks: MediaOverlayGeometry.OverlaySnapMarks) {
        let rect = mediaRect
        let seen = rect.intersection(clearRect)
        let ready = !seen.isNull && seen.width > 0 && seen.height > 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        acrossGuide.isHidden = !ready || !marks.contains(.centredAcross)
        if !acrossGuide.isHidden {
            let path = UIBezierPath()
            path.move(to: CGPoint(x: rect.midX, y: seen.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: seen.maxY))
            acrossGuide.path = path.cgPath
        }
        downGuide.isHidden = !ready || !marks.contains(.centredDown)
        if !downGuide.isHidden {
            let path = UIBezierPath()
            path.move(to: CGPoint(x: seen.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: seen.maxX, y: rect.midY))
            downGuide.path = path.cgPath
        }
        CATransaction.commit()
        for item in items { item.setSquared(item.id == live?.id && marks.contains(.square)) }
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
    /// Internal for tests: how many times the engine has been ticked for a
    /// snap. Counted where the tick is fired, so the two cannot drift.
    var debugTicks: Int { ticks }
    /// Internal for tests: the guides that are DRAWN, as the line each strokes
    /// in this layer's points — an empty array when none is.
    var debugGuides: [CGRect] {
        [acrossGuide, downGuide]
            .filter { !$0.isHidden }
            .compactMap { $0.path?.boundingBoxOfPath }
    }
    /// Internal for tests: the raw, unsnapped placement of the overlay under
    /// the fingers.
    var debugRawPlacement: OverlayPlacement? { live?.raw }
}
