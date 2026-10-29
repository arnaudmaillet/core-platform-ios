import CoreImage
import UIKit

/// THE ACTION COLUMN AS ONE GLASS (#1872): the like, the post's actions and
/// the sound are bubbles of ONE `UIGlassContainerEffect` that fuse, split
/// and fold into each other the way a native `UIToolbar`'s items do.
///
/// Ported from the liquidglass lab's `LiquidGlassMorphStack` (branch
/// `disparition-native`, d3afda2), whose model was measured on a native
/// toolbar at 60 Hz:
/// - one spring for position, size and opacity: k 260, ζ 0.75;
/// - the bubble that survives goes to its new frame and BULGES (its contour
///   swells ~0.125 × the thickness, then settles; spring k 250, ζ 0.5, held
///   0.1 s);
/// - the absorbed bubbles shrink to 0.2× towards the anchor, unfaded (they
///   vanish into the union);
/// - a new bubble is born inside its neighbour at 0.2×;
/// - an item that comes or goes fades through a blur: 10 pt × (1 − opacity),
///   at 0.2× ↔ 1×;
/// - the first move waits 0.03 s, the toolbar's own delay.
///
/// What changed for the app:
/// - **The frames are the caller's** (`layout`): the stations Auto Layout
///   already resolves, so the column stands exactly where it always stood.
/// - **An item is a real view** (`register`), hosted in its bubble's glass
///   `contentView` — the only way a touch reaches the glass, so the native
///   interactive glass answers it (the lab's finding 3). While it comes or
///   goes it is replaced by a blurred picture of itself.
/// - **The glass materializes on window attach** (#46): never off a window.
///
/// ⚠️ Native glass findings this follows (the lab's README):
/// - a child glass's `alpha` is ignored in the container, so no bubble
///   ever fades: every new one is born inside the anchor's, and `spacing`
///   is set on a NEW container effect;
/// - a paused property animator renders a ghost: the springs are stepped
///   here, frame by frame, never scrubbed.
@MainActor
final class SnapGlassColumn: UIView {
    /// One item's frame, in this view's bounds.
    struct Slot: Equatable {
        let id: String
        let frame: CGRect
    }

    /// The shapes to stand, each a run of slots that one bubble covers.
    var layout: () -> [[Slot]] = { [] }

    /// The item whose bubble survives every change and which the others fold
    /// into and are born from — the sound (the owner, 2026-10-29).
    var anchorID: String?
    /// The reveal from the anchor in two steps, like the native toolbar: one
    /// capsule over every item first, then the split after this delay.
    var anchoredRevealDelay: Double = 0.12
    /// Between two separate shapes: the union's smoothing.
    var gap: CGFloat = 12 {
        didSet { applySpacing() }
    }

    // The lab's measured constants.
    nonisolated static let springK: Double = 260
    nonisolated static let springZeta: Double = 0.75
    nonisolated static let bulgeK: Double = 250
    nonisolated static let bulgeZeta: Double = 0.5
    nonisolated static let bulgeFraction: CGFloat = 0.125
    nonisolated static let bulgeHold: Double = 0.1
    nonisolated static let bornScale: CGFloat = 0.2
    nonisolated static let maxBlur: CGFloat = 10
    nonisolated static let startDelay: Double = 0.03

    private let container = UIVisualEffectView(effect: nil)
    /// The pictures of the items that come and go, over the glass.
    private let pictureLayer = UIView()
    private var contents: [String: UIView] = [:]
    private var shapes: [[Slot]] = []
    private var blobs: [Blob] = []
    private var faces: [String: Face] = [:]
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var holdUntil: CFTimeInterval = 0
    private var pendingSplit: DispatchWorkItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        container.frame = bounds
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(container)
        pictureLayer.frame = bounds
        pictureLayer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pictureLayer.isUserInteractionEnabled = false
        container.contentView.addSubview(pictureLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `content` stands for `id`: the column hosts it in its bubble.
    func register(_ content: UIView, for id: String) {
        contents[id] = content
    }

    /// The thickness of a bubble: the column's width.
    private var thickness: CGFloat {
        shapes.joined().map(\.frame.width).max() ?? 44
    }

    // MARK: - Touches

    /// Only the bubbles and the accessories take a touch: between them, the
    /// page under the column gets it.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        if accessories.allObjects.contains(where: { hit.isDescendant(of: $0) }) { return hit }
        return blobs.contains(where: { !$0.dying && hit.isDescendant(of: $0.view) }) ? hit : nil
    }

