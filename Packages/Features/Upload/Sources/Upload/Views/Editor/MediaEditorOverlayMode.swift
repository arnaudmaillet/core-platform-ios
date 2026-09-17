import MediaPlayback
import UIKit

/// Text and Stickers: things laid over the picture, dragged, pinched and turned
/// on the canvas.
///
/// ⚠️ **ONE MODE FOR BOTH CATEGORIES.** Both edit the same overlay layer on the
/// same page; only the tools in the band differ. The screen sets `kind` before
/// it opens the mode.
///
/// ⚠️ **STICKERS REUSE EVERYTHING BUT THE TOOLS.** Their band offers "Add
/// sticker", which opens `MediaStickerPickerViewController` as a sheet; the
/// pick lands at the centre, and the layer, the lock, the gestures and the bin
/// are text's.
///
/// ⚠️ **THE CANVAS IS HELD STILL WHILE TEXT IS OPEN** (`lockCanvas(by:
/// .overlays)`): a drag on an overlay must not page the canvas, pop the screen
/// or pull the sheet shut — dismissal is velocity-dominated, so only
/// `isModalInPresentation` makes that safe. Every way out gives the lock back:
/// another tenant in the band (`bandWillChange`) and the screen going
/// (`screenWillDisappear`).
///
/// ⚠️ **OVERLAYS ARE DRAWN IN EVERY MODE AND MOVED IN THIS ONE ONLY.** `dress`
/// fills every page's layer as the canvas configures it; only the page in front
/// of the author, while this mode is open, takes touches.
@MainActor
final class MediaEditorOverlayMode: MediaEditorMode {
    /// Which of the two categories the mode is open as.
    enum Kind {
        case text
        case stickers
    }

    var kind: Kind = .text

    private weak var host: (any MediaEditorHosting)?

    /// Whether the overlays can be moved — the canvas is locked while it is true.
    private(set) var isOpen = false
    /// The page whose overlays can be moved, while open.
    private var openID: String?

    /// What is being typed, and where it goes.
    private var composing: (pageID: String, overlayID: String?)?
    private var composer: MediaTextComposerView?

    init(host: any MediaEditorHosting) {
        self.host = host
    }

    private lazy var textTools: MediaOverlayToolsView = {
        let tools = MediaOverlayToolsView(addTitle: "Add text", addSymbol: "textformat")
        tools.onAction = { [weak self] action in self?.toolsDid(action) }
        return tools
    }()

    private lazy var stickerTools: MediaOverlayToolsView = {
        let tools = MediaOverlayToolsView(addTitle: "Add sticker", addSymbol: "face.smiling")
        tools.onAction = { [weak self] action in self?.toolsDid(action) }
        return tools
    }()

    /// The tools of the category the mode is open as.
    private var tools: MediaOverlayToolsView { kind == .text ? textTools : stickerTools }

    /// Whether an overlay belongs to the category the mode is open as.
    private func belongs(_ overlay: FrameOverlay) -> Bool {
        switch overlay.content {
        case .text: kind == .text
        case .emoji, .sticker: kind == .stickers
        }
    }

    /// Lays the overlays stored for `id` into `cell`'s overlay host — called
    /// every time the canvas configures a page, because a recycled cell
    /// arrives carrying the previous picture's.
    func dress(_ cell: MediaEditorPageCell, for id: String) {
        guard let host else { return }
        let layer = cell.overlayHost
        layer.onEvent = { [weak self] event in self?.layerDid(event, on: id) }
        layer.show(host.edits(for: id).overlays)
        layer.isEditable = isOpen && id == openID
        cell.overlaysDidChange()
    }

    var tenant: UIView? {
        guard host?.currentItemID != nil else { return nil }
        return tools
    }

    func open(for id: String, item: MediaLibraryItem) {
        guard let host else { return }
        host.showInBand(tools)
        begin(on: id)
    }

    func bandWillChange(to accessory: UIView?) {
        guard isOpen, accessory !== textTools, accessory !== stickerTools else { return }
        close()
    }

