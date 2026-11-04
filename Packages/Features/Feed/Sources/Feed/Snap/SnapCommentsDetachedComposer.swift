import DesignSystem
import UIKit

/// The comments sheet's composer, edited in a bar of its own over the
/// keyboard — TikTok's and Instagram's way (#2087, a trial, the owner
/// 2026-11-04, `CommentsV2.detachedComposer`).
///
/// ⚠️ UIKIT RAISES A SHEET OVER THE KEYBOARD OF A FIELD IN IT, and nothing
/// turns that off; taking the rise back frame by frame was tried and ran
/// away. A field OUTSIDE the sheet leaves it be (measured, 2026-11-04): the
/// sheet's own bar never edits — a tap on it, a reply, hand this bar the
/// keyboard instead. It stands on the keys' guide, over the rows, on the
/// soft frost the app's composers stand on; the sheet, its rows and the
/// media do not move. The draft goes back to the sheet's bar as the
/// keyboard goes.
///
/// ⚠️ NOTHING CHANGES AT THE HAND-OVER (the owner, 2026-11-04): the bar
/// takes the sheet's bar's place exactly, and its frost — across the sheet's
/// width, not the screen's — comes in only as it rises: an opaque band
/// covered the sheet's own soft edge and its corners at once.
@MainActor
final class SnapCommentsDetachedComposer {
    private weak var source: CommentsInputBar?
    private let bar = CommentsInputBar()
    /// Under the bar, from its top to the keys' top, across the sheet: the
    /// rows recede under it. ⚠️ ONE RAMP OVER ITS WHOLE HEIGHT, as the sheet's
    /// own soft edge, only shorter (the owner, 2026-11-04): none at the bar's
    /// top — never over it — the most at the keys.
    private let band = ProgressiveFrostView(
        maskColors: SnapCommentsLayout.footerFrostMaskColors,
        maskLocations: SnapCommentsLayout.footerFrostMaskLocations
    )
    /// The sheet's view: the band spans its width.
    private weak var sheetView: UIView?
    /// Where the bar's foot stands at rest, in the window.
    private var restingBottom: CGFloat = 0
    /// Over how much of its rise the frost comes in.
    private static let frostRise: CGFloat = 48
    /// Whether the bar edits, for the sheet (a tap on it ends editing, its
    /// height holds meanwhile).
    var onEditingChanged: ((Bool) -> Void)?
    private(set) var isEditingDetached = false
    /// The window's whole bounds: its keyboard guide is the keys' (the
    /// window's own does not follow them, measured 2026-11-04). While the
    /// bar edits, it takes every touch outside the bar.
    private let host = PassThroughView()
    private let observers = NotificationObserverBag()
    private var isEditing = false

