import MediaPlayback
import QuartzCore
import UIKit

/// Effects: the dials — brightness, contrast, saturation, warmth, highlights,
/// shadows, sharpness, vignette, grain — and one stylised effect, on photos and
/// videos alike.
///
/// ⚠️ **ONE PATH FOR BOTH KINDS OF PAGE.** A change is written through
/// `change`, then announced as `.look`: the screen redraws a photograph and
/// hands a playing clip a live look — no new item, which a ruler dragged at
/// 60Hz could never afford (`MediaEditorHosting.editsDidChange`).
///
/// ⚠️ **WHILE A FINGER IS ON THE RULER, THE SCREEN IS TOLD AT MOST 30 TIMES A
/// SECOND.** Every value is stored the moment it arrives; only the redraw is
/// paced. A photograph's render is latest-wins, but each one that lands behind
/// the edits starts another — announced at the ruler's own rate, those chains
/// would pile up faster than they land. The lift always announces the last
/// value, so nothing is left behind.
///
/// ⚠️ **AND THE SCREEN'S SPINNER HOLDS ITS TONGUE MEANWHILE** (`isTracking`):
/// a render is always in flight during a drag, and a spinner flashing under a
/// finger reads as the picture failing to keep up.
///
/// ⚠️ **THE UNDO ARROW TAKES AWAY THE DIALS AND THE EFFECT, AND NOTHING
/// ELSE.** The preset belongs to Filters, the cut to Crop and Trim.
@MainActor
final class MediaEditorEffectsMode: MediaEditorMode {
    private weak var host: (any MediaEditorHosting)?

    init(host: any MediaEditorHosting) {
        self.host = host
    }

    /// The fastest the screen is told about a change while a finger is down.
    static let liveInterval: CFTimeInterval = 1.0 / 30

    /// Whether a finger is on the ruler.
    private(set) var isTracking = false

    /// The page the tools were last opened or settled on.
    private var shownID: String?
    /// When the screen was last told about a change during a drag.
    private var lastAnnounced: CFTimeInterval = 0
    /// The announcement a drag is still owed, if one is waiting for its turn.
    private var owed: Task<Void, Never>?
    /// What the effect pills were last dressed from, so an unchanged request
    /// renders nothing.
    private var dressedFrom: CardsSource?
    private var dressing: Task<Void, Never>?

    private struct CardsSource: Equatable {
        let id: String
        let look: FrameLook
        let crop: MediaCrop
        let fromHeldPicture: Bool
    }

    private lazy var tools: MediaEffectsToolsView = {
        let tools = MediaEffectsToolsView()
        tools.onDial = { [weak self] key, value, tracking in
            self?.write(tracking: tracking) { $0.adjustments[key] = value }
        }
        tools.onEffect = { [weak self] effect, tracking in
            self?.write(tracking: tracking) { $0.effect = effect }
        }
        tools.onTracking = { [weak self] tracking in
            self?.isTracking = tracking
        }
        return tools
    }()

    /// ⚠️ **ALWAYS THE TOOLS, ON A PHOTO AND ON A VIDEO.** Non-nil is also what
    /// lets a repeat tap on the category open them — Effects is chosen at
    /// launch over an empty band.
    var tenant: UIView? { tools }

    func open(for id: String, item: MediaLibraryItem) {
        host?.showInBand(tools)
        present(id)
    }

    func bandWillChange(to accessory: UIView?) {
        guard accessory !== tools else { return }
        settleTheDrag()
        tools.browse(animated: false)
    }

    /// ⚠️ **ANOTHER PAGE PUTS THE RULER AWAY.** A ruler left up would show the
    /// previous page's value over a picture that does not carry it.
    func pageDidSettle(on id: String?) {
        guard let host, host.bandContent === tools, let id, id != shownID else { return }
        settleTheDrag()
        tools.browse(animated: false)
        present(id)
    }

    func screenWillDisappear() {
        settleTheDrag()
    }

    var canReset: Bool {
        guard let host, let id = host.currentItemID else { return false }
        let edits = host.edits(for: id)
        return !edits.adjustments.isNeutral || edits.effect != nil
    }