    /// ⚠️ **THE LAYER IS REBUILT FOR THE PAGE THAT SETTLED**, and while the mode
    /// is open, that page becomes the one whose overlays move — the previous
    /// page's go inert.
    func pageDidSettle(on id: String?) {
        guard let host else { return }
        if isOpen, id != openID {
            if let previous = openID, let cell = host.pageCell(for: previous) {
                cell.overlayHost.isEditable = false
            }
            openID = id
        }
        if let id, let cell = host.pageCell(for: id) { dress(cell, for: id) }
        if isOpen { refreshTools() }
    }

    /// Gives the lock back and puts the keyboard away. The tools stay in the
    /// band; a tap on them opens the mode again (`toolsDid`).
    func screenWillDisappear() {
        close()
    }

    /// Always false, on purpose: each overlay has its own delete, and a one-tap
    /// "remove every overlay" is too destructive.
    var canReset: Bool { false }

    func reset() {}

    // MARK: - Opening and closing

    private func begin(on id: String) {
        guard let host else { return }
        if let previous = openID, previous != id, let cell = host.pageCell(for: previous) {
            cell.overlayHost.isEditable = false
        }
        isOpen = true
        openID = id
        host.lockCanvas(by: .overlays)
        if let cell = host.pageCell(for: id) { dress(cell, for: id) }
        refreshTools()
    }

    private func close() {
        finishComposing()
        guard isOpen else { return }
        isOpen = false
        if let id = openID, let cell = host?.pageCell(for: id) {
            cell.overlayHost.isEditable = false
        }
        openID = nil
        host?.unlockCanvas(by: .overlays)
    }

    private func refreshTools() {
        guard let host, let id = openID ?? host.currentItemID else { return }
        tools.show(host.edits(for: id).overlays.filter(belongs))
    }

    // MARK: - What the tools and the layer say

    private func toolsDid(_ action: MediaOverlayToolsView.Action) {
        guard let host, let id = host.currentItemID else { return }
        // ⚠️ **A TOOL TAPPED AFTER THE SCREEN CAME BACK REOPENS THE MODE.** The
        // tools stay in the band while "Next" is away; the lock does not.
        if !isOpen || openID != id { begin(on: id) }
        switch action {
        case .add where kind == .stickers: pickSticker(on: id)
        case .add: compose(on: id, editing: nil)
        case .edit(let overlayID) where kind == .stickers: host.pageCell(for: id)?.overlayHost.select(overlayID)
        case .edit(let overlayID): compose(on: id, editing: overlayID)
        case .delete(let overlayID): remove(overlayID, on: id)
        case .bringToFront(let overlayID): bringToFront(overlayID, on: id)
        }
    }

    private func layerDid(_ event: MediaOverlayLayerView.Event, on id: String) {
        switch event {
        case .placed(let overlay):
            store(on: id) { overlays in
                guard let index = overlays.firstIndex(where: { $0.id == overlay.id }) else { return }
                overlays[index].placement = overlay.placement
            }
        case .delete(let overlayID):
            remove(overlayID, on: id)
        case .edit(let overlayID):
            compose(on: id, editing: overlayID)
        case .bringToFront(let overlayID):
            bringToFront(overlayID, on: id)
        }
    }

    private func remove(_ overlayID: String, on id: String) {
        store(on: id) { $0.removeAll { $0.id == overlayID } }
    }

    /// The array's order is the z-order: the front is the end.
    private func bringToFront(_ overlayID: String, on id: String) {
        store(on: id) { overlays in
            guard let index = overlays.firstIndex(where: { $0.id == overlayID }) else { return }
            overlays.append(overlays.remove(at: index))
        }
    }

    /// Every overlay edit: written through the host, then drawn again from what
    /// was written — never from what the layer believes.
    private func store(on id: String, _ mutate: (inout [FrameOverlay]) -> Void) {
        guard let host else { return }
        host.change(id) { mutate(&$0.overlays) }
        host.editsDidChange(id, .overlays)
        if let cell = host.pageCell(for: id) { dress(cell, for: id) }
        refreshTools()
    }