    // MARK: - Accessories (#1872, the wheel's capsule)

    private let accessories = NSHashTable<UIView>.weakObjects()

    /// Glass the caller lays in the SAME container as the bubbles, under the
    /// items: it fuses with them (the smooth union, bridges included). The
    /// caller frames it in this view's bounds and takes it away.
    func insertAccessory(_ view: UIView) {
        accessories.add(view)
        container.contentView.insertSubview(view, belowSubview: pictureLayer)
    }

    /// While an accessory covers an item's bubble whole, that bubble
    /// retracts towards its centre (`amount` 0 … 1, down to a point), well
    /// inside the accessory: the smooth union swells by about spacing / 4
    /// wherever two contours coincide, so a doubled bubble would step the
    /// accessory's outline (the lab's finding 5). The item does not move.
    func setCover(_ id: String?, amount: CGFloat) {
        let clamped = id == nil ? 0 : max(0, min(1, amount))
        guard id != coverID || clamped != coverAmount else { return }
        coverID = id
        coverAmount = clamped
        for blob in blobs { blob.render(inset: coverInset(for: blob)) }
        // The items stay put: each is placed against its bubble's new frame.
        for face in faces.values { render(face) }
    }

    private var coverID: String?
    private var coverAmount: CGFloat = 0

    private func coverInset(for blob: Blob) -> CGFloat {
        guard let id = coverID, coverAmount > 0, !blob.dying, blob.ids.contains(id) else { return 0 }
        return coverAmount * max(0, min(blob.renderedRect.width, blob.renderedRect.height) / 2 - 0.5)
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        container.frame = bounds
        pictureLayer.frame = bounds
        // At rest, the stations rule: a new frame (rotation, text size, the
        // post's actions) snaps the column onto them.
        guard link == nil, pendingSplit == nil else { return }
        let wanted = layout()
        if wanted != shapes || blobs.count != wanted.count { relayout(wanted) }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        // #46: the glass is made on window attach, never off a window.
        applySpacing()
        for blob in blobs where blob.view.effect == nil {
            blob.view.effect = Self.makeGlass()
        }
    }

    /// Stands the column on `layout()` now — animated through the morph, or
    /// snapped.
    func refresh(animated: Bool) {
        let wanted = layout()
        guard animated, window != nil, !shapes.isEmpty, wanted != shapes else {
            return relayout(wanted)
        }
        pendingSplit?.cancel()
        pendingSplit = nil
        let oldIDs = Set(shapes.joined().map(\.id))
        let newIDs = Set(wanted.joined().map(\.id))
        // The reveal from the anchor: one capsule over every item first.
        if let anchor = anchorID, oldIDs.contains(anchor), newIDs.contains(anchor),
           wanted.count > 1, !newIDs.isSubset(of: oldIDs) {
            transition(to: [Array(wanted.joined())], deferring: newIDs.subtracting(oldIDs))
            let split = DispatchWorkItem { [weak self] in
                guard let self else { return }
                pendingSplit = nil
                transition(to: layout())
            }
            pendingSplit = split
            DispatchQueue.main.asyncAfter(deadline: .now() + anchoredRevealDelay, execute: split)
            return
        }
        transition(to: wanted)
    }

    private static func union(_ slots: [Slot]) -> CGRect {
        slots.dropFirst().reduce(slots.first?.frame ?? .zero) { $0.union($1.frame) }
    }

