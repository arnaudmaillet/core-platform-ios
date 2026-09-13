import DesignSystem
import UIKit

/// The reserved strip between the toolbar and the page indicator, where an
/// editing control is put when a category needs one — a row of filters, say.
///
/// ```
/// │      the media, filling the canvas      │
/// │  • • • • •                              │  ← page indicator, pushed up
/// │ ▣▣▣▣▣▣▣▣▣▣▣▣▣▣▣▣▣▣▣▣▣▣▣▣▣▣▣▣▣▣▣▣▣▣▣▣▣▣ │  ← this band, full width
/// │ ⊕ Add a song  Effects Text Stickers ░░  │  ← the stack's toolbar
/// ```
///
/// **It is a HOST, not a control.** It owns placement and nothing else: no
/// background, no material, no padding of its own beyond the gap above its
/// content. Whatever is shown inside brings its own look — a horizontal scroller
/// of filter thumbnails is the first intended tenant.
///
/// ⚠️ **NO BACKGROUND, DELIBERATELY.** The canvas runs full-bleed underneath and
/// the media is the subject; a plate here would cut the picture in two. This is
/// the opposite choice from `InlineFilterTrayView`, which exists precisely to
/// supply glass — do not reach for that one here.
///
/// ⚠️ **THE GAP LIVES INSIDE THE BAND, AND THAT IS WHAT KEEPS AN EMPTY ONE
/// INVISIBLE TO LAYOUT.** The indicator anchors to `topAnchor` with no constant
/// of its own. Were the gap stated on the indicator's constraint instead, an
/// empty band of zero height would still push it 8pt down from where it sits
/// today — a silent regression on the single-medium screen, which has no
/// indicator at all to reveal it. Empty, this band reproduces the previous
/// geometry exactly; filled, it grows by its content plus one gap.
@MainActor
final class MediaEditorBandView: UIView {
    /// Collapses the band when it holds nothing. Deactivated while content is in.
    private var collapsed: NSLayoutConstraint!

    private(set) var content: UIView?

    init() {
        super.init(frame: .zero)
        // A host, not a surface: the media shows through everywhere it is not
        // covered by its tenant.
        backgroundColor = .clear
        isHidden = true
        collapsed = heightAnchor.constraint(equalToConstant: 0)
        collapsed.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Puts a control in the band, replacing whatever was there.
    func show(_ view: UIView) {
        clear()
        content = view
        view.constrain(in: self) { band in
            view.leadingAnchor.constraint(equalTo: band.leadingAnchor)
            view.trailingAnchor.constraint(equalTo: band.trailingAnchor)
            // The gap the indicator would otherwise have to state. See the type
            // comment for why it belongs here.
            view.topAnchor.constraint(equalTo: band.topAnchor, constant: Spacing.sm)
            view.bottomAnchor.constraint(equalTo: band.bottomAnchor)
        }
        collapsed.isActive = false
        isHidden = false
    }

    /// Empties the band and takes its height back.
    func clear() {
        content?.removeFromSuperview()
        content = nil
        collapsed.isActive = true
        isHidden = true
    }

    /// Internal for tests: whether the band is standing open.
    var debugIsShowing: Bool { !isHidden && content != nil }
}
