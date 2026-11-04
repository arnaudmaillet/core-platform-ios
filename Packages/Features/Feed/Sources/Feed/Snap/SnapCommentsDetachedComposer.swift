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
/// keyboard instead. It stands on the window's keyboard guide, over the rows,
/// on a band of the sheet's ground; the sheet, its rows and the media do not
/// move. The draft goes back to the sheet's bar as the keyboard goes.
@MainActor
final class SnapCommentsDetachedComposer {
    private weak var source: CommentsInputBar?
    private let bar = CommentsInputBar()
    /// Under the bar, from a breath over it to under the keys: the rows do
    /// not show around it.
    private let band = UIView()
    /// The window's whole bounds, touches passing through but for the bar:
    /// its keyboard guide is the keys' (the window's own does not follow
    /// them, measured 2026-11-04).
    private let host = PassThroughView()
    private let observers = NotificationObserverBag()
    private var isEditing = false

    init(source: CommentsInputBar) {
        self.source = source
        source.shouldBeginEditing = { [weak self] in
            self?.beginEditing()
            return false
        }
        bar.tracksKeyboard = false
        bar.onSend = { [weak self] text in self?.send(text) }
        band.isUserInteractionEnabled = false
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
        band.backgroundColor = .systemBackground
        let frame = source.convert(source.bounds, to: window)
        host.frame = window.bounds
        host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(host)
        for view in [band, bar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(view)
        }
        let guide = host.keyboardLayoutGuide
        guide.usesBottomSafeArea = false
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: frame.minX),
            bar.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: frame.maxX - window.bounds.width),
            // Where the sheet's bar stands with no keyboard, on the keys' top
            // with one, riding them both ways.
            bar.bottomAnchor.constraint(equalTo: guide.topAnchor, constant: -Spacing.sm).withPriority(.defaultHigh),
            bar.bottomAnchor.constraint(lessThanOrEqualTo: host.topAnchor, constant: frame.maxY),
            band.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            band.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            band.topAnchor.constraint(equalTo: bar.topAnchor, constant: -Spacing.sm),
            band.bottomAnchor.constraint(equalTo: guide.topAnchor, constant: Spacing.xl),
        ])
        host.layoutIfNeeded()
        source.alpha = 0
        bar.focusComposer()
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
        band.removeFromSuperview()
        host.removeFromSuperview()
        source?.alpha = 1
    }
}

/// A view that takes no touch of its own: only its subviews do.
private final class PassThroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
