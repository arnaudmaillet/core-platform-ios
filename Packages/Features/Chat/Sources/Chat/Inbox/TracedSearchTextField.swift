import UIKit

/// A `UISearchTextField` that reports every layout pass it is put through,
/// timestamped from the moment search was activated.
///
/// It exists for one question: the search field's magnifier and placeholder rise
/// ~8pt roughly 400ms after activation — after the 300ms crossfade has finished —
/// and neither focusing earlier nor forcing a layout before the animation moved
/// it. A pass that late has a cause, and guessing at it twice was enough.
final class TracedSearchTextField: UISearchTextField {
    /// Set when search is activated; nil silences the trace.
    var activatedAt: CFTimeInterval?

    private var lastGlyphY: CGFloat = .nan

    override func layoutSubviews() {
        super.layoutSubviews()
        #if DEBUG
        // ⚠️ Logged even OFF-WINDOW. Guarding on `window` hid every pass before
        // the title view was installed — which is exactly the window the morph
        // animates through, and the only one left unaccounted for.
        guard let activatedAt else { return }
        let elapsed = (CACurrentMediaTime() - activatedAt) * 1000
        let reference: UIView = window ?? self
        let glyph = leftView.map { $0.convert($0.bounds, to: reference) } ?? .null
        let moved = lastGlyphY.isNaN ? 0 : glyph.midY - lastGlyphY
        lastGlyphY = glyph.midY
        print(String(format:
            "[field-layout] t=%4.0fms self=%.0f,%.0f %.0fx%.0f slot=%.0fx%.0f "
            + "glyphY=%.1f moved=%+.1f inWindow=%.0f slotH=%.0f",
            elapsed, frame.minX, frame.minY, frame.width, frame.height,
            superview?.bounds.width ?? -1, superview?.bounds.height ?? -1,
            glyph.midY, moved,
            window == nil ? -1 : 1,
            (superview?.superview?.bounds.height) ?? -1))
        #endif
    }
}