    init(source: CommentsInputBar, sheetView: UIView) {
        self.source = source
        self.sheetView = sheetView
        host.onLayout = { [weak self] in self?.followRise() }
        // Any touch outside the bar while the keys are up puts them away,
        // and nothing else — a row's own action never fires with it
        // (TikTok's way, the owner 2026-11-04).
        host.onTouchOutside = { [weak self] in self?.endEditing() }
        source.shouldBeginEditing = { [weak self] in
            self?.beginEditing()
            return false
        }
        bar.tracksKeyboard = false
        bar.onSend = { [weak self] text in self?.send(text) }
        band.effect = UIBlurEffect(style: SnapCommentsLayout.frostStyle)
        band.setRampStrength(0)
        let center = NotificationCenter.default
        observers.add(center.addObserver(
            forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.keyboardWillHide() } })
        observers.add(center.addObserver(
            forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.tearDown() } })
    }

    /// The keyboard into the bar over it, the sheet's bar hidden meanwhile.
    private func beginEditing() {
        guard !isEditing, let source, let window = source.window else { return }
        isEditing = true
        bar.mirrorLook(of: source)
        bar.draftText = source.draftText
        bar.onVoiceNote = source.onVoiceNote
        let frame = source.convert(source.bounds, to: window)
        let sheetFrame = sheetView.map { $0.convert($0.bounds, to: window) } ?? window.bounds
        restingBottom = frame.maxY
        band.setRampStrength(0)
        host.frame = window.bounds
        host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(host)
        for view in [band, bar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(view)
        }
        let guide = host.keyboardLayoutGuide
        guide.usesBottomSafeArea = false
        // ⚠️ THE SHEET'S SCALE (measured, 2026-11-04): a floating sheet lays
        // its content out at the screen's width and draws it scaled down
        // (×0.96 on an iPhone 18 Pro) — its bar 43.2 pt high for this one's
        // 45, a jump in size at the hand-over. This bar is laid out at the
        // sheet's bar's own size and drawn at its scale, about its centre:
        // its constraints place it unscaled, so its foot is offset by the
        // half-height the scale takes off.
        let scale = source.bounds.width > 0 ? frame.width / source.bounds.width : 1
        bar.transform = CGAffineTransform(scaleX: scale, y: scale)
        let shrink = source.bounds.height * (1 - scale) / 2
        NSLayoutConstraint.activate([
            bar.widthAnchor.constraint(equalToConstant: source.bounds.width),
            bar.centerXAnchor.constraint(equalTo: host.leadingAnchor, constant: frame.midX),
            // Where the sheet's bar stands with no keyboard, on the keys' top
            // with one, riding them both ways.
            bar.bottomAnchor.constraint(equalTo: guide.topAnchor, constant: shrink - Spacing.sm)
                .withPriority(.defaultHigh),
            bar.bottomAnchor.constraint(lessThanOrEqualTo: host.topAnchor, constant: frame.maxY + shrink),
            band.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: sheetFrame.minX),
            band.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: sheetFrame.maxX - window.bounds.width),
            band.topAnchor.constraint(equalTo: bar.topAnchor, constant: shrink),
            band.bottomAnchor.constraint(equalTo: guide.topAnchor),
        ])
        host.layoutIfNeeded()
        hideSource(true)
        isEditingDetached = true
        onEditingChanged?(true)
        bar.focusComposer()
    }

    /// ⚠️ THE SHEET'S BAR'S CONTENT, NOT THE BAR (measured, 2026-11-04): the
    /// sheet's bottom soft edge is drawn for it (its edge pocket), and gone
    /// with the bar's alpha — the sheet's foot lost its frost as the keys rose.
    private var hiddenSourceViews: [UIView] = []

    private func hideSource(_ hidden: Bool) {
        if hidden, let source {
            hiddenSourceViews = source.subviews.filter { $0.alpha > 0 }
            hiddenSourceViews.forEach { $0.alpha = 0 }
        } else {
            hiddenSourceViews.forEach { $0.alpha = 1 }
            hiddenSourceViews = []
        }
    }

    /// The frost as the bar rises: none where the sheet's bar stood, whole
    /// once it has risen `frostRise`.
    private func followRise() {
        guard isEditing else { return }
        let rise = restingBottom - bar.frame.maxY
        band.setRampStrength(min(1, max(0, rise / Self.frostRise)))
    }

    private func send(_ text: String) {
        guard let source else { return }
        source.draftText = text
        source.send()
    }

    /// The draft back to the sheet's bar as the keyboard goes.
    private func keyboardWillHide() {
        guard isEditing, let source else { return }
        source.draftText = bar.draftText
    }

    func endEditing() {
        bar.endEditing(true)
    }

    /// The bar gone, the sheet's bar back.
    func tearDown() {
        guard isEditing else { return }
        isEditing = false
        source?.draftText = bar.draftText
        bar.endEditing(true)
        bar.removeFromSuperview()
        bar.transform = .identity
        band.removeFromSuperview()
        host.removeFromSuperview()
        hideSource(false)
        isEditingDetached = false
        onEditingChanged?(false)
    }
}

/// The bar's host: its subviews take their touches; any other touch it
/// takes itself and reports, once, as it begins.
private final class PassThroughView: UIView {
    var onLayout: (() -> Void)?
    var onTouchOutside: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        onTouchOutside?()
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