    private func relayout(_ wanted: [[Slot]]) {
        link?.invalidate()
        link = nil
        shapes = wanted.filter { !$0.isEmpty }
        var pool = blobs.map(\.view)
        blobs = shapes.map { slots in
            let view = pool.isEmpty ? makeGlassView() : pool.removeFirst()
            let blob = Blob(view: view, ids: Set(slots.map(\.id)), rect: Self.union(slots))
            blob.render(inset: coverInset(for: blob))
            return blob
        }
        pool.forEach { $0.removeFromSuperview() }
        let slots = Dictionary(shapes.joined().map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
        for (id, face) in faces where slots[id] == nil {
            face.retire()
            faces[id] = nil
        }
        for id in contents.keys where slots[id] == nil {
            contents[id]?.removeFromSuperview()
        }
        for (id, frame) in slots {
            let face = faces[id] ?? Face(id: id)
            faces[id] = face
            face.snap(centre: CGPoint(x: frame.midX, y: frame.midY), size: frame.size, scale: 1, alpha: 1)
            render(face)
        }
        container.contentView.bringSubviewToFront(pictureLayer)
    }

    // MARK: - Transition

    private func transition(to wanted: [[Slot]], deferring deferred: Set<String> = []) {
        shapes = wanted.filter { !$0.isEmpty }
        let targets = shapes.map(Self.union)
        let slots = Dictionary(shapes.joined().map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
        let live = blobs.filter { !$0.dying }
        let anchorOld = anchorID.flatMap { id in live.firstIndex { $0.ids.contains(id) } }
        let anchorNew = anchorID.flatMap { id in shapes.firstIndex { $0.contains { $0.id == id } } }
        let anchorSlot = anchorNew != nil ? anchorID.flatMap { slots[$0] } : nil
        let anchorTarget = anchorOld.map { live[$0].target }

        // 1. Survivors: the anchor's bubble first, then the nearest pairs.
        var oldTaken = Set<Int>()
        var newTaken = Set<Int>()
        var survivorOf: [Int: Blob] = [:]
        func adopt(_ old: Int, _ new: Int) {
            oldTaken.insert(old)
            newTaken.insert(new)
            let blob = live[old]
            blob.ids = Set(shapes[new].map(\.id))
            if !Self.same(blob.target, targets[new]) { blob.kickBulge() }
            blob.animate(to: targets[new])
            survivorOf[new] = blob
        }
        if let old = anchorOld, let new = anchorNew { adopt(old, new) }
        var pairs: [(CGFloat, Int, Int)] = []
        for (old, blob) in live.enumerated() {
            for (new, rect) in targets.enumerated() {
                let shared = !blob.ids.isDisjoint(with: shapes[new].map(\.id))
                pairs.append((Self.distance(blob.centre, Self.centre(rect)) - (shared ? 0.001 : 0), old, new))
            }
        }
        pairs.sort { $0.0 < $1.0 }
        for (_, old, new) in pairs where !oldTaken.contains(old) && !newTaken.contains(new) { adopt(old, new) }

        // 2. Absorbed: shrink towards the anchor (or the nearest shape).
        for (old, blob) in live.enumerated() where !oldTaken.contains(old) {
            let point = anchorSlot.map(Self.centre) ?? nearestCentre(to: blob.centre, in: targets)
            blob.dying = true
            blob.ids = []
            blob.animate(to: dot(at: point))
        }

        // 3. New shapes: born from the anchor's bubble, or inside the nearest.
        var startOf: [Int: CGPoint] = [:]
        for (new, rect) in targets.enumerated() where survivorOf[new] == nil {
            let blob = Blob(view: makeGlassView(), ids: Set(shapes[new].map(\.id)), rect: rect)
            let source = anchorTarget ?? live.min {
                Self.distance($0.centre, Self.centre(rect)) < Self.distance($1.centre, Self.centre(rect))
            }?.target
            let point = source.map { closestOnAxis($0, to: Self.centre(rect)) } ?? Self.centre(rect)
            blob.place(CGRect(
                x: point.x - rect.width * Self.bornScale / 2, y: point.y - rect.height * Self.bornScale / 2,
                width: rect.width * Self.bornScale, height: rect.height * Self.bornScale
            ))
            blob.animate(to: rect)
            if let old = anchorOld, live[old].bulgeStart == nil { live[old].kickBulge() }
            startOf[new] = point
            blobs.append(blob)
        }

        // 4. Faces.
        for (id, face) in faces where slots[id] == nil {
            let point = anchorSlot.map(Self.centre) ?? face.centreNow
            face.leave(to: point, scale: Self.bornScale, picture: picture(of: id), in: pictureLayer)
            contents[id]?.removeFromSuperview()
        }
        for (new, run) in shapes.enumerated() {
            for slot in run {
                let centre = Self.centre(slot.frame)
                if let face = faces[slot.id], !face.leaving {
                    face.go(to: centre, size: slot.frame.size)
                    continue
                }
                if deferred.contains(slot.id) { continue }
                faces[slot.id]?.retire()
                let face = Face(id: slot.id)
                face.snap(centre: startOf[new] ?? centre, size: slot.frame.size, scale: Self.bornScale, alpha: 0)
                face.arrive(picture: picture(of: slot.id, size: slot.frame.size), in: pictureLayer)
                face.go(to: centre, size: slot.frame.size)
                faces[slot.id] = face
            }
        }
        container.contentView.bringSubviewToFront(pictureLayer)
        holdUntil = CACurrentMediaTime() + Self.startDelay
        start()
    }

    private func nearestCentre(to point: CGPoint, in rects: [CGRect]) -> CGPoint {
        rects.map(Self.centre).min { Self.distance($0, point) < Self.distance($1, point) } ?? point
    }

    private func dot(at point: CGPoint) -> CGRect {
        let side = thickness * Self.bornScale
        return CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
    }

    /// The point of `rect`'s axis (the segment between its two end caps)
    /// nearest `point`.
    private func closestOnAxis(_ rect: CGRect, to point: CGPoint) -> CGPoint {
        let radius = min(rect.width, rect.height) / 2
        let vertical = rect.height >= rect.width
        let a = vertical ? CGPoint(x: rect.midX, y: rect.minY + radius) : CGPoint(x: rect.minX + radius, y: rect.midY)
        let b = vertical ? CGPoint(x: rect.midX, y: rect.maxY - radius) : CGPoint(x: rect.maxX - radius, y: rect.midY)
        let ab = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let length = ab.x * ab.x + ab.y * ab.y
        guard length > 0 else { return a }
        let t = max(0, min(1, ((point.x - a.x) * ab.x + (point.y - a.y) * ab.y) / length))
        return CGPoint(x: a.x + t * ab.x, y: a.y + t * ab.y)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
    private static func centre(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
    private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5
            && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }

    // MARK: - Glass

    private static func makeGlass() -> UIGlassEffect {
        let glass = UIGlassEffect(style: .regular)
        glass.isInteractive = true
        return glass
    }

    /// ⚠️ The effect is COPIED by the view: a new spacing needs a new effect,
    /// or the union is hard (no smoothing, no bridges).
    private func applySpacing() {
        guard window != nil else { return }
        if let effect = container.effect as? UIGlassContainerEffect, effect.spacing == gap { return }
        let effect = UIGlassContainerEffect()
        effect.spacing = gap
        container.effect = effect
    }

    private func makeGlassView() -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: window == nil ? nil : Self.makeGlass())
        view.cornerConfiguration = .capsule()
        container.contentView.insertSubview(view, belowSubview: pictureLayer)
        return view
    }

    // MARK: - The pictures an item fades through

    /// The item's view drawn at `size`, blurred at six levels (sharp → 10 pt).
    private func picture(of id: String, size: CGSize? = nil) -> [UIImage] {
        guard let content = contents[id] else { return [] }
        let side = size ?? content.bounds.size
        guard side.width > 0, side.height > 0 else { return [] }
        if content.bounds.size != side {
            content.bounds = CGRect(origin: .zero, size: side)
            content.layoutIfNeeded()
        }
        return Self.blurLevels(of: content, size: side)
    }

    /// `view` drawn at `size`, blurred at six levels (sharp → `maxBlur`), each
    /// padded by 1.5 × the blur so it can spread: what an item — or an emote
    /// of the wheel (#1872) — fades through, blur = 10 pt × (1 − opacity).
    static func blurLevels(of view: UIView, size side: CGSize) -> [UIImage] {
        guard side.width > 0, side.height > 0 else { return [] }
        let content = view
        let pad = Self.maxBlur * 1.5
        let format = UIGraphicsImageRendererFormat.preferred()
        let canvas = CGSize(width: side.width + 2 * pad, height: side.height + 2 * pad)
        let sharp = UIGraphicsImageRenderer(size: canvas, format: format).image { context in
            context.cgContext.translateBy(x: pad, y: pad)
            content.layer.render(in: context.cgContext)
        }
        var levels = [sharp]
        guard let image = sharp.cgImage else { return levels }
        let input = CIImage(cgImage: image)
        for step in 1...5 {
            let sigma = Self.maxBlur * CGFloat(step) / 5 * format.scale / 2
            let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: Double(sigma)).cropped(to: input.extent)
            if let output = Self.ciContext.createCGImage(blurred, from: input.extent) {
                levels.append(UIImage(cgImage: output, scale: format.scale, orientation: .up))
            }
        }
        return levels
    }