    // MARK: - Stickers

    /// Opens the sticker sheet; a pick lands at the centre of the picture and
    /// is held, ready to be moved.
    private func pickSticker(on id: String) {
        guard let host else { return }
        let picker = MediaStickerPickerViewController()
        picker.onPick = { [weak self] content in self?.place(content, on: id) }
        if let sheet = picker.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        picker.loadViewIfNeeded()
        self.picker = picker
        host.presentSheet(picker)
    }

    private func place(_ content: FrameOverlay.Content, on id: String) {
        let layer = host?.pageCell(for: id)?.overlayHost
        let centre = layer?.newCentre ?? CGPoint(x: 0.5, y: 0.5)
        let overlay = FrameOverlay(content: content, placement: OverlayPlacement(centre: centre))
        store(on: id) { $0.append(overlay) }
        layer?.select(overlay.id)
    }

    /// The last sheet opened, for tests.
    private weak var picker: MediaStickerPickerViewController?

    // MARK: - Typing

    /// Opens the composer over the editor, on a new text or on `overlayID`'s.
    ///
    /// ⚠️ **INSIDE THE EDITOR'S OWN VIEW, REACHED THROUGH THE HOST AS A
    /// CONTROLLER.** `MediaEditorHosting` offers sheets, not a view — and a
    /// sheet is exactly what the composer must not be (see
    /// `MediaTextComposerView`).
    private func compose(on id: String, editing overlayID: String?) {
        guard let host, let screen = (host as? UIViewController)?.view else { return }
        finishComposing()
        let layer = host.pageCell(for: id)?.overlayHost
        var style = TextOverlay.fresh
        if let overlayID,
           let stored = host.edits(for: id).overlays.first(where: { $0.id == overlayID }),
           case .text(let text) = stored.content {
            style = text
            layer?.item(for: overlayID)?.isHidden = true
        }
        let composer = MediaTextComposerView(frame: screen.bounds)
        composer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        composer.onFinish = { [weak self] text in self?.composed(text) }
        composing = (id, overlayID)
        self.composer = composer
        screen.addSubview(composer)
        composer.layoutIfNeeded()
        composer.begin(with: style, mediaWidth: layer?.mediaRect.width ?? screen.bounds.width)
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        composer.alpha = 0
        UIView.animate(withDuration: 0.2) { composer.alpha = 1 }
    }

    /// "Done" on whatever is being typed, if anything is.
    private func finishComposing() {
        composer?.finish()
    }

    /// ⚠️ **EMPTY WORDS REMOVE THE TEXT**, whether it was new or not.
    private func composed(_ typed: TextOverlay) {
        guard let (id, overlayID) = composing else { return }
        composing = nil
        if let composer {
            self.composer = nil
            composer.removeFromSuperview()
        }
        var text = typed
        text.text = typed.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let layer = host?.pageCell(for: id)?.overlayHost
        if let overlayID {
            layer?.item(for: overlayID)?.isHidden = false
            store(on: id) { overlays in
                guard let index = overlays.firstIndex(where: { $0.id == overlayID }) else { return }
                if text.text.isEmpty {
                    overlays.remove(at: index)
                } else {
                    overlays[index].content = .text(text)
                }
            }
        } else if !text.text.isEmpty {
            let centre = layer?.newCentre ?? CGPoint(x: 0.5, y: 0.5)
            let overlay = FrameOverlay(content: .text(text), placement: OverlayPlacement(centre: centre))
            store(on: id) { $0.append(overlay) }
            layer?.select(overlay.id)
        }
    }

    // MARK: - Tests

    /// Internal for tests: the text tools, whatever the band holds.
    var debugTextTools: MediaOverlayToolsView { textTools }
    /// Internal for tests: the sticker tools, whatever the band holds.
    var debugStickerTools: MediaOverlayToolsView { stickerTools }
    /// Internal for tests: the sticker sheet last opened.
    var debugPicker: MediaStickerPickerViewController? { picker }
    /// Internal for tests: the composer, while one is up.
    var debugComposer: MediaTextComposerView? { composer }
}