    func reset() {
        guard let host, let id = host.currentItemID, canReset else { return }
        settleTheDrag()
        host.change(id) {
            $0.adjustments = .neutral
            $0.effect = nil
        }
        host.editsDidChange(id, .look)
        tools.browse(animated: true)
        present(id)
    }

    // MARK: - Writing

    /// Stores the change at once, and tells the screen now or on the next
    /// beat — see the type's note.
    private func write(tracking: Bool, _ mutate: (inout MediaEdits) -> Void) {
        guard let host, let id = shownID ?? host.currentItemID else { return }
        host.change(id, mutate)
        guard tracking else {
            owed?.cancel()
            owed = nil
            announce(id)
            dressCards(for: id)
            return
        }
        let wait = Self.liveInterval - (CACurrentMediaTime() - lastAnnounced)
        guard wait > 0 else {
            announce(id)
            return
        }
        guard owed == nil else { return }
        owed = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled else { return }
            owed = nil
            announce(id)
        }
    }

    private func announce(_ id: String) {
        lastAnnounced = CACurrentMediaTime()
        host?.editsDidChange(id, .look)
    }

    /// A drag that ends because the band or the screen is going: the finger is
    /// no longer anyone's, and a waiting announcement is sent now.
    private func settleTheDrag() {
        isTracking = false
        guard let pending = owed else { return }
        pending.cancel()
        owed = nil
        if let id = shownID { announce(id) }
    }

    // MARK: - Showing

    private func present(_ id: String) {
        guard let host else { return }
        shownID = id
        tools.show(host.edits(for: id).look)
        dressCards(for: id)
    }

    /// Renders the effect pills' pictures from the page's own picture, cut and dressed
    /// as the page is, each wearing its effect.
    ///
    /// ⚠️ **OFF THE MAIN ACTOR, AND LATEST WINS.** Twelve looks are twelve Core
    /// Image renders; a result is kept only if the page and its look are still
    /// what it was rendered for.
    private func dressCards(for id: String) {
        guard let host else { return }
        let edits = host.edits(for: id)
        let held = host.heldPicture.flatMap { $0.id == id ? $0.image : nil }
        let source = CardsSource(
            id: id, look: FrameLook(preset: edits.filter, adjustments: edits.adjustments),
            crop: edits.crop, fromHeldPicture: held != nil
        )
        guard source != dressedFrom else { return }
        dressedFrom = source
        dressing?.cancel()
        let side = MediaEffectsToolsView.thumbnailSide
        let pixels = side * max(1, tools.traitCollection.displayScale)
        let library = host.library
        dressing = Task { [weak self] in
            var picture = held
            if picture == nil {
                picture = await library.thumbnail(for: id, size: CGSize(width: side, height: side))
            }
            guard let picture, !Task.isCancelled else {
                // Nothing to dress from: the next request for the same page
                // must be allowed to try again.
                if self?.dressedFrom == source { self?.dressedFrom = nil }
                return
            }
            let pictures = await Task.detached(priority: .userInitiated) {
                Self.cards(from: picture, source: source, pixels: pixels)
            }.value
            guard let self, !Task.isCancelled, dressedFrom == source else { return }
            tools.show(pictures: pictures)
        }
    }

    nonisolated private static func cards(
        from picture: UIImage, source: CardsSource, pixels: CGFloat
    ) -> [LookEffectKind: UIImage] {
        let base = MediaLookThumbnails.base(picture, crop: source.crop, pixels: pixels)
        var pictures: [LookEffectKind: UIImage] = [:]
        for kind in LookEffectKind.allCases {
            var look = source.look
            look.effect = LookEffect(kind: kind, intensity: MediaEffectsCatalog.startingIntensity)
            pictures[kind] = MediaLookThumbnails.dressed(base, in: look)
        }
        return pictures
    }

    // MARK: - Tests

    /// Internal for tests: the tools, whether or not the band holds them.
    var debugTools: MediaEffectsToolsView { tools }
    /// Internal for tests: waits for the effect pills to be dressed.
    var debugCardsAreDressed: Bool {
        LookEffectKind.allCases.allSatisfy { tools.debugPicture(for: $0) != nil }
    }
}