    private static let ciContext = CIContext(options: nil)

    // MARK: - The loop

    private func start() {
        if link == nil { lastTick = CACurrentMediaTime() }
        guard link == nil else { return }
        let link = CADisplayLink(target: TickProxy(self), selector: #selector(TickProxy.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    fileprivate func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let dt = min(max(0, now - max(lastTick, holdUntil)), 0.05)
        lastTick = now
        var active = false
        let steps = max(1, Int(ceil(dt / 0.004)))
        let h = dt / Double(steps)
        for _ in 0..<steps {
            for blob in blobs where blob.step(h) { active = true }
            for face in faces.values where face.step(h) { active = true }
        }
        for blob in blobs { blob.render(inset: coverInset(for: blob)) }
        let alive = blobs.filter { !$0.dying }.map(\.renderedRect)
        blobs.removeAll { blob in
            guard blob.dying else { return false }
            let rect = blob.renderedRect
            let hidden = alive.contains { $0.insetBy(dx: 1, dy: 1).contains(rect) }
            if hidden || !blob.moving {
                blob.view.removeFromSuperview()
                return true
            }
            return false
        }
        for face in faces.values { render(face) }
        for (id, face) in faces where face.leaving && !face.moving {
            face.retire()
            faces[id] = nil
        }
        if !active {
            link.invalidate()
            self.link = nil
            // Settled: every item is its live view again, in its bubble.
            for face in faces.values { render(face) }
        }
    }

    /// Puts `face`'s item where its springs say: its live view in its
    /// bubble's glass while it is whole, its picture while it fades.
    ///
    /// ⚠️ An ARRIVING item's live view joins its bubble at once, unseen
    /// (alpha 0), and is only shown once whole: added to the glass at the
    /// end, the glass faded it in on its own clock — empty bubbles for a
    /// beat between the picture and the view (filmed).
    private func render(_ face: Face) {
        let owner = blobs.first { !$0.dying && $0.ids.contains(face.id) }
        guard let content = contents[face.id], let owner, !face.leaving else {
            contents[face.id]?.removeFromSuperview()
            face.renderPicture()
            return
        }
        if content.superview !== owner.view.contentView {
            owner.view.contentView.addSubview(content)
        }
        content.transform = .identity
        content.bounds = CGRect(origin: .zero, size: face.size)
        let frame = owner.view.frame
        content.center = CGPoint(x: face.centreNow.x - frame.minX, y: face.centreNow.y - frame.minY)
        // ⚠️ SHOWN BEFORE IT IS WHOLE: the glass eases its content in on
        // its own clock (~130 ms, filmed as empty bubbles between the
        // picture and the view), so the view comes on two thirds into the
        // fade and the picture finishes over it.
        content.alpha = face.showsLiveView ? 1 : 0
        if face.isWhole {
            face.hidePicture()
        } else {
            face.renderPicture()
        }
    }

    // MARK: - The items as drawn

    /// An item as it is drawn now — its centre in this view's bounds, its
    /// scale and opacity — or nil while it does not exist (not born yet, or
    /// gone). What the wheel hangs on to follow the like through its folds
    /// (#1872, the lab's `presentedIcon(of:)`).
    func presentedFace(of id: String) -> (centre: CGPoint, scale: CGFloat, alpha: CGFloat)? {
        guard let face = faces[id] else { return nil }
        return (face.centreNow, face.scale.x, max(0, min(1, face.alpha.x)))
    }

    // MARK: - Tests

    #if DEBUG
    /// The bubbles standing now (the absorbed ones excluded), in bounds.
    var debugShapes: [CGRect] { blobs.filter { !$0.dying }.map(\.target) }
    #endif

    // MARK: - Spring

    fileprivate struct Spring {
        var x: CGFloat
        var v: CGFloat = 0
        var target: CGFloat
        init(_ x: CGFloat) {
            self.x = x
            target = x
        }

        mutating func step(_ h: Double, k: Double, zeta: Double) {
            let a = CGFloat(k) * (target - x) - CGFloat(2 * zeta * sqrt(k)) * v
            v += a * CGFloat(h)
            x += v * CGFloat(h)
        }

        var settled: Bool { abs(target - x) < 0.01 && abs(v) < 0.05 }
    }

    // MARK: - Bubble

    @MainActor fileprivate final class Blob {
        let view: UIVisualEffectView
        var ids: Set<String>
        var dying = false
        var cx: Spring, cy: Spring, w: Spring, h: Spring
        var outset = Spring(0)
        var bulgeStart: Double?
        var clock: Double = 0
        private let thickness: CGFloat

        init(view: UIVisualEffectView, ids: Set<String>, rect: CGRect) {
            self.view = view
            self.ids = ids
            thickness = min(rect.width, rect.height)
            cx = Spring(rect.midX)
            cy = Spring(rect.midY)
            w = Spring(rect.width)
            h = Spring(rect.height)
        }

        var centre: CGPoint { CGPoint(x: cx.x, y: cy.x) }
        var target: CGRect {
            CGRect(x: cx.target - w.target / 2, y: cy.target - h.target / 2, width: w.target, height: h.target)
        }

        func place(_ rect: CGRect) {
            cx = Spring(rect.midX)
            cy = Spring(rect.midY)
            w = Spring(rect.width)
            h = Spring(rect.height)
        }

        func animate(to rect: CGRect) {
            cx.target = rect.midX
            cy.target = rect.midY
            w.target = rect.width
            h.target = rect.height
        }

        func kickBulge() { bulgeStart = clock }

        var moving: Bool {
            !(cx.settled && cy.settled && w.settled && h.settled && outset.settled) || bulgeStart != nil
        }

        func step(_ dt: Double) -> Bool {
            clock += dt
            let k = SnapGlassColumn.springK
            let zeta = SnapGlassColumn.springZeta
            cx.step(dt, k: k, zeta: zeta)
            cy.step(dt, k: k, zeta: zeta)
            w.step(dt, k: k, zeta: zeta)
            h.step(dt, k: k, zeta: zeta)
            if let start = bulgeStart {
                outset.target = clock - start < SnapGlassColumn.bulgeHold
                    ? SnapGlassColumn.bulgeFraction * thickness : 0
                outset.step(dt, k: SnapGlassColumn.bulgeK, zeta: SnapGlassColumn.bulgeZeta)
                if clock - start > SnapGlassColumn.bulgeHold, outset.settled { bulgeStart = nil }
            } else {
                outset.target = 0
                outset.step(dt, k: k, zeta: zeta)
            }
            return moving
        }

        var renderedRect: CGRect {
            let o = outset.x
            return CGRect(
                x: cx.x - w.x / 2 - o, y: cy.x - h.x / 2 - o,
                width: max(w.x + 2 * o, 1), height: max(h.x + 2 * o, 1)
            )
        }

        func render(inset: CGFloat = 0) {
            view.frame = renderedRect.insetBy(dx: inset, dy: inset)
        }
    }

    // MARK: - An item's face

    @MainActor fileprivate final class Face {
        let id: String
        var cx: Spring, cy: Spring, scale: Spring, alpha: Spring
        private(set) var size: CGSize = .zero
        private(set) var leaving = false
        /// The blurred pictures, while the item fades.
        private let pictureView = UIView()
        private let lower = UIImageView()
        private let upper = UIImageView()
        private var levels: [UIImage] = []
        private var shownLevel = -1

        init(id: String) {
            self.id = id
            cx = Spring(0)
            cy = Spring(0)
            scale = Spring(1)
            alpha = Spring(1)
            pictureView.isUserInteractionEnabled = false
            for view in [lower, upper] {
                view.contentMode = .center
                pictureView.addSubview(view)
            }
        }

        var centreNow: CGPoint { CGPoint(x: cx.x, y: cy.x) }
        var moving: Bool { !(cx.settled && cy.settled && scale.settled && alpha.settled) }
        /// Whole and arrived: the live view stands for it.
        var isWhole: Bool { !leaving && alpha.target == 1 && alpha.x > 0.99 && abs(scale.x - 1) < 0.01 }
        /// Far enough into its arrival for its live view to come on.
        var showsLiveView: Bool { !leaving && alpha.target == 1 && alpha.x > 0.6 }

        func snap(centre: CGPoint, size: CGSize, scale s: CGFloat, alpha a: CGFloat) {
            cx = Spring(centre.x)
            cy = Spring(centre.y)
            scale = Spring(s)
            alpha = Spring(a)
            self.size = size
        }

        func go(to centre: CGPoint, size: CGSize) {
            cx.target = centre.x
            cy.target = centre.y
            scale.target = 1
            alpha.target = 1
            self.size = size
            leaving = false
        }

        func arrive(picture: [UIImage], in layer: UIView) {
            levels = picture
            shownLevel = -1
            layer.addSubview(pictureView)
        }

        func leave(to centre: CGPoint, scale s: CGFloat, picture: [UIImage], in layer: UIView) {
            cx.target = centre.x
            cy.target = centre.y
            scale.target = s
            alpha.target = 0
            leaving = true
            levels = picture
            shownLevel = -1
            layer.addSubview(pictureView)
        }

        func step(_ dt: Double) -> Bool {
            let k = SnapGlassColumn.springK
            let zeta = SnapGlassColumn.springZeta
            cx.step(dt, k: k, zeta: zeta)
            cy.step(dt, k: k, zeta: zeta)
            scale.step(dt, k: k, zeta: zeta)
            alpha.step(dt, k: k, zeta: zeta)
            return moving
        }

        func hidePicture() {
            pictureView.removeFromSuperview()
        }

        func retire() {
            pictureView.removeFromSuperview()
        }

        /// Blur = 10 pt × (1 − opacity), between two of the six levels.
        func renderPicture() {
            guard levels.count > 1, let first = levels.first else { return }
            let a = max(0, min(1, alpha.x))
            pictureView.bounds = CGRect(origin: .zero, size: first.size)
            lower.frame = pictureView.bounds
            upper.frame = pictureView.bounds
            pictureView.center = centreNow
            let s = max(scale.x, 0.01)
            pictureView.transform = CGAffineTransform(scaleX: s, y: s)
            let position = (1 - a) * CGFloat(levels.count - 1)
            let index = min(Int(position), levels.count - 2)
            let fraction = position - CGFloat(index)
            if index != shownLevel {
                lower.image = levels[index]
                upper.image = levels[index + 1]
                shownLevel = index
            }
            lower.alpha = 1 - fraction
            upper.alpha = fraction
            pictureView.alpha = a
        }
    }
}

/// Holds the column for its display link without keeping it alive.
@MainActor
private final class TickProxy: NSObject {
    weak var column: SnapGlassColumn?
    init(_ column: SnapGlassColumn) { self.column = column }

    @objc func tick(_ link: CADisplayLink) {
        guard let column else { return link.invalidate() }
        column.tick(link)
    }
}
