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
        /// The crop the cards were CUT BY, which is `.untouched` whenever they
        /// are drawn from the reference photograph — see `fromReference`.
        let crop: MediaCrop
        let fromHeldPicture: Bool
        /// Whether these cards were drawn from `MediaLookReference` rather than
        /// from the page's own picture.
        ///
        /// ⚠️ **IN THE KEY EVEN THOUGH THE PAGE'S ID IS ALREADY IN IT.** Two
        /// pages of different media never share an id, so the medium alone can
        /// never smuggle the previous page's cards onto this one — but the
        /// reference can also be ABSENT (a bundle with no such resource), and
        /// then the very same video is dressed from its poster instead. Without
        /// this field the key would call those two sets of cards the same
        /// thing, and whichever was rendered first would stand.
        let fromReference: Bool
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
        tools.onClear = { [weak self] in self?.reset() }
        tools.onRevert = { [weak self] in self?.revert() }
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

    /// The look each page was wearing when this tab opened on it — what the ↺
    /// icon puts back.
    ///
    /// ⚠️ **PER PAGE, AND TAKEN THE FIRST TIME THE TAB SHOWS THAT PAGE.** A
    /// swipe to another picture while Effects is open is that picture's opening
    /// too; taking one snapshot for the whole session would offer to put a
    /// look back on a page that never wore it.
    private var openedOn: [String: FrameLook] = [:]

    func bandWillChange(to accessory: UIView?) {
        guard accessory !== tools else { return }
        settleTheDrag()
        tools.openOnTheFirstDial()
        // The tab is closing: the next opening is a new one, and what it opened
        // on then is not what it will open on next time.
        openedOn.removeAll()
    }

    /// ⚠️ **ANOTHER PAGE PUTS THE RULER BACK ON THE FIRST DIAL.** A ruler left
    /// where it was would show the previous page's value over a picture that
    /// does not carry it.
    func pageDidSettle(on id: String?) {
        guard let host, host.bandContent === tools, let id, id != shownID else { return }
        settleTheDrag()
        tools.openOnTheFirstDial()
        present(id)
    }

    /// A step back or forward may have moved the dials or the effect under the
    /// tools; they state what the page wears now.
    func editsWereRestored(for id: String) {
        guard let host, host.bandContent === tools, id == shownID else { return }
        settleTheDrag()
        present(id)
    }

    func screenWillDisappear() {
        settleTheDrag()
    }

    /// Whether the ⊘ icon has anything to take off. Its own, not a seam: the
    /// header's arrows ask no mode what it owns.
    private var canReset: Bool {
        guard let host, let id = host.currentItemID else { return false }
        let edits = host.edits(for: id)
        return !edits.adjustments.isNeutral || edits.effect != nil
    }

    private func reset() {
        guard let host, let id = host.currentItemID, canReset else { return }
        settleTheDrag()
        host.change(id) {
            $0.adjustments = .neutral
            $0.effect = nil
        }
        host.editsDidChange(id, .look)
        present(id)
    }

    /// The ↺ icon: the dials and the effect back to what this tab opened on.
    ///
    /// ⚠️ **THE PRESET IS NOT TOUCHED, EXACTLY AS THE ⊘ ICON DOES NOT TOUCH
    /// IT.** The look Filters chose belongs to Filters; this tab owns the dials
    /// and the effect and puts back only those.
    private func revert() {
        guard let host, let id = host.currentItemID, let opening = openedOn[id] else { return }
        let edits = host.edits(for: id)
        guard edits.adjustments != opening.adjustments || edits.effect != opening.effect else { return }
        settleTheDrag()
        host.change(id) {
            $0.adjustments = opening.adjustments
            $0.effect = opening.effect
        }
        host.editsDidChange(id, .look)
        present(id)
    }

    // MARK: - Writing

    /// Stores the change at once, and tells the screen now or on the next
    /// beat — see the type's note.
    private func write(tracking: Bool, _ mutate: (inout MediaEdits) -> Void) {
        guard let host, let id = shownID ?? host.currentItemID else { return }
        // ⚠️ **A DRAG IS ONE STEP IN THE HISTORY, NOT SIXTY.** Only the mode
        // that owns the finger knows whether one is down, so it says; the lift
        // settles, and the state the drag started from is the one the back
        // arrow hands back.
        host.change(id, settling: !tracking, mutate)
        // Cheap, and the ↺ icon is wrong the moment it is not asked: it lights
        // as soon as the page differs from what the tab opened on.
        tools.setCanRevert(canRevert(id, wearing: host.edits(for: id).look))
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
        let look = host.edits(for: id).look
        if openedOn[id] == nil { openedOn[id] = look }
        tools.show(look)
        tools.setCanRevert(canRevert(id, wearing: look))
        dressCards(for: id)
    }

    /// Whether this page is wearing something other than what the tab opened
    /// on — the ↺ icon's whole question.
    private func canRevert(_ id: String, wearing look: FrameLook) -> Bool {
        guard let opening = openedOn[id] else { return false }
        return look.adjustments != opening.adjustments || look.effect != opening.effect
    }

    /// Renders the effect pills' pictures — from the page's own picture on a
    /// photograph, cut and dressed as the page is, and from the reference
    /// photograph on a video — each wearing its effect.
    ///
    /// ⚠️ **A VIDEO'S PILLS ARE DRAWN FROM `MediaLookReference`, WHOLE.** Its
    /// note has the why, and the crop it is NOT cut by. A clip whose reference
    /// is missing falls back to its poster, which is where this started.
    ///
    /// ⚠️ **OFF THE MAIN ACTOR, AND LATEST WINS.** Twelve looks are twelve Core
    /// Image renders; a result is kept only if the page and its look are still
    /// what it was rendered for.
    private func dressCards(for id: String) {
        guard let host else { return }
        let edits = host.edits(for: id)
        let reference = MediaLookReference.standsIn(for: host.item(id)) ? MediaLookReference.picture : nil
        // Asked for only when it is going to be used: on a video the page's
        // poster is not wanted, and holding it here would make the key lie.
        let held = reference == nil ? host.heldPicture.flatMap { $0.id == id ? $0.image : nil } : nil
        let source = CardsSource(
            id: id, look: FrameLook(preset: edits.filter, adjustments: edits.adjustments),
            // ⚠️ **THE CROP THAT WILL BE APPLIED, NOT THE ONE THE PAGE
            // CARRIES.** The reference is never cut, so a video whose author
            // moves the crop box must NOT re-render twelve cards that cannot
            // differ by a pixel.
            crop: reference == nil ? edits.crop : .untouched,
            fromHeldPicture: held != nil, fromReference: reference != nil
        )
        guard source != dressedFrom else { return }
        dressedFrom = source
        dressing?.cancel()
        let side = MediaEffectsToolsView.thumbnailSide
        let pixels = side * max(1, tools.traitCollection.displayScale)
        let library = host.library
        dressing = Task { [weak self] in
            var picture = reference ?? held
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
            look.effect = LookEffect(kind: kind, intensity: MediaEffectsCatalog.previewIntensity)
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
